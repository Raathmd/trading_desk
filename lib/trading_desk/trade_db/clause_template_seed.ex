defmodule TradingDesk.TradeDB.ClauseTemplateSeed do
  @moduledoc """
  Seeds the nh3_clause_templates and nh3_contract_families tables.

  Source: "Ammonia Commercial Contract Templates.aspx" index page.
  Version: NH3_TEMPLATES_ALL_PAGE_V1

  Covers all 7 Trammo NH3 template families across 3 entities:
    - Trammo, Inc.
    - Trammo SAS
    - Trammo DMCC

  Template types:
    - spot_vessel_purchase / spot_vessel_sale / spot_vessel_dap
    - spot_domestic_cpt / spot_domestic_multimodal
    - long_term_sale / long_term_purchase

  ## Usage

      # Run once after migrations:
      TradingDesk.TradeDB.ClauseTemplateSeed.run()

      # Or from Mix:
      mix run -e "TradingDesk.TradeDB.ClauseTemplateSeed.run()"

  The seed is idempotent — re-running upserts without duplicating rows.
  """

  require Logger

  alias TradingDesk.TradeRepo
  alias TradingDesk.TradeDB.{NH3ClauseTemplate, NH3ContractFamily}

  @version "NH3_TEMPLATES_ALL_PAGE_V1"

  # ──────────────────────────────────────────────────────────
  # CANONICAL CLAUSE DEFINITIONS
  # 28 clauses covering all template families
  # ──────────────────────────────────────────────────────────

  @clause_templates [
    %{
      clause_id: "INCOTERMS",
      category: "metadata",
      anchors: ["INCOTERMS 2020", "INCOTERMS"],
      variants: ["FOB", "CFR", "CIF", "DAP", "DDP", "CPT"],
      extract_fields: [],
      notes: "Incoterm differs by template family; DAP/DDP vs CFR/CIF vs FOB vs CPT."
    },
    %{
      clause_id: "PRODUCT_AND_SPECS",
      category: "core_terms",
      anchors: ["Product", "Product Specifications", "Specifications"],
      variants: [],
      extract_fields: ["product_name", "temp_requirement", "purity", "water", "oil"],
      notes: "Specs present in all templates; small numeric differences appear across some families."
    },
    %{
      clause_id: "QUANTITY_TOLERANCE",
      category: "core_terms",
      anchors: ["Quantity", "+/-", "more or less", "shipping tolerance"],
      variants: ["seller_option", "buyer_option", "vessel_option", "fixed_exact_then_tolerance"],
      extract_fields: ["qty", "uom", "tolerance_pct", "option_holder"],
      notes: "Option-holder varies; long-term defines annual quantities + shipment sizing."
    },
    %{
      clause_id: "ORIGIN",
      category: "core_terms",
      anchors: ["Origin", "Any origin", "right but not the obligation"],
      variants: [],
      extract_fields: ["origin_text", "alternate_origin_right"],
      notes: "Common 'any origin' + optional alternate origin language in sales templates."
    },
    %{
      clause_id: "PORTS_AND_SAFE_BERTH",
      category: "logistics",
      anchors: ["Port(s) of Discharge", "Port of discharge", "Port(s) of Loading",
                "One safe port", "One safe berth", "draft"],
      variants: [],
      extract_fields: ["load_port", "discharge_port", "safe_port_safe_berth", "draft_guarantee"],
      notes: "Vessel templates include safe port/safe berth + draft guarantees."
    },
    %{
      clause_id: "DATES_WINDOWS_NOMINATIONS",
      category: "logistics",
      anchors: ["Loading Dates", "Arrival Dates", "during the period",
                "Shipments / nominations", "Nominations and Notices"],
      variants: ["spot_window", "long_term_quarterly_monthly_rules"],
      extract_fields: ["loading_dates", "arrival_window", "nomination_timeline"],
      notes: "Spot uses a discharge window; LT includes quarterly/monthly nomination structure."
    },
    %{
      clause_id: "PRICE",
      category: "commercial",
      anchors: ["Price", "US $", "price will be agreed", "Fertecon", "FMB"],
      variants: ["fixed_price", "index_reference_long_term", "eu_duty_divisor"],
      extract_fields: ["price_value", "price_uom", "pricing_mechanism", "duty_adjustment_formula"],
      notes: "LT CFR includes reference pricing and EU duty divisor logic; spot is usually fixed."
    },
    %{
      clause_id: "PAYMENT",
      category: "commercial",
      anchors: ["Payment", "letter of credit", "telegraphic transfer", "standby letter of credit"],
      variants: ["LC", "TT", "TT_30_days_BL", "standby_LC_optional"],
      extract_fields: ["payment_method", "days_from_bl_or_delivery", "docs_required",
                       "lc_terms", "standby_lc_terms"],
      notes: "DAP sales (SAS/DMCC) include standby LC option; many spot templates use 30 days from B/L."
    },
    %{
      clause_id: "LAYTIME_DEMURRAGE",
      category: "logistics_cost",
      anchors: ["Laytime", "Demurrage", "per day or pro rata",
                "Discharge Rate and Demurrage", "Discharge and Demurrage Rates",
                "Conditions of Loading"],
      variants: ["vessel_laytime_BL_div_rate", "truck_free_hours_then_hourly",
                 "charter_party_controls"],
      extract_fields: ["rate_mt_per_hr", "allowed_laytime_formula", "demurrage_rate",
                       "charterparty_alt", "claim_deadline_days"],
      notes: "Vessel templates: laytime = B/L qty ÷ rate; demurrage per day pro rata; " <>
             "domestic CPT uses free hours + hourly rate."
    },
    %{
      clause_id: "CHARTERPARTY_ASBATANKVOY_INCORP",
      category: "incorporation",
      anchors: ["ASBATANKVOY", "Charter Party", "incorporated by reference"],
      variants: [],
      extract_fields: ["charterparty_form", "role_mapping_owner_charterer"],
      notes: "Vessel templates incorporate ASBATANKVOY with role mapping."
    },
    %{
      clause_id: "NOR_AND_READINESS",
      category: "operational",
      anchors: ["Notice of Readiness", "NOR"],
      variants: [],
      extract_fields: ["nor_rules", "earliest_nor_time", "laytime_commencement_rule"],
      notes: "Appears in vessel templates; details differ between load-port vs discharge-port context."
    },
    %{
      clause_id: "PRESENTATION_COOLDOWN_GASSING",
      category: "operational",
      anchors: ["Presentation", "cool down", "purging", "gassing", "cargo tanks"],
      variants: [],
      extract_fields: ["tank_condition_required", "who_pays_ammonia_used",
                       "time_counts_or_excluded"],
      notes: "In FOB purchase/sale templates; defines vessel tank condition and cost allocation " <>
             "for ammonia used."
    },
    %{
      clause_id: "VESSEL_ELIGIBILITY",
      category: "compliance",
      anchors: ["Vessel Classification and Eligibility", "IACS", "P&I", "ISPS", "MTSA", "USCG"],
      variants: [],
      extract_fields: ["class_requirements", "pandi_requirement", "terminal_acceptance",
                       "rejection_rights"],
      notes: "Vessel-specific eligibility and compliance prerequisites."
    },
    %{
      clause_id: "INSPECTION_AND_QTY_DETERMINATION",
      category: "determination",
      anchors: ["Inspection", "independent inspector", "final and binding",
                "bill of lading quantity", "certified scale weight", "flow meter"],
      variants: ["loadport_inspector", "shipper_cert_prevails_dap",
                 "truck_scale_or_flowmeter_cpt"],
      extract_fields: ["inspector_appointer", "cost_split", "qty_basis", "quality_basis"],
      notes: "Who appoints/pays varies. CPT uses certified scale/flow meter at truck load manifold."
    },
    %{
      clause_id: "DOCUMENTS_AND_CERTIFICATES",
      category: "documentation",
      anchors: ["Documents", "certificate of origin", "EUR 1", "Form A", "T2L",
                "shipping documents"],
      variants: [],
      extract_fields: ["required_docs", "origin_cert_types", "where_delivered"],
      notes: "Strongly defined in CFR/FOB purchase templates; also referenced for payment."
    },
    %{
      clause_id: "INSURANCE",
      category: "risk_allocation",
      anchors: ["Insurance", "cargo insurance", "all risk",
                "contract price plus ten percent", "war strike riot"],
      variants: ["cif_seller_insures", "cfr_buyer_insures",
                 "purchase_terms_insurance_clause_present"],
      extract_fields: ["who_insures", "coverage_minimum", "war_risk_addon"],
      notes: "CFR/CIF sales differentiate who buys insurance; purchase terms mention " <>
             "insurance for CIF scenarios."
    },
    %{
      clause_id: "LOI",
      category: "documentation",
      anchors: ["Letter of Indemnity", "LOI",
                "without presentation of an original Bill of Lading"],
      variants: [],
      extract_fields: ["loi_allowed_cases", "bank_guarantee_required"],
      notes: "Present in vessel sale/DAP terms; enables discharge without original B/L " <>
             "or at alternate port."
    },
    %{
      clause_id: "TAXES_FEES_DUES",
      category: "commercial",
      anchors: ["Taxes", "Fees", "Dues", "VAT", "added to the sale price",
                "deducted from the purchase price"],
      variants: [],
      extract_fields: ["payer", "add_to_price_rule", "deduct_from_price_rule",
                       "import_duty_responsibility"],
      notes: "Allocation differs by incoterm and template family."
    },
    %{
      clause_id: "EXPORT_IMPORT_REACH",
      category: "compliance",
      anchors: ["Compliance with Export and Import Laws", "REACH", "Safety Data Sheet",
                "not prohibited"],
      variants: [],
      extract_fields: ["import_permitted_warranty", "reach_obligations", "who_handles_customs"],
      notes: "REACH compliance explicitly appears in vessel templates; responsibility allocation differs."
    },
    %{
      clause_id: "WAR_RISK_AND_ROUTE_CLOSURE",
      category: "risk_costs",
      anchors: ["War Risk", "Joint War Committee", "Main Shipping Routes Closure"],
      variants: [],
      extract_fields: ["war_risk_cost_rule", "route_closure_options"],
      notes: "Some templates include a routes-closure clause and war-risk cost multipliers."
    },
    %{
      clause_id: "FORCE_MAJEURE",
      category: "risk_events",
      anchors: ["Force Majeure", "notify", "cancel", "deliver later"],
      variants: [],
      extract_fields: ["notice_period", "remedies", "demurrage_interaction"],
      notes: "Common across templates; some specify FM does not change laytime/demurrage accounting."
    },
    %{
      clause_id: "DEFAULT_AND_REMEDIES",
      category: "credit_legal",
      anchors: ["Default", "event of default", "48 hours", "terminate", "cancel",
                "interest", "setoff", "net"],
      variants: [],
      extract_fields: ["events_of_default", "remedies", "interest_rate", "setoff_netting"],
      notes: "Default remedies present across templates; includes setoff/netting language."
    },
    %{
      clause_id: "WARRANTY_DISCLAIMER",
      category: "legal",
      anchors: ["Exclusion of Warranties", "Disclaimer of Warranties", "MAKES NO WARRANTY"],
      variants: [],
      extract_fields: ["disclaimer_text_present"],
      notes: "Appears in vessel and domestic templates; wording is very consistent."
    },
    %{
      clause_id: "CLAIMS_NOTICE_AND_LIMITS",
      category: "legal",
      anchors: ["Claims", "15 days", "one year", "90 calendar days", "absolutely barred"],
      variants: [],
      extract_fields: ["notice_deadline", "limitation_period", "caps_on_liability"],
      notes: "Domestic templates may use shorter litigation windows; vessel templates " <>
             "commonly reference one-year periods."
    },
    %{
      clause_id: "GOVERNING_LAW_AND_ARBITRATION",
      category: "legal",
      anchors: ["Arbitration", "Governing Law", "LMAA", "SMA", "English law", "New York"],
      variants: ["english_law_lmaa", "ny_law_sma"],
      extract_fields: ["governing_law", "forum", "ruleset"],
      notes: "Key discriminator: vessel templates use English/LMAA; domestic CPT & " <>
             "multimodal Sales use NY/SMA."
    },
    %{
      clause_id: "NOTICES",
      category: "legal",
      anchors: ["Notices", "deemed to be given", "courier", "fax", "e-mail"],
      variants: [],
      extract_fields: ["notice_methods", "deemed_delivery_rules", "copy_recipients"],
      notes: "Standard in all templates; addresses differ by entity."
    },
    %{
      clause_id: "MISCELLANEOUS_BOILERPLATE",
      category: "legal",
      anchors: ["Miscellaneous", "Entire Agreement", "Modifications", "Waiver",
                "Assignment", "Severability", "Immunity"],
      variants: [],
      extract_fields: ["boilerplate_present"],
      notes: "Consistent across all; long-term adds additional sections."
    },
    %{
      clause_id: "HARDSHIP_AND_REPRESENTATIONS",
      category: "legal_long_term",
      anchors: ["Hardship", "Representations and Warranties"],
      variants: [],
      extract_fields: ["hardship_present", "reps_present"],
      notes: "Appears in long-term sale templates (CFR LT)."
    }
  ]

  # ──────────────────────────────────────────────────────────
  # FAMILY SIGNATURES
  # 7 template families across Trammo Inc, SAS, DMCC
  # ──────────────────────────────────────────────────────────

  @family_signatures [
    %{
      family_id: "VESSEL_SPOT_PURCHASE",
      detect_anchors: [
        "PURCHASE CONTRACT",
        "TRAMMO GENERAL TERMS AND CONDITIONS (FOB PURCHASE)",
        "TRAMMO GENERAL TERMS AND CONDITIONS (CFR PURCHASE)"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE", "PORTS_AND_SAFE_BERTH",
        "DATES_WINDOWS_NOMINATIONS", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "CHARTERPARTY_ASBATANKVOY_INCORP", "NOR_AND_READINESS",
        "PRESENTATION_COOLDOWN_GASSING", "VESSEL_ELIGIBILITY",
        "INSPECTION_AND_QTY_DETERMINATION", "DOCUMENTS_AND_CERTIFICATES",
        "EXPORT_IMPORT_REACH", "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "CLAIMS_NOTICE_AND_LIMITS",
        "GOVERNING_LAW_AND_ARBITRATION", "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    %{
      family_id: "VESSEL_SPOT_SALE",
      detect_anchors: [
        "SALE CONTRACT",
        "TRAMMO GENERAL TERMS AND CONDITIONS (FOB SALES)",
        "TRAMMO GENERAL TERMS AND CONDITIONS (CFR AND CIF SALES)"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE", "ORIGIN",
        "PORTS_AND_SAFE_BERTH", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "CHARTERPARTY_ASBATANKVOY_INCORP", "NOR_AND_READINESS",
        "PRESENTATION_COOLDOWN_GASSING", "VESSEL_ELIGIBILITY",
        "INSPECTION_AND_QTY_DETERMINATION", "INSURANCE", "LOI",
        "TAXES_FEES_DUES", "EXPORT_IMPORT_REACH", "WAR_RISK_AND_ROUTE_CLOSURE",
        "FORCE_MAJEURE", "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER",
        "CLAIMS_NOTICE_AND_LIMITS", "GOVERNING_LAW_AND_ARBITRATION",
        "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    %{
      family_id: "VESSEL_SPOT_DAP",
      detect_anchors: [
        "DAP Sale Contract",
        "TRAMMO GENERAL TERMS AND CONDITIONS (DAP SALES)",
        "TRAMMO GENERAL TERMS AND CONDITIONS (DAP/DDP SALES)"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE", "ORIGIN",
        "PORTS_AND_SAFE_BERTH", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "CHARTERPARTY_ASBATANKVOY_INCORP", "INSPECTION_AND_QTY_DETERMINATION",
        "LOI", "TAXES_FEES_DUES", "EXPORT_IMPORT_REACH",
        "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE", "DEFAULT_AND_REMEDIES",
        "WARRANTY_DISCLAIMER", "CLAIMS_NOTICE_AND_LIMITS",
        "GOVERNING_LAW_AND_ARBITRATION", "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    %{
      family_id: "DOMESTIC_CPT_TRUCKS",
      detect_anchors: [
        "CPT SALE CONTRACT",
        "TRAMMO GENERAL TERMS AND CONDITIONS (CPT SALES)"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "INSPECTION_AND_QTY_DETERMINATION", "WARRANTY_DISCLAIMER",
        "CLAIMS_NOTICE_AND_LIMITS", "DEFAULT_AND_REMEDIES", "FORCE_MAJEURE",
        "TAXES_FEES_DUES", "NOTICES", "GOVERNING_LAW_AND_ARBITRATION",
        "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    %{
      family_id: "DOMESTIC_MULTIMODAL_SALE",
      detect_anchors: [
        "Sale Contract for Barge, Rail and Trucks",
        "TRAMMO GENERAL TERMS AND CONDITIONS (SALES)"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "PRICE", "PAYMENT",
        "INSPECTION_AND_QTY_DETERMINATION", "LAYTIME_DEMURRAGE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER", "CLAIMS_NOTICE_AND_LIMITS",
        "GOVERNING_LAW_AND_ARBITRATION", "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    },
    %{
      family_id: "LONG_TERM_SALE_CFR",
      detect_anchors: [
        "ANHYDROUS AMMONIA SALES CONTRACT",
        "Shipments / nominations",
        "Fertecon",
        "FMB"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE",
        "DATES_WINDOWS_NOMINATIONS", "PRICE", "PAYMENT", "LAYTIME_DEMURRAGE",
        "CHARTERPARTY_ASBATANKVOY_INCORP", "LOI", "TAXES_FEES_DUES",
        "EXPORT_IMPORT_REACH", "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE",
        "DEFAULT_AND_REMEDIES", "WARRANTY_DISCLAIMER", "CLAIMS_NOTICE_AND_LIMITS",
        "GOVERNING_LAW_AND_ARBITRATION", "NOTICES", "MISCELLANEOUS_BOILERPLATE",
        "HARDSHIP_AND_REPRESENTATIONS"
      ]
    },
    %{
      family_id: "LONG_TERM_PURCHASE_FOB",
      detect_anchors: [
        "ANHYDROUS AMMONIA FOB PURCHASE CONTRACT",
        "bill of lading date of the first cargo lifted"
      ],
      expected_clause_ids: [
        "INCOTERMS", "PRODUCT_AND_SPECS", "QUANTITY_TOLERANCE",
        "DATES_WINDOWS_NOMINATIONS", "PRICE", "PAYMENT",
        "DOCUMENTS_AND_CERTIFICATES", "INSPECTION_AND_QTY_DETERMINATION",
        "PRESENTATION_COOLDOWN_GASSING", "CHARTERPARTY_ASBATANKVOY_INCORP",
        "LAYTIME_DEMURRAGE", "TAXES_FEES_DUES", "EXPORT_IMPORT_REACH",
        "WAR_RISK_AND_ROUTE_CLOSURE", "FORCE_MAJEURE", "DEFAULT_AND_REMEDIES",
        "GOVERNING_LAW_AND_ARBITRATION", "NOTICES", "MISCELLANEOUS_BOILERPLATE"
      ]
    }
  ]

  # ──────────────────────────────────────────────────────────
  # PUBLIC API
  # ──────────────────────────────────────────────────────────

  @doc """
  Seed clause templates and family signatures into SQLite.

  Idempotent — uses upsert so re-running is safe.
  Logs a summary when complete.
  """
  def run do
    now = DateTime.utc_now()
    clause_count = seed_clause_templates(now)
    family_count = seed_family_signatures(now)

    Logger.info(
      "ClauseTemplateSeed: seeded #{clause_count} clause templates, " <>
      "#{family_count} contract families (version: #{@version})"
    )

    :ok
  rescue
    e ->
      Logger.error("ClauseTemplateSeed: failed — #{Exception.message(e)}")
      {:error, e}
  end

  # ──────────────────────────────────────────────────────────
  # PRIVATE
  # ──────────────────────────────────────────────────────────

  defp seed_clause_templates(now) do
    Enum.each(@clause_templates, fn ct ->
      attrs = %{
        clause_id: ct.clause_id,
        category: ct.category,
        anchors_json: Jason.encode!(ct.anchors),
        variants_json: Jason.encode!(ct.variants),
        extract_fields_json: Jason.encode!(ct.extract_fields),
        notes: ct.notes,
        inventory_version: @version
      }

      %NH3ClauseTemplate{}
      |> NH3ClauseTemplate.changeset(attrs)
      |> TradeRepo.insert(
        on_conflict: {:replace, [:category, :anchors_json, :variants_json,
                                  :extract_fields_json, :notes, :updated_at]},
        conflict_target: :clause_id
      )
    end)

    length(@clause_templates)
  end

  defp seed_family_signatures(now) do
    Enum.each(@family_signatures, fn fam ->
      expected_ids = fam.expected_clause_ids

      attrs = %{
        family_id: fam.family_id,
        detect_anchors_json: Jason.encode!(fam.detect_anchors),
        expected_clause_ids_json: Jason.encode!(expected_ids),
        expected_clause_count: length(expected_ids),
        inventory_version: @version
      }

      %NH3ContractFamily{}
      |> NH3ContractFamily.changeset(attrs)
      |> TradeRepo.insert(
        on_conflict: {:replace, [:detect_anchors_json, :expected_clause_ids_json,
                                  :expected_clause_count, :updated_at]},
        conflict_target: :family_id
      )
    end)

    length(@family_signatures)
  end
end
