# STATCOM Placement and Control for Voltage Unbalance — Inner-Sydney LV Feeder

Julia + OpenDSS simulation of a representative inner-Sydney residential LV feeder, built for the honours thesis *Phase Imbalance Mitigation in Australian Low-Voltage Networks: Evaluating Static Synchronous Compensator Placement and Control Against Unbalance and Voltage Limits* (Matthew Peruzzi, University of Sydney, 2026).

The model compares legacy PV inverters with AS/NZS 4777.2:2020 inverters, then adds a 75 kVA STATCOM at three locations, each under two control laws: per-phase Volt-Var and coordinated negative-sequence compensation (NSC). Results are assessed against the AS/NZS IEC 61000.2.2 VUF limit and the AS 61000.3.100 voltage limits, across 100 household arrangements and every week of 2019.

## How to Run

Requires **Julia 1.11** with `OpenDSSDirect.jl`, `CSV`, `DataFrames`, `Plots`, `Statistics` and `Random`.

```julia
include("run.jl")                  # simulations and analysis (long: tap selection, year screen, base, diagnostic, Monte Carlo)
include("plot_results.jl")         # thesis figures from the saved outputs
include("plot_inverter_curves.jl") # Volt-Watt / Volt-Var curve figures
include("plot_phasors.jl")         # phasor and sequence component figures
include("copy_appendix_figures.jl")# collects every thesis figure into thesis_figures/
```

`run.jl` saves its progress after every run, so an interrupted sweep resumes where it stopped. Delete `outputs/` to start again from scratch (for example after changing the model). Each stage can be switched on or off in the settings block at the top of `run.jl`.

All outputs land in `outputs/`, and `copy_appendix_figures.jl` gathers the figures used in the thesis into `thesis_figures/`, ready to upload to Overleaf.

---

## Cases

| Case | PV model | STATCOM placement | Control law | Code label |
|---|---|---|---|---|
| 1 | Legacy | None | – | `case1` (`:dumb`) |
| 2 | AS/NZS 4777.2 | None | – | `case2` (`:smart`) |
| 3 | AS/NZS 4777.2 | `NorthSpine_End` (A, B, C) | Volt-Var, NSC | `case3_vv`, `case3_nsc` (`:A_end`) |
| 4 | AS/NZS 4777.2 | `FN_Trunk` (A, B, C) | Volt-Var, NSC | `case4_vv`, `case4_nsc` (`:B_junction`) |
| 5 | AS/NZS 4777.2 | `NorthSpine_End` (A), `West_End_B` (B), `East_South_End` (C) | Volt-Var, NSC | `case5_vv`, `case5_nsc` (`:C_decentralised`) |

The eight configurations are defined in `cases.jl`.

---

## Pipeline (`run.jl`)

1. **Tap selection** — Case 2 at seed 42 over every week of 2019 for each off-load tap position (0, +2.5, +5%). The position with the most voltage-compliant weeks is used for everything after (+5%).
2. **Year screen** — every case at seed 42 for each of the 52 weeks of 2019. The week with the highest Case 2 P95 VUF becomes the assessment week (week 22).
3. **Base runs** — every case at seed 42 over the assessment week, with full analysis and comparison tables.
4. **Diagnostic** — Cases 2–5 repeated with PV held at unity power factor, to measure how the household inverters interact with the STATCOM.
5. **Monte Carlo** — every case across seeds 1–100 over the assessment week, each seed giving a different allocation of households to connection points.

---

## Files

### `LVNetwork.dss`
OpenDSS network definition. 17-bus radial four-wire LV feeder fed from a 200 kVA, 11/0.4 kV Dyn11 pole-mount transformer, with three branches (north spine, west, east) serving 25 single-phase connection points. The neutral is modelled explicitly and earthed through 10 Ω at every LV bus (0.3 Ω at the transformer star point).

### `load_consumer_profiles.jl`
Reads the Solar Analytics CSVs, keeps sites with postcodes 2000–2299, rejects consumers with more than 20 missing timestamps (filling smaller gaps by averaging neighbours), converts to kW and returns 52 valid consumers. Also calls `plot_load_profiles.jl`.

### `plot_load_profiles.jl`
Input-data validation plots (fleet average day, aggregate duck curve, seasonal profiles, duration curves, three illustrative consumers) and a per-consumer summary CSV. Output: `outputs/input_plots/`.

