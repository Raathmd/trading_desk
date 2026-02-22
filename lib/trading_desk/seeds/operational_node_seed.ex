defmodule TradingDesk.Seeds.OperationalNodeSeed do
  @moduledoc """
  Seeds all operational nodes across every Trammo product group.

  Nodes include: terminals, barge docks, ocean ports, refineries,
  rail yards, USGS river gauge stations, and vessel fleet markers.

  Run once after migrations:

      TradingDesk.Seeds.OperationalNodeSeed.run()
  """

  alias TradingDesk.Repo
  alias TradingDesk.DB.OperationalNodeRecord
  import Ecto.Query
  require Logger

  # ──────────────────────────────────────────────────────────
  # AMMONIA DOMESTIC — Mississippi River Barge
  # ──────────────────────────────────────────────────────────

  @ammonia_domestic [
    # Supply terminals (Trammo's own NH3 storage — source of domestic barge supply)
    %{node_key: "mer",  name: "Meredosia, IL",
      node_type: "barge_dock", role: "supply",
      country: "US", region: "Illinois River",
      lat: 39.8284, lon: -90.5568, capacity_mt: 150_000,
      notes: "Trammo NH3 terminal on Illinois River; primary supply point for St. Louis & Memphis barges"},

    %{node_key: "nio",  name: "Niota, IL",
      node_type: "barge_dock", role: "supply",
      country: "US", region: "Upper Mississippi",
      lat: 40.5798, lon: -91.3162, capacity_mt: 120_000,
      notes: "Trammo NH3 terminal on Upper Mississippi River; supply point for northern and southern routes"},

    # Delivery terminals (where product is delivered and sold)
    %{node_key: "stl",  name: "St. Louis, MO",
      node_type: "barge_dock", role: "demand",
      country: "US", region: "Upper Mississippi",
      lat: 38.6270, lon: -90.1994, capacity_mt: nil,
      notes: "Mississippi River barge unloading dock; Corn Belt distribution hub"},

    %{node_key: "mem",  name: "Memphis, TN",
      node_type: "barge_dock", role: "demand",
      country: "US", region: "Mid Mississippi",
      lat: 35.1495, lon: -90.0490, capacity_mt: nil,
      notes: "Mississippi River barge terminal; Mid-South distribution"},

    # USGS river gauge stations — operational monitoring
    %{node_key: "gauge_baton_rouge", name: "Baton Rouge Gauge (USGS 07374000)",
      node_type: "gauge_station", role: "monitoring",
      country: "US", region: "Lower Mississippi",
      lat: 30.4436, lon: -91.1871, capacity_mt: nil,
      notes: "Primary navigation gauge; draft restrictions below 5 ft"},

    %{node_key: "gauge_vicksburg", name: "Vicksburg Gauge (USGS 07289000)",
      node_type: "gauge_station", role: "monitoring",
      country: "US", region: "Lower Mississippi",
      lat: 32.3526, lon: -90.8779, capacity_mt: nil,
      notes: "Mid-river gauge; indicator of transit conditions Meredosia/Niota→Memphis"},

    %{node_key: "gauge_memphis", name: "Memphis Gauge (USGS 07032000)",
      node_type: "gauge_station", role: "monitoring",
      country: "US", region: "Mid Mississippi",
      lat: 35.1495, lon: -90.0490, capacity_mt: nil,
      notes: "Gauge at Memphis delivery point; low water restricts unloading"},

    %{node_key: "gauge_cairo", name: "Cairo Gauge (USGS 03612500)",
      node_type: "gauge_station", role: "monitoring",
      country: "US", region: "Upper Mississippi",
      lat: 37.0053, lon: -89.1764, capacity_mt: nil,
      notes: "Ohio/Mississippi confluence gauge; leading indicator for St. Louis stage"}
  ]

  # ──────────────────────────────────────────────────────────
  # AMMONIA INTERNATIONAL — Refrigerated Ocean
  # ──────────────────────────────────────────────────────────

  @ammonia_international [
    # Origin loading terminals (FOB)
    %{node_key: "point_lisas", name: "Point Lisas, Trinidad",
      node_type: "port", role: "supply",
      country: "TT", region: "Caribbean",
      lat: 10.4167, lon: -61.5000, capacity_mt: 2_000_000,
      notes: "Yara/Nutrien ammonia terminal; largest Western Hemisphere producer hub"},

    %{node_key: "yuzhnyy", name: "Yuzhnyy, Ukraine",
      node_type: "port", role: "supply",
      country: "UA", region: "Black Sea",
      lat: 46.6302, lon: 31.3695, capacity_mt: 1_000_000,
      notes: "Black Sea export terminal; OPZ / TogliattiAzot supply route; war-risk zone"},

    %{node_key: "jubail", name: "Jubail, Saudi Arabia",
      node_type: "port", role: "supply",
      country: "SA", region: "Middle East / Arabian Gulf",
      lat: 27.0114, lon: 49.6586, capacity_mt: 1_500_000,
      notes: "SABIC / SAFCO ammonia export; major Middle East FOB benchmark"},

    %{node_key: "ruwais", name: "Ruwais, UAE",
      node_type: "port", role: "supply",
      country: "AE", region: "Middle East / Arabian Gulf",
      lat: 24.1104, lon: 52.7300, capacity_mt: 800_000,
      notes: "ADNOC Ruwais fertilizer complex; secondary Middle East supply"},

    # Destination receiving terminals (CFR)
    %{node_key: "tampa", name: "Tampa, FL",
      node_type: "port", role: "demand",
      country: "US", region: "US Gulf",
      lat: 27.9506, lon: -82.4572, capacity_mt: 1_000_000,
      is_trammo_owned: false,
      notes: "Mosaic / CF Industries terminal; primary US ammonia import port"},

    %{node_key: "paradip", name: "Paradip, India",
      node_type: "port", role: "demand",
      country: "IN", region: "East India",
      lat: 20.3201, lon: 86.6118, capacity_mt: 600_000,
      notes: "IFFCO / KRIBHCO receiving terminal; major fertilizer complex"},

    %{node_key: "mumbai", name: "Mumbai, India",
      node_type: "port", role: "demand",
      country: "IN", region: "West India",
      lat: 18.9220, lon: 72.8347, capacity_mt: 400_000,
      notes: "Nhava Sheva / JNPT; secondary India receiving port"},

    %{node_key: "jorf_lasfar_nh3", name: "Jorf Lasfar, Morocco",
      node_type: "port", role: "demand",
      country: "MA", region: "North Africa",
      lat: 33.1026, lon: -8.6379, capacity_mt: 1_200_000,
      notes: "OCP phosphate complex; largest ammonia consumer in North Africa"},

    # Vessel fleet marker
    %{node_key: "nh3_fleet", name: "NH3 Refrigerated Carrier Fleet",
      node_type: "vessel_fleet", role: "waypoint",
      country: "XX", region: "Global",
      lat: nil, lon: nil, capacity_mt: nil,
      notes: "Trammo-chartered refrigerated ammonia carriers (25,000–52,000 MT class)"}
  ]

  # ──────────────────────────────────────────────────────────
  # PETCOKE — Global Bulk
  # ──────────────────────────────────────────────────────────

  @petcoke [
    # US Gulf Coast origin refineries and export terminals
    %{node_key: "houston_ship_channel", name: "Houston Ship Channel, TX",
      node_type: "terminal", role: "supply",
      country: "US", region: "US Gulf",
      lat: 29.7604, lon: -95.3698, capacity_mt: 5_000_000,
      notes: "ExxonMobil Baytown, Shell Deer Park, Lyondell refineries; largest USGC petcoke hub"},

    %{node_key: "port_arthur", name: "Port Arthur, TX",
      node_type: "terminal", role: "supply",
      country: "US", region: "US Gulf",
      lat: 29.8988, lon: -93.9399, capacity_mt: 3_000_000,
      notes: "Motiva (Saudi Aramco/Shell), Total; second-largest USGC export point"},

    %{node_key: "beaumont", name: "Beaumont, TX",
      node_type: "terminal", role: "supply",
      country: "US", region: "US Gulf",
      lat: 30.0861, lon: -94.1018, capacity_mt: 1_500_000,
      notes: "ExxonMobil / Motiva refinery complex"},

    %{node_key: "baton_rouge_refinery", name: "Baton Rouge, LA (ExxonMobil)",
      node_type: "refinery", role: "supply",
      country: "US", region: "US Gulf",
      lat: 30.4436, lon: -91.1871, capacity_mt: 1_000_000,
      notes: "ExxonMobil Baton Rouge refinery; barged to Gulf terminals for export"},

    # India origin refineries
    %{node_key: "jamnagar", name: "Jamnagar, India (Reliance)",
      node_type: "refinery", role: "supply",
      country: "IN", region: "West India",
      lat: 22.4707, lon: 70.0577, capacity_mt: 8_000_000,
      notes: "Reliance Industries; world's largest refining complex; major petcoke exporter"},

    %{node_key: "panipat", name: "Panipat, India (IOCL)",
      node_type: "refinery", role: "supply",
      country: "IN", region: "North India",
      lat: 29.3909, lon: 76.9635, capacity_mt: 1_200_000,
      notes: "Indian Oil Corporation; significant domestic and export petcoke source"},

    # Destination ports
    %{node_key: "mundra", name: "Mundra, India",
      node_type: "port", role: "demand",
      country: "IN", region: "West India",
      lat: 22.8387, lon: 69.7029, capacity_mt: 10_000_000,
      notes: "Adani Ports; largest private port; primary Indian petcoke import terminal"},

    %{node_key: "kandla", name: "Kandla, India",
      node_type: "port", role: "demand",
      country: "IN", region: "West India",
      lat: 23.0333, lon: 70.2167, capacity_mt: 8_000_000,
      notes: "Deendayal Port; cement and power sector petcoke imports"},

    %{node_key: "qingdao", name: "Qingdao, China",
      node_type: "port", role: "demand",
      country: "CN", region: "East China",
      lat: 36.0671, lon: 120.3826, capacity_mt: 15_000_000,
      notes: "Primary Chinese petcoke import port; aluminum smelting / power"},

    %{node_key: "lianyungang", name: "Lianyungang, China",
      node_type: "port", role: "demand",
      country: "CN", region: "East China",
      lat: 34.5970, lon: 119.2220, capacity_mt: 5_000_000,
      notes: "Secondary China petcoke terminal; chemical feedstock"},

    %{node_key: "aliaga", name: "Aliağa, Turkey",
      node_type: "port", role: "demand",
      country: "TR", region: "Aegean Turkey",
      lat: 38.8030, lon: 26.9740, capacity_mt: 3_000_000,
      notes: "Primary Turkish petcoke import; cement industry fuel"}
  ]

  # ──────────────────────────────────────────────────────────
  # SULPHUR INTERNATIONAL — Global Bulk
  # ──────────────────────────────────────────────────────────

  @sulphur_international [
    # Origin terminals
    %{node_key: "vancouver_pct", name: "Vancouver, BC (Pacific Coast Terminals)",
      node_type: "terminal", role: "supply",
      country: "CA", region: "Pacific Coast",
      lat: 49.3024, lon: -123.1192, capacity_mt: 3_000_000,
      is_trammo_owned: false,
      notes: "PCT — one of world's largest sulphur export terminals; fed by Alberta oil sands via rail"},

    %{node_key: "moose_jaw", name: "Moose Jaw, SK (Mosaic / Nutrien)",
      node_type: "rail_yard", role: "supply",
      country: "CA", region: "Canadian Prairies",
      lat: 50.3934, lon: -105.5519, capacity_mt: nil,
      notes: "Upstream oil sands / refinery sulphur; moves to Vancouver via CN/CP Rail"},

    %{node_key: "ruwais_s", name: "Ruwais, UAE (ADNOC Sulphur)",
      node_type: "terminal", role: "supply",
      country: "AE", region: "Middle East / Arabian Gulf",
      lat: 24.1104, lon: 52.7300, capacity_mt: 5_000_000,
      notes: "ADNOC refinery / gas processing; world's largest single sulphur export point"},

    %{node_key: "mina_ahmadi", name: "Mina Al-Ahmadi, Kuwait",
      node_type: "port", role: "supply",
      country: "KW", region: "Middle East / Arabian Gulf",
      lat: 29.0731, lon: 48.1482, capacity_mt: 1_500_000,
      notes: "KOC / KNPC refinery sulphur export; Arabian Gulf benchmark"},

    %{node_key: "mesaieed", name: "Mesaieed, Qatar",
      node_type: "port", role: "supply",
      country: "QA", region: "Middle East / Arabian Gulf",
      lat: 24.9977, lon: 51.5550, capacity_mt: 2_000_000,
      notes: "QatarEnergy / Qapco; large LNG-associated sulphur volumes"},

    %{node_key: "batumi", name: "Batumi, Georgia",
      node_type: "terminal", role: "supply",
      country: "GE", region: "Black Sea",
      lat: 41.6422, lon: 41.6394, capacity_mt: 1_000_000,
      is_trammo_owned: true,
      notes: "Trammo-owned terminal; receives Kazakhstani sulphur via Caspian Sea / rail"},

    %{node_key: "aktau", name: "Aktau, Kazakhstan",
      node_type: "port", role: "supply",
      country: "KZ", region: "Caspian Sea",
      lat: 43.6486, lon: 51.1727, capacity_mt: 800_000,
      notes: "Tengizchevroil / KazMunayGas; Caspian ferry connection to Baku/Batumi"},

    # Destination ports
    %{node_key: "jorf_lasfar_s", name: "Jorf Lasfar, Morocco",
      node_type: "port", role: "demand",
      country: "MA", region: "North Africa",
      lat: 33.1026, lon: -8.6379, capacity_mt: 5_000_000,
      notes: "OCP Group phosphate complex; world's largest sulphur consumer; ~3M MT/yr"},

    %{node_key: "safi", name: "Safi, Morocco",
      node_type: "port", role: "demand",
      country: "MA", region: "North Africa",
      lat: 32.2994, lon: -9.2365, capacity_mt: 1_000_000,
      notes: "OCP Safi complex; secondary Morocco sulphur terminal"},

    %{node_key: "mumbai_s", name: "Mumbai, India",
      node_type: "port", role: "demand",
      country: "IN", region: "West India",
      lat: 18.9220, lon: 72.8347, capacity_mt: 2_000_000,
      notes: "JNPT / Nhava Sheva; fertilizer and chemical sulphur imports"},

    %{node_key: "paradip_s", name: "Paradip, India",
      node_type: "port", role: "demand",
      country: "IN", region: "East India",
      lat: 20.3201, lon: 86.6118, capacity_mt: 1_500_000,
      notes: "IFFCO / GSFC; East Coast India fertilizer sulphur terminal"},

    %{node_key: "ennore", name: "Ennore, India",
      node_type: "port", role: "demand",
      country: "IN", region: "South India",
      lat: 13.2020, lon: 80.3200, capacity_mt: 800_000,
      notes: "Kamarajar Port; Tamil Nadu fertilizer / chemical imports"},

    %{node_key: "nanjing_s", name: "Nanjing, China",
      node_type: "port", role: "demand",
      country: "CN", region: "East China",
      lat: 32.0603, lon: 118.7969, capacity_mt: 3_000_000,
      notes: "Yangtze River terminal; chemical and fertilizer sulphur"},

    %{node_key: "zhanjiang", name: "Zhanjiang, China",
      node_type: "port", role: "demand",
      country: "CN", region: "South China",
      lat: 21.2714, lon: 110.3592, capacity_mt: 2_500_000,
      notes: "Baoshan / CNOOC refinery complex; fertilizer sulphur hub"},

    %{node_key: "santos", name: "Santos, Brazil",
      node_type: "port", role: "demand",
      country: "BR", region: "South America",
      lat: -23.9619, lon: -46.3291, capacity_mt: 2_000_000,
      notes: "Primary Brazilian sulphur terminal; fertilizer sector (soy / sugar belt)"},

    %{node_key: "paranagua", name: "Paranaguá, Brazil",
      node_type: "port", role: "demand",
      country: "BR", region: "South America",
      lat: -25.5200, lon: -48.5100, capacity_mt: 1_500_000,
      notes: "Parana state fertilizer terminal; secondary Brazil sulphur import point"}
  ]

  # ──────────────────────────────────────────────────────────
  # RUN
  # ──────────────────────────────────────────────────────────

  def run do
    seed_group("ammonia_domestic",      @ammonia_domestic)
    seed_group("ammonia_international", @ammonia_international)
    seed_group("petcoke",               @petcoke)
    seed_group("sulphur_international", @sulphur_international)
    Logger.info("OperationalNodeSeed: complete")
  end

  defp seed_group(product_group, nodes) do
    Enum.each(nodes, fn attrs ->
      full_attrs = Map.put(attrs, :product_group, product_group)

      unless Repo.exists?(
        from n in OperationalNodeRecord,
        where: n.product_group == ^product_group and n.node_key == ^attrs.node_key
      ) do
        %OperationalNodeRecord{}
        |> OperationalNodeRecord.changeset(full_attrs)
        |> Repo.insert!()
      end
    end)

    Logger.info("OperationalNodeSeed: #{length(nodes)} nodes for #{product_group}")
  end
end
