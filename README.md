# Voltage Unbalance Study — Inner-Sydney LV Network

Julia + OpenDSS simulation of an inner-Sydney LV residential feeder, comparing dumb PV inverters against AS/NZS 4777.2:2020 smart inverters. Stage 1 of a Year 4 thesis on voltage unbalance and STATCOM mitigation.

## How to Run

Requires **Julia 1.11**

```julia
include("run.jl")                   
include("plot_inverter_curves.jl")
```

All outputs (graphs & csv) land in `outputs/`.

---

## Files

### `LVNetwork.dss`
OpenDSS network definition. 17-bus radial LV feeder fed from a 200 kVA pole-mount 11/0.4 kV transformer. Three branches (North spine, West, East) servicing 25 single-phase residential loads. Multi-point grounded neutral. Loaded at runtime by the Julia simulation script.

**Output:** none directly. Defines the network simulated by `run_opendss_simulation.jl`.

---

### `load_consumer_profiles.jl`
Reads consumer CSVs from `SolarAnalytics/5minutes/`. Filters to inner-Sydney postcodes (2000–2299), screens for missing data, scales units to kW, and constructs a `Vector{Consumer}` containing 52 valid consumers. Also calls `plot_load_profiles.jl` for input-data validation.

**Output:** `consumers` (Julia variable, used downstream).

---

### `plot_load_profiles.jl`
Generates validation plots and a per-consumer summary CSV from the loaded consumer data. Used to sanity-check the input data before running the simulation.

**Output (`outputs/input_plots/`):**
- `fleet_01_average_day.png` — mean daily load + PV per household
- `fleet_02_aggregate_day.png` — fleet-aggregated load + PV + net demand
- `fleet_03_summer.png`, `_autumn.png`, `_winter.png`, `_spring.png` — seasonal profiles
- `fleet_04_duration_curve.png` — annual load + PV duration curves
- `compare_01_average_day.png` — three illustrative consumers (low / med / high self-consumption)
- `compare_02_weekday_vs_weekend.png`
- `compare_03_load_vs_pv.png`
- `consumer_summary.csv` — per-consumer annual stats (load kWh, PV kWh, peak kW, self-consumption ratio)

---

### `run_opendss_simulation.jl`
The simulation engine. Takes the `consumers` vector and a `pv_mode` argument (`:dumb` or `:smart`), builds and solves an OpenDSS daily simulation at 5-min resolution. Aggregates consumers across 25 load slots, defines loadshapes, attaches 70 monitors, optionally applies AS/NZS 4777.2:2020 inverter control, then solves and returns time-series data.

Called twice from `run.jl` — once per scenario.

**Output (`outputs/raw_dumb/` and `outputs/raw_smart/`):**
- `node_voltages.csv` — final-timestep voltages at every node
- `summary.csv` — feeder-level totals (power, losses, min/max voltages)
- `timeseries/*.csv` — 70 monitor files (one per monitor × per scenario)

Also returns a Julia NamedTuple with `voltages`, `summary`, `timeseries`, `pv_mode` for downstream analysis.

---

### `analyse_results.jl`
Per-scenario analysis. Takes the simulation results, computes voltage compliance, VUF (both IEC and NEMA methods), and self-consumption metrics. Generates plots and CSVs. Called twice from `run.jl`.

**Output (`outputs/analysis_dumb/` and `outputs/analysis_smart/`):**
- `01_voltage_envelope.png` — voltage time-series at all 25 loads
- `02_transformer_v_curve.png` — transformer power flow (duck curve)
- `03_vuf_iec_timeseries.png` — IEC VUF at all 16 LV buses
- `04_compliance_per_bus.png` — voltage compliance bar chart
- `05_self_consumption_per_slot.png` — per-slot self-consumption bar chart
- `06_vuf_nema_timeseries.png` — NEMA VUF at all 16 LV buses
- `07_peak_vuf_per_bus.png` — peak VUF per bus (IEC vs NEMA)
- `voltage_compliance_per_bus.csv` — per-load min/max/mean voltage + compliance %
- `self_consumption_per_slot.csv` — per-slot energy and SC %
- `vuf_per_bus.csv` — peak VUF per bus (both methods)

---

### `compare_results.jl`
Builds dumb-vs-smart comparison tables. Three tables (feeder summary, per-bus voltage, per-bus VUF), each saved in three formats.

**Output (`outputs/comparison/`):**
- `comparison_summary.csv`, `.md`, `.tex` — feeder-wide head-to-head (10 metrics)
- `per_bus_voltage.csv`, `.md`, `.tex` — per-load voltage comparison (25 rows)
- `per_bus_vuf.csv`, `.md`, `.tex` — per-bus VUF comparison (16 rows, both methods)

LaTeX tables use `booktabs` formatting and are ready to `\input{}` into a thesis.

---

### `plot_inverter_curves.jl`
Standalone script that generates the AS/NZS 4777.2:2020 Volt-Watt and Volt-Var curve figures for the thesis methodology chapter. Not called from `run.jl` — run separately.

**Output (`outputs/inverter_curves/`):**
- `inverter_voltwatt_curve.png` — Volt-Watt response only
- `inverter_voltvar_curve.png` — Volt-Var response only
- `inverter_curves_combined.png` — both stacked vertically (use for the methodology figure)

---

### `run.jl`
The orchestrator. Runs the full pipeline end-to-end:

1. Loads 52 inner-Sydney consumers (via `load_consumer_profiles.jl`)
2. Generates input-data validation plots
3. Runs Scenario A (dumb PV) and analyses it
4. Runs Scenario B (smart PV) and analyses it
5. Builds comparison tables

Everything lands under `outputs/`. Typical runtime: 60–90 seconds.

---

## Data

`SolarAnalytics/5minutes/` — University of Sydney Solar Analytics dataset, 2019, 5-min resolution. 508 consumer CSVs + `site_details_USYD_202010.csv`. Not committed to the repo (size + licensing); obtain separately.




## Acknowledgement of AI Assistance

An AI assistant (Anthropic's Claude) was used to assist with the readability and
presentation of this work — including code formatting, inline comments, variable naming,
structural clean-up, and drafting this README. The underlying logic, methodology,
simulation design, and analysis are the author's own.