### `run_opendss_simulation.jl`
The simulation engine. Builds the network, allocates consumers to the 25 connection points for a given seed, applies the PV model (`:dumb`, `:smart`, or `:smart_unity` for the diagnostic), adds the STATCOM scenario, and steps through the window at 5-minute resolution from Julia so the NSC controller can update setpoints between timesteps. `MaxControlIter` is raised to 100 so the many inverter and STATCOM controllers can settle.

### `add_statcom.jl`
Adds the STATCOM units for each placement. Each unit is a single-phase OpenDSS `Storage` element (25 kVA, real power zero, idling loss zero, constant-power range widened to 0.7–1.3 pu). Under Volt-Var, all units follow one `InvControl` curve (full injection at 0.94 pu, deadband 0.98–1.02 pu, full absorption at 1.06 pu).

### `nsc_controller.jl`
The negative-sequence compensation controller. At each timestep it estimates how the negative sequence voltage at every bus responds to each unit (1 kvar perturbations), then takes up to three Gauss-Newton steps that reduce the total negative sequence voltage, keeping only steps that improve it.

### `cases.jl`
Case definitions, placement names and the bus order shared by the other scripts.

### `analyse_results.jl`
Per-case analysis: sequence components and IEC, NEMA and PVUR unbalance at every bus, 10-minute aggregation and P95 assessment, customer voltage compliance against AS 61000.3.100, transformer power, STATCOM output and self-consumption. Output: CSVs in each case's `outputs/base/<case>/` folder.

### `compare_results.jl`
Comparison tables across cases and the Monte Carlo summary (with 95% Wilson intervals), saved as CSV and booktabs LaTeX ready to `\input{}` into the thesis.

### `plot_results.jl`
All results figures for the thesis (Chapter 5 and the appendix), plus a set of verification plots per case. Output: `outputs/figures/` and `outputs/figures/verification/<case>/`.

### `plot_inverter_curves.jl`
AS/NZS 4777.2:2020 Volt-Watt and Volt-Var curves and the STATCOM Volt-Var curve. Output: `outputs/inverter_curves/`.

### `plot_phasors.jl`
Phasor figures for the theory sections (sequence decomposition example, STATCOM phasor diagram, sequence currents from single-phase units) and the worked operating point in Section 5.4.4, with its values saved to `worked_point.csv`.

### `check_voltvar_reference.jl`
Check of which voltage the OpenDSS `InvControl` responds to, comparing recorded STATCOM output against the Volt-Var curve applied to phase-to-neutral and phase-to-ground voltage. It confirms OpenDSS uses phase-to-ground (discussed in Section 3.3.6).

### `copy_appendix_figures.jl`
Copies every figure and table used in the thesis into `thesis_figures/`, renaming the per-case verification plots so they don't clash.

---

## Outputs

| Folder | Contents |
|---|---|
| `outputs/tap_selection/` | Weekly results for each tap position and the summary used to choose the tap |
| `outputs/year_screen/` | Weekly results for every case across 2019 and the chosen assessment week |
| `outputs/base/<case>/` | Full time series and analysis CSVs for each case at seed 42 |
| `outputs/comparison/` | Comparison tables (CSV and LaTeX) |
| `outputs/monte_carlo/` | Per-seed results and the Monte Carlo summary |
| `outputs/figures/` | Thesis figures |
| `thesis_figures/` | Everything the thesis needs, in one folder |

---

## Data

`SolarAnalytics/5minutes/` — University of Sydney Solar Analytics dataset, 2019, 5-minute resolution. Not included in the repository because of its size and licensing; obtain it separately and place it in this folder. The cleaning and allocation routines will run on any Solar Analytics dataset in the same format.

---

## Acknowledgement of AI Assistance

AI assistants (Anthropic's Claude and OpenAI's ChatGPT) were used during development of this code. The network model, the simulation design, the choice of cases and control laws, the NSC approach and the analysis of the results are the author's own.

AI was used to improve the readability of the code (formatting, comments, variable names and structural clean-up) and to help with debugging. Some of the simpler supporting code was also written with AI assistance to save time, mainly the plotting scripts and small helper functions that read saved outputs and calculate summary values such as percentiles, pass counts and per-bus statistics. This code is routine data handling and presentation rather than part of the modelling itself. All AI-assisted code was reviewed, run and checked against the simulation outputs by the author.

AI was also used to help draft this README.
