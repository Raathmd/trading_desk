defmodule TradingDesk.Seeds.NH3ContractSeed do
  @moduledoc """
  Seeds 5 representative NH3 contracts covering both sides of the ammonia book.

  ## Business context

  Trammo moves anhydrous ammonia (NH3) from two Gulf Coast terminals:
    - Donaldsonville, LA  (CF Industries plant — primary supply)
    - Geismar, LA         (Koch Nitrogen — secondary/spot supply)

  ...north on the Mississippi River to:
    - St. Louis, MO       (agricultural interior — spring demand)
    - Memphis, TN         (mid-South distribution — year-round)

  ## Contracts seeded

    1. CF Industries Holdings    — Long Term FOB Purchase at Donaldsonville (supplier)
    2. Koch Nitrogen Company     — Spot FOB Purchase at Geismar (supplier)
    3. The Mosaic Company        — Spot Multimodal Sale, St. Louis (customer)
    4. Nutrien Ltd               — Spot Multimodal Sale, Memphis (customer)
    5. J.R. Simplot Company      — Annual Supply Agreement, multi-point (customer)

  ## Clause ↔ solver variable mapping

  Every LP-relevant clause carries a `parameter`, `operator`, and `value` that
  express how the clause constrains or interacts with a solver variable:

    PRICE (purchase)          → :nola_buy,   :<=,     max $/ton we pay supplier
    PRICE (sale StL)          → :sell_stl,   :>=,     min $/ton we receive at StL
    PRICE (sale Mem)          → :sell_mem,   :>=,     min $/ton we receive at Mem
    QUANTITY_TOLERANCE        → :inv_mer/:inv_nio, :between, shipment volume range (tons)
    LAYTIME_DEMURRAGE         → :lock_hrs,   :<=,     free hours before penalty accrues;
                                                       penalty_per_unit = demurrage $/hr
    PORTS_AND_SAFE_BERTH      → :river_stage, :>=,    minimum river stage for safe berth (ft)
    PAYMENT                   → :working_cap, :>=,    capital required for LC/TT ($)
    FORCE_MAJEURE             → :mer_outage/:nio_outage, :==, 1.0 = FM trigger condition
    PRODUCT_AND_SPECS         → :temp_f,     :<=,     max temp for NH3 integrity (°F)
    DATES_WINDOWS_NOMINATIONS → :barge_count, :>=,    barges needed to meet schedule
    INSPECTION_AND_QTY_DET.   → :inv_mer/:inv_nio, :>=, inspector quantity basis (tons)

  Non-LP clauses (legal, compliance, vessel ops) are included with nil parameter
  to give completeness scores and document the full contract structure.

  ## Usage

      # Run once after migrations and clause template seed:
      TradingDesk.Seeds.NH3ContractSeed.run()

      # Or from Mix:
      mix run -e "TradingDesk.Seeds.NH3ContractSeed.run()"

  Idempotent — skips contracts that are already active in the store.
  """

  require Logger

  alias TradingDesk.Contracts.{Contract, Clause, Store}
  alias TradingDesk.DB.Writer

  @now DateTime.utc_now()
  @today Date.utc_today()

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc "Return the 5 NH3 contract structs without ingesting them (useful for testing)."
  def seed_contracts, do: contracts()

  @doc "Seed all 5 NH3 contracts. Idempotent."
  def run do
    results =
      contracts()
      |> Enum.map(&ingest_contract/1)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    skip_count = Enum.count(results, &match?(:skipped, &1))

    Logger.info(
      "NH3ContractSeed: #{ok_count} contracts seeded, #{skip_count} already present"
    )

    :ok
  end

  # ──────────────────────────────────────────────────────────
  # INGEST
  # ──────────────────────────────────────────────────────────

  defp ingest_contract(%Contract{} = contract) do
    # Skip if already active — seed is idempotent
    case Store.get_active(contract.counterparty, contract.product_group) do
      {:ok, _existing} ->
        Logger.debug("NH3ContractSeed: #{contract.counterparty} already active, skipping")
        :skipped

      _ ->
        case Store.ingest(contract) do
          {:ok, versioned} ->
            Writer.persist_contract(versioned)
            Logger.info("NH3ContractSeed: seeded #{versioned.counterparty} v#{versioned.version} (#{versioned.family_id})")
            {:ok, versioned}

          {:error, reason} ->
            Logger.error("NH3ContractSeed: failed to seed #{contract.counterparty}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  rescue
    e ->
      Logger.error("NH3ContractSeed: crash seeding #{contract.counterparty}: #{Exception.message(e)}")
      {:error, e}
  end

  # ──────────────────────────────────────────────────────────
  # CONTRACT DEFINITIONS
  # ──────────────────────────────────────────────────────────

  defp contracts do
    [
      cf_industries_long_term_purchase(),
      koch_nitrogen_spot_purchase(),
      mosaic_spot_sale_stl(),
      nutrien_spot_sale_mem(),
      simplot_annual_supply()
    ]
  end

  # ── 1. CF INDUSTRIES HOLDINGS — Long Term FOB Purchase, Donaldsonville ──────

  defp cf_industries_long_term_purchase do
    # Annual commitment: ~120,000 MT/yr; current remaining open position 42,000 MT.
    # Pricing: Fertecon weekly NH3 reference + $5/MT premium.
    # Payment: irrevocable LC, 30 days from B/L date.
    # Laytime: 400 MT/hr; demurrage USD 22,500/day ($937.50/hr).
    # Draft guarantee: Donaldsonville dock rated to 40 ft; river_stage >= 9 ft required
    #   for safe approach to CH-2 berth.
    # ASBATANKVOY incorporated; English law / LMAA arbitration.
    # SAP: TRAMMO-LTP-2026-0001

    %Contract{
      counterparty:      "CF Industries Holdings, Inc.",
      counterparty_type: :supplier,
      product_group:     :ammonia,
      template_type:     :purchase,
      incoterm:          :fob,
      term_type:         :long_term,
      company:           :trammo_inc,
      status:            :approved,
      contract_number:   "TRAMMO-LTP-2026-0001",
      family_id:         "LONG_TERM_PURCHASE_FOB",
      contract_date:     ~D[2026-01-01],
      expiry_date:       ~D[2026-12-31],
      sap_contract_id:   "4700001001",
      sap_validated:     true,
      open_position:     42_000.0,
      source_file:       "CF_Industries_LTP_FOB_2026_v1.docx",
      source_format:     :docx,
      scan_date:         @now,
      reviewed_by:       "legal@trammo.com",
      reviewed_at:       @now,
      review_notes:      "Reviewed and approved. Fertecon index clause confirmed with market desk.",
      verification_status: :verified,
      last_verified_at:  @now,
      network_path:      "\\\\trammo-sp\\Contracts\\Ammonia\\Purchase\\CF_Industries_LTP_2026",
      created_at:        @now,
      updated_at:        @now,
      template_validation: %{
        "family" => "LONG_TERM_PURCHASE_FOB",
        "expected_clauses" => 20,
        "found_clauses" => 20,
        "completeness_pct" => 100.0,
        "missing" => []
      },
      clauses: [
        # ── LP-RELEVANT CLAUSES ──────────────────────────────

        # PRICE: Max we pay CF per MT. Fertecon reference ≈ $360; seed with
        # current cap of $365/MT. Solver: nola_buy <= 365 for this contract to be
        # profitable after freight. If nola_buy > 365, CF contract is underwater.
        clause("PRICE", :price_term, :commercial,
          "Price shall be the Fertecon weekly NH3 reference price plus USD 5.00 per Metric Ton, " <>
          "FOB Donaldsonville, Louisiana. Price shall not exceed USD 365.00/MT.",
          parameter: :nola_buy,
          operator:  :<=,
          value:     365.0,
          unit:      "$/MT",
          period:    :spot,
          confidence: :high,
          anchors:   ["Price", "US $", "Fertecon"],
          fields:    %{"price_value" => 365.0, "price_uom" => "$/MT",
                       "pricing_mechanism" => "fertecon_weekly_plus_premium",
                       "premium" => 5.0, "cap" => 365.0}
        ),

        # QUANTITY_TOLERANCE: Annual 120,000 MT ±5% seller's option.
        # Each shipment 10,000–12,000 MT. Solver: inv_mer must absorb these draws.
        # between constraint expresses a single-shipment volume window.
        clause("QUANTITY_TOLERANCE", :obligation, :core_terms,
          "Annual quantity: 120,000 Metric Tons (+/- 5% in Seller's option). " <>
          "Individual shipments: 10,000 MT minimum, 12,000 MT maximum per cargo.",
          parameter:  :inv_mer,
          operator:   :between,
          value:      10_000.0,
          value_upper: 12_000.0,
          unit:       "MT",
          period:     :annual,
          confidence: :high,
          anchors:    ["Quantity", "+/-", "more or less"],
          fields:     %{"qty" => 120_000.0, "uom" => "MT", "tolerance_pct" => 5.0,
                        "option_holder" => "seller", "shipment_min" => 10_000.0,
                        "shipment_max" => 12_000.0}
        ),

        # TAKE_OR_PAY: Annual minimum lift obligation. If Trammo lifts less than
        # 114,000 MT (95% floor of 120,000 MT), Trammo owes CF a shortfall payment
        # of $365/MT on unlifted volume within 30 days of year-end.
        # Solver: committed_lift_mer >= 10,000 MT per shipment (matching QUANTITY_TOLERANCE
        # lower bound). This sets the minimum throughput on the supply_mer constraint so
        # the optimizer must route at least 10,000 MT from Meredosia when CF is active.
        # Annual floor (114,000 MT) is captured in extracted_fields for exposure reporting.
        # penalty_cap: 24,000 MT × $365 = $8,760,000 (20% max shortfall exposure).
        clause("TAKE_OR_PAY", :obligation, :commercial,
          "Take-or-Pay: Trammo commits to lift minimum 114,000 Metric Tons per contract " <>
          "year (95% of 120,000 MT committed volume, Seller's option applies to upper band). " <>
          "If annual off-take falls below 114,000 MT, Trammo shall pay CF Industries " <>
          "USD 365.00 per Metric Ton of shortfall (\"take-or-pay payment\") within " <>
          "30 days of year-end. Make-whole obligation survives contract expiry for the " <>
          "relevant contract year. Force Majeure volume shortfalls excluded from calculation.",
          parameter:        :committed_lift_mer,
          operator:         :>=,
          value:            10_000.0,
          unit:             "MT",
          period:           :annual,
          confidence:       :high,
          penalty_per_unit: 365.0,
          penalty_cap:      8_760_000.0,
          anchors:          ["Take or Pay", "minimum off-take", "shortfall payment",
                             "Annual Commitment", "take-or-pay"],
          fields:           %{
            "annual_committed_mt"      => 120_000.0,
            "annual_floor_pct"         => 95.0,
            "annual_floor_mt"          => 114_000.0,
            "per_shipment_floor_mt"    => 10_000.0,
            "shortfall_rate_per_mt"    => 365.0,
            "payment_terms_days"       => 30,
            "measurement_period"       => "calendar_year",
            "surviving_obligation"     => true,
            "fm_volume_excluded"       => true,
            "open_position_mt"         => 42_000.0
          }
        ),

        # DATES_WINDOWS_NOMINATIONS: Quarterly delivery plan + monthly nominations.
        # Solver: barge_count >= 3 to handle 10,000-MT shipments on a ~20-day cycle.
        clause("DATES_WINDOWS_NOMINATIONS", :delivery, :logistics,
          "Shipments shall be nominated quarterly with monthly sub-nominations. " <>
          "Buyer shall provide 14 days loading notice. Minimum 3 barges required " <>
          "per shipment to accommodate 10,000 MT cargo sizes.",
          parameter:  :barge_count,
          operator:   :>=,
          value:      3.0,
          unit:       "barges",
          period:     :quarterly,
          confidence: :medium,
          anchors:    ["Shipments / nominations", "Nominations and Notices", "Loading Dates"],
          fields:     %{"nomination_timeline" => "14_days_loading_notice",
                        "loading_dates" => "quarterly_plan_monthly_sub",
                        "min_barges_per_shipment" => 3}
        ),

        # PAYMENT: Irrevocable confirmed LC. Capital locked from cargo readiness
        # until 30 days post-B/L. At $365/MT × 11,000 MT avg = $4,015,000.
        # Solver: working_cap >= 4,015,000 to open LC for each shipment.
        clause("PAYMENT", :obligation, :commercial,
          "Payment by irrevocable, confirmed Letter of Credit, opened 10 banking days " <>
          "prior to first loading date, valid 30 days after Bill of Lading date. " <>
          "LC amount: contract price × shipment quantity.",
          parameter:  :working_cap,
          operator:   :>=,
          value:      4_015_000.0,
          unit:       "$",
          period:     :spot,
          confidence: :high,
          anchors:    ["Payment", "letter of credit"],
          fields:     %{"payment_method" => "LC", "days_from_bl_or_delivery" => 30,
                        "lc_terms" => "irrevocable_confirmed",
                        "lc_open_days_prior" => 10,
                        "docs_required" => ["bill_of_lading", "quality_cert", "quantity_cert"]}
        ),

        # LAYTIME_DEMURRAGE: 400 MT/hr loading rate; laytime = B/L qty ÷ 400.
        # For 11,000 MT: allowed = 27.5 hrs. Demurrage USD 22,500/day ($937.50/hr).
        # Solver: lock_hrs represents additional delay beyond planned transit.
        # If lock_hrs exceeds free laytime buffer, demurrage accrues at $937.50/hr.
        # value = 24.0 hrs free allowance built into freight rate; beyond = penalty.
        clause("LAYTIME_DEMURRAGE", :penalty, :logistics_cost,
          "Laytime: Bill of Lading quantity divided by 400 Metric Tons per hour, " <>
          "SHINC. Demurrage: USD 22,500 per day (USD 937.50/hr) pro rata. " <>
          "Claims must be submitted within 90 days of completion of discharge. " <>
          "ASBATANKVOY charterparty provisions apply where not stated herein.",
          parameter:       :lock_hrs,
          operator:        :<=,
          value:           24.0,
          unit:            "hours",
          penalty_per_unit: 937.50,
          penalty_cap:     112_500.0,
          confidence:      :high,
          anchors:         ["Laytime", "Demurrage", "per day or pro rata",
                            "Discharge Rate and Demurrage"],
          fields:          %{"rate_mt_per_hr" => 400.0,
                             "allowed_laytime_formula" => "BL_qty / 400",
                             "demurrage_rate" => 22_500.0,
                             "charterparty_alt" => "ASBATANKVOY",
                             "claim_deadline_days" => 90}
        ),

        # PORTS_AND_SAFE_BERTH: Seller guarantees safe berth at Donaldsonville.
        # CH-2 berth requires minimum 9 ft river stage for safe approach.
        # Solver: river_stage >= 9.0 is a hard load-feasibility condition.
        clause("PORTS_AND_SAFE_BERTH", :condition, :logistics,
          "Port of Loading: Donaldsonville, Louisiana, CH-2 berth or as nominated. " <>
          "Seller guarantees one safe port, one safe berth, always afloat. " <>
          "Minimum river stage 9.0 feet required for safe berth approach. " <>
          "Seller warrants maximum draft of 9 feet at load berth.",
          parameter:  :river_stage,
          operator:   :>=,
          value:      9.0,
          unit:       "ft",
          confidence: :high,
          anchors:    ["Port(s) of Loading", "One safe berth", "draft"],
          fields:     %{"load_port" => "Donaldsonville, LA",
                        "safe_port_safe_berth" => true,
                        "draft_guarantee" => 9.0,
                        "min_river_stage" => 9.0}
        ),

        # PRODUCT_AND_SPECS: NH3 must be refrigerated grade, stored ≤ -27°F (-33°C).
        # Solver: temp_f <= -27.0 is the product integrity condition. If ambient
        # temperatures push storage above this, the product specification is breached.
        clause("PRODUCT_AND_SPECS", :compliance, :core_terms,
          "Product: Anhydrous Ammonia, refrigerated grade. Purity min 99.5% NH3 by weight. " <>
          "Water max 0.2%, Oil max 5 ppm. Storage temperature: maximum -27°F (-33°C). " <>
          "Specification per CF Industries Certificate of Analysis at load port.",
          parameter:  :temp_f,
          operator:   :<=,
          value:      -27.0,
          unit:       "°F",
          confidence: :high,
          anchors:    ["Product Specifications", "Specifications"],
          fields:     %{"product_name" => "Anhydrous Ammonia, refrigerated",
                        "temp_requirement" => -27.0,
                        "purity" => 99.5, "water" => 0.2, "oil" => 5.0}
        ),

        # INSPECTION_AND_QTY_DETERMINATION: Load-port inspector appoints quantity
        # and quality basis. B/L qty is final and binding for freight/demurrage.
        # Solver: inv_mer >= 10,000 at time of loading to satisfy minimum shipment.
        clause("INSPECTION_AND_QTY_DETERMINATION", :condition, :determination,
          "Independent inspector appointed by Buyer at Buyer's cost. Quality and " <>
          "quantity determined at load port; Bill of Lading quantity final and binding. " <>
          "Minimum loadable inventory at Donaldsonville: 10,000 MT.",
          parameter:  :inv_mer,
          operator:   :>=,
          value:      10_000.0,
          unit:       "MT",
          confidence: :high,
          anchors:    ["Inspection", "independent inspector", "bill of lading quantity"],
          fields:     %{"inspector_appointer" => "buyer",
                        "cost_split" => "buyer_pays",
                        "qty_basis" => "bill_of_lading",
                        "quality_basis" => "load_port_cert"}
        ),

        # FORCE_MAJEURE: Dock outage at Donaldsonville triggers FM; obligations
        # suspended for duration. Seller must notify within 48 hrs.
        # Solver: mer_outage = 1.0 modelled as FM condition (StL outage prevents delivery).
        # (Meredosia terminal outage is modelled via mer_outage; trader-toggled.)
        clause("FORCE_MAJEURE", :condition, :risk_events,
          "Force Majeure includes: Acts of God, war, strikes, government action, " <>
          "terminal or dock closure beyond the party's control. Party invoking FM " <>
          "must notify within 48 hours. Laytime and demurrage obligations are not " <>
          "affected by Force Majeure unless dock is physically inaccessible.",
          parameter:  :mer_outage,
          operator:   :==,
          value:      1.0,
          unit:       "",
          confidence: :medium,
          anchors:    ["Force Majeure", "notify", "cancel"],
          fields:     %{"notice_period" => "48_hours",
                        "remedies" => "suspend_obligations",
                        "demurrage_interaction" => "not_affected_unless_dock_inaccessible"}
        ),

        # DELIVERY_SCHEDULE_TERMS: Quarterly delivery commitments with late penalty.
        # Extracted by DeliverySchedule.from_contract/1 to calculate penalty exposure.
        clause("DELIVERY_SCHEDULE_TERMS", :delivery, :logistics,
          "Quarterly delivery commitment: minimum 10,000 Metric Tons per loading window " <>
          "as nominated. Each delivery window is open for 14 days from the scheduled " <>
          "nomination date. Grace period: 5 business days before late delivery penalties " <>
          "accrue. Late delivery penalty: USD 2.50 per Metric Ton per day of delay " <>
          "beyond grace period. Penalty cap: 10% of affected shipment invoice value.",
          fields: %{
            "scheduled_qty_mt"       => 10_000.0,
            "frequency"              => "quarterly",
            "delivery_window_days"   => 14,
            "grace_period_days"      => 5,
            "penalty_per_mt_per_day" => 2.50,
            "penalty_cap_pct"        => 10.0,
            "next_window_days"       => 30
          }
        ),

        # ── NON-LP CLAUSES (legal, compliance, vessel ops) ──

        clause("INCOTERMS", :metadata, :metadata,
          "INCOTERMS 2020 — FOB Donaldsonville, Louisiana.",
          anchors: ["INCOTERMS 2020"],
          fields:  %{"incoterm" => "FOB", "place" => "Donaldsonville, LA"}
        ),

        clause("CHARTERPARTY_ASBATANKVOY_INCORP", :legal, :incorporation,
          "ASBATANKVOY tanker voyage charterparty incorporated by reference. " <>
          "Where Seller acts as Owner and Buyer as Charterer for purposes of this clause.",
          anchors: ["ASBATANKVOY", "Charter Party", "incorporated by reference"],
          fields:  %{"charterparty_form" => "ASBATANKVOY",
                     "role_mapping_owner_charterer" => "seller=owner, buyer=charterer"}
        ),

        clause("NOR_AND_READINESS", :operational, :operational,
          "Notice of Readiness to be tendered when vessel is ready in all respects " <>
          "to load. NOR tendered at berth WIBON. Laytime commences 6 hours after " <>
          "valid NOR or upon commencement of loading, whichever is earlier.",
          anchors: ["Notice of Readiness", "NOR"],
          fields:  %{"nor_rules" => "WIBON",
                     "earliest_nor_time" => "at_berth",
                     "laytime_commencement_rule" => "6hrs_after_NOR_or_loading_start"}
        ),

        clause("PRESENTATION_COOLDOWN_GASSING", :operational, :operational,
          "Vessel cargo tanks must be pre-cooled and inerted before loading. " <>
          "NH3 used for cool-down and gassing at Seller's expense and for Seller's account. " <>
          "Time for cool-down counts as laytime.",
          anchors: ["Presentation", "cool down", "purging", "gassing"],
          fields:  %{"tank_condition_required" => "pre_cooled_inerted",
                     "who_pays_ammonia_used" => "seller",
                     "time_counts_or_excluded" => "counts_as_laytime"}
        ),

        clause("VESSEL_ELIGIBILITY", :compliance, :compliance,
          "Vessel must be IACS classed, P&I insured (IGP&I member), ISPS and MTSA " <>
          "compliant, and acceptable to CF Industries terminal. Seller may reject " <>
          "vessel at sole discretion if terminal standards not met.",
          anchors: ["Vessel Classification and Eligibility", "IACS", "P&I", "ISPS", "USCG"],
          fields:  %{"class_requirements" => "IACS",
                     "pandi_requirement" => "IGP&I_member",
                     "terminal_acceptance" => "CF_Industries_approval",
                     "rejection_rights" => "seller_sole_discretion"}
        ),

        clause("DOCUMENTS_AND_CERTIFICATES", :legal, :documentation,
          "Seller to provide: 3/3 original Bills of Lading, Certificate of Origin, " <>
          "Quality Certificate, Quantity Certificate, Safety Data Sheet. " <>
          "Documents to be presented to Buyer within 5 banking days of B/L date.",
          anchors: ["Documents", "certificate of origin", "shipping documents"],
          fields:  %{"required_docs" => ["bill_of_lading_3x3", "certificate_of_origin",
                                          "quality_cert", "quantity_cert", "sds"],
                     "where_delivered" => "buyer_5_banking_days_post_bl"}
        ),

        clause("TAXES_FEES_DUES", :price_term, :commercial,
          "All taxes, duties and dues levied on the cargo at load port for Seller's account. " <>
          "Any import duties or taxes at discharge port for Buyer's account. " <>
          "US export licence and compliance for Seller's account.",
          anchors: ["Taxes", "Fees", "Dues"],
          fields:  %{"payer" => "split_by_port",
                     "add_to_price_rule" => nil,
                     "deduct_from_price_rule" => nil,
                     "import_duty_responsibility" => "buyer"}
        ),

        clause("EXPORT_IMPORT_REACH", :compliance, :compliance,
          "Both parties warrant that export and import of Anhydrous Ammonia is not " <>
          "prohibited under applicable law. Seller responsible for US export compliance. " <>
          "REACH SDS provided by Seller per EU Regulation 1907/2006.",
          anchors: ["Compliance with Export and Import Laws", "REACH", "Safety Data Sheet"],
          fields:  %{"import_permitted_warranty" => true,
                     "reach_obligations" => "seller_provides_sds",
                     "who_handles_customs" => "each_party_own_jurisdiction"}
        ),

        clause("WAR_RISK_AND_ROUTE_CLOSURE", :condition, :risk_costs,
          "Additional war risk premiums beyond standard P&I for Buyer's account. " <>
          "If Joint War Committee lists load or discharge port as war-risk area, " <>
          "Buyer may cancel or agree additional freight at market rate.",
          anchors: ["War Risk", "Joint War Committee"],
          fields:  %{"war_risk_cost_rule" => "buyer_pays_additional_premium",
                     "route_closure_options" => "cancel_or_additional_freight"}
        ),

        clause("DEFAULT_AND_REMEDIES", :condition, :credit_legal,
          "Event of default: failure to pay within 2 banking days of due date, " <>
          "insolvency, or failure to perform. Non-defaulting party may terminate " <>
          "with 48 hours notice and claim market-price damages. Interest on overdue " <>
          "amounts at SOFR + 3% p.a. Set-off and netting rights preserved.",
          anchors: ["Default", "event of default", "48 hours", "terminate", "interest", "setoff"],
          fields:  %{"events_of_default" => ["non_payment", "insolvency", "non_performance"],
                     "remedies" => "terminate_claim_market_damages",
                     "interest_rate" => "SOFR+3%",
                     "setoff_netting" => true}
        ),

        clause("CLAIMS_NOTICE_AND_LIMITS", :legal, :legal,
          "Quality claims: 15 days from discharge completion. Quantity claims: 15 days. " <>
          "All claims absolutely barred unless submitted in writing within one year " <>
          "of Bill of Lading date. Liability cap: invoice value of affected cargo.",
          anchors: ["Claims", "15 days", "one year", "absolutely barred"],
          fields:  %{"notice_deadline" => "15_days_from_discharge",
                     "limitation_period" => "1_year_from_bl",
                     "caps_on_liability" => "invoice_value"}
        ),

        clause("GOVERNING_LAW_AND_ARBITRATION", :legal, :legal,
          "This Contract shall be governed by English law. Any dispute shall be " <>
          "referred to arbitration in London under LMAA Terms (current edition). " <>
          "Three arbitrators to be appointed per LMAA Small Claims Procedure if " <>
          "claim value below USD 100,000.",
          anchors: ["Arbitration", "Governing Law", "LMAA", "English law"],
          fields:  %{"governing_law" => "English",
                     "forum" => "London_LMAA",
                     "ruleset" => "LMAA_current_edition"}
        ),

        clause("NOTICES", :legal, :legal,
          "All notices to be given in writing by email with read receipt or courier. " <>
          "Deemed given on receipt. Trammo, Inc. notice address: 120 Long Ridge Road, " <>
          "Stamford CT 06902; CF Industries: 4 Parkway N, Deerfield IL 60015.",
          anchors: ["Notices", "deemed to be given", "e-mail"],
          fields:  %{"notice_methods" => ["email_read_receipt", "courier"],
                     "deemed_delivery_rules" => "on_receipt"}
        ),

        clause("MISCELLANEOUS_BOILERPLATE", :legal, :legal,
          "This Contract constitutes the entire agreement. No modification binding " <>
          "unless in writing signed by both parties. Waiver of any breach not a waiver " <>
          "of subsequent breach. Assignment requires prior written consent. " <>
          "Severability: invalid clause does not affect remainder.",
          anchors: ["Miscellaneous", "Entire Agreement", "Modifications", "Waiver",
                    "Assignment", "Severability"],
          fields:  %{"boilerplate_present" => true}
        )
      ]
    }
  end

  # ── 2. KOCH NITROGEN COMPANY — Spot FOB Purchase, Geismar ───────────────────

  defp koch_nitrogen_spot_purchase do
    # Spot cargo: 3,000 MT ±5% seller's option at fixed price.
    # Payment: TT 30 days from B/L date.
    # Laytime: 350 MT/hr; demurrage USD 18,000/day ($750/hr).
    # Geismar dock: minimum 8.0 ft river stage required.
    # English law / LMAA. SAP: TRAMMO-SP-2026-0012.

    %Contract{
      counterparty:      "Koch Nitrogen Company, LLC",
      counterparty_type: :supplier,
      product_group:     :ammonia,
      template_type:     :spot_purchase,
      incoterm:          :fob,
      term_type:         :spot,
      company:           :trammo_inc,
      status:            :approved,
      contract_number:   "TRAMMO-SP-2026-0012",
      family_id:         "VESSEL_SPOT_PURCHASE",
      contract_date:     @today,
      expiry_date:       Date.add(@today, 45),
      sap_contract_id:   "4700001012",
      sap_validated:     true,
      open_position:     3_000.0,
      source_file:       "Koch_Nitrogen_Spot_FOB_Geis_2026_0012.pdf",
      source_format:     :pdf,
      scan_date:         @now,
      reviewed_by:       "legal@trammo.com",
      reviewed_at:       @now,
      verification_status: :verified,
      last_verified_at:  @now,
      network_path:      "\\\\trammo-sp\\Contracts\\Ammonia\\Purchase\\Koch_Spot_2026_0012",
      created_at:        @now,
      updated_at:        @now,
      template_validation: %{
        "family" => "VESSEL_SPOT_PURCHASE",
        "expected_clauses" => 22,
        "found_clauses" => 20,
        "completeness_pct" => 90.9,
        "missing" => ["WAR_RISK_AND_ROUTE_CLOSURE", "PRESENTATION_COOLDOWN_GASSING"]
      },
      clauses: [
        # PRICE: Fixed $342/MT FOB Geismar. Solver: nola_buy <= 342 for this
        # cargo to be profitable (Koch spot is usually below Fertecon reference).
        clause("PRICE", :price_term, :commercial,
          "Price: USD 342.00 per Metric Ton, FOB Geismar, Louisiana. Fixed price. " <>
          "No escalation or index adjustment.",
          parameter:  :nola_buy,
          operator:   :<=,
          value:      342.0,
          unit:       "$/MT",
          period:     :spot,
          confidence: :high,
          anchors:    ["Price", "US $"],
          fields:     %{"price_value" => 342.0, "price_uom" => "$/MT",
                        "pricing_mechanism" => "fixed"}
        ),

        # QUANTITY_TOLERANCE: 3,000 MT ±5% seller's option = 2,850–3,150 MT.
        # Solver: inv_nio between 2,850-3,150 for this shipment.
        clause("QUANTITY_TOLERANCE", :obligation, :core_terms,
          "Quantity: 3,000 Metric Tons (+/- 5% in Seller's option), " <>
          "being approximately 2,850 to 3,150 Metric Tons.",
          parameter:   :inv_nio,
          operator:    :between,
          value:       2_850.0,
          value_upper: 3_150.0,
          unit:        "MT",
          period:      :spot,
          confidence:  :high,
          anchors:     ["Quantity", "+/-", "more or less"],
          fields:      %{"qty" => 3_000.0, "uom" => "MT", "tolerance_pct" => 5.0,
                         "option_holder" => "seller"}
        ),

        # PAYMENT: TT 30 days from B/L. Capital tied up: 3,000 × $342 = $1,026,000.
        # Solver: working_cap >= 1,026,000 outstanding for 30 days.
        clause("PAYMENT", :obligation, :commercial,
          "Payment by Telegraphic Transfer (TT) within 30 days of Bill of Lading date. " <>
          "Buyer to provide bank details 5 days prior to loading.",
          parameter:  :working_cap,
          operator:   :>=,
          value:      1_026_000.0,
          unit:       "$",
          period:     :spot,
          confidence: :high,
          anchors:    ["Payment", "telegraphic transfer"],
          fields:     %{"payment_method" => "TT",
                        "days_from_bl_or_delivery" => 30,
                        "docs_required" => ["bill_of_lading", "quality_cert"]}
        ),

        # LAYTIME_DEMURRAGE: 350 MT/hr; 3,000 MT → 8.57 hrs allowed.
        # Demurrage $18,000/day ($750/hr). Lock delays eat into free laytime.
        # Solver: lock_hrs <= 8.0 hrs free allowance; beyond = $750/hr penalty.
        clause("LAYTIME_DEMURRAGE", :penalty, :logistics_cost,
          "Loading rate: 350 Metric Tons per hour, SHINC. Laytime: B/L quantity " <>
          "divided by 350 MT/hr. Demurrage: USD 18,000 per day pro rata (USD 750.00/hr). " <>
          "Claims submitted within 90 days of loading completion.",
          parameter:        :lock_hrs,
          operator:         :<=,
          value:            8.0,
          unit:             "hours",
          penalty_per_unit: 750.00,
          penalty_cap:      90_000.0,
          confidence:       :high,
          anchors:          ["Laytime", "Demurrage", "per day or pro rata",
                             "Conditions of Loading"],
          fields:           %{"rate_mt_per_hr" => 350.0,
                              "allowed_laytime_formula" => "BL_qty / 350",
                              "demurrage_rate" => 18_000.0,
                              "claim_deadline_days" => 90}
        ),

        # PORTS_AND_SAFE_BERTH: Geismar dock safe at 8.0 ft minimum river stage.
        clause("PORTS_AND_SAFE_BERTH", :condition, :logistics,
          "Port of Loading: Geismar, Louisiana. Seller guarantees one safe port, " <>
          "one safe berth, always afloat. Minimum river stage 8.0 feet for safe berth. " <>
          "Maximum draft at berth: 8 feet.",
          parameter:  :river_stage,
          operator:   :>=,
          value:      8.0,
          unit:       "ft",
          confidence: :high,
          anchors:    ["Port(s) of Loading", "One safe berth", "draft"],
          fields:     %{"load_port" => "Geismar, LA",
                        "safe_port_safe_berth" => true,
                        "draft_guarantee" => 8.0,
                        "min_river_stage" => 8.0}
        ),

        # PRODUCT_AND_SPECS: Same NH3 spec as CF Industries.
        clause("PRODUCT_AND_SPECS", :compliance, :core_terms,
          "Anhydrous Ammonia, refrigerated grade. Purity min 99.5%, Water max 0.2%, " <>
          "Oil max 5 ppm. Temperature at loading: maximum -27°F (-33°C).",
          parameter:  :temp_f,
          operator:   :<=,
          value:      -27.0,
          unit:       "°F",
          confidence: :high,
          anchors:    ["Product Specifications"],
          fields:     %{"product_name" => "Anhydrous Ammonia, refrigerated",
                        "temp_requirement" => -27.0, "purity" => 99.5,
                        "water" => 0.2, "oil" => 5.0}
        ),

        # INSPECTION_AND_QTY_DETERMINATION: Same structure as CF contract.
        clause("INSPECTION_AND_QTY_DETERMINATION", :condition, :determination,
          "Independent inspector appointed and paid by Buyer. Quantity and quality " <>
          "determined at load port, B/L quantity final and binding. " <>
          "Minimum inventory at Geismar: 2,850 MT at time of loading.",
          parameter:  :inv_nio,
          operator:   :>=,
          value:      2_850.0,
          unit:       "MT",
          confidence: :high,
          anchors:    ["Inspection", "independent inspector", "bill of lading quantity"],
          fields:     %{"inspector_appointer" => "buyer", "cost_split" => "buyer_pays",
                        "qty_basis" => "bill_of_lading", "quality_basis" => "load_port_cert"}
        ),

        # FORCE_MAJEURE: Geismar dock outage modelled via mer_outage (general outage proxy).
        clause("FORCE_MAJEURE", :condition, :risk_events,
          "Force Majeure: Acts of God, government action, terminal closure. " <>
          "Notice within 48 hours. Demurrage not tolled unless dock physically inaccessible.",
          parameter:  :mer_outage,
          operator:   :==,
          value:      1.0,
          unit:       "",
          confidence: :medium,
          anchors:    ["Force Majeure", "notify"],
          fields:     %{"notice_period" => "48_hours",
                        "remedies" => "suspend_obligations",
                        "demurrage_interaction" => "not_tolled_unless_dock_inaccessible"}
        ),

        # DELIVERY_SCHEDULE_TERMS: Spot delivery window — currently open.
        clause("DELIVERY_SCHEDULE_TERMS", :delivery, :logistics,
          "Spot delivery: 3,000 Metric Tons within 10-day loading window from contract " <>
          "date. Delivery window currently open. Grace period: 2 business days. " <>
          "Late delivery penalty: USD 3.00 per Metric Ton per day after grace period. " <>
          "Penalty cap: 10% of cargo invoice value.",
          fields: %{
            "scheduled_qty_mt"       => 3_000.0,
            "frequency"              => "spot",
            "delivery_window_days"   => 10,
            "grace_period_days"      => 2,
            "penalty_per_mt_per_day" => 3.00,
            "penalty_cap_pct"        => 10.0,
            "next_window_days"       => 0
          }
        ),

        # Non-LP clauses
        clause("INCOTERMS", :metadata, :metadata,
          "INCOTERMS 2020 — FOB Geismar, Louisiana.",
          anchors: ["INCOTERMS 2020"],
          fields:  %{"incoterm" => "FOB", "place" => "Geismar, LA"}
        ),
        clause("CHARTERPARTY_ASBATANKVOY_INCORP", :legal, :incorporation,
          "ASBATANKVOY incorporated; Seller = Owner, Buyer = Charterer.",
          anchors: ["ASBATANKVOY", "Charter Party"],
          fields:  %{"charterparty_form" => "ASBATANKVOY"}
        ),
        clause("NOR_AND_READINESS", :operational, :operational,
          "NOR at berth WIBON. Laytime commences 6 hours after valid NOR or " <>
          "commencement of loading, whichever earlier.",
          anchors: ["Notice of Readiness", "NOR"],
          fields:  %{"nor_rules" => "WIBON", "laytime_commencement_rule" => "6hrs_after_NOR"}
        ),
        clause("VESSEL_ELIGIBILITY", :compliance, :compliance,
          "IACS class, IGP&I P&I, ISPS/MTSA compliant, Koch terminal acceptable.",
          anchors: ["Vessel Classification and Eligibility", "IACS", "P&I"],
          fields:  %{"class_requirements" => "IACS", "pandi_requirement" => "IGP&I_member",
                     "terminal_acceptance" => "Koch_Nitrogen_approval"}
        ),
        clause("EXPORT_IMPORT_REACH", :compliance, :compliance,
          "Both parties warrant NH3 export/import not prohibited. REACH SDS provided.",
          anchors: ["Compliance with Export and Import Laws", "REACH"],
          fields:  %{"import_permitted_warranty" => true, "reach_obligations" => "seller_provides_sds"}
        ),
        clause("DEFAULT_AND_REMEDIES", :condition, :credit_legal,
          "Default: non-payment, insolvency, non-performance. Terminate with 48 hrs notice. " <>
          "Market-price damages. Interest SOFR+3%. Set-off and netting preserved.",
          anchors: ["Default", "48 hours", "terminate", "setoff"],
          fields:  %{"interest_rate" => "SOFR+3%", "setoff_netting" => true}
        ),
        clause("CLAIMS_NOTICE_AND_LIMITS", :legal, :legal,
          "Quality and quantity claims within 15 days of discharge. " <>
          "All claims barred after one year from B/L date.",
          anchors: ["Claims", "15 days", "one year"],
          fields:  %{"notice_deadline" => "15_days", "limitation_period" => "1_year_from_bl"}
        ),
        clause("GOVERNING_LAW_AND_ARBITRATION", :legal, :legal,
          "English law. LMAA arbitration, London.",
          anchors: ["Arbitration", "Governing Law", "LMAA", "English law"],
          fields:  %{"governing_law" => "English", "forum" => "London_LMAA"}
        ),
        clause("NOTICES", :legal, :legal,
          "Notices by email with read receipt. Deemed given on receipt.",
          anchors: ["Notices", "e-mail"],
          fields:  %{"notice_methods" => ["email_read_receipt"]}
        ),
        clause("MISCELLANEOUS_BOILERPLATE", :legal, :legal,
          "Entire agreement. Written modification only. Severability.",
          anchors: ["Miscellaneous", "Entire Agreement"],
          fields:  %{"boilerplate_present" => true}
        )
      ]
    }
  end

  # ── 3. THE MOSAIC COMPANY — Spot Multimodal Sale, St. Louis ─────────────────

  defp mosaic_spot_sale_stl do
    # Spot sale: 5,000 MT ±5% buyer's option, DAP St. Louis.
    # Payment: TT 10 days from delivery completion.
    # Laytime (barge unloading): 48 free hours; thereafter $208.33/hr ($5,000/day).
    # Sale price: $415/MT DAP St. Louis.
    # GOVERNING LAW: New York / SMA (domestic multimodal template).
    # SAP: TRAMMO-SS-2026-0031

    %Contract{
      counterparty:      "The Mosaic Company",
      counterparty_type: :customer,
      product_group:     :ammonia,
      template_type:     :spot_sale,
      incoterm:          :dap,
      term_type:         :spot,
      company:           :trammo_inc,
      status:            :approved,
      contract_number:   "TRAMMO-SS-2026-0031",
      family_id:         "DOMESTIC_MULTIMODAL_SALE",
      contract_date:     @today,
      expiry_date:       Date.add(@today, 60),
      sap_contract_id:   "4700001031",
      sap_validated:     true,
      open_position:     5_000.0,
      source_file:       "Mosaic_Spot_DAP_StL_2026_0031.docx",
      source_format:     :docx,
      scan_date:         @now,
      reviewed_by:       "legal@trammo.com",
      reviewed_at:       @now,
      verification_status: :verified,
      last_verified_at:  @now,
      network_path:      "\\\\trammo-sp\\Contracts\\Ammonia\\Sales\\Mosaic_Spot_StL_2026_0031",
      created_at:        @now,
      updated_at:        @now,
      template_validation: %{
        "family" => "DOMESTIC_MULTIMODAL_SALE",
        "expected_clauses" => 13,
        "found_clauses" => 13,
        "completeness_pct" => 100.0,
        "missing" => []
      },
      clauses: [
        # PRICE: We must receive >= $415/MT at St. Louis DAP to be profitable.
        # Solver: sell_stl >= 415 for this contract to be serviceable. If sell_stl
        # (market) drops below 415, accepting delivery would produce a loss.
        clause("PRICE", :price_term, :commercial,
          "Price: USD 415.00 per Metric Ton, DAP St. Louis, Missouri. Fixed. " <>
          "Inclusive of all freight, barge, and terminal handling to delivery point.",
          parameter:  :sell_stl,
          operator:   :>=,
          value:      415.0,
          unit:       "$/MT",
          period:     :spot,
          confidence: :high,
          anchors:    ["Price", "US $"],
          fields:     %{"price_value" => 415.0, "price_uom" => "$/MT",
                        "pricing_mechanism" => "fixed_dap"}
        ),

        # QUANTITY_TOLERANCE: 5,000 MT ±5% buyer's option = 4,750–5,250 MT.
        # Solver: inv_mer between 4,750-5,250 (we draw from Meredosia to service Mosaic StL).
        clause("QUANTITY_TOLERANCE", :obligation, :core_terms,
          "Quantity: 5,000 Metric Tons (+/- 5% Buyer's option), " <>
          "being 4,750 to 5,250 Metric Tons DAP St. Louis.",
          parameter:   :inv_mer,
          operator:    :between,
          value:       4_750.0,
          value_upper: 5_250.0,
          unit:        "MT",
          period:      :spot,
          confidence:  :high,
          anchors:     ["Quantity", "+/-", "more or less"],
          fields:      %{"qty" => 5_000.0, "uom" => "MT", "tolerance_pct" => 5.0,
                         "option_holder" => "buyer"}
        ),

        # PAYMENT: TT 10 days from delivery. Capital outstanding: 5,000 × $415 =
        # $2,075,000. Solver: working_cap >= 2,075,000 extended to Mosaic for 10 days.
        clause("PAYMENT", :obligation, :commercial,
          "Payment by Telegraphic Transfer within 10 business days of delivery " <>
          "completion confirmation. Buyer to provide payment instructions 3 days prior.",
          parameter:  :working_cap,
          operator:   :>=,
          value:      2_075_000.0,
          unit:       "$",
          period:     :spot,
          confidence: :high,
          anchors:    ["Payment", "telegraphic transfer"],
          fields:     %{"payment_method" => "TT",
                        "days_from_bl_or_delivery" => 10,
                        "docs_required" => ["delivery_receipt", "quantity_cert"]}
        ),

        # LAYTIME_DEMURRAGE: 48 free hours for barge unloading at St. Louis terminal.
        # Beyond 48 hrs: $5,000/day demurrage ($208.33/hr).
        # Solver: lock_hrs adds to transit time; if total river delays push beyond
        # the 48-hr free window, demurrage accrues. Penalty_per_unit = $208.33/hr.
        clause("LAYTIME_DEMURRAGE", :penalty, :logistics_cost,
          "Buyer allowed 48 hours free time for unloading at St. Louis terminal, " <>
          "commencing upon barge arrival and readiness. Thereafter: USD 5,000 per day " <>
          "(USD 208.33/hr) demurrage for Buyer's account. Seller's barge detention " <>
          "claims submitted within 30 days of completion.",
          parameter:        :lock_hrs,
          operator:         :<=,
          value:            48.0,
          unit:             "hours",
          penalty_per_unit: 208.33,
          penalty_cap:      25_000.0,
          confidence:       :high,
          anchors:          ["Laytime", "Demurrage", "Discharge Rate and Demurrage"],
          fields:           %{"rate_mt_per_hr" => nil,
                              "allowed_laytime_formula" => "48_free_hours_from_arrival",
                              "demurrage_rate" => 5_000.0,
                              "charterparty_alt" => nil,
                              "claim_deadline_days" => 30}
        ),

        # FORCE_MAJEURE: St. Louis dock outage = FM trigger for this delivery.
        # Solver: mer_outage = 1.0 directly represents delivery impossibility at StL.
        clause("FORCE_MAJEURE", :condition, :risk_events,
          "Force Majeure: floods, ice, dock closure, USCG navigation closure, " <>
          "government restriction. St. Louis dock outage declared FM after 24 hours. " <>
          "Party invoking FM must notify within 24 hours. Delivery schedule suspended.",
          parameter:  :mer_outage,
          operator:   :==,
          value:      1.0,
          unit:       "",
          confidence: :high,
          anchors:    ["Force Majeure", "notify", "cancel"],
          fields:     %{"notice_period" => "24_hours",
                        "remedies" => "suspend_delivery_schedule",
                        "demurrage_interaction" => "tolled_during_FM"}
        ),

        # INSPECTION_AND_QTY_DETERMINATION: Certified scale weight at StL terminal.
        # Seller appoints inspector; cost shared 50/50.
        clause("INSPECTION_AND_QTY_DETERMINATION", :condition, :determination,
          "Quantity determined by certified scale weight at St. Louis terminal upon " <>
          "unloading. Seller appoints inspector; cost shared equally. " <>
          "Scale certificate final and binding.",
          parameter:  :inv_mer,
          operator:   :>=,
          value:      4_750.0,
          unit:       "MT",
          confidence: :high,
          anchors:    ["Inspection", "certified scale weight"],
          fields:     %{"inspector_appointer" => "seller",
                        "cost_split" => "50_50",
                        "qty_basis" => "certified_scale_weight",
                        "quality_basis" => "discharge_port_cert"}
        ),

        # DELIVERY_SCHEDULE_TERMS: Spot sale delivery — window currently open.
        clause("DELIVERY_SCHEDULE_TERMS", :delivery, :logistics,
          "Spot delivery commitment: 5,000 Metric Tons within 14-day delivery window, " <>
          "currently open. Grace period: 3 business days after scheduled delivery date " <>
          "before late delivery penalties accrue. " <>
          "Late delivery penalty: USD 4.00 per Metric Ton per day. " <>
          "Penalty cap: 10% of contract value.",
          fields: %{
            "scheduled_qty_mt"       => 5_000.0,
            "frequency"              => "spot",
            "delivery_window_days"   => 14,
            "grace_period_days"      => 3,
            "penalty_per_mt_per_day" => 4.00,
            "penalty_cap_pct"        => 10.0,
            "next_window_days"       => 0
          }
        ),

        # Non-LP clauses
        clause("INCOTERMS", :metadata, :metadata,
          "INCOTERMS 2020 — DAP St. Louis, Missouri.",
          anchors: ["INCOTERMS 2020"],
          fields:  %{"incoterm" => "DAP", "place" => "St. Louis, MO"}
        ),
        clause("PRODUCT_AND_SPECS", :compliance, :core_terms,
          "Anhydrous Ammonia: purity min 99.5%, water max 0.2%, oil max 5 ppm, " <>
          "temperature at delivery max -27°F (-33°C).",
          anchors: ["Product Specifications"],
          fields:  %{"product_name" => "Anhydrous Ammonia", "temp_requirement" => -27.0,
                     "purity" => 99.5}
        ),
        clause("WARRANTY_DISCLAIMER", :legal, :legal,
          "SELLER MAKES NO WARRANTY, EXPRESS OR IMPLIED, AS TO MERCHANTABILITY " <>
          "OR FITNESS FOR PURPOSE BEYOND THE SPECIFICATIONS STATED HEREIN.",
          anchors: ["Disclaimer of Warranties", "MAKES NO WARRANTY"],
          fields:  %{"disclaimer_text_present" => true}
        ),
        clause("DEFAULT_AND_REMEDIES", :condition, :credit_legal,
          "Default: non-payment within 10 business days, insolvency. " <>
          "Non-defaulting party may terminate and claim cover price damages. " <>
          "Interest at SOFR+2.5%. Set-off rights preserved.",
          anchors: ["Default", "terminate", "interest", "setoff"],
          fields:  %{"interest_rate" => "SOFR+2.5%", "setoff_netting" => true}
        ),
        clause("CLAIMS_NOTICE_AND_LIMITS", :legal, :legal,
          "Quality claims within 15 days of delivery. Quantity claims within 15 days. " <>
          "All claims barred after 90 calendar days of delivery date.",
          anchors: ["Claims", "15 days", "90 calendar days", "absolutely barred"],
          fields:  %{"notice_deadline" => "15_days_from_delivery",
                     "limitation_period" => "90_calendar_days"}
        ),
        clause("GOVERNING_LAW_AND_ARBITRATION", :legal, :legal,
          "New York law. SMA arbitration, New York.",
          anchors: ["Arbitration", "Governing Law", "SMA", "New York"],
          fields:  %{"governing_law" => "New_York", "forum" => "New_York_SMA",
                     "ruleset" => "SMA_current"}
        ),
        clause("NOTICES", :legal, :legal,
          "Notices by email; deemed given upon transmission with delivery receipt.",
          anchors: ["Notices", "e-mail"],
          fields:  %{"notice_methods" => ["email"]}
        ),
        clause("MISCELLANEOUS_BOILERPLATE", :legal, :legal,
          "Entire agreement. Written modification only. Assignment with consent. Severability.",
          anchors: ["Miscellaneous", "Entire Agreement"],
          fields:  %{"boilerplate_present" => true}
        )
      ]
    }
  end

  # ── 4. NUTRIEN LTD — Spot Multimodal Sale, Memphis ──────────────────────────

  defp nutrien_spot_sale_mem do
    # Spot sale: 4,000 MT ±5% buyer's option, DAP Memphis.
    # Payment: LC at sight.
    # Laytime: 36 free hours; thereafter $5,000/day ($208.33/hr).
    # Sale price: $388/MT DAP Memphis.
    # Primary inventory draw: Geismar (shorter route to Memphis).
    # SAP: TRAMMO-SS-2026-0044

    %Contract{
      counterparty:      "Nutrien Ltd",
      counterparty_type: :customer,
      product_group:     :ammonia,
      template_type:     :spot_sale,
      incoterm:          :dap,
      term_type:         :spot,
      company:           :trammo_inc,
      status:            :approved,
      contract_number:   "TRAMMO-SS-2026-0044",
      family_id:         "DOMESTIC_MULTIMODAL_SALE",
      contract_date:     @today,
      expiry_date:       Date.add(@today, 45),
      sap_contract_id:   "4700001044",
      sap_validated:     true,
      open_position:     4_000.0,
      source_file:       "Nutrien_Spot_DAP_Mem_2026_0044.docx",
      source_format:     :docx,
      scan_date:         @now,
      reviewed_by:       "legal@trammo.com",
      reviewed_at:       @now,
      verification_status: :verified,
      last_verified_at:  @now,
      network_path:      "\\\\trammo-sp\\Contracts\\Ammonia\\Sales\\Nutrien_Spot_Mem_2026_0044",
      created_at:        @now,
      updated_at:        @now,
      template_validation: %{
        "family" => "DOMESTIC_MULTIMODAL_SALE",
        "expected_clauses" => 13,
        "found_clauses" => 13,
        "completeness_pct" => 100.0,
        "missing" => []
      },
      clauses: [
        # PRICE: Min $388/MT DAP Memphis. Solver: sell_mem >= 388. If market sell_mem
        # drops below 388, honouring this contract locks in a loss on the Memphis leg.
        clause("PRICE", :price_term, :commercial,
          "Price: USD 388.00 per Metric Ton, DAP Memphis, Tennessee. Fixed price. " <>
          "Inclusive of all freight and terminal handling to Memphis delivery point.",
          parameter:  :sell_mem,
          operator:   :>=,
          value:      388.0,
          unit:       "$/MT",
          period:     :spot,
          confidence: :high,
          anchors:    ["Price", "US $"],
          fields:     %{"price_value" => 388.0, "price_uom" => "$/MT",
                        "pricing_mechanism" => "fixed_dap"}
        ),

        # QUANTITY_TOLERANCE: 4,000 MT ±5% buyer's option = 3,800–4,200 MT.
        # Primary draw from Geismar (shorter haul to Memphis vs. Don).
        clause("QUANTITY_TOLERANCE", :obligation, :core_terms,
          "Quantity: 4,000 Metric Tons (+/- 5% Buyer's option), " <>
          "being 3,800 to 4,200 Metric Tons DAP Memphis, Tennessee.",
          parameter:   :inv_nio,
          operator:    :between,
          value:       3_800.0,
          value_upper: 4_200.0,
          unit:        "MT",
          period:      :spot,
          confidence:  :high,
          anchors:     ["Quantity", "+/-", "more or less"],
          fields:      %{"qty" => 4_000.0, "uom" => "MT", "tolerance_pct" => 5.0,
                         "option_holder" => "buyer"}
        ),

        # PAYMENT: LC at sight. Capital locked: 4,000 × $388 = $1,552,000.
        # Solver: working_cap >= 1,552,000 to open and maintain LC.
        clause("PAYMENT", :obligation, :commercial,
          "Payment by irrevocable Letter of Credit, payable at sight against " <>
          "delivery documents. LC to be opened 5 banking days prior to vessel arrival.",
          parameter:  :working_cap,
          operator:   :>=,
          value:      1_552_000.0,
          unit:       "$",
          period:     :spot,
          confidence: :high,
          anchors:    ["Payment", "letter of credit"],
          fields:     %{"payment_method" => "LC_at_sight",
                        "lc_terms" => "irrevocable_sight",
                        "docs_required" => ["delivery_receipt", "quantity_cert", "quality_cert"]}
        ),

        # LAYTIME_DEMURRAGE: 36 free hours at Memphis terminal; $5,000/day thereafter.
        # Memphis gets shorter free time than StL given shorter river transit.
        # Lock delays on the lower Mississippi directly eat into this window.
        clause("LAYTIME_DEMURRAGE", :penalty, :logistics_cost,
          "Buyer allowed 36 hours free time at Memphis terminal from barge readiness. " <>
          "Demurrage thereafter: USD 5,000 per day (USD 208.33/hr) for Buyer's account. " <>
          "Claims within 30 days of discharge completion.",
          parameter:        :lock_hrs,
          operator:         :<=,
          value:            36.0,
          unit:             "hours",
          penalty_per_unit: 208.33,
          penalty_cap:      25_000.0,
          confidence:       :high,
          anchors:          ["Laytime", "Demurrage", "Discharge and Demurrage Rates"],
          fields:           %{"rate_mt_per_hr" => nil,
                              "allowed_laytime_formula" => "36_free_hours_from_readiness",
                              "demurrage_rate" => 5_000.0,
                              "claim_deadline_days" => 30}
        ),

        # FORCE_MAJEURE: Memphis dock outage directly triggers FM on this contract.
        # Solver: nio_outage = 1.0 is the exact variable that models this condition.
        clause("FORCE_MAJEURE", :condition, :risk_events,
          "Force Majeure: Memphis dock closure, USCG navigation hold, ice, flood, " <>
          "government restriction. FM declared after 24-hour dock outage. " <>
          "Delivery obligations suspended; demurrage tolled during FM period.",
          parameter:  :nio_outage,
          operator:   :==,
          value:      1.0,
          unit:       "",
          confidence: :high,
          anchors:    ["Force Majeure", "notify", "cancel"],
          fields:     %{"notice_period" => "24_hours",
                        "remedies" => "suspend_delivery",
                        "demurrage_interaction" => "tolled_during_FM"}
        ),

        # INSPECTION_AND_QTY_DETERMINATION: Flow meter at Memphis terminal manifold.
        clause("INSPECTION_AND_QTY_DETERMINATION", :condition, :determination,
          "Quantity by flow meter at Memphis terminal manifold, certified by independent " <>
          "inspector appointed jointly. Cost shared equally. Meter certificate final.",
          parameter:  :inv_nio,
          operator:   :>=,
          value:      3_800.0,
          unit:       "MT",
          confidence: :high,
          anchors:    ["Inspection", "flow meter"],
          fields:     %{"inspector_appointer" => "jointly",
                        "cost_split" => "50_50",
                        "qty_basis" => "flow_meter",
                        "quality_basis" => "discharge_cert"}
        ),

        # DELIVERY_SCHEDULE_TERMS: Spot sale delivery to Memphis — window currently open.
        clause("DELIVERY_SCHEDULE_TERMS", :delivery, :logistics,
          "Spot delivery commitment: 4,000 Metric Tons within 10-day delivery window, " <>
          "currently open. Grace period: 2 business days. " <>
          "Late delivery penalty: USD 3.50 per Metric Ton per day after grace period. " <>
          "Penalty cap: 10% of shipment invoice value.",
          fields: %{
            "scheduled_qty_mt"       => 4_000.0,
            "frequency"              => "spot",
            "delivery_window_days"   => 10,
            "grace_period_days"      => 2,
            "penalty_per_mt_per_day" => 3.50,
            "penalty_cap_pct"        => 10.0,
            "next_window_days"       => 0
          }
        ),

        # Non-LP clauses
        clause("INCOTERMS", :metadata, :metadata,
          "INCOTERMS 2020 — DAP Memphis, Tennessee.",
          anchors: ["INCOTERMS 2020"],
          fields:  %{"incoterm" => "DAP", "place" => "Memphis, TN"}
        ),
        clause("PRODUCT_AND_SPECS", :compliance, :core_terms,
          "Anhydrous Ammonia: purity 99.5% min, water 0.2% max, oil 5 ppm max, " <>
          "temperature at delivery max -27°F (-33°C).",
          anchors: ["Product Specifications"],
          fields:  %{"product_name" => "Anhydrous Ammonia", "temp_requirement" => -27.0}
        ),
        clause("WARRANTY_DISCLAIMER", :legal, :legal,
          "SELLER MAKES NO WARRANTY BEYOND PRODUCT SPECIFICATIONS HEREIN.",
          anchors: ["Disclaimer of Warranties"],
          fields:  %{"disclaimer_text_present" => true}
        ),
        clause("DEFAULT_AND_REMEDIES", :condition, :credit_legal,
          "Default: non-payment, insolvency. Terminate with 48 hrs notice. " <>
          "Cover-price damages. Interest SOFR+2.5%. Set-off and netting.",
          anchors: ["Default", "48 hours", "terminate"],
          fields:  %{"interest_rate" => "SOFR+2.5%", "setoff_netting" => true}
        ),
        clause("CLAIMS_NOTICE_AND_LIMITS", :legal, :legal,
          "Claims within 15 days of delivery; barred after 90 days.",
          anchors: ["Claims", "15 days", "90 calendar days"],
          fields:  %{"notice_deadline" => "15_days", "limitation_period" => "90_calendar_days"}
        ),
        clause("GOVERNING_LAW_AND_ARBITRATION", :legal, :legal,
          "New York law. SMA arbitration, New York.",
          anchors: ["Arbitration", "Governing Law", "SMA", "New York"],
          fields:  %{"governing_law" => "New_York", "forum" => "New_York_SMA"}
        ),
        clause("NOTICES", :legal, :legal,
          "Notices by email; deemed given on delivery receipt.",
          anchors: ["Notices", "e-mail"],
          fields:  %{"notice_methods" => ["email"]}
        ),
        clause("MISCELLANEOUS_BOILERPLATE", :legal, :legal,
          "Entire agreement. Written modification only. Severability.",
          anchors: ["Miscellaneous", "Entire Agreement"],
          fields:  %{"boilerplate_present" => true}
        )
      ]
    }
  end

  # ── 5. J.R. SIMPLOT COMPANY — Annual Supply Agreement, Multi-point ───────────

  defp simplot_annual_supply do
    # Annual commitment: 30,000 MT; 25,000 MT remaining open.
    # Multi-point delivery: primarily St. Louis, with Memphis as secondary.
    # Prices: $400/MT DAP StL; $375/MT DAP Memphis.
    # Quarterly scheduling; Trammo nominates delivery split per quarter.
    # Payment: TT 15 days from delivery. Working cap requirement based on
    # quarterly off-take: 7,500 MT × $400 avg = $3,000,000/quarter.
    # New York law / SMA. SAP: TRAMMO-LT-2026-0007

    %Contract{
      counterparty:      "J.R. Simplot Company",
      counterparty_type: :customer,
      product_group:     :ammonia,
      template_type:     :sale,
      incoterm:          :dap,
      term_type:         :long_term,
      company:           :trammo_inc,
      status:            :approved,
      contract_number:   "TRAMMO-LT-2026-0007",
      family_id:         "DOMESTIC_MULTIMODAL_SALE",
      contract_date:     ~D[2026-01-01],
      expiry_date:       ~D[2026-12-31],
      sap_contract_id:   "4700001007",
      sap_validated:     true,
      open_position:     25_000.0,
      source_file:       "Simplot_Annual_Supply_2026_v1.docx",
      source_format:     :docx,
      scan_date:         @now,
      reviewed_by:       "legal@trammo.com",
      reviewed_at:       @now,
      review_notes:      "Annual supply. Delivery split 70% StL / 30% Memphis by default.",
      verification_status: :verified,
      last_verified_at:  @now,
      network_path:      "\\\\trammo-sp\\Contracts\\Ammonia\\Sales\\Simplot_Annual_2026_0007",
      created_at:        @now,
      updated_at:        @now,
      template_validation: %{
        "family" => "DOMESTIC_MULTIMODAL_SALE",
        "expected_clauses" => 13,
        "found_clauses" => 14,
        "completeness_pct" => 100.0,
        "missing" => [],
        "extra" => ["ORIGIN"]
      },
      clauses: [
        # PRICE (StL): $400/MT DAP St. Louis. The annual floor for StL deliveries.
        # Solver: sell_stl >= 400 for Simplot StL deliveries to be profitable.
        clause("PRICE", :price_term, :commercial,
          "Price at St. Louis: USD 400.00 per Metric Ton, DAP St. Louis, Missouri. " <>
          "Price at Memphis: USD 375.00 per Metric Ton, DAP Memphis, Tennessee. " <>
          "Prices fixed for contract year. Price review clause applies if Fertecon " <>
          "NH3 index moves more than +/- 15% from contract date reference.",
          parameter:  :sell_stl,
          operator:   :>=,
          value:      400.0,
          unit:       "$/MT",
          period:     :annual,
          confidence: :high,
          anchors:    ["Price", "US $"],
          fields:     %{"price_value" => 400.0, "price_uom" => "$/MT",
                        "pricing_mechanism" => "fixed_annual_with_review",
                        "price_stl" => 400.0, "price_mem" => 375.0,
                        "review_trigger_pct" => 15.0}
        ),

        # PRICE (Memphis leg): separate price_term clause for the Memphis component.
        # Solver: sell_mem >= 375 for Simplot Memphis deliveries to cover freight.
        clause("PRICE", :price_term, :commercial,
          "Memphis delivery price: USD 375.00 per Metric Ton, DAP Memphis, Tennessee. " <>
          "Approximately 30% of annual volume routed to Memphis per quarterly plan.",
          parameter:  :sell_mem,
          operator:   :>=,
          value:      375.0,
          unit:       "$/MT",
          period:     :annual,
          confidence: :high,
          anchors:    ["Price", "US $"],
          fields:     %{"price_value" => 375.0, "price_uom" => "$/MT",
                        "delivery_point" => "Memphis, TN",
                        "volume_share_pct" => 30.0}
        ),

        # QUANTITY_TOLERANCE: 30,000 MT annual ±5% Trammo option. Quarterly splits
        # nominated by Trammo. Solver: total inv_mer draw (primary source) >= 21,000
        # (70% of 30,000) over the year. Expressed as quarterly minimum.
        clause("QUANTITY_TOLERANCE", :obligation, :core_terms,
          "Annual quantity: 30,000 Metric Tons (+/- 5% Seller's option). " <>
          "Quarterly minimum off-take: 6,750 MT (5% below 7,500 MT/quarter). " <>
          "Delivery split: 70% St. Louis, 30% Memphis per Seller's quarterly plan.",
          parameter:   :inv_mer,
          operator:    :between,
          value:       6_750.0,
          value_upper: 8_250.0,
          unit:        "MT",
          period:      :quarterly,
          confidence:  :high,
          anchors:     ["Quantity", "+/-", "more or less", "Shipments / nominations"],
          fields:      %{"qty" => 30_000.0, "uom" => "MT", "tolerance_pct" => 5.0,
                         "option_holder" => "seller", "split_stl_pct" => 70.0,
                         "split_mem_pct" => 30.0, "quarterly_min" => 6_750.0}
        ),

        # DATES_WINDOWS_NOMINATIONS: Quarterly delivery schedule. Trammo nominates
        # specific delivery windows 30 days ahead. Requires fleet planning.
        # Solver: barge_count >= 2 sustained to meet quarterly schedule.
        clause("DATES_WINDOWS_NOMINATIONS", :delivery, :logistics,
          "Quarterly delivery plan submitted by Seller by 1st of each quarter. " <>
          "Monthly sub-nominations 14 days prior to loading. Minimum 2 barges " <>
          "committed per quarter for Simplot account.",
          parameter:  :barge_count,
          operator:   :>=,
          value:      2.0,
          unit:       "barges",
          period:     :quarterly,
          confidence: :medium,
          anchors:    ["Shipments / nominations", "Nominations and Notices", "Arrival Dates"],
          fields:     %{"nomination_timeline" => "14_days_prior",
                        "loading_dates" => "quarterly_plan",
                        "min_barges_committed" => 2}
        ),

        # PAYMENT: TT 15 days from delivery. Quarterly exposure: 7,500 MT × $393 avg
        # (70/30 blend of $400/$375) = $2,947,500. Round to $3,000,000.
        clause("PAYMENT", :obligation, :commercial,
          "Payment by Telegraphic Transfer within 15 business days of delivery " <>
          "completion and invoice. Quarterly payment cycle; single invoice per delivery. " <>
          "Working capital requirement approximately USD 3,000,000 per quarter.",
          parameter:  :working_cap,
          operator:   :>=,
          value:      3_000_000.0,
          unit:       "$",
          period:     :quarterly,
          confidence: :high,
          anchors:    ["Payment", "telegraphic transfer"],
          fields:     %{"payment_method" => "TT",
                        "days_from_bl_or_delivery" => 15,
                        "docs_required" => ["delivery_receipt", "quantity_cert"]}
        ),

        # LAYTIME_DEMURRAGE: 48 hrs free at StL; 36 hrs free at Memphis.
        # Blended: model at 48 hrs (conservative for StL primary destination).
        clause("LAYTIME_DEMURRAGE", :penalty, :logistics_cost,
          "Free time: 48 hours at St. Louis terminal, 36 hours at Memphis terminal, " <>
          "from barge arrival and readiness. Thereafter: USD 5,000 per day (USD 208.33/hr). " <>
          "Claims within 30 days of discharge completion.",
          parameter:        :lock_hrs,
          operator:         :<=,
          value:            48.0,
          unit:             "hours",
          penalty_per_unit: 208.33,
          penalty_cap:      50_000.0,
          confidence:       :high,
          anchors:          ["Laytime", "Demurrage"],
          fields:           %{"free_hours_stl" => 48, "free_hours_mem" => 36,
                              "demurrage_rate" => 5_000.0, "claim_deadline_days" => 30}
        ),

        # FORCE_MAJEURE (StL): Dock outage at StL suspends deliveries to that point.
        clause("FORCE_MAJEURE", :condition, :risk_events,
          "Force Majeure at St. Louis: dock closure, ice, flood, USCG hold. " <>
          "FM declared after 24-hour continuous outage; delivery obligations suspended. " <>
          "Trammo to re-route affected volume to Memphis if feasible.",
          parameter:  :mer_outage,
          operator:   :==,
          value:      1.0,
          unit:       "",
          confidence: :high,
          anchors:    ["Force Majeure", "notify"],
          fields:     %{"notice_period" => "24_hours",
                        "remedies" => "suspend_stl_reroute_to_mem",
                        "demurrage_interaction" => "tolled_during_FM"}
        ),

        # FORCE_MAJEURE (Memphis): Dock outage at Memphis suspends Memphis deliveries.
        clause("FORCE_MAJEURE", :condition, :risk_events,
          "Force Majeure at Memphis: dock closure, ice, USCG hold. " <>
          "FM declared after 24-hour outage; Memphis deliveries suspended. " <>
          "Trammo to re-route affected volume to St. Louis if feasible.",
          parameter:  :nio_outage,
          operator:   :==,
          value:      1.0,
          unit:       "",
          confidence: :high,
          anchors:    ["Force Majeure", "notify"],
          fields:     %{"notice_period" => "24_hours",
                        "remedies" => "suspend_mem_reroute_to_stl"}
        ),

        # INSPECTION_AND_QTY_DETERMINATION: Scale weight at each terminal.
        clause("INSPECTION_AND_QTY_DETERMINATION", :condition, :determination,
          "Quantity by certified scale weight at delivery terminal. Joint inspection. " <>
          "Cost shared equally. Certificate final and binding for invoicing.",
          parameter:  :inv_mer,
          operator:   :>=,
          value:      6_750.0,
          unit:       "MT",
          confidence: :high,
          anchors:    ["Inspection", "certified scale weight"],
          fields:     %{"inspector_appointer" => "jointly",
                        "cost_split" => "50_50",
                        "qty_basis" => "certified_scale_weight"}
        ),

        # DELIVERY_SCHEDULE_TERMS: Quarterly supply schedule — next window in 14 days.
        clause("DELIVERY_SCHEDULE_TERMS", :delivery, :logistics,
          "Quarterly delivery schedule: 7,500 Metric Tons per quarter within 21-day " <>
          "delivery window per Seller's quarterly plan. Next window opens in 14 days. " <>
          "Grace period: 5 business days per shipment before penalty accrues. " <>
          "Late delivery penalty: USD 2.00 per Metric Ton per day. " <>
          "Penalty cap: 10% of quarterly invoice value. Annual commitment: 30,000 MT.",
          fields: %{
            "scheduled_qty_mt"       => 7_500.0,
            "frequency"              => "quarterly",
            "delivery_window_days"   => 21,
            "grace_period_days"      => 5,
            "penalty_per_mt_per_day" => 2.00,
            "penalty_cap_pct"        => 10.0,
            "next_window_days"       => 14
          }
        ),

        # Non-LP clauses
        clause("INCOTERMS", :metadata, :metadata,
          "INCOTERMS 2020 — DAP St. Louis, MO and Memphis, TN (as applicable).",
          anchors: ["INCOTERMS 2020"],
          fields:  %{"incoterm" => "DAP", "place" => "St. Louis, MO / Memphis, TN"}
        ),
        clause("PRODUCT_AND_SPECS", :compliance, :core_terms,
          "Anhydrous Ammonia refrigerated grade. Purity 99.5% min, water 0.2% max, " <>
          "oil 5 ppm max. Temperature at delivery max -27°F.",
          anchors: ["Product Specifications"],
          fields:  %{"product_name" => "Anhydrous Ammonia", "temp_requirement" => -27.0}
        ),
        clause("WARRANTY_DISCLAIMER", :legal, :legal,
          "NO WARRANTIES BEYOND PRODUCT SPECIFICATIONS.",
          anchors: ["Disclaimer of Warranties"],
          fields:  %{"disclaimer_text_present" => true}
        ),
        clause("DEFAULT_AND_REMEDIES", :condition, :credit_legal,
          "Default: non-payment, insolvency. Terminate with 48 hrs notice. " <>
          "Cover-price damages. Interest SOFR+2.5%. Set-off and netting.",
          anchors: ["Default", "48 hours", "terminate"],
          fields:  %{"interest_rate" => "SOFR+2.5%", "setoff_netting" => true}
        ),
        clause("CLAIMS_NOTICE_AND_LIMITS", :legal, :legal,
          "Quality and quantity claims within 15 days of delivery. Barred after 90 days.",
          anchors: ["Claims", "15 days", "90 calendar days"],
          fields:  %{"notice_deadline" => "15_days", "limitation_period" => "90_calendar_days"}
        ),
        clause("GOVERNING_LAW_AND_ARBITRATION", :legal, :legal,
          "New York law. SMA arbitration, New York.",
          anchors: ["Arbitration", "Governing Law", "SMA", "New York"],
          fields:  %{"governing_law" => "New_York", "forum" => "New_York_SMA"}
        ),
        clause("NOTICES", :legal, :legal,
          "Notices by email; deemed given upon delivery confirmation.",
          anchors: ["Notices", "e-mail"],
          fields:  %{"notice_methods" => ["email"]}
        ),
        clause("MISCELLANEOUS_BOILERPLATE", :legal, :legal,
          "Entire agreement. Written modifications only. Assignment with consent. Severability.",
          anchors: ["Miscellaneous", "Entire Agreement"],
          fields:  %{"boilerplate_present" => true}
        )
      ]
    }
  end

  # ──────────────────────────────────────────────────────────
  # CLAUSE BUILDER HELPER
  # ──────────────────────────────────────────────────────────

  defp clause(clause_id, type, category, description, opts \\ []) do
    %Clause{
      id:               Clause.generate_id(),
      clause_id:        clause_id,
      type:             type,
      category:         category,
      description:      description,
      parameter:        Keyword.get(opts, :parameter),
      operator:         Keyword.get(opts, :operator),
      value:            Keyword.get(opts, :value),
      value_upper:      Keyword.get(opts, :value_upper),
      unit:             Keyword.get(opts, :unit),
      penalty_per_unit: Keyword.get(opts, :penalty_per_unit),
      penalty_cap:      Keyword.get(opts, :penalty_cap),
      period:           Keyword.get(opts, :period),
      confidence:       Keyword.get(opts, :confidence, :high),
      reference_section: Keyword.get(opts, :section),
      anchors_matched:  Keyword.get(opts, :anchors, []),
      extracted_fields: Keyword.get(opts, :fields, %{}),
      extracted_at:     @now
    }
  end
end
