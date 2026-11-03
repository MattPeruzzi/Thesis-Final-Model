# -----------------------------------------------------------------------------
# Note on AI assistance:
# AI assistants (Anthropic's Claude and OpenAI's ChatGPT) were used during the
# development of this code. The network model, simulation design, choice of
# cases and control laws, and analysis of the results are the author's own.
#
# AI was used to improve readability (formatting, comments, variable names,
# docstrings and structural clean-up), to help with debugging, and to style
# figures, including legends, layout and colour-blind-safe palettes. Some of
# the simpler supporting code was also written with AI assistance to save
# time, mainly plotting code and small helper functions that read saved
# outputs and calculate summary values. All AI-assisted code was reviewed,
# run and checked against the simulation outputs by the author.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Orchestrator. Five stages, each switchable below:
#   T. TAP SELECTION: Case 2 at seed 42 over every week of 2019 for each
#                   standard off-load tap position. The position with the most
#                   voltage-compliant weeks is used for every later stage.
#   0. YEAR SCREEN: every case at seed 42, one-week runs across all of 2019.
#                   The week where Case 2 has the highest P95 VUF becomes the
#                   assessment week for everything after it.
#   1. BASE:        every case once at seed 42 over the assessment week,
#                   full analysis + comparison tables
#   2. DIAGNOSTIC:  STATCOM cases with PV at unity pf (inverter interaction check)
#   3. MONTE CARLO: every case across MC_SEEDS over the assessment week.
#
# The tap selection, year screen and Monte Carlo append to CSV after every run, so an
# interrupted sweep resumes where it stopped. Delete outputs/ to start from
# scratch (e.g. after changing the model).
# Figures are made separately: include("plot_results.jl") once this finishes.
# -----------------------------------------------------------------------------

cd(@__DIR__)

using Dates

include("load_consumer_profiles.jl")
include("run_opendss_simulation.jl")
include("add_statcom.jl")
include("nsc_controller.jl")
include("cases.jl")
include("analyse_results.jl")
include("compare_results.jl")

# ------------------------------- Settings -------------------------------------
OUTPUT_ROOT      = "outputs"
NETWORK_FILE     = joinpath(@__DIR__, "LVNetwork.dss")
BASE_SEED        = 42
MC_SEEDS         = 1:100
N_DAYS           = 7          # length of the assessment window (days)
SCREEN_WEEKS     = 1:52       # weeks of 2019 covered by the year screen
ASSESS_START_DAY = nothing    # set to a day number (e.g. 190) to skip the automatic choice
DATA_YEAR        = 2019
TAP_OPTIONS      = [1.0, 1.025, 1.05]   # standard off-load positions (nominal, +2.5%, +5%)
TAP              = nothing    # set to e.g. 1.025 to skip the automatic choice
SCREEN_CASES     = [c.id for c in CASES]   # e.g. [:case1, :case2] for a quick screen
ALLOCATION       = :all       # :all = 2-3 households per connection point, :single = one each

RUN_TAP_SELECT   = true
RUN_YEAR_SCREEN  = true
RUN_BASE         = true
RUN_DIAGNOSTIC   = true
RUN_MONTE_CARLO  = true
QUIET            = true       # hide per-run OpenDSS output in the sweeps
# ------------------------------------------------------------------------------

mkpath(OUTPUT_ROOT)

banner(msg) = println("\n" * "="^70 * "\n" * msg * "\n" * "="^70)

function run_case(c, seed::Int; start_day::Int, n_days::Int = N_DAYS,
                  output_dir::AbstractString, write_files::Bool = true,
                  pv_mode::Symbol = c.pv, quiet::Bool = false, tap::Real = TAP_PU)
    f() = run_opendss_simulation(consumers;
        network_file     = NETWORK_FILE,
        mode             = :daily,
        start_day        = start_day,
        n_days           = n_days,
        transformer_kVA  = 200.0,
        tap              = Float64(tap),
        seed             = seed,
        allocation       = ALLOCATION,
        pv_mode          = pv_mode,
        statcom_scenario = c.scenario,
        statcom_control  = c.control,
        output_dir       = output_dir,
        write_files      = write_files)
    return quiet ? redirect_stdout(f, devnull) : f()
