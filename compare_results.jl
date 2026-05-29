# -----------------------------------------------------------------------------
# Note on AI assistance:
# An AI assistant (Anthropic's Claude) was used to improve the readability of
# this code — formatting, comments, variable naming, and structural clean-up.
# The underlying logic, methodology, and implementation are the author's own.
# -----------------------------------------------------------------------------

using DataFrames
using CSV
using Statistics
using Printf


"""
    compare_scenarios(analysis_dumb, analysis_smart; output_dir)

Build feeder-wide and per-bus comparison tables for two scenarios.
Saves CSV, Markdown, and LaTeX versions of each.
"""
function compare_scenarios(
    analysis_dumb,
    analysis_smart;
    output_dir::AbstractString = "comparison_results",
)
    mkpath(output_dir)

    # ------------------------------------------------------------------
    # Feeder-wide summary table
    # ------------------------------------------------------------------
    summary = build_summary_table(analysis_dumb, analysis_smart)

    write_csv(summary, joinpath(output_dir, "comparison_summary.csv"))
    write_markdown(summary, joinpath(output_dir, "comparison_summary.md"),
                   "Feeder-wide comparison: dumb PV vs smart inverters (AS/NZS 4777.2:2020)")
    write_latex(summary, joinpath(output_dir, "comparison_summary.tex"),
                "feeder-summary", "Feeder-wide comparison.")
    print_table(summary, "FEEDER-WIDE SUMMARY")

    # ------------------------------------------------------------------
    # Per-bus voltage comparison
    # ------------------------------------------------------------------
    per_bus_v = build_per_bus_voltage_table(analysis_dumb, analysis_smart)
    write_csv(per_bus_v, joinpath(output_dir, "per_bus_voltage.csv"))
    write_markdown(per_bus_v, joinpath(output_dir, "per_bus_voltage.md"),
                   "Per-bus voltage comparison")
    write_latex(per_bus_v, joinpath(output_dir, "per_bus_voltage.tex"),
                "per-bus-voltage", "Per-bus voltage comparison.")

    # ------------------------------------------------------------------
    # Per-bus VUF comparison
    # ------------------------------------------------------------------
    per_bus_vuf = build_per_bus_vuf_table(analysis_dumb, analysis_smart)
    write_csv(per_bus_vuf, joinpath(output_dir, "per_bus_vuf.csv"))
    write_markdown(per_bus_vuf, joinpath(output_dir, "per_bus_vuf.md"),
                   "Per-bus VUF comparison")
    write_latex(per_bus_vuf, joinpath(output_dir, "per_bus_vuf.tex"),
                "per-bus-vuf", "Per-bus VUF comparison.")
    print_table(per_bus_vuf, "PER-BUS VUF COMPARISON")

    println("\nAll comparison tables written to: $output_dir")

    return (
        summary = summary,
        per_bus_voltage = per_bus_v,
        per_bus_vuf = per_bus_vuf,
    )
end


function build_summary_table(a_dumb, a_smart)
    DataFrame(
        Metric = [
            "Min phase voltage (pu)",
            "Max phase voltage (pu)",
            "Voltage spread (max-min)",
            "Mean phase voltage (pu)",
            "Voltage compliance (%)",
            "Peak VUF — IEC (%)",
            "Mean VUF — IEC (%)",
            "Peak VUF — NEMA (%)",
            "Mean VUF — NEMA (%)",
            "Mean self-consumption (%)",
        ],
        Dumb = [
            round(minimum(a_dumb.compliance.min_pu), digits=3),
            round(maximum(a_dumb.compliance.max_pu), digits=3),
            round(maximum(a_dumb.compliance.max_pu) - minimum(a_dumb.compliance.min_pu), digits=3),
            round(mean(a_dumb.compliance.mean_pu), digits=3),
            round(mean(a_dumb.compliance.pct_within_band), digits=2),
            round(maximum(a_dumb.peak_vuf.peak_vuf_iec), digits=3),
            round(mean(a_dumb.peak_vuf.peak_vuf_iec), digits=3),
            round(maximum(a_dumb.peak_vuf.peak_vuf_nema), digits=3),
            round(mean(a_dumb.peak_vuf.peak_vuf_nema), digits=3),
            round(mean(a_dumb.self_consumption.self_consumption_pct), digits=2),
        ],
        Smart = [
            round(minimum(a_smart.compliance.min_pu), digits=3),
            round(maximum(a_smart.compliance.max_pu), digits=3),
            round(maximum(a_smart.compliance.max_pu) - minimum(a_smart.compliance.min_pu), digits=3),
            round(mean(a_smart.compliance.mean_pu), digits=3),
            round(mean(a_smart.compliance.pct_within_band), digits=2),
            round(maximum(a_smart.peak_vuf.peak_vuf_iec), digits=3),
            round(mean(a_smart.peak_vuf.peak_vuf_iec), digits=3),
            round(maximum(a_smart.peak_vuf.peak_vuf_nema), digits=3),
            round(mean(a_smart.peak_vuf.peak_vuf_nema), digits=3),
            round(mean(a_smart.self_consumption.self_consumption_pct), digits=2),
        ],
    )
