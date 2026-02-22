# Zig Solver — Code Documentation & Trammo Coverage Analysis

_Date: 2026-02-22_

---

## 1. What the Zig Code Is Doing

There are five Zig source files in this project. Two are build scripts; three are runtime components.

---

### 1.1 `native/solver.zig` — Generic LP Solver (Primary, ~757 lines)

This is the live production solver. It runs as a persistent OS process, connected to Elixir via an Erlang Port using a 4-byte big-endian length-prefixed binary protocol over stdin/stdout.

**Core job:** receive a model descriptor + current variable values → build a Linear Program → call HiGHS → return optimal allocation.

#### Protocol

```
Request:  [4-byte len (BE)] [cmd: u8] [payload...]
Response: [4-byte len (BE)] [status: u8] [payload...]

cmd 1 = single solve
cmd 2 = monte carlo (n_scenarios u32 prepended to payload)
```

#### Model Descriptor (parsed at runtime from binary)

Elixir's `Solver.ModelDescriptor` serialises the product group frame into a binary blob sent with every request. The Zig side deserialises:

| Section | Contents |
|---|---|
| Header | `n_vars` (u16), `n_routes` (u8), `n_constraints` (u8), `obj_mode` (u8), `lambda` (f64), `profit_floor` (f64) |
| Routes × n | `sell_var_idx`, `buy_var_idx`, `freight_var_idx` (each u8), `transit_cost_per_day`, `base_transit_days`, `unit_capacity` (each f64) |
| Constraints × n | `ctype`, `bound_var_idx`, `bound_min_var_idx`, `outage_var_idx` (each u8), `outage_factor` (f64), route index list |
| Perturbations × n_vars | `stddev`, `lo`, `hi` (f64), `n_corr` (u8), correlation pairs `(var_idx, coefficient)` |

Limits: up to 64 variables, 16 routes, 32 constraints, 8 correlations per variable, 10,000 Monte Carlo scenarios.

#### LP Construction (`solve_one`)

For each route, the solver computes:

```
margin[r] = sell_price - buy_price - freight - (transit_days × transit_cost_per_day)
```

Decision variables are tons allocated to each route (`x[r] ≥ 0`, continuous).

**Objective modes:**

| Mode | Formula | Use case |
|---|---|---|
| `OBJ_MAX_PROFIT` (0) | maximise `Σ margin[r] × x[r]` | Default trading decision |
| `OBJ_MIN_COST` (1) | minimise `Σ (buy + freight)[r] × x[r]` | Procurement optimisation |
| `OBJ_MAX_ROI` (2) | maximise profit/cost (Charnes-Cooper linearisation) | Capital efficiency |
| `OBJ_CVAR_ADJUSTED` (3) | maximise `profit − λ × CVaR₅` | Risk-adjusted returns |
| `OBJ_MIN_RISK` (4) | minimise CVaR₅ subject to profit ≥ floor | Capital preservation |

**Constraint types:**

| Type | Coefficient | Meaning |
|---|---|---|
| `CT_SUPPLY` (0) | 1.0 per route | `Σ tons ≤ inventory_at_origin` |
| `CT_DEMAND` (1) | 1.0 per route | `Σ tons ≤ demand_at_destination` (with optional minimum) |
| `CT_FLEET` (2) | `1 / unit_capacity` | `Σ (tons/barge_cap) ≤ available_barges` |
| `CT_CAPITAL` (3) | `buy + freight` per route | `Σ cost ≤ working_capital` |
| `CT_CUSTOM` (4) | explicit coefficients | Any user-defined linear constraint |

Outage modifier: if `vars[outage_var_idx] > 0.5` (binary flag), the upper bound of that constraint is multiplied by `outage_factor` (e.g. 0.5 = terminal at 50% capacity).

Minimum demand constraint: if `bound_min_var_idx != 0xFF`, a lower bound is enforced (`Σ tons ≥ committed_minimum`).

HiGHS solves the LP in microseconds at this problem size. The solver returns optimal route allocations, per-route profits, total profit/cost/ROI, and shadow prices (dual values) for every constraint.

#### Monte Carlo (`run_monte_carlo`)

Runs up to 10,000 scenarios per call. Each scenario:

1. **Perturb** — two-pass perturbation:
   - Pass 1: independent Gaussian noise (`rand_normal() × stddev`) clamped to `[lo, hi]` for continuous variables; Bernoulli flip for binary flags (outages).
   - Pass 2: additive correlation adjustments — each variable can depend on the perturbed values of up to 8 other variables via linear coefficients.
2. **Solve** — calls `solve_one` with perturbed variables.
3. **Record** — stores profit (or cost/ROI depending on mode) and per-variable values for feasible scenarios.

Outputs: `n_scenarios`, `n_feasible`, `n_infeasible`, `mean`, `stddev`, percentiles (p5/p25/p50/p75/p95), min/max.

**Sensitivity analysis:** Pearson correlation of each input variable with the objective metric across all feasible scenarios. Tells traders which variables drive profit uncertainty most.

PRNG: xoshiro256** (period 2²⁵⁶, fast, adequate for simulation). Box-Muller transform for normal sampling.

---

### 1.2 `native/solver_v1_ammonia.zig` — Legacy Ammonia Solver (~606 lines)

The original hardcoded solver for domestic ammonia barge trading only. **Superseded by solver.zig** and not used in current production. Documents the domain model as it was initially conceived:

- 4 routes: Donaldsonville→St. Louis, Donaldsonville→Memphis, Geismar→St. Louis, Geismar→Memphis
- 20 fixed variables (6 environmental, 5 operational, 9 commercial)
- 6 constraints (supply×2, demand×2, fleet, capital)
- Hardcoded causal chain for correlated Monte Carlo perturbation:
  - weather (independent) → precipitation affects river stage → stage/temp/wind affect lock delays → all affect barge availability → logistics difficulty affects freight price adjustments

Notable: the v1 solver uses hardcoded terminal names (`inv_don`, `inv_geis` for Donaldsonville and Geismar, Louisiana — actual Trammo terminals). The generic solver.zig replaced these with indexed variable references.

---

### 1.3 `native/solver_mobile.zig` — C ABI Wrapper (~204 lines)

Exports `solve_one` and `run_monte_carlo` as C-compatible functions for iOS/Android FFI. Identical mathematical model to solver.zig; different calling convention and struct layout. Allows a mobile trader app to run the same LP locally without a server round-trip.

---

### 1.4 `native/scanner/src/main.zig` — Contract Scanner (~561 lines)

Separate binary. Watches a SharePoint/OneDrive folder via Microsoft Graph API. Responsibilities:

- **`scan`**: List files + return metadata + SHA-256 hash from Graph API quickXorHash
- **`diff_hashes`**: Batch-compare stored hashes against current Graph API state; return changed/unchanged/missing sets
- **`hash_local`**: SHA-256 of a local file (UNC path fallback)

Filters to `.pdf`, `.docx`, `.docm`, `.doc`, `.txt`. JSON-lines protocol over stdin/stdout. Does not download or parse file content — that is handled by the Elixir `Contracts.CopilotClient` layer.

---

### 1.5 Build Scripts

- **`native/build_mobile.zig`**: Cross-compiles `solver_mobile.zig` to shared libraries for Android (4 ABI targets: arm64-v8a, armeabi-v7a, x86_64, x86) and a static framework for iOS.
- **`native/scanner/build.zig`**: Builds the `contract_scanner` binary; links libc for HTTPS.

---

## 2. Trammo's Operational Environment and Problem Space

Trammo is a **privately-held global commodity trader**, not a producer. Its competitive advantage is logistics arbitrage: moving commodities from surplus geographies to deficit geographies, capturing spread across space, time, and product form. Below is a full inventory of their environment.

### 2.1 Products Traded

| Product | Scale | Notes |
|---|---|---|
| **Anhydrous Ammonia** | ~4M metric tons/year, 25+ buying countries, ~35 selling countries | >20% global seaborne market share — largest independent trader |
| **Sulphur** | Large volumes | Primary feedstock for sulphuric acid; end markets: fertilisers (70%), metal leaching (20%), chemicals (10%) |
| **Sulphuric Acid** | Market leader | Sold as industrial input |
| **Petroleum Coke (Petcoke)** | >3M MT/year | One of the largest independent global marketers |
| **Nitric Acid** | Niche | Own production at North Bend, Ohio (from ammonia + air) |
| **Green/Blue Ammonia** | Emerging | Offtakes signed with Allied Green Ammonia (Australia), Iberdrola (Spain), Lotte (Korea), Proton Ventures |
| **Finished Fertilisers** | Batumi terminal hub | Urea, other N-fertilisers transshipped through Black Sea |