end

"Set of already-finished keys in a resumable CSV, as tuples of strings."
function finished_keys(path::AbstractString, keycols::Vector{Symbol})
    done = Set{Tuple}()
    isfile(path) || return done
    for r in eachrow(CSV.read(path, DataFrame))
        push!(done, Tuple(string(r[k]) for k in keycols))
    end
    return done
end

append_csv(path::AbstractString, df::DataFrame) = CSV.write(path, df; append = isfile(path))

date_of(day::Int) = Date(DATA_YEAR, 1, 1) + Day(day - 1)

"Stop if a resumable CSV was made with a different tap (or window)."
function check_same(path::AbstractString, col::Symbol, value, what::AbstractString)
    isfile(path) || return
    old = CSV.read(path, DataFrame)
    (nrow(old) > 0 && hasproperty(old, col)) || return
    old[1, col] ≈ value || error("$path holds runs for $what = $(old[1, col]), not $value. " *
                                 "Delete that folder and run again.")
end


# ========================================================================
# T. TAP SELECTION (Case 2, seed 42): which off-load tap position?
# ========================================================================
tap_dir  = joinpath(OUTPUT_ROOT, "tap_selection")
tap_path = joinpath(tap_dir, "tap_weekly.csv")
TAP_PU   = 1.0   # placeholder until chosen

if TAP === nothing && RUN_TAP_SELECT
    mkpath(tap_dir)
    c2 = CASE_BY_ID[:case2]
    done = finished_keys(tap_path, [:tap, :week])
    n_total = length(TAP_OPTIONS) * length(SCREEN_WEEKS)
    banner("TAP SELECTION: Case 2 x $(length(TAP_OPTIONS)) taps x $(length(SCREEN_WEEKS)) weeks = $n_total runs" *
           (isempty(done) ? "" : "  (resuming, $(length(done)) done)"))
    for tp in TAP_OPTIONS, w in SCREEN_WEEKS
        (string(tp), string(w)) in done && continue
        sd = (w - 1) * 7 + 1
        t = @elapsed r = run_case(c2, BASE_SEED; start_day = sd, n_days = 7, tap = tp,
                                  output_dir = joinpath(OUTPUT_ROOT, "tap_tmp"),
                                  write_files = false, quiet = QUIET)
        f = compute_metrics(r).feeder
        append_csv(tap_path, DataFrame([merge((tap = tp, week = w, start_day = sd), f, (runtime_s = t,))]))
        push!(done, (string(tp), string(w)))
        println("  [$(length(done))/$n_total] tap $tp, week $w: V $(round(f.min_v, digits=1))-" *
                "$(round(f.max_v, digits=1)) V, loads passing 99% band $(f.n_pass_99)/25")
    end
end

if TAP !== nothing
    TAP_PU = Float64(TAP)
    tap_note = "set manually"
elseif isfile(tap_path)
    tw = CSV.read(tap_path, DataFrame)
    tap_summary = combine(groupby(tw, :tap),
        :voltage_compliant => (x -> count(Bool.(x))) => :weeks_voltage_compliant,
        :n_pass_99 => mean => :mean_loads_pass_99,
        :min_v => minimum => :lowest_v, :max_v => maximum => :highest_v)
    sort!(tap_summary, :tap)
    CSV.write(joinpath(tap_dir, "tap_summary.csv"), tap_summary)
    println(tap_summary)
    # Most compliant weeks; ties go to the more loads passing, then the lower tap
    i = sortperm(collect(zip(-tap_summary.weeks_voltage_compliant, -tap_summary.mean_loads_pass_99,
                             tap_summary.tap)))[1]
    TAP_PU = Float64(tap_summary.tap[i])
    tap_note = "most voltage-compliant weeks for Case 2 ($(tap_summary.weeks_voltage_compliant[i]) of $(length(unique(tw.week))))"
else
    error("No tap selection results. Set RUN_TAP_SELECT = true or set TAP.")
end
CSV.write(joinpath(OUTPUT_ROOT, "tap_choice.csv"), DataFrame(tap = [TAP_PU], note = [tap_note]))
banner("TRANSFORMER TAP: $(TAP_PU) pu ($tap_note)")


