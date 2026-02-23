# Trammo Product Group — Variables & Constraints Reference

_Date: 2026-02-23_
_Purpose: Comprehensive catalogue of what is modelled in each product group frame, what is currently stub/unconnected, and requirements for frames that still need to be built. This document is the specification baseline for model builders._

---

## 1. Overview

The system uses a **frame architecture**: each product group is a self-contained specification of variables, routes, constraints, API sources, and perturbation parameters. The generic Zig LP solver consumes any frame identically via a binary model descriptor.

Four frames currently exist. Two product groups (UAN, Urea) are registered as aliases pointing to the `AmmoniaDomestic` frame — they need their own frames built. Additional Trammo product lines (nitric acid, green/blue ammonia, sulphuric acid) have no frame at all.

### 1.1 Registry State

| Frame ID | Module | Status |
|---|---|---|
| `ammonia_domestic` | `Frames.AmmoniaDomestic` | **Full** — live data, production use |
| `ammonia_international` | `Frames.AmmoniaInternational` | **Partial** — structure complete, market/freight APIs are stubs |
| `sulphur_international` | `Frames.SulphurInternational` | **Partial** — structure complete, market/freight APIs are stubs |
| `petcoke` | `Frames.Petcoke` | **Partial** — structure complete, market/freight APIs are stubs |
| `uan` | → `Frames.AmmoniaDomestic` | **Placeholder** — must be replaced with a UAN-specific frame |
| `urea` | → `Frames.AmmoniaDomestic` | **Placeholder** — must be replaced with a Urea-specific frame |
| `nitric_acid` | — | **Missing** — no frame exists |
| `green_ammonia` | — | **Missing** — no frame exists |
| `sulphuric_acid` | — | **Missing** — no frame exists |

---

## 2. Existing Frames — Complete Variable & Constraint Catalogue

### 2.1 `ammonia_domestic` — NH3 Domestic Barge

**Geography:** Illinois & Upper Mississippi River, USA
**Transport:** Inland waterway barge
**Routes:** 4 (Meredosia/Niota × St. Louis/Memphis)
**Variables:** 20 | **Constraints:** 6

#### Variables

| # | Key | Label | Unit | Min | Max | Default | Source | Group | Type |
|---|---|---|---|---|---|---|---|---|---|
| 0 | `river_stage` | River Stage | ft | 2 | 55 | 18.0 | USGS | environment | float |
| 1 | `lock_hrs` | Lock Delays | hrs | 0 | 96 | 12.0 | USACE | environment | float |
| 2 | `temp_f` | Temperature | °F | -20 | 115 | 45.0 | NOAA | environment | float |
| 3 | `wind_mph` | Wind Speed | mph | 0 | 55 | 12.0 | NOAA | environment | float |
| 4 | `vis_mi` | Visibility | mi | 0.05 | 15 | 5.0 | NOAA | environment | float |
| 5 | `precip_in` | Precip (3-day) | in | 0 | 8 | 1.0 | NOAA | environment | float |
| 6 | `inv_mer` | Meredosia Inv | tons | 0 | 15,000 | 12,000 | Insight TMS | operations | float |
| 7 | `inv_nio` | Niota Inv | tons | 0 | 10,000 | 8,000 | Insight TMS | operations | float |
| 8 | `mer_outage` | Meredosia Outage | — | 0 | 1 | false | Manual | operations | boolean |
| 9 | `nio_outage` | Niota Outage | — | 0 | 1 | false | Manual | operations | boolean |
| 10 | `barge_count` | Barges Available | count | 1 | 30 | 14 | Internal | operations | float |
| 11 | `demand_stl` | StL Max Demand | tons | 0 | 20,000 | 10,000 | Internal | operations | float |
| 12 | `demand_mem` | Memphis Max Demand | tons | 0 | 15,000 | 8,000 | Internal | operations | float |
| 13 | `nola_buy` | NH3 NOLA Buy | $/t | 200 | 600 | 320 | Market API | commercial | float |
| 14 | `sell_stl` | NH3 StL Delivered | $/t | 300 | 600 | 410 | Market API | commercial | float |
| 15 | `sell_mem` | NH3 Memphis Delivered | $/t | 280 | 550 | 385 | Market API | commercial | float |
| 16 | `fr_mer_stl` | Freight Mer→StL | $/t | 10 | 80 | 25 | Broker API | commercial | float |
| 17 | `fr_mer_mem` | Freight Mer→Mem | $/t | 20 | 100 | 48 | Broker API | commercial | float |
| 18 | `fr_nio_stl` | Freight Nio→StL | $/t | 20 | 110 | 42 | Broker API | commercial | float |
| 19 | `fr_nio_mem` | Freight Nio→Mem | $/t | 25 | 120 | 58 | Broker API | commercial | float |
| 20 | `nat_gas` | Nat Gas (Henry Hub) | $/MMBtu | 1.0 | 8.0 | 2.80 | EIA | commercial | float |
| 21 | `working_cap` | Working Capital | $ | 500k | 10M | 4.2M | SAP FI | commercial | float |

#### Routes

| Key | Origin | Destination | Distance | Transit days | Barge capacity |
|---|---|---|---|---|---|
| `mer_stl` | Meredosia, IL | St. Louis, MO | 100 mi | 1.0 | 1,500 t |
| `mer_mem` | Meredosia, IL | Memphis, TN | 450 mi | 4.0 | 1,500 t |
| `nio_stl` | Niota, IL | St. Louis, MO | 260 mi | 2.5 | 1,500 t |
| `nio_mem` | Niota, IL | Memphis, TN | 590 mi | 5.0 | 1,500 t |

#### Constraints

