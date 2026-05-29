# -----------------------------------------------------------------------------
# Note on AI assistance:
# An AI assistant (Anthropic's Claude) was used to improve the readability of
# this code — formatting, comments, variable naming, and structural clean-up.
# The underlying logic, methodology, and implementation are the author's own.
# -----------------------------------------------------------------------------

cd(@__DIR__)

include("load_consumer_profiles.jl")
include("run_opendss_simulation.jl")
include("analyse_results.jl")
include("compare_results.jl")

# Base output folder — everything is written under here
const OUTPUT_ROOT = "outputs"
mkpath(OUTPUT_ROOT)

# ========================================================================
# SCENARIO A: Dumb PV (2019-era, no inverter response)
# ========================================================================
println("\n" * "="^70)
println("SCENARIO A: Dumb PV (negative-load, no inverter response)")
println("="^70)
results_dumb = run_opendss_simulation(consumers;
    network_file = joinpath(@__DIR__, "LVNetwork.dss"),
    mode = :daily,
    transformer_kVA = 200.0,
    pv_mode = :dumb,
    output_dir = joinpath(OUTPUT_ROOT, "raw_dumb"))

println("\nAnalysing scenario A...")
analysis_dumb = analyse_results(results_dumb;
    output_dir = joinpath(OUTPUT_ROOT, "analysis_dumb"))

# ========================================================================
# SCENARIO B: Smart PV (AS/NZS 4777.2:2020)
# ========================================================================
println("\n" * "="^70)
println("SCENARIO B: Smart PV (AS/NZS 4777.2:2020 Volt-Watt + Volt-Var)")
println("="^70)
results_smart = run_opendss_simulation(consumers;
    network_file = joinpath(@__DIR__, "LVNetwork.dss"),
    mode = :daily,
    transformer_kVA = 200.0,
    pv_mode = :smart,
    output_dir = joinpath(OUTPUT_ROOT, "raw_smart"))

println("\nAnalysing scenario B...")
analysis_smart = analyse_results(results_smart;
    output_dir = joinpath(OUTPUT_ROOT, "analysis_smart"))

# ========================================================================
# COMPARISON
# ========================================================================
println("\n" * "="^70)
println("BUILDING COMPARISON TABLES")
println("="^70)
comparison = compare_scenarios(analysis_dumb, analysis_smart;
    output_dir = joinpath(OUTPUT_ROOT, "comparison"))