# ========================================================================
# 0. YEAR SCREEN (seed 42): one-week runs across the whole year
# ========================================================================
year_dir  = joinpath(OUTPUT_ROOT, "year_screen")
year_path = joinpath(year_dir, "year_weekly.csv")

if RUN_YEAR_SCREEN
    mkpath(year_dir)
    check_same(year_path, :tap, TAP_PU, "tap")
    screen = [c for c in CASES if c.id in SCREEN_CASES]
    done = finished_keys(year_path, [:case, :week])
    n_total = length(screen) * length(SCREEN_WEEKS)
    banner("YEAR SCREEN: $(length(screen)) cases x $(length(SCREEN_WEEKS)) weeks = $n_total runs" *
           (isempty(done) ? "" : "  (resuming, $(length(done)) done)"))

    for c in screen, w in SCREEN_WEEKS
        (String(c.id), string(w)) in done && continue
        sd = (w - 1) * 7 + 1
        t = @elapsed r = run_case(c, BASE_SEED; start_day = sd, n_days = 7,
                                  output_dir = joinpath(OUTPUT_ROOT, "year_tmp"),
                                  write_files = false, quiet = QUIET)
        f = compute_metrics(r).feeder
        row = merge((case = String(c.id), tap = TAP_PU, week = w, start_day = sd,
                     start_date = string(date_of(sd))), f, (runtime_s = t,))
        append_csv(year_path, DataFrame([row]))
        push!(done, (String(c.id), string(w)))
        println("  [$(length(done))/$n_total] $(c.label), week $w ($(date_of(sd))): " *
                "P95 VUF $(round(f.p95_iec, digits=2))%, " *
                "V $(round(f.min_v, digits=1))-$(round(f.max_v, digits=1)) V, " *
                "$(round(t, digits=1)) s")
    end

    banner("YEAR SCREEN SUMMARY")
    summarise_year(CSV.read(year_path, DataFrame); output_dir = year_dir)
end


# ========================================================================
# Choose the assessment window
# ========================================================================
if ASSESS_START_DAY !== nothing
    START_DAY = ASSESS_START_DAY
    week      = (START_DAY - 1) ÷ 7 + 1
    note      = "set manually"
elseif isfile(year_path)
    y  = CSV.read(year_path, DataFrame)
    y2 = y[string.(y.case) .== "case2", :]
    nrow(y2) > 0 || error("Year screen has no Case 2 rows; cannot choose the assessment week")
    i  = argmax(y2.p95_iec)
    START_DAY = Int(y2.start_day[i])
    week      = Int(y2.week[i])
    note      = "week with the highest Case 2 P95 VUF ($(round(y2.p95_iec[i], digits=3))%)"
else
    error("No year screen results found. Set RUN_YEAR_SCREEN = true or set ASSESS_START_DAY.")
end

CSV.write(joinpath(OUTPUT_ROOT, "assessment_window.csv"),
          DataFrame(start_day = [START_DAY], n_days = [N_DAYS], week = [week],
                    start_date = [string(date_of(START_DAY))], note = [note]))
banner("ASSESSMENT WINDOW: $(date_of(START_DAY)) to $(date_of(START_DAY + N_DAYS - 1)) " *
       "(week $week, $note)")


# ========================================================================
# 1. BASE RUNS (seed 42): full analysis for every case
# ========================================================================
analyses = Dict{Symbol, Any}()

if RUN_BASE
    for c in CASES
        banner("$(c.label): $(c.name)   (seed $BASE_SEED)")
        case_dir = joinpath(OUTPUT_ROOT, "base", String(c.id))
        t = @elapsed results = run_case(c, BASE_SEED; start_day = START_DAY,
                                        output_dir = joinpath(case_dir, "raw"))
        analyses[c.id] = analyse_results(results; output_dir = case_dir)
        println("  run time: $(round(t, digits=1)) s")
    end

    banner("COMPARISON TABLES")
    compare_cases(analyses, [:case1, :case2];
        output_dir = joinpath(OUTPUT_ROOT, "comparison"),
        name = "pv_comparison",
        caption = "Feeder-wide comparison of legacy and AS/NZS~4777.2:2020 PV over the assessment week (seed 42).")
    compare_cases(analyses, [c.id for c in CASES if c.id != :case1];
        output_dir = joinpath(OUTPUT_ROOT, "comparison"),
        name = "statcom_comparison",
        caption = "Feeder-wide comparison of the STATCOM cases against Case~2 over the assessment week (seed 42).")