| Key | Type | Bound variable | Affected routes |
|---|---|---|---|
| `supply_mer` | CT_SUPPLY | `inv_mer` | mer_stl, mer_mem |
| `supply_nio` | CT_SUPPLY | `inv_nio` | nio_stl, nio_mem |
| `cap_stl` | CT_DEMAND | `demand_stl` (outage: `mer_outage`) | mer_stl, nio_stl |
| `cap_mem` | CT_DEMAND | `demand_mem` (outage: `nio_outage`) | mer_mem, nio_mem |
| `fleet` | CT_FLEET | `barge_count` | all 4 routes |
| `working_cap` | CT_CAPITAL | `working_cap` | all 4 routes |

#### API Connectivity — Live

| Source | Module | Variables fed |
|---|---|---|
| USGS | `Data.API.USGS` | `river_stage` |
| NOAA | `Data.API.NOAA` | `temp_f`, `wind_mph`, `vis_mi`, `precip_in` |
| USACE | `Data.API.USACE` | `lock_hrs` |
| EIA | `Data.API.EIA` | `nat_gas` |
| Market | `Data.API.Market` | `nola_buy`, `sell_stl`, `sell_mem` |
| Broker | `Data.API.Broker` | all 4 freight rates |
| Internal/Insight | `Data.API.Internal` | inventory, outages, barge count, demands, working cap |

**Status: All API sources connected. This frame is production-ready.**

---

### 2.2 `ammonia_international` — NH3 International Ocean

**Geography:** Global — Trinidad, Black Sea, Middle East → Tampa, India, Morocco
**Transport:** Refrigerated ocean vessel
**Routes:** 4 | **Variables:** 24 | **Constraints:** 8

#### Variables

| # | Key | Label | Unit | Min | Max | Default | Source | Group |
|---|---|---|---|---|---|---|---|---|
| 0 | `fob_trinidad` | FOB Trinidad | $/t | 150 | 700 | 350 | ⚠️ stub | market |
| 1 | `fob_yuzhnyy` | FOB Yuzhnyy | $/t | 150 | 700 | 320 | ⚠️ stub | market |
| 2 | `fob_mideast` | FOB ME (Saudi) | $/t | 150 | 700 | 310 | ⚠️ stub | market |
| 3 | `cfr_tampa` | CFR Tampa | $/t | 200 | 800 | 420 | ⚠️ stub | market |
| 4 | `cfr_india` | CFR India | $/t | 200 | 750 | 380 | ⚠️ stub | market |
| 5 | `cfr_morocco` | CFR Morocco | $/t | 200 | 750 | 370 | ⚠️ stub | market |
| 6 | `fr_trinidad_tampa` | Freight Trin→Tampa | $/t | 15 | 80 | 30 | ⚠️ stub | freight |
| 7 | `fr_yuzhnyy_morocco` | Freight Yuzh→Morocco | $/t | 20 | 90 | 40 | ⚠️ stub | freight |
| 8 | `fr_me_india` | Freight ME→India | $/t | 15 | 70 | 28 | ⚠️ stub | freight |
| 9 | `fr_trinidad_india` | Freight Trin→India | $/t | 35 | 120 | 65 | ⚠️ stub | freight |
| 10 | `vessel_count` | NH3 Carriers Available | count | 0 | 10 | 3 | Internal | operations |
| 11 | `storage_tampa_kt` | Tampa Terminal Storage | kt | 0 | 100 | 35 | Internal | operations |
| 12 | `plant_utilization_pct` | Supplier Plant Util | % | 50 | 100 | 88 | Internal | operations |
| 13 | `tank_level_pct` | Dest Tank Levels | % | 0 | 100 | 60 | Internal | operations |
| 14 | `supply_trinidad_kt` | Trinidad Supply Cap | kt | 0 | 200 | 40 | Internal | operations |
| 15 | `supply_yuzhnyy_kt` | Yuzhnyy Supply Cap | kt | 0 | 100 | 25 | Internal | operations |
| 16 | `supply_mideast_kt` | ME Supply Cap | kt | 0 | 200 | 50 | Internal | operations |
| 17 | `demand_tampa_kt` | Tampa Demand Cap | kt | 0 | 100 | 50 | Internal | operations |
| 18 | `demand_india_kt` | India Demand Cap | kt | 0 | 300 | 100 | Internal | operations |
| 19 | `demand_morocco_kt` | Morocco Demand Cap | kt | 0 | 200 | 50 | Internal | operations |
| 20 | `nat_gas_feedstock` | Nat Gas (feedstock) | $/MMBtu | 1 | 12 | 3.50 | EIA (live) | macro |
| 21 | `bunker_380` | Bunker 380cSt | $/t | 200 | 800 | 480 | ⚠️ stub | macro |
| 22 | `eur_usd` | EUR/USD | rate | 0.8 | 1.3 | 1.08 | ⚠️ stub | macro |
| 23 | `working_cap` | Working Capital | $M | 5 | 200 | 50 | SAP FI | macro |

#### Routes

| Key | Origin | Destination | Distance | Transit days | Vessel cap |
|---|---|---|---|---|---|
| `trinidad_tampa` | Point Lisas, Trinidad | Tampa, FL | 1,800 nm | 5 | 30,000 t |
| `yuzhnyy_morocco` | Yuzhnyy, Ukraine | Jorf Lasfar, Morocco | 3,500 nm | 10 | 30,000 t |
| `me_india` | Jubail, Saudi Arabia | Paradip/Mumbai, India | 2,200 nm | 7 | 30,000 t |
| `trinidad_india` | Point Lisas, Trinidad | Paradip/Mumbai, India | 10,000 nm | 30 | 30,000 t |

#### Constraints

| Key | Type | Bound variable | Affected routes |
|---|---|---|---|
| `supply_trinidad` | CT_SUPPLY | `supply_trinidad_kt` | trinidad_tampa, trinidad_india |
| `supply_yuzhnyy` | CT_SUPPLY | `supply_yuzhnyy_kt` | yuzhnyy_morocco |
| `supply_mideast` | CT_SUPPLY | `supply_mideast_kt` | me_india |
| `dest_tampa` | CT_DEMAND | `demand_tampa_kt` | trinidad_tampa |
| `dest_india` | CT_DEMAND | `demand_india_kt` | me_india, trinidad_india |
| `dest_morocco` | CT_DEMAND | `demand_morocco_kt` | yuzhnyy_morocco |
| `fleet` | CT_FLEET | `vessel_count` | all 4 routes |
| `working_cap` | CT_CAPITAL | `working_cap` | all 4 routes |

