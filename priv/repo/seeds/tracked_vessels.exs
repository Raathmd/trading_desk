# Seed tracked_vessels with real ammonia gas carriers and domestic towboats.
#
# International vessels have confirmed MMSIs from MarineTraffic/VesselFinder.
# Domestic towboats use US-flag MMSI range (366/367/368) — these are realistic
# placeholders since inland vessel MMSIs aren't in public databases. Replace
# with actual Kirby/ARTCO towboat MMSIs from your ops team.
#
# Run: mix run priv/repo/seeds/tracked_vessels.exs

alias TradingDesk.Fleet.TrackedVessel

vessels = [
  # ── AMMONIA INTERNATIONAL ──
  # Real gas carriers confirmed on ammonia/LPG routes

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
    notes: "Hartmann Group MGC — March Trinidad cargo"
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
    notes: "Navigator Gas LPG carrier — Black Sea to India"
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
    notes: "Navigator Gas — Trinidad import to NOLA region"
  },

  # ── AMMONIA DOMESTIC ──
  # Mississippi River towboats pushing NH3 barges.
  # Replace MMSIs with actual Kirby/ARTCO towboat IDs from ops.

  %{
    vessel_name: "MV Miss Kae D",
    mmsi: "367500210",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Donaldsonville",
    discharge_port: "St. Louis",
    eta: Date.add(Date.utc_today(), 6),
    sap_shipping_number: "80012345",
    status: "in_transit",
    notes: "Kirby Inland Marine — 3x refrigerated barges, 4500 MT total"
  },
  %{
    vessel_name: "MV Barbara E",
    mmsi: "367469880",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Donaldsonville",
    discharge_port: "Memphis",
    eta: Date.add(Date.utc_today(), 4),
    sap_shipping_number: "80012346",
    status: "in_transit",
    notes: "ARTCO towboat — 2x barges, 3000 MT"
  },
  %{
    vessel_name: "MV Crystal Allen",
    mmsi: "367703250",
    product_group: "ammonia_domestic",
    cargo: "Anhydrous Ammonia",
    loading_port: "Donaldsonville",
    discharge_port: "Cairo",
    eta: Date.add(Date.utc_today(), 10),
    sap_shipping_number: "80012347",
    status: "active",
    notes: "Marquette Transportation — 3x barges, 4500 MT"
  },

  # ── SULPHUR INTERNATIONAL ──
  %{
    vessel_name: "MV Sulphur Enterprise",
    mmsi: "636092321",
    product_group: "sulphur_international",
    cargo: "Granular Sulphur",
    loading_port: "Ras Tanura",
    discharge_port: "Tampa",
    eta: Date.add(Date.utc_today(), 18),
    status: "in_transit",
    notes: "Bulk carrier — Persian Gulf sulphur"
  },

  # ── PETCOKE ──
  %{
    vessel_name: "MV Gulf Petcoke",
    mmsi: "367125090",
    product_group: "petcoke",
    cargo: "Petroleum Coke",
    loading_port: "Houston",
    discharge_port: "Cartagena",
    eta: Date.add(Date.utc_today(), 7),
    status: "in_transit",
    notes: "Handysize bulk — Gulf petcoke export"
  }
]

for attrs <- vessels do
  case TrackedVessel.get_by_mmsi(attrs.mmsi) do
    nil -> TrackedVessel.create(attrs)
    existing -> TrackedVessel.update(existing, attrs)
  end
end

IO.puts("Seeded #{length(vessels)} tracked vessels")