### 2.2 Operational Environments

#### Inland Waterway — North America (Domestic)
- **Illinois/Mississippi River system**: Meredosia and Niota, Illinois storage terminals
- **Ohio River**: North Bend, Ohio (nitric acid production)
- Largest independent fleet of fully refrigerated inland waterway ammonia barge tows in the US
- Constraints: river stage (USGS), lock delays (USACE), ice/low water seasons, barge availability, terminal outages

#### Ocean Vessel — Global (International)
- Fleet of 10–14 semi- and fully-refrigerated gas carriers (LPG tankers, various sizes)
- Global port coverage for anhydrous ammonia and sulphur
- Key hubs: Rotterdam (APM Terminals Maasvlakte), Batumi (Georgia), Nanjing (China, leased)
- Constraints: vessel availability and positioning, port congestion, ice seasons (Baltic), geopolitical routing disruptions

#### Multi-Modal — Batumi Terminal (Black Sea / Eurasian Corridor)
- Trans-Caspian Middle Corridor: China → Kazakhstan → Caspian → Georgia → Turkey/Europe
- Combines rail (from Central Asia), vessel (Caspian/Black Sea), and barging
- Strategic in post-2022 environment with northern route disruptions

#### Rail Distribution
- Connected to Batumi multi-modal terminal
- Used for inland distribution in Central Asia and Eastern Europe

#### Production Operations
- North Bend, Ohio: converts ammonia + air → nitric acid (form arbitrage)

### 2.3 Trading Model Dimensions

| Dimension | Description |
|---|---|
| **Physical spot** | Buy/sell at current market on individual cargoes |
| **Term contracts** | Long-term supply/offtake agreements with producers and consumers |
| **Geographic arbitrage** | Exploit price differentials between regions (e.g., US Gulf vs. Rotterdam vs. Asia) |
| **Temporal arbitrage** | Use storage and transit timing to capture seasonal price curves |
| **Form conversion** | Ammonia → nitric acid at North Bend, Ohio |
| **Financial hedging** | Derivatives (options, swaps, forwards) for price risk management |

### 2.4 Key Risk Categories

| Risk | Description |
|---|---|
| **Price risk** | Ammonia/sulphur/petcoke prices are volatile; correlated with natural gas |
| **Freight risk** | Vessel and barge freight rates fluctuate with supply/demand for transport |
| **Logistics/operational risk** | River stage, lock delays, port congestion, terminal outages |
| **Counterparty/credit risk** | Exposure across 25–35 countries; managed by Risk Steering Committee |
| **Geopolitical risk** | Sanctions, routing disruptions, regional conflicts (especially post-2022) |
| **Regulatory risk** | Environmental/safety regs for hazardous ammonia transport |
| **Weather risk** | Ice, storms, low water levels affecting both inland and ocean operations |
| **Green energy transition risk** | Demand shift as green ammonia volumes scale up |

---

## 3. Coverage Analysis: Does the Zig Model Comprehensively Solve Trammo's Problem?

### 3.1 What the Model Covers Well

**Domestic ammonia barge trading (U.S. inland waterway)** is the most developed part of the model and is well-matched to Trammo's actual U.S. operations:

| Trammo reality | Model coverage |
|---|---|
| Meredosia and Niota storage terminals | Inventory constraints with outage flags (`inv_mer`, `inv_nio`, `mer_outage`, `nio_outage`) |
| 4 trade lanes (2 origins × 2 destinations: StL, Memphis) | 4 LP decision variables with origin-specific freight rates |
| River stage, lock delays, weather | 6 environmental variables fed from USGS, NOAA, USACE APIs |
| Barge fleet constraint | `CT_FLEET` constraint with per-route capacity divisor |
| Working capital limit | `CT_CAPITAL` constraint |
| Price uncertainty | Monte Carlo with correlated perturbations, Pearson sensitivity |
| Risk-adjusted trading | CVaR₅ objective modes, lambda risk-aversion parameter |
| Real-time decision support | <100ms solve time via HiGHS, live API polling, trader UI sliders |
| Multiple objective modes | Max profit, min cost, max ROI, CVaR-adjusted, min risk |
| Shadow prices | Dual values tell traders which constraint is most binding (e.g., "fleet is the bottleneck") |
| Scenario comparison | Saved scenario store, sensitivity rankings |
| Mobile access | C FFI for iOS/Android — solver runs on-device |
| Contract lifecycle | SharePoint scanner → LLM extraction → SAP validation → constraint bridge |