#### API Connectivity — Gaps

| Source | Module | Status |
|---|---|---|
| Market prices (Argus Ammonia, ICIS, Fertecon) | `nil` | **Not connected** |
| Ocean freight (Baltic Exchange, Clarksons) | `nil` | **Not connected** |
| Vessel tracking (AIS) | `Data.API.VesselTracking` | Connected (no variables assigned) |
| Nat gas (EIA) | `Data.API.EIA` | **Connected** |
| FX rates (EUR/USD) | `nil` | **Not connected** |
| Bunker fuel | `nil` | **Not connected** |
| Internal/SAP | `nil` | **Not connected** |

**Status: Frame specification complete. Blocked on market data API integrations.**

---

### 2.3 `sulphur_international` — Sulphur International Ocean

**Geography:** Global — Middle East, Vancouver, Batumi → Morocco, India, China
**Transport:** Ocean bulk carrier + rail (Central Asia origins)
**Routes:** 4 | **Variables:** 22 | **Constraints:** 8

#### Variables

| # | Key | Label | Unit | Min | Max | Default | Source | Group |
|---|---|---|---|---|---|---|---|---|
| 0 | `fob_vancouver` | FOB Vancouver | $/t | 50 | 300 | 120 | ⚠️ stub | market |
| 1 | `fob_mideast` | FOB Middle East | $/t | 40 | 280 | 95 | ⚠️ stub | market |
| 2 | `fob_batumi` | FOB Batumi | $/t | 40 | 250 | 88 | ⚠️ stub | market |
| 3 | `cfr_morocco` | CFR Morocco | $/t | 80 | 350 | 155 | ⚠️ stub | market |
| 4 | `cfr_india` | CFR India | $/t | 70 | 350 | 140 | ⚠️ stub | market |
| 5 | `cfr_china` | CFR China | $/t | 70 | 350 | 145 | ⚠️ stub | market |
| 6 | `fr_van_morocco` | Freight Van→Morocco | $/t | 15 | 80 | 32 | ⚠️ stub | freight |
| 7 | `fr_me_india` | Freight ME→India | $/t | 8 | 50 | 18 | ⚠️ stub | freight |
| 8 | `fr_me_china` | Freight ME→China | $/t | 12 | 65 | 25 | ⚠️ stub | freight |
| 9 | `fr_batumi_morocco` | Freight Batumi→Morocco | $/t | 10 | 55 | 22 | ⚠️ stub | freight |
| 10 | `port_congestion_days` | Dest Port Congestion | days | 0 | 30 | 3 | ⚠️ stub | operations |
| 11 | `vessel_count` | Vessels Available | count | 0 | 20 | 6 | Internal | operations |
| 12 | `storage_vancouver_kt` | Vancouver Storage | kt | 0 | 500 | 180 | Internal | operations |
| 13 | `rail_capacity_pct` | Rail Capacity | % | 0 | 100 | 85 | Internal | operations |
| 14 | `supply_mideast_kt` | ME Supply Cap | kt | 0 | 1,000 | 300 | Internal | operations |
| 15 | `supply_batumi_kt` | Batumi Supply Cap | kt | 0 | 300 | 100 | Internal | operations |
| 16 | `demand_morocco_kt` | Morocco Demand Cap | kt | 0 | 500 | 200 | Internal | operations |
| 17 | `demand_india_kt` | India Demand Cap | kt | 0 | 800 | 300 | Internal | operations |
| 18 | `demand_china_kt` | China Demand Cap | kt | 0 | 1,000 | 500 | Internal | operations |
| 19 | `usd_inr` | USD/INR | rate | 70 | 100 | 83.5 | ⚠️ stub | macro |
| 20 | `bunker_380` | Bunker 380cSt | $/t | 200 | 800 | 480 | ⚠️ stub | macro |
| 21 | `suez_canal_usd` | Suez Transit Cost | $k | 100 | 800 | 350 | Internal | macro |
| 22 | `working_cap` | Working Capital | $M | 1 | 100 | 25 | SAP FI | macro |

#### Routes

| Key | Origin | Destination | Distance | Transit days | Vessel cap |
|---|---|---|---|---|---|
| `van_morocco` | Vancouver, BC | Jorf Lasfar, Morocco | 8,900 nm | 25 | 50,000 t |
| `me_india` | Abu Dhabi/Ruwais, UAE | Mumbai/Paradip, India | 1,800 nm | 7 | 50,000 t |
| `me_china` | Abu Dhabi/Ruwais, UAE | Nanjing/Zhanjiang, China | 5,500 nm | 18 | 50,000 t |
| `batumi_morocco` | Batumi, Georgia | Jorf Lasfar, Morocco | 3,200 nm | 10 | 50,000 t |

#### Constraints

| Key | Type | Bound variable | Affected routes |
|---|---|---|---|
| `supply_vancouver` | CT_SUPPLY | `storage_vancouver_kt` | van_morocco |
| `supply_mideast` | CT_SUPPLY | `supply_mideast_kt` | me_india, me_china |
| `supply_batumi` | CT_SUPPLY | `supply_batumi_kt` | batumi_morocco |
| `dest_morocco` | CT_DEMAND | `demand_morocco_kt` | van_morocco, batumi_morocco |
| `dest_india` | CT_DEMAND | `demand_india_kt` | me_india |
| `dest_china` | CT_DEMAND | `demand_china_kt` | me_china |
| `fleet` | CT_FLEET | `vessel_count` | all 4 routes |
| `working_cap` | CT_CAPITAL | `working_cap` | all 4 routes |