end


# ========================================================================
# 2. DIAGNOSTIC: does smart-inverter Volt-Var interact with the STATCOM?
# Same runs with PV held at unity power factor.
# ========================================================================
if RUN_DIAGNOSTIC
    banner("DIAGNOSTIC: PV at unity pf vs AS/NZS 4777.2")
    diag_df = DataFrame()
    for pvm in (:smart, :smart_unity), c in CASES
        c.pv == :smart || continue
        r = run_case(c, BASE_SEED; start_day = START_DAY,
                     output_dir = joinpath(OUTPUT_ROOT, "diag_tmp"),
                     write_files = false, pv_mode = pvm, quiet = QUIET)
        bs = compute_metrics(r).bus_summary
        append!(diag_df, DataFrame(pv_mode  = fill(String(pvm), nrow(bs)),
                                   case     = fill(String(c.id), nrow(bs)),
                                   bus      = bs.bus,
                                   peak_iec = bs.peak_iec,
                                   p95_iec  = bs.p95_iec))
        println("  $(c.label), PV $(pvm): done")
    end
    CSV.write(joinpath(OUTPUT_ROOT, "diagnostic_pv_interaction.csv"), diag_df)
end


# ========================================================================
# 3. MONTE CARLO: every case across MC_SEEDS (resumable)
# ========================================================================
if RUN_MONTE_CARLO
    mc_dir = joinpath(OUTPUT_ROOT, "monte_carlo")
    mkpath(mc_dir)
    feeder_path = joinpath(mc_dir, "mc_feeder.csv")
    bus_path    = joinpath(mc_dir, "mc_bus.csv")

    # Refuse to mix results from different windows or taps in one sweep
    check_same(feeder_path, :tap, TAP_PU, "tap")
    if isfile(feeder_path)
        old = CSV.read(feeder_path, DataFrame)
        if nrow(old) > 0 && (Int(old.start_day[1]) != START_DAY || Int(old.n_days[1]) != N_DAYS)
            error("outputs/monte_carlo/ holds runs for start day $(old.start_day[1]), " *
                  "not $START_DAY. Delete that folder and run again.")
        end
    end

    done = finished_keys(feeder_path, [:case, :seed])
    n_total = length(CASES) * length(MC_SEEDS)
    banner("MONTE CARLO: $(length(CASES)) cases x $(length(MC_SEEDS)) seeds = $n_total runs" *
           (isempty(done) ? "" : "  (resuming, $(length(done)) done)"))

    for c in CASES, seed in MC_SEEDS
        (String(c.id), string(seed)) in done && continue

        t = @elapsed r = run_case(c, seed; start_day = START_DAY,
                                  output_dir = joinpath(OUTPUT_ROOT, "mc_tmp"),
                                  write_files = false, quiet = QUIET)
        f, b = mc_record(compute_metrics(r), c.id, seed; runtime_s = t)
        f = merge(f, (start_day = START_DAY, n_days = N_DAYS, tap = TAP_PU))

        append_csv(feeder_path, DataFrame([f]))
        append_csv(bus_path, b)
        push!(done, (String(c.id), string(seed)))

        println("  [$(length(done))/$n_total] $(c.label), seed $seed: " *
                "P95 VUF $(round(f.p95_iec, digits=2))%, " *
                "voltage compliant: $(f.voltage_compliant), $(round(t, digits=1)) s")
    end

    banner("MONTE CARLO SUMMARY")
    summarise_monte_carlo(CSV.read(feeder_path, DataFrame), CSV.read(bus_path, DataFrame);
                          output_dir = mc_dir)
end

println("\nDone. Run include(\"plot_results.jl\") to make the thesis figures.")