end


function build_per_bus_voltage_table(a_dumb, a_smart)
    df = DataFrame(
        Load = a_dumb.compliance.load,
        Min_Dumb = a_dumb.compliance.min_pu,
        Min_Smart = a_smart.compliance.min_pu,
        Max_Dumb = a_dumb.compliance.max_pu,
        Max_Smart = a_smart.compliance.max_pu,
    )
    df.Min_change = round.(df.Min_Smart .- df.Min_Dumb, digits=3)
    df.Max_change = round.(df.Max_Smart .- df.Max_Dumb, digits=3)
    return df
end


function build_per_bus_vuf_table(a_dumb, a_smart)
    df = DataFrame(
        Bus       = a_dumb.peak_vuf.bus,
        IEC_Dumb  = a_dumb.peak_vuf.peak_vuf_iec,
        IEC_Smart = a_smart.peak_vuf.peak_vuf_iec,
        NEMA_Dumb = a_dumb.peak_vuf.peak_vuf_nema,
        NEMA_Smart= a_smart.peak_vuf.peak_vuf_nema,
    )
    df.IEC_change_pct  = round.(100 .* (df.IEC_Smart .- df.IEC_Dumb)  ./ df.IEC_Dumb,  digits=1)
    df.NEMA_change_pct = round.(100 .* (df.NEMA_Smart .- df.NEMA_Dumb) ./ df.NEMA_Dumb, digits=1)
    return df
end


function write_csv(df::DataFrame, path::AbstractString)
    CSV.write(path, df)
    println("  saved $(basename(path))")
end


function write_markdown(df::DataFrame, path::AbstractString, caption::String)
    open(path, "w") do io
        println(io, "# ", caption)
        println(io)
        # Header
        println(io, "| ", join(string.(names(df)), " | "), " |")
        println(io, "|", join(["---" for _ in names(df)], "|"), "|")
        # Rows
        for row in eachrow(df)
            println(io, "| ", join(string.(values(row)), " | "), " |")
        end
    end
    println("  saved $(basename(path))")
end


function write_latex(df::DataFrame, path::AbstractString, label::String, caption::String)
    n_cols = ncol(df)
    open(path, "w") do io
        println(io, "\\begin{table}[h]")
        println(io, "\\centering")
        println(io, "\\caption{", caption, "}")
        println(io, "\\label{tab:", label, "}")
        println(io, "\\begin{tabular}{", "l" * "r"^(n_cols-1), "}")
        println(io, "\\toprule")
        println(io, join(string.(names(df)), " & "), " \\\\")
        println(io, "\\midrule")
        for row in eachrow(df)
            println(io, join(string.(values(row)), " & "), " \\\\")
        end
        println(io, "\\bottomrule")
        println(io, "\\end{tabular}")
        println(io, "\\end{table}")
    end
    println("  saved $(basename(path))")
end


function print_table(df::DataFrame, title::String)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    show(stdout, df; allrows=true, allcols=true, summary=false)
    println()
end