**Status: Frame specification complete. Blocked on market data API integrations. Same API gap as NH3 International.**

---

### 2.4 `petcoke` — Petroleum Coke

**Geography:** Global — US Gulf, India → India, China
**Transport:** Ocean bulk carrier
**Routes:** 3 | **Variables:** 16 | **Constraints:** 6

#### Variables

| # | Key | Label | Unit | Min | Max | Default | Source | Group |
|---|---|---|---|---|---|---|---|---|
| 0 | `fob_usgc` | FOB US Gulf | $/t | 30 | 200 | 55 | ⚠️ stub | market |
| 1 | `fob_india` | FOB India | $/t | 20 | 180 | 42 | ⚠️ stub | market |
| 2 | `cfr_india` | CFR India | $/t | 50 | 250 | 82 | ⚠️ stub | market |
| 3 | `cfr_china` | CFR China | $/t | 50 | 250 | 88 | ⚠️ stub | market |
| 4 | `fr_usgc_india` | Freight USGC→India | $/t | 15 | 70 | 30 | ⚠️ stub | freight |
| 5 | `fr_usgc_china` | Freight USGC→China | $/t | 20 | 80 | 35 | ⚠️ stub | freight |
| 6 | `fr_india_china` | Freight India→China | $/t | 8 | 40 | 15 | ⚠️ stub | freight |
| 7 | `refinery_util_pct` | Refinery Utilization | % | 60 | 100 | 92 | ⚠️ stub (EIA) | operations |
| 8 | `storage_usgc_kt` | USGC Storage | kt | 0 | 300 | 120 | Internal | operations |
| 9 | `vessel_count` | Vessels Available | count | 0 | 15 | 4 | Internal | operations |
| 10 | `load_rate_tpd` | Load Rate | t/day | 5,000 | 30,000 | 15,000 | Internal | operations |
| 11 | `supply_india_kt` | India Supply Cap | kt | 0 | 200 | 60 | Internal | operations |
| 12 | `demand_india_kt` | India Demand Cap | kt | 0 | 500 | 200 | Internal | operations |
| 13 | `demand_china_kt` | China Demand Cap | kt | 0 | 600 | 300 | Internal | operations |
| 14 | `hgi` | HGI (Hardgrove) | index | 30 | 100 | 55 | Internal | quality |
| 15 | `sulfur_pct` | Sulfur Content | % | 1 | 8 | 5.5 | Internal | quality |
| 16 | `cv_kcal` | Calorific Value | kcal/kg | 6,000 | 8,500 | 7,800 | Internal | quality |
| 17 | `bunker_380` | Bunker 380cSt | $/t | 200 | 800 | 480 | ⚠️ stub | macro |
| 18 | `working_cap` | Working Capital | $M | 1 | 50 | 12 | SAP FI | macro |

#### Routes

| Key | Origin | Destination | Distance | Transit days | Vessel cap |
|---|---|---|---|---|---|
| `usgc_india` | US Gulf Coast | Mundra/Kandla, India | 9,500 nm | 35 | 50,000 t |
| `usgc_china` | US Gulf Coast | Qingdao/Lianyungang, China | 11,000 nm | 40 | 50,000 t |
| `india_china` | Mundra/Jamnagar, India | Qingdao/Lianyungang, China | 4,500 nm | 15 | 50,000 t |

#### Constraints

| Key | Type | Bound variable | Affected routes |
|---|---|---|---|
| `supply_usgc` | CT_SUPPLY | `storage_usgc_kt` | usgc_india, usgc_china |
| `supply_india` | CT_SUPPLY | `supply_india_kt` | india_china |
| `dest_india` | CT_DEMAND | `demand_india_kt` | usgc_india |
| `dest_china` | CT_DEMAND | `demand_china_kt` | usgc_china, india_china |
| `fleet` | CT_FLEET | `vessel_count` | all 3 routes |
| `working_cap` | CT_CAPITAL | `working_cap` | all 3 routes |

**Petcoke-specific note:** Three quality variables (`hgi`, `sulfur_pct`, `cv_kcal`) are tracked but do not currently feed into the LP objective or constraints. They are available for future use (e.g., quality discount/premium adjustments on the sell price, or buyer specification constraints). Building this linkage is a model-building task.

**Status: Frame specification complete. Blocked on market data API integrations.**

---

## 3. Missing Frames — Requirements for Model Building

These product groups need a new `Frames.<Module>` created, registered in `ProductGroup.@registry`, and supplied with test seed data before the LP solver can operate on them.

---

### 3.1 `uan` — Urea Ammonium Nitrate Solution

**Business context:** UAN (28%, 30%, or 32% N) is a liquid nitrogen fertilizer commonly used in the US Corn Belt and Europe. Trammo trades UAN as part of its nitrogen fertilizer portfolio.

**Transport:** Inland barge (primary US distribution), ocean vessel (for international trade), rail

**Relationship to existing frames:** UAN trades on similar river routes to NH3 domestic but is **not interchangeable** — different terminals, different buyer types (agriculture co-ops vs. industrial), different seasonal demand profile (spring planting peak), different price series.

#### Required Variables