**This covers the core U.S. inland waterway ammonia dispatch problem well.**

---

### 3.2 Significant Gaps Against the Full Trammo Business

The following dimensions of Trammo's actual business are **not modelled** or only partially represented:

#### Gap 1: Ocean Vessel Operations — Not Modelled
Trammo operates 10–14 refrigerated gas carriers globally. Ocean shipping involves:
- **Vessel positioning** (empty repositioning costs, laden vs. ballast legs)
- **Port-to-port routing** with canal transit options (Suez, Panama)
- **Cargo size flexibility** (full vs. partial cargo, parcel sizes)
- **Vessel scheduling** (multi-voyage planning horizon)
- **Ice class restrictions** (Baltic routes in winter)
- **Laytime/demurrage** (penalty costs for port delays beyond agreed berth time)

The current model has a `AmmoniaInternational` frame in Elixir but the variables and route definitions for international operations are not apparent in the Zig solver — it would need separate ocean route definitions, port congestion variables, and vessel scheduling constraints rather than barge fleet constraints.

**Business impact:** Trammo's largest profit pool by volume is seaborne ammonia. Not having an optimised ocean dispatch model is the single biggest coverage gap.

#### Gap 2: Multi-Product Portfolio Optimisation — Not Modelled
Trammo trades ammonia, sulphur, petcoke, sulphuric acid, and nitric acid simultaneously and often shares:
- Vessel fleet (some carriers can carry different products)
- Terminal infrastructure (Batumi handles sulphur + fertilisers)
- Working capital (budget allocated across products)

The current model solves each product group independently. A joint portfolio optimisation across products sharing capital or transport assets is not implemented.

**Business impact:** Capital and vessel allocation decisions that span products cannot be optimised. Traders must mentally integrate across separate solver outputs.

#### Gap 3: Temporal / Multi-Period Planning — Not Modelled
The current model is a **single-period (snapshot) LP**. It optimises the current decision given today's conditions but does not model:
- **Inventory build** ahead of seasonal demand peaks
- **Contract delivery scheduling** over weeks or months
- **Price curve trading** (buying forward when contango warrants storage)
- **Vessel voyage sequencing** (which cargo goes on which vessel in what order)
- **Hedge ratio optimisation** (rolling derivatives programme across delivery periods)

A multi-period MIP or stochastic programme would be needed to capture these temporal dimensions.

**Business impact:** Traders cannot use the tool to plan beyond the immediate dispatch decision. Medium-term (1–12 month) optimisation that is central to Trammo's value-add (time arbitrage) is absent.

#### Gap 4: Geographic Arbitrage / Price Spread Capture — Partially Modelled
The domestic model captures US regional spreads (NOLA vs. StL vs. Memphis). But Trammo's core global arbitrage engine involves:
- **Inter-regional spread trading**: US Gulf vs. Tampa vs. Rotterdam vs. Yuzhny (Ukraine) vs. Middle East
- **Producer price differentials**: e.g., Trinidad vs. Middle East vs. FSU ammonia prices
- **Destination market premiums**: European vs. Asian vs. Latin American buyers

These global price spread variables and corresponding route structures are not in the solver frames visible in the codebase.

#### Gap 5: Green Ammonia — Not Modelled
Trammo has signed long-term offtake agreements for green ammonia (Australia, Spain, Korea). Green ammonia involves:
- **Carbon intensity tracking** per cargo (green vs. blue vs. grey)
- **Certificate of origin** and attribute bundling (ammonia + renewable energy certificate)
- **Premium pricing** over grey ammonia (basis spread between green and conventional)
- **Blending decisions** (green vs. grey supply to meet buyer specifications)
- **Delivery obligations** under fixed offtake agreements (not pure optimisation — contractual floor)

None of this is modelled. As green volumes scale, a separate or augmented frame will be needed.

#### Gap 6: Derivative / Hedging Integration — Not Modelled
The model takes prices as inputs (spot or trader-estimated). It does not:
- Model the P&L of an existing derivatives book alongside physical positions
- Optimise the hedge ratio (how much price exposure to cover with swaps/options)
- Integrate forward curves to value time-spread opportunities
- Compute Value-at-Risk for the combined physical + derivatives portfolio

