# Seed tracked_vessels with real ammonia gas carriers and Mississippi River towboats.
#
# INTERNATIONAL vessels: confirmed MMSIs from MarineTraffic/VesselFinder.
# DOMESTIC towboats: US-flag MMSI range (366/367/368).
#   - MMSIs below are realistic placeholders from the US AIS registry range.
#   - River barges do NOT carry AIS transponders — tracked via their towboats.
#   - Replace towboat MMSIs with actual vessel IDs from your ops team / Kirby/ARTCO contacts.
#
# Mississippi River NH3 operators (for reference):
#   - Kirby Inland Marine (largest US inland carrier)
#   - ARTCO (American River Transportation Co) — CF Industries subsidiary
#   - Marquette Transportation Company
#   - Canal Barge Company
#   - SCF Marine Inc (Savage Companies)
#   - Ingram Barge Company
#
# carrying_stock = true means the vessel is currently loaded with Trammo-owned product.
# track_in_fleet = true means the vessel counts toward Trammo's operational fleet.
#
# Run: mix run priv/repo/seeds/tracked_vessels.exs

alias TradingDesk.Fleet.TrackedVessel

vessels = [
  # ─────────────────────────────────────────────────────────────
  # AMMONIA INTERNATIONAL — gas carriers on deep-water routes
  # ─────────────────────────────────────────────────────────────

  %{
    vessel_name: "Gaschem Beluga",
    mmsi: "636017711",
    imo: "9743928",
    product_group: "ammonia_international",
    cargo: "Anhydrous Ammonia",
    loading_port: "Point Lisas",
    discharge_port: "Tampa",
    eta: Date.add(Date.utc_today(), 12),
    sap_contract_id: "4600000101",
    status: "in_transit",
    vessel_type: "gas_carrier",
    operator: "Hartmann Group",
    flag_state: "LR",
    capacity_mt: 8500.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "MGC — March Trinidad cargo"
  },
  %{
    vessel_name: "Navigator Aurora",
    mmsi: "636017409",
    imo: "9726322",
    product_group: "ammonia_international",
    cargo: "Anhydrous Ammonia",
    loading_port: "Yuzhnyy",
    discharge_port: "Mundra",
    eta: Date.add(Date.utc_today(), 21),
    sap_contract_id: "4600000103",
    status: "in_transit",
    vessel_type: "gas_carrier",
    operator: "Navigator Gas",
    flag_state: "MH",
    capacity_mt: 22000.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "LPG carrier — Black Sea to India"
  },
  %{
    vessel_name: "Clipper Mars",
    mmsi: "258667000",
    imo: "9377078",
    product_group: "ammonia_international",
    cargo: "Anhydrous Ammonia",
    loading_port: "Ras Al Khair",
    discharge_port: "Mundra",
    eta: Date.add(Date.utc_today(), 8),
    status: "in_transit",
    vessel_type: "gas_carrier",
    operator: "Clipper Group",
    flag_state: "NO",
    capacity_mt: 15000.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Norwegian flag — Middle East to India"
  },
  %{
    vessel_name: "Phoenix Harmonia",
    mmsi: "352002825",
    imo: "9947483",
    product_group: "ammonia_international",
    cargo: "Anhydrous Ammonia",
    loading_port: "Yuzhnyy",
    discharge_port: "Rostock",
    eta: Date.add(Date.utc_today(), 5),
    status: "in_transit",
    vessel_type: "gas_carrier",
    operator: "Phoenix Tankers",
    flag_state: "PA",
    capacity_mt: 45000.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "VLGC — Black Sea to Baltic"
  },
  %{
    vessel_name: "Navigator Galaxy",
    mmsi: "636015946",
    imo: "9536363",
    product_group: "ammonia_international",
    cargo: "Anhydrous Ammonia",
    loading_port: "Point Lisas",
    discharge_port: "Donaldsonville",
    eta: Date.add(Date.utc_today(), 3),
    status: "active",
    vessel_type: "gas_carrier",
    operator: "Navigator Gas",
    flag_state: "MH",
    capacity_mt: 22000.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "Trinidad import to NOLA region — awaiting berth"
  },
  %{
    vessel_name: "BW Odin",
    mmsi: "477996900",
    imo: "9398451",
    product_group: "ammonia_international",
    cargo: "Anhydrous Ammonia",
    loading_port: "Ras Al Khair",
    discharge_port: "Freeport",
    eta: Date.add(Date.utc_today(), 16),
    status: "in_transit",
    vessel_type: "gas_carrier",
    operator: "BW Epic Kosan",
    flag_state: "HK",
    capacity_mt: 45000.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "VLGC — Saudi to Gulf Coast"
  },

  # ─────────────────────────────────────────────────────────────
  # AMMONIA DOMESTIC — Illinois & Mississippi River towboats & NH3 barges
  #
  # Route segments:
  #   Illinois River: Meredosia, IL → Grafton, IL (Mississippi confluence, ~100 mi)
  #   Upper Mississippi: Niota, IL → Cairo (Mile 0) → Memphis → further south
  #   Upper/Mid Mississippi: Meredosia or Niota → St. Louis (Mile 180) → Minneapolis (Mile 857)
  #
  # Trammo's NH3 supply chain:
  #   Meredosia, IL (Trammo terminal) → St. Louis & Memphis via Illinois River
  #   Niota, IL (Trammo terminal) → Minneapolis, St. Louis, Memphis via Upper Mississippi
  # ─────────────────────────────────────────────────────────────

  # ── Kirby Inland Marine towboats ──
  %{
    vessel_name: "MV Miss Kae D",
    mmsi: "367500210",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 6),
    sap_shipping_number: "80012345",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 4500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "3x refrigerated NH3 barges — Lower MS"
  },
  %{
    vessel_name: "MV Carey Brennan",
    mmsi: "367500215",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Memphis",
    eta: Date.add(Date.utc_today(), 5),
    sap_shipping_number: "80012350",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "2x NH3 barges — Memphis delivery"
  },
  %{
    vessel_name: "MV Carl D. Glover",
    mmsi: "367500220",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Cairo",
    eta: Date.add(Date.utc_today(), 8),
    status: "active",
    vessel_type: "towboat",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 4500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "3x barges southbound staging — waiting spot"
  },
  %{
    vessel_name: "MV Kay Lynn M",
    mmsi: "367500225",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Minneapolis",
    eta: Date.add(Date.utc_today(), 14),
    sap_shipping_number: "80012351",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "upper_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "2x barges — Upper Mississippi, seasonal route"
  },

  # ── ARTCO (American River Transportation Co) — contracted barge carrier ──
  %{
    vessel_name: "MV Barbara E",
    mmsi: "367469880",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Memphis",
    eta: Date.add(Date.utc_today(), 4),
    sap_shipping_number: "80012346",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "ARTCO",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "ARTCO — 2x barges, Meredosia to Memphis"
  },
  %{
    vessel_name: "MV Dorothy Ann",
    mmsi: "367469885",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 7),
    sap_shipping_number: "80012352",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "ARTCO",
    flag_state: "US",
    capacity_mt: 4500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "ARTCO — 3x barges, Lower MS to Gateway"
  },
  %{
    vessel_name: "MV Indiana",
    mmsi: "367469890",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Cairo",
    eta: Date.add(Date.utc_today(), 5),
    status: "active",
    vessel_type: "towboat",
    operator: "ARTCO",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: false,
    carrying_stock: false,
    notes: "ARTCO — spot charter, 1x barge only — NOT counted toward Trammo fleet"
  },

  # ── Marquette Transportation ──
  %{
    vessel_name: "MV Crystal Allen",
    mmsi: "367703250",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Cairo",
    eta: Date.add(Date.utc_today(), 10),
    sap_shipping_number: "80012347",
    status: "active",
    vessel_type: "towboat",
    operator: "Marquette Transportation",
    flag_state: "US",
    capacity_mt: 4500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "Marquette — 3x barges, Cairo staging"
  },
  %{
    vessel_name: "MV Houma",
    mmsi: "367703255",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Vicksburg",
    eta: Date.add(Date.utc_today(), 3),
    sap_shipping_number: "80012353",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "Marquette Transportation",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Marquette — 2x barges, Lower MS"
  },
  %{
    vessel_name: "MV Louisiana",
    mmsi: "367703260",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Baton Rouge",
    eta: Date.add(Date.utc_today(), 1),
    status: "active",
    vessel_type: "towboat",
    operator: "Marquette Transportation",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Niota–Memphis short-haul staging barge"
  },

  # ── Canal Barge Company ──
  %{
    vessel_name: "MV Jim Burns",
    mmsi: "367612100",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "New Orleans",
    eta: Date.add(Date.utc_today(), 2),
    status: "in_transit",
    vessel_type: "towboat",
    operator: "Canal Barge Company",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Canal Barge — river terminal shuttle"
  },
  %{
    vessel_name: "MV E.N. Bisso",
    mmsi: "367612105",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Memphis",
    eta: Date.add(Date.utc_today(), 6),
    status: "active",
    vessel_type: "towboat",
    operator: "Canal Barge Company",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "Canal Barge — 2x NH3 barges staging Memphis"
  },

  # ── SCF Marine (Savage Companies) ──
  %{
    vessel_name: "MV Savage Voyager",
    mmsi: "367455310",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 9),
    sap_shipping_number: "80012354",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "SCF Marine",
    flag_state: "US",
    capacity_mt: 4500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "SCF/Savage — 3x barges via Lower MS"
  },
  %{
    vessel_name: "MV Savage Enterprise",
    mmsi: "367455315",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Minneapolis",
    eta: Date.add(Date.utc_today(), 18),
    status: "active",
    vessel_type: "towboat",
    operator: "SCF Marine",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "upper_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "SCF/Savage — Upper Mississippi seasonal run"
  },

  # ── Ingram Barge Company ──
  %{
    vessel_name: "MV Robert V. Ingram",
    mmsi: "367380100",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Baton Rouge",
    eta: Date.add(Date.utc_today(), 1),
    status: "active",
    vessel_type: "towboat",
    operator: "Ingram Barge Company",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: false,
    carrying_stock: false,
    notes: "Ingram — short-haul spot hire, not in Trammo fleet"
  },
  %{
    vessel_name: "MV James R. Petroff",
    mmsi: "367380105",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Greenville",
    eta: Date.add(Date.utc_today(), 5),
    sap_shipping_number: "80012355",
    status: "in_transit",
    vessel_type: "towboat",
    operator: "Ingram Barge Company",
    flag_state: "US",
    capacity_mt: 3000.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Ingram — 2x barges Lower MS, Greenville delivery"
  },

  # ─────────────────────────────────────────────────────────────
  # AMMONIA DOMESTIC — NH3 pressure barges (non-powered, pushed by above towboats)
  # These are the actual cargo-carrying vessels — river NH3 tank barges.
  # No MMSI — AIS tracking is via the pushing towboat.
  # ─────────────────────────────────────────────────────────────

  %{
    vessel_name: "TRAMMO NH3-101",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 6),
    sap_shipping_number: "80012345",
    status: "in_transit",
    vessel_type: "barge",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "NH3 pressure barge — towed by MV Miss Kae D"
  },
  %{
    vessel_name: "TRAMMO NH3-102",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 6),
    sap_shipping_number: "80012345",
    status: "in_transit",
    vessel_type: "barge",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "NH3 pressure barge — towed by MV Miss Kae D"
  },
  %{
    vessel_name: "TRAMMO NH3-103",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Memphis",
    eta: Date.add(Date.utc_today(), 5),
    sap_shipping_number: "80012350",
    status: "in_transit",
    vessel_type: "barge",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "NH3 pressure barge — towed by MV Carey Brennan"
  },
  %{
    vessel_name: "ARTCO NH3-201",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Memphis",
    eta: Date.add(Date.utc_today(), 4),
    sap_shipping_number: "80012346",
    status: "in_transit",
    vessel_type: "barge",
    operator: "ARTCO",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "ARTCO barge — towed by MV Barbara E"
  },
  %{
    vessel_name: "ARTCO NH3-202",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 7),
    sap_shipping_number: "80012352",
    status: "in_transit",
    vessel_type: "barge",
    operator: "ARTCO",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "ARTCO barge — towed by MV Dorothy Ann"
  },
  %{
    vessel_name: "ARTCO NH3-203",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 7),
    sap_shipping_number: "80012352",
    status: "in_transit",
    vessel_type: "barge",
    operator: "ARTCO",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "ARTCO barge — towed by MV Dorothy Ann"
  },
  %{
    vessel_name: "MQT NH3-301",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Cairo",
    eta: Date.add(Date.utc_today(), 10),
    sap_shipping_number: "80012347",
    status: "active",
    vessel_type: "barge",
    operator: "Marquette Transportation",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "Marquette barge — towed by MV Crystal Allen, staging"
  },
  %{
    vessel_name: "MQT NH3-302",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Vicksburg",
    eta: Date.add(Date.utc_today(), 3),
    sap_shipping_number: "80012353",
    status: "in_transit",
    vessel_type: "barge",
    operator: "Marquette Transportation",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Marquette barge — towed by MV Houma"
  },
  %{
    vessel_name: "SCF NH3-401",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 9),
    sap_shipping_number: "80012354",
    status: "in_transit",
    vessel_type: "barge",
    operator: "SCF Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "SCF/Savage barge — towed by MV Savage Voyager"
  },
  %{
    vessel_name: "SCF NH3-402",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Minneapolis",
    eta: Date.add(Date.utc_today(), 18),
    status: "active",
    vessel_type: "barge",
    operator: "SCF Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "upper_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "SCF/Savage barge — towed by MV Savage Enterprise, staging"
  },
  %{
    vessel_name: "IB NH3-501",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Greenville",
    eta: Date.add(Date.utc_today(), 5),
    sap_shipping_number: "80012355",
    status: "in_transit",
    vessel_type: "barge",
    operator: "Ingram Barge Company",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Ingram barge — towed by MV James R. Petroff"
  },
  %{
    vessel_name: "TRAMMO NH3-104",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "Minneapolis",
    eta: Date.add(Date.utc_today(), 14),
    sap_shipping_number: "80012351",
    status: "in_transit",
    vessel_type: "barge",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "upper_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "NH3 pressure barge — towed by MV Kay Lynn M"
  },
  %{
    vessel_name: "TRAMMO NH3-105",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Meredosia",
    discharge_port: "Cairo",
    eta: Date.add(Date.utc_today(), 8),
    status: "active",
    vessel_type: "barge",
    operator: "Kirby Inland Marine",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: false,
    notes: "NH3 pressure barge — towed by MV Carl D. Glover, staging"
  },
  %{
    vessel_name: "CBC NH3-601",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Niota",
    discharge_port: "New Orleans",
    eta: Date.add(Date.utc_today(), 2),
    status: "in_transit",
    vessel_type: "barge",
    operator: "Canal Barge Company",
    flag_state: "US",
    capacity_mt: 1500.0,
    river_segment: "lower_mississippi",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Canal Barge — towed by MV Jim Burns"
  },

  # ─────────────────────────────────────────────────────────────
  # SULPHUR INTERNATIONAL
  # ─────────────────────────────────────────────────────────────

  %{
    vessel_name: "MV Sulphur Enterprise",
    mmsi: "636092321",
    product_group: "sulphur_international",
    cargo: "Granular Sulphur",
    loading_port: "Ras Tanura",
    discharge_port: "Tampa",
    eta: Date.add(Date.utc_today(), 18),
    status: "in_transit",
    vessel_type: "bulk_carrier",
    operator: "Charterer",
    flag_state: "LR",
    capacity_mt: 40000.0,
    river_segment: "international",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Bulk carrier — Persian Gulf sulphur"
  },

  # ─────────────────────────────────────────────────────────────
  # PETCOKE
  # ─────────────────────────────────────────────────────────────

  %{
    vessel_name: "MV Gulf Petcoke",
    mmsi: "367125090",
    product_group: "petcoke",
    cargo: "Petroleum Coke",
    loading_port: "Houston",
    discharge_port: "Cartagena",
    eta: Date.add(Date.utc_today(), 7),
    status: "in_transit",
    vessel_type: "bulk_carrier",
    operator: "Charterer",
    flag_state: "US",
    capacity_mt: 35000.0,
    river_segment: "gulf",
    track_in_fleet: true,
    carrying_stock: true,
    notes: "Handysize bulk — Gulf petcoke export"
  }
]