| Group | Key (suggested) | Label | Unit | Notes |
|---|---|---|---|---|
| **Environment** | `river_stage` | River Stage | ft | Share USGS feed with NH3 domestic |
| **Environment** | `lock_hrs` | Lock Delays | hrs | Share USACE feed |
| **Environment** | `temp_f` | Temperature | °F | Share NOAA feed |
| **Operations** | `inv_nola_uan` | NOLA UAN Terminal Inv | tons | Storage at Gulf origin terminals |
| **Operations** | `inv_midwest_uan` | Midwest UAN Storage | tons | Destination storage level |
| **Operations** | `terminal_outage` | Terminal Outage | boolean | Outage flag at origin |
| **Operations** | `barge_count_uan` | Barges Available (UAN) | count | UAN-rated barges (lined tanks) |
| **Operations** | `demand_spring_peak` | Spring Application Window | boolean | Binary flag: spring peak in effect |
| **Commercial** | `uan_nola_buy` | UAN NOLA (28%) Buy | $/t | Primary price benchmark (Argus/ICIS UAN NOLA) |
| **Commercial** | `uan_stl_sell` | UAN St. Louis Delivered | $/t | Delivered Midwest price |
| **Commercial** | `uan_corn_belt_sell` | UAN Corn Belt Delivered | $/t | Agricultural demand region |
| **Commercial** | `fr_nola_stl` | Freight NOLA→StL | $/t | Barge freight rate |
| **Commercial** | `fr_nola_cb` | Freight NOLA→Corn Belt | $/t | Barge freight rate to agricultural hub |
| **Commercial** | `nat_gas` | Nat Gas (Henry Hub) | $/MMBtu | Correlated with UAN production cost |
| **Commercial** | `working_cap_uan` | Working Capital | $ | Separate UAN budget allocation |

#### Required Routes

| Route | Origin | Destination | Transport |
|---|---|---|---|
| `nola_stl` | NOLA UAN terminal | St. Louis, MO | Barge (Mississippi) |
| `nola_corn_belt` | NOLA UAN terminal | Corn Belt hub (IL/IN) | Barge (Illinois River) |

#### Required Constraints

| Constraint | Type | Notes |
|---|---|---|
| `supply_nola` | CT_SUPPLY | `inv_nola_uan` |
| `dest_stl` | CT_DEMAND | StL demand cap |
| `dest_corn_belt` | CT_DEMAND | Corn Belt demand cap; should increase significantly when `demand_spring_peak = true` |
| `fleet_uan` | CT_FLEET | `barge_count_uan` — UAN requires lined tank barges, separate fleet from NH3 |
| `working_cap` | CT_CAPITAL | `working_cap_uan` |

#### Data Sources Required

| Variable group | Source |
|---|---|
| UAN spot prices (NOLA, delivered) | Argus FMB, ICIS UAN assessments |
| Freight rates (barge) | Existing broker API — extend to UAN |
| Terminal inventory | Internal TMS |
| River/weather | Existing USGS/NOAA/USACE feeds — reuse |

#### Model-Building Notes
- UAN has a pronounced **spring seasonal demand spike** — consider a binary `demand_spring_peak` variable that relaxes or tightens the demand cap constraint rather than a static bound.
- UAN prices are correlated with (but not identical to) NH3 prices. Include a correlation term in perturbation parameters linking `uan_nola_buy` to `nola_buy` from the NH3 domestic frame.
- Minimum variable count estimate: **14–16**. Maximum routes needed initially: **2–3** (can expand later).

---

### 3.2 `urea` — Urea (Granular/Prilled)

**Business context:** Urea is the world's most widely traded nitrogen fertilizer (46% N, solid form). Trammo participates in global urea trading through its Batumi terminal hub and ocean vessel fleet. Unlike NH3 or UAN, urea requires **no refrigeration** — standard bulk carriers.

**Transport:** Ocean bulk carrier (primary), rail (inland distribution from Batumi)

#### Required Variables

| Group | Key (suggested) | Label | Unit | Notes |
|---|---|---|---|---|
| **Market prices** | `fob_mideast_urea` | FOB Middle East (Urea) | $/t | Saudi Arabia, Qatar — Argus/ICIS Urea ME assessment |
| **Market prices** | `fob_china_urea` | FOB China (Urea) | $/t | China urea export benchmark |
| **Market prices** | `fob_black_sea_urea` | FOB Black Sea (Urea) | $/t | Egypt, Russia — Baltic/Black Sea benchmark |
| **Market prices** | `cfr_india_urea` | CFR India (Urea) | $/t | India is the world's largest importer |
| **Market prices** | `cfr_nola_urea` | CFR US Gulf (Urea) | $/t | US import price — NOLA/Tampa delivery |
| **Market prices** | `cfr_brazil_urea` | CFR Brazil (Urea) | $/t | Brazil agricultural import |
| **Freight** | `fr_me_india_urea` | Freight ME→India | $/t | Supramax/Panamax bulk rate |
| **Freight** | `fr_me_brazil_urea` | Freight ME→Brazil | $/t | Cape/Panamax bulk rate |
| **Freight** | `fr_bs_nola_urea` | Freight Black Sea→US Gulf | $/t | Panamax bulk rate |
| **Freight** | `fr_china_india_urea` | Freight China→India | $/t | Short-haul supramax rate |
| **Operations** | `vessel_count_urea` | Vessels Available (Urea) | count | Bulk carriers on urea programme |
| **Operations** | `storage_batumi_kt` | Batumi Storage (Urea) | kt | Trammo Batumi terminal |
| **Operations** | `supply_mideast_kt_urea` | ME Supply Cap | kt | Available tonnage from ME producers |
| **Operations** | `demand_india_kt_urea` | India Demand Cap | kt | Import demand |
| **Operations** | `demand_brazil_kt_urea` | Brazil Demand Cap | kt | Import demand (seasonal — soy/corn planting) |
| **Macro** | `nat_gas_feedstock_urea` | Nat Gas (feedstock) | $/MMBtu | Main urea production cost driver |
| **Macro** | `usd_brl` | USD/BRL | rate | Brazilian Real FX — important for Brazil import demand |
| **Macro** | `bunker_380` | Bunker 380cSt | $/t | Share with existing frames |
| **Macro** | `working_cap_urea` | Working Capital | $M | Separate urea budget |

#### Required Routes

| Route | Origin | Destination | Transport |
|---|---|---|---|
| `me_india` | Saudi Arabia/Qatar | Kandla/Nhava Sheva, India | Ocean bulk carrier |
| `me_brazil` | Saudi Arabia/Qatar | Paranaguá, Brazil | Ocean bulk carrier |
| `bs_nola` | Egypt/Black Sea | NOLA/Tampa, US | Ocean bulk carrier |
| `china_india` | China (Nanjing) | Kandla, India | Ocean bulk carrier |