CVaR₅ is computed for the physical allocation under Monte Carlo — this is a meaningful risk metric for the physical book, but it does not incorporate the derivatives overlay that Trammo uses to manage price risk.

#### Gap 7: Counterparty / Credit Constraints — Not Modelled
Trammo manages credit exposure across 25–35 countries. Optimal dispatch may be constrained by:
- Credit limits per counterparty
- Concentration limits (maximum % of portfolio to one buyer or region)
- Payment terms (the working capital constraint partially proxies this, but is not counterparty-specific)

#### Gap 8: Demand Minimum Enforcement — Partially Modelled
The `CT_DEMAND` constraint supports an optional minimum (`bound_min_var_idx`), which can represent committed contract volumes. However, the contract extraction pipeline (SharePoint → LLM → SAP) that feeds minimum quantities is present in Elixir but its integration into solver constraint generation needs to be verified end-to-end.

#### Gap 9: Batumi Multi-Modal Terminal — Not Modelled
The trans-Caspian Middle Corridor routing through Batumi (rail → Black Sea vessel → Mediterranean) involves modal handoff constraints that do not map to the current route/constraint structure.

---

### 3.3 Coverage Summary Table

| Trammo Operational Area | Zig Model Coverage | Status |
|---|---|---|
| US domestic ammonia barge dispatch | Full LP optimisation, Monte Carlo, shadow prices | **Covered** |
| US river environmental constraints | 6 live variables (USGS/NOAA/USACE), correlated MC | **Covered** |
| US terminal inventory & outages | Supply constraints with outage modifier | **Covered** |
| US barge fleet constraint | CT_FLEET with per-route capacity | **Covered** |
| US working capital constraint | CT_CAPITAL | **Covered** |
| Trader risk preferences | 5 objective modes including CVaR | **Covered** |
| Real-time decision latency | <100ms via HiGHS | **Covered** |
| Contract term capture | Scanner + LLM + SAP pipeline | **Covered (Elixir layer)** |
| Mobile deployment | C FFI for iOS/Android | **Covered** |
| Ocean vessel dispatch (global ammonia) | Frame exists in Elixir; solver variables/constraints not fully defined | **Partial** |
| Multi-product portfolio optimisation | Separate frames per product, no joint solve | **Not covered** |
| Multi-period planning (weeks/months) | Single-period snapshot only | **Not covered** |
| Global geographic price arbitrage | US routes only in current frames | **Not covered** |
| Green/blue ammonia attributes | No carbon intensity or certificate tracking | **Not covered** |
| Derivatives / hedging integration | Physical book only; no derivatives P&L | **Not covered** |
| Counterparty credit limits | Working capital proxy only | **Not covered** |
| Batumi multi-modal routing | No rail + vessel + handoff model | **Not covered** |
| Petcoke/sulphur dispatch optimisation | Frames in Elixir but domain variables unclear | **Not covered** |

---

## 4. Recommendations

The Zig solver is well-engineered for what it does. The generic solver.zig architecture (data-driven model descriptor, multiple objective modes, Monte Carlo with correlations, shadow prices) is extensible. The gaps are not architectural failures in the solver — they are missing **product group frames** (route/variable/constraint definitions) and, in some cases, require **model extensions** beyond single-period LP.

**Highest priority for Trammo business alignment:**

1. **Ocean vessel frame** — define route variables, vessel fleet constraint, port congestion variables, and laytime cost structure for the `AmmoniaInternational` and `SulphurInternational` frames. This unlocks the majority of Trammo's volume.

2. **Multi-period LP extension** — add a time-horizon dimension (even a 4–8 week rolling window) to enable inventory build and contract scheduling decisions. This likely requires a separate solver mode rather than changes to the existing single-period LP.

3. **Global price variables** — extend the variable set for international frames to include Rotterdam, Tampa, Middle East, and Asia price nodes with corresponding freight cost estimates.

4. **Green ammonia frame** — add carbon intensity attributes and offtake contract floors as hard constraints when green volumes reach material scale.

5. **Derivatives integration** — feed the current hedge book's delta (net price exposure) as a constraint input so the physical dispatch optimiser accounts for what is already hedged.