upserted = 0
skipped  = 0

{upserted, skipped} = Enum.reduce(vessels, {0, 0}, fn attrs, {u, s} ->
  mmsi = attrs[:mmsi]
  existing = cond do
    mmsi != nil -> TrackedVessel.get_by_mmsi(mmsi)
    attrs[:sap_shipping_number] != nil ->
      TradingDesk.Repo.get_by(TrackedVessel, sap_shipping_number: attrs[:sap_shipping_number])
    true ->
      TradingDesk.Repo.get_by(TrackedVessel, vessel_name: attrs[:vessel_name])
  end
  case existing do
    nil ->
      case TrackedVessel.create(attrs) do
        {:ok, _}    -> {u + 1, s}
        {:error, e} ->
          IO.puts("  WARN: failed to insert #{attrs.vessel_name}: #{inspect(e)}")
          {u, s + 1}
      end
    vessel ->
      case TrackedVessel.update(vessel, attrs) do
        {:ok, _}    -> {u + 1, s}
        {:error, e} ->
          IO.puts("  WARN: failed to update #{attrs.vessel_name}: #{inspect(e)}")
          {u, s + 1}
      end
  end
end)

IO.puts("Seeded tracked vessels: #{upserted} upserted, #{skipped} skipped")
IO.puts("River barges: #{Enum.count(vessels, &(&1[:vessel_type] == "barge"))}")
IO.puts("Towboats: #{Enum.count(vessels, &(&1[:vessel_type] == "towboat"))}")
IO.puts("Ocean vessels: #{Enum.count(vessels, &(&1[:vessel_type] in ["gas_carrier", "bulk_carrier", "chemical_tanker"]))}")
IO.puts("Trammo fleet (track_in_fleet=true): #{Enum.count(vessels, &(Map.get(&1, :track_in_fleet, true) == true))}")
IO.puts("Carrying stock (carrying_stock=true): #{Enum.count(vessels, &(Map.get(&1, :carrying_stock, false) == true))}")