#### Required Constraints

| Constraint | Type | Notes |
|---|---|---|
| `supply_mideast` | CT_SUPPLY | `supply_mideast_kt_urea` |
| `supply_batumi` | CT_SUPPLY | `storage_batumi_kt` (Batumi also ships urea) |
| `dest_india` | CT_DEMAND | `demand_india_kt_urea` |
| `dest_brazil` | CT_DEMAND | `demand_brazil_kt_urea` |
| `fleet` | CT_FLEET | `vessel_count_urea` |
| `working_cap` | CT_CAPITAL | `working_cap_urea` |

#### Data Sources Required

| Variable group | Source |
|---|---|
| Urea spot prices (FOB/CFR) | Argus FMB Urea, ICIS, Fertecon |
| Bulk carrier freight rates | Baltic Supramax Index (BSI), Clarksons |
| FX rates | ECB/Fed (reuse EUR/USD pattern, add USD/BRL) |

#### Model-Building Notes
- Urea prices are **strongly correlated with natural gas** (feedstock for Haber-Bosch). `nat_gas_feedstock_urea` should have a strong positive correlation coefficient with all FOB price variables in the perturbation configuration.
- Brazil demand is **highly seasonal** (Q1 peak ahead of soy planting). Consider a seasonal demand modifier.
- The Batumi terminal already appears in the sulphur frame. When building the urea frame, ensure `storage_batumi_kt` for urea is tracked separately from `supply_batumi_kt` for sulphur — they share physical terminal space but are independent product volumes.
- Minimum variable count estimate: **19–22**.

---

### 3.3 `nitric_acid` — Nitric Acid (North Bend, Ohio)

**Business context:** Trammo operates its own nitric acid production facility at North Bend, Ohio (converts NH3 + air → HNO₃). This is a **form conversion** business: the solver should determine when to sell NH3 directly vs. converting to nitric acid for higher margin industrial sale.

**Transport:** Truck and rail (regional — OH, KY, PA, WV industrial users)

**Dependency:** This frame needs to consume the `nola_buy` price from `ammonia_domestic` as its primary feedstock cost input, or reference the NOLA market feed directly.

#### Required Variables

| Group | Key (suggested) | Label | Unit | Notes |
|---|---|---|---|---|
| **Feedstock** | `nh3_feedstock_cost` | NH3 Feedstock Cost | $/t NH3 | Should reference/shadow `nola_buy` from NH3 domestic frame |
| **Production** | `plant_util_pct` | Plant Utilization | % | North Bend plant throughput rate |
| **Production** | `plant_capacity_tpd` | Plant Capacity | t/day | Rated daily output — can be varied for planned maintenance |
| **Production** | `plant_outage` | Plant Outage | boolean | Unplanned shutdown flag |
| **Production** | `conversion_ratio` | NH3→HNO₃ Conversion | t NH3/t HNO₃ | ~0.29 t NH3 per t 100% HNO₃ |
| **Commercial** | `sell_hno3_conc` | Conc. HNO₃ Sell Price | $/t | Concentrated (≥98%) industrial grade |
| **Commercial** | `sell_hno3_weak` | Weak HNO₃ Sell Price | $/t | 55–65% — specialty chemical |
| **Commercial** | `freight_regional` | Regional Freight (truck) | $/t | Delivered to OH/KY/PA/WV industrial buyers |
| **Commercial** | `demand_industrial` | Regional Industrial Demand | t/month | Buyer demand ceiling |
| **Commercial** | `working_cap_na` | Working Capital | $ | Nitric acid budget |

#### Required Routes

| Route | Origin | Destination | Transport |
|---|---|---|---|
| `nb_ohio_ind` | North Bend, OH | Ohio/KY/PA/WV industrial | Truck/rail |

#### Required Constraints

| Constraint | Type | Notes |
|---|---|---|
| `production_cap` | CT_SUPPLY | Bound by `plant_capacity_tpd × plant_util_pct`; outage modifier via `plant_outage` |
| `dest_industrial` | CT_DEMAND | `demand_industrial` — regional buyer ceiling |
| `working_cap` | CT_CAPITAL | `working_cap_na` |

#### Model-Building Notes
- The **make-or-sell decision** is the key optimisation: the margin on converting NH3 to HNO₃ at North Bend must be compared against simply selling NH3 domestically. This may be best expressed as a cross-frame decision or as a single frame that holds both alternatives.
- The conversion ratio (~0.29 t NH3 per t 100% HNO₃) is a fixed physical constant but the yield efficiency varies with plant condition — consider a `plant_efficiency_pct` modifier.
- Working capital needed for this frame is small (regional, small volumes) but NH3 feedstock acquisition from the same budget as NH3 domestic could create a shared capital constraint — document this interaction explicitly when building.

---

### 3.4 `green_ammonia` — Green / Blue Ammonia

**Business context:** Trammo has signed long-term offtake agreements with Allied Green Ammonia (Australia), Iberdrola (Spain), Lotte (Korea), and Proton Ventures. These are fixed-volume contractual commitments, not purely optional spot trades. The solver must treat offtake floor volumes as **hard constraints**.

**Transport:** Ocean vessel (refrigerated, same carriers as conventional NH3)

**Key structural difference from conventional NH3:** Green ammonia trades at a **premium** over grey that depends on its certified carbon intensity (CI). The premium and the CI score are both variables. Blending decisions (green vs. grey supply to a buyer with a CI specification) add a new constraint type not present in other frames.

#### Required Variables

| Group | Key (suggested) | Label | Unit | Notes |
|---|---|---|---|---|
| **Market prices** | `fob_aus_green` | FOB Australia (Green NH3) | $/t | Allied Green Ammonia — electrolyser + Haber-Bosch, Pilbara |
| **Market prices** | `fob_spain_green` | FOB Spain (Green NH3) | $/t | Iberdrola project — renewable wind-powered |
| **Market prices** | `grey_nh3_ref` | Grey NH3 Reference Price | $/t | Conventional NH3 benchmark (reuse from NH3 International) |
| **Market prices** | `green_premium` | Green Premium over Grey | $/t | Spread = green NH3 price − grey reference |
| **Market prices** | `rec_price` | Renewable Energy Certificate | $/MWh | REC/I-REC price attached to green NH3 cargo |
| **Operations** | `ci_aus` | CI Score — Australia | gCO₂e/MJ | Certified carbon intensity of Australia supply |
| **Operations** | `ci_spain` | CI Score — Spain | gCO₂e/MJ | Certified carbon intensity of Spain supply |
| **Operations** | `offtake_floor_korea_kt` | Korea Offtake Floor | kt | Contracted minimum — Lotte agreement |
| **Operations** | `offtake_floor_europe_kt` | Europe Offtake Floor | kt | Contracted minimum — European buyers |
| **Operations** | `supply_aus_kt` | Australia Supply Cap | kt | Available from Allied Green per period |
| **Operations** | `supply_spain_kt` | Spain Supply Cap | kt | Available from Iberdrola per period |
| **Operations** | `vessel_count_green` | NH3 Carriers Available | count | Refrigerated carriers on green programme |
| **Macro** | `renewable_power_cost` | Renewable Power Cost | $/MWh | Key input cost driver for green NH3 |
| **Macro** | `working_cap_green` | Working Capital | $M | Green NH3 budget |

#### Required Routes

| Route | Origin | Destination | Transport |
|---|---|---|---|
| `aus_korea` | Pilbara, Australia | Ulsan, South Korea | Ocean vessel |
| `aus_japan` | Pilbara, Australia | Yokohama, Japan | Ocean vessel |
| `spain_europe` | Bilbao/Almería, Spain | NW Europe (Rotterdam/Hamburg) | Ocean vessel |

#### Required Constraints

| Constraint | Type | Notes |
|---|---|---|
| `supply_aus` | CT_SUPPLY | `supply_aus_kt` |
| `supply_spain` | CT_SUPPLY | `supply_spain_kt` |
| `offtake_korea` | **CT_DEMAND (minimum)** | `offtake_floor_korea_kt` — **hard lower bound**, not a cap |
| `offtake_europe` | **CT_DEMAND (minimum)** | `offtake_floor_europe_kt` — **hard lower bound**, not a cap |
| `fleet` | CT_FLEET | `vessel_count_green` |
| `working_cap` | CT_CAPITAL | `working_cap_green` |
| `ci_spec_korea` | **CT_CUSTOM** | Blended CI of Korea delivery ≤ buyer CI specification |
| `ci_spec_europe` | **CT_CUSTOM** | Blended CI of Europe delivery ≤ EU Green Hydrogen Delegated Act threshold |

#### Model-Building Notes
- The **offtake floor constraints** are the most important distinction from other frames. Unlike `CT_DEMAND` which imposes an upper bound, offtake contracts are **lower bounds** on volume. The Zig solver already supports minimum demand constraints (`bound_min_var_idx ≠ 0xFF`). Use this mechanism, not an upper bound.
- **CI blending constraint:** If a buyer specifies a maximum CI (e.g., Korea targets <1 kgCO₂/kgNH₃), and Trammo can blend green supply with conventional NH3, the weighted average CI of the delivered cargo must meet the spec. This is a linear constraint expressible as CT_CUSTOM.
- Green ammonia economics depend heavily on **renewable power cost** — this should have a strong negative correlation with `fob_aus_green` in perturbation parameters (cheaper renewable power → lower green NH3 cost → lower price or higher margin).
- Regulatory threshold to track: EU Green Hydrogen Delegated Act CI threshold (currently ≤3.38 kgCO₂e/kgH₂ equivalent).

---

### 3.5 `sulphuric_acid` — Sulphuric Acid

**Business context:** Trammo is a market leader in sulphuric acid trading. Sulphuric acid (H₂SO₄) is produced either from burning sulphur (at acid plants, often at fertilizer complexes) or as a by-product of smelting (copper, zinc, lead). End markets are phosphate fertilizer production (~70%), metal leaching (copper, gold mining, ~20%), and chemical industry (~10%).

**Transport:** Ocean vessel (corrosive — requires lined or stainless steel tankers or coated holds), rail, road

**Note:** Trammo does not currently appear to own sulphuric acid production assets (unlike North Bend for nitric acid). The trading model is arbitrage and logistics: buy at smelter by-product prices or contract with acid plants, sell to fertilizer and mining buyers.

#### Required Variables

| Group | Key (suggested) | Label | Unit | Notes |
|---|---|---|---|---|
| **Market prices** | `fob_smelter_sa` | FOB Smelter (SA) | $/t | South American copper smelter by-product — often cheapest global source |
| **Market prices** | `fob_me_sa` | FOB Middle East (SA) | $/t | From sulphur-burning acid plants (near sulphur sources) |
| **Market prices** | `fob_europe_sa` | FOB Europe (SA) | $/t | European smelter by-product |
| **Market prices** | `cfr_india_sa` | CFR India (SA) | $/t | India: OCP, Hindalco, Coromandel — phosphate producers |
| **Market prices** | `cfr_morocco_sa` | CFR Morocco (SA) | $/t | Morocco OCP — world's largest phosphate producer |
| **Market prices** | `cfr_aus_mining_sa` | CFR Australia (Mining) | $/t | Copper/gold mining operations (WA, QLD) |
| **Freight** | `fr_sa_india` | Freight SA→India | $/t | Coated tanker or lined bulker |
| **Freight** | `fr_sa_morocco` | Freight SA→Morocco | $/t | |
| **Freight** | `fr_europe_aus` | Freight Europe→Australia | $/t | Long-haul to mining |
| **Operations** | `vessel_count_sa` | Vessels Available (SA) | count | Acid-rated (lined/coated) vessels |
| **Operations** | `supply_sa_total_kt` | Total SA Supply Cap | kt | |
| **Operations** | `demand_india_sa_kt` | India Demand Cap | kt | |
| **Operations** | `demand_morocco_sa_kt` | Morocco Demand Cap | kt | |
| **Macro** | `sulphur_price_ref` | Sulphur Price Reference | $/t | Feedstock cost for sulphur-burning acid plants; links to sulphur frame |
| **Macro** | `bunker_380` | Bunker 380cSt | $/t | Share with other frames |
| **Macro** | `working_cap_sa` | Working Capital | $M | |

#### Required Routes

| Route | Origin | Destination | Transport |
|---|---|---|---|
| `sa_india` | South America / ME acid plants | India | Ocean (coated tanker) |
| `sa_morocco` | South America / ME acid plants | Morocco | Ocean |
| `europe_aus` | European smelter | Western Australia (mining) | Ocean |

#### Required Constraints

| Constraint | Type | Notes |
|---|---|---|
| `supply_total` | CT_SUPPLY | `supply_sa_total_kt` |
| `dest_india` | CT_DEMAND | `demand_india_sa_kt` |
| `dest_morocco` | CT_DEMAND | `demand_morocco_sa_kt` |
| `fleet` | CT_FLEET | `vessel_count_sa` — acid-rated vessels only |
| `working_cap` | CT_CAPITAL | `working_cap_sa` |

#### Model-Building Notes
- Sulphuric acid is heavily correlated with sulphur price (sulphur-burning route) and copper/zinc production rates (smelter by-product route). Include cross-correlations between `sulphur_price_ref` and `fob_me_sa`/`fob_europe_sa`.
- Acid-rated vessels are a **distinct fleet** from NH3 refrigerated carriers and bulk carriers for sulphur/petcoke. `vessel_count_sa` must not share the `CT_FLEET` constraint with other frames.
- The Morocco OCP demand is closely linked to the sulphur frame (OCP also buys sulphur for their own acid plants). The combined sulphur + sulphuric acid position into Morocco is relevant context for Trammo traders even if the two frames optimise independently.

---

## 4. Shared Variables & Cross-Frame Considerations

The following variables appear in multiple frames with the same underlying market price. When building new frames, use the same API source configuration so that a single feed update propagates correctly.

| Variable | Appears in | Market source |
|---|---|---|
| `bunker_380` | ammonia_international, sulphur_international, petcoke, (urea, sulphuric_acid) | Ship & Bunker / Argus Bunker |
| `nat_gas` / `nat_gas_feedstock` | ammonia_domestic, ammonia_international, (nitric_acid, urea) | EIA Henry Hub |
| `demand_india_kt` | ammonia_international, sulphur_international, (petcoke separately named) | — |
| `cfr_morocco` | ammonia_international, sulphur_international, (sulphuric_acid) | Different markets — DO NOT share a single variable |

**Note:** `cfr_morocco` for NH3 and `cfr_morocco` for sulphur and sulphuric acid are different price series — different buyers, different units, different volatility. Use distinct variable keys even though the destination geography overlaps.

---

## 5. API Integration Priority List

The three existing partial frames are blocked purely on market data API integrations. Priority order for connecting live feeds:

| Priority | Feed | Variables unlocked | Frames |
|---|---|---|---|
| 1 | **Argus Ammonia** (or ICIS) | `fob_trinidad`, `fob_yuzhnyy`, `fob_mideast`, `cfr_tampa`, `cfr_india`, `cfr_morocco` | NH3 International |
| 2 | **Baltic Exchange / Clarksons** (NH3 freight) | `fr_trinidad_tampa`, `fr_yuzhnyy_morocco`, `fr_me_india`, `fr_trinidad_india` | NH3 International |
| 3 | **Ship & Bunker / Argus Bunker** | `bunker_380` | NH3 Intl, Sulphur, Petcoke |
| 4 | **ECB / Fed FX feed** | `eur_usd`, `usd_inr` | NH3 Intl, Sulphur |
| 5 | **Argus Sulphur / CRU** | All 6 sulphur market price variables | Sulphur Intl |
| 6 | **Baltic Supramax (sulphur freight)** | All 4 sulphur freight rates | Sulphur Intl |
| 7 | **Argus Petcoke / CRU** | All 4 petcoke market price variables | Petcoke |
| 8 | **EIA refinery utilization** | `refinery_util_pct` | Petcoke |
| 9 | **Port congestion data** | `port_congestion_days` | Sulphur Intl |

Connecting feeds 1–4 activates the NH3 International frame on live data. Feeds 5–6 activate Sulphur. Feeds 7–8 activate Petcoke.

---

## 6. Solver Compatibility Checklist for New Frames

When a new frame is built, verify the following before wiring to the solver:

- [ ] Variable count ≤ 64 (hard Zig solver limit)
- [ ] Route count ≤ 16
- [ ] Constraint count ≤ 32
- [ ] Every route references `buy_variable`, `sell_variable`, `freight_variable` that exist in the variable list
- [ ] Every constraint's `bound_variable` (and `outage_variable` if used) exists in the variable list
- [ ] Each variable has `perturbation` parameters (`stddev`, `min`, `max` for floats; `flip_prob` for booleans)
- [ ] `signal_thresholds` are calibrated to the typical cargo profit scale (not copied from domestic barge — ocean cargo profits are orders of magnitude larger per solve)
- [ ] `chain_magic` is a unique 4-byte identifier not used by any existing frame
- [ ] `chain_product_code` is a unique byte value not used by any existing frame
- [ ] `contract_term_map` covers the standard clause IDs that the LLM extraction pipeline produces
- [ ] `location_anchors` covers all terminal/port names that would appear in contracts for this product
