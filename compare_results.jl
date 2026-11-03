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
# Comparison tables across cases (base runs) and the Monte Carlo summary.
# Every table is written as CSV, Markdown and a booktabs LaTeX table that can
# be \input{} straight into the thesis.
# -----------------------------------------------------------------------------

using DataFrames
using CSV
using Statistics
using Printf


# ----------------------------------------------------------------------
# Formatting helpers
# ----------------------------------------------------------------------
fmt(x::Bool, d::Int = 3) = x ? "Yes" : "No"
fmt(x::AbstractString, d::Int = 3) = String(x)
fmt(x::Integer, d::Int = 3) = string(x)
fmt(x::Real, d::Int = 3) = isnan(x) ? "--" : Printf.format(Printf.Format("%.$(d)f"), x)

function format_table(df::DataFrame; digits::Int = 3)
    out = DataFrame()
    for name in names(df)
        out[!, name] = [fmt(x, digits) for x in df[!, name]]
    end
    return out
end

latex_escape(s) = replace(string(s), "\\" => "\\textbackslash{}", "%" => "\\%",
                          "_" => "\\_", "&" => "\\&", "#" => "\\#", ">=" => "\$\\geq\$")

function write_csv(df::DataFrame, path::AbstractString)
    CSV.write(path, df)
    println("  saved $(basename(path))")
end

function write_markdown(df::DataFrame, path::AbstractString, caption::AbstractString)
    open(path, "w") do io
        println(io, "# ", caption, "\n")
        println(io, "| ", join(string.(names(df)), " | "), " |")
        println(io, "|", join(["---" for _ in names(df)], "|"), "|")
        for row in eachrow(df)
            println(io, "| ", join(string.(values(row)), " | "), " |")
        end
    end
    println("  saved $(basename(path))")
end

function write_latex(df::DataFrame, path::AbstractString, label::AbstractString, caption::AbstractString)
    n_cols = ncol(df)
    open(path, "w") do io
        println(io, "\\begin{table}[H]")
        println(io, "\\centering")
        println(io, "\\caption{", caption, "}")
        println(io, "\\label{tab:", label, "}")
        println(io, "\\begin{tabular}{l", "r"^(n_cols - 1), "}")
        println(io, "\\toprule")
        println(io, join(latex_escape.(names(df)), " & "), " \\\\")
        println(io, "\\midrule")
        for row in eachrow(df)
            println(io, join(latex_escape.(values(row)), " & "), " \\\\")
        end
        println(io, "\\bottomrule")
        println(io, "\\end{tabular}")
        println(io, "\\end{table}")
    end
    println("  saved $(basename(path))")
end

function write_all(df::DataFrame, dir::AbstractString, name::AbstractString, caption::AbstractString)
    write_csv(df, joinpath(dir, "$(name).csv"))
    write_markdown(df, joinpath(dir, "$(name).md"), caption)
    write_latex(df, joinpath(dir, "$(name).tex"), replace(name, "_" => "-"), caption)
end

function print_table(df::DataFrame, title::AbstractString)
    println("\n" * "="^70)
    println(title)
    println("="^70)
    show(stdout, df; allrows = true, allcols = true, summary = false)
    println()
end


# ----------------------------------------------------------------------
# Base-run comparison across any set of cases
# ----------------------------------------------------------------------
const FEEDER_ROWS = [
    ("Minimum customer voltage (V)",                    :min_v,             1),
    ("Maximum customer voltage (V)",                    :max_v,             1),
    ("Loads within 225-244 V for >= 50% of time",       :n_pass_50,         0),
    ("Loads within 216-253 V for >= 99% of time",       :n_pass_99,         0),
    ("Peak VUF, IEC (%)",                               :peak_iec,          3),
    ("95th-percentile VUF, IEC, worst bus (%)",         :p95_iec,           3),
    ("Worst bus",                                       :worst_bus,         0),
    ("Peak unbalance, NEMA line-to-line (%)",           :peak_nema,         3),
    ("95th-percentile NEMA, worst bus (%)",             :p95_nema,          3),
    ("Peak phase voltage unbalance, PVUR (%)",          :peak_pvur,         3),
    ("95th-percentile PVUR, worst bus (%)",             :p95_pvur,          3),
    ("Meets 2% VUF limit",                              :vuf_compliant,     0),
    ("Meets voltage limits",                            :voltage_compliant, 0),
]

"""
    compare_cases(analyses, ids; output_dir, name, caption)

Feeder-wide summary (one column per case) and per-bus 95th-percentile IEC VUF.
"""
function compare_cases(analyses::AbstractDict, ids::Vector{Symbol};
                       output_dir::AbstractString, name::AbstractString, caption::AbstractString)
    mkpath(output_dir)
    ids = filter(id -> haskey(analyses, id), ids)

    summary = DataFrame(Metric = [r[1] for r in FEEDER_ROWS])
    for id in ids
        f = analyses[id].feeder
        summary[!, CASE_BY_ID[id].label] = [fmt(getproperty(f, r[2]), r[3]) for r in FEEDER_ROWS]
    end

    per_bus = DataFrame(Bus = BUS_ORDER)
    for id in ids
        bs = analyses[id].bus_summary
        lookup = Dict(zip(bs.bus, bs.p95_iec))
        per_bus[!, CASE_BY_ID[id].label] = [fmt(get(lookup, b, NaN), 3) for b in BUS_ORDER]
    end

    write_all(summary, output_dir, "$(name)_summary", caption)
    write_all(per_bus, output_dir, "$(name)_per_bus_p95_vuf",
              "95th-percentile IEC VUF (\\%) at each bus.")
    print_table(summary, uppercase(replace(name, "_" => " ")))

    return (summary = summary, per_bus = per_bus)
end


# ----------------------------------------------------------------------
# Monte Carlo summary
# ----------------------------------------------------------------------
"""
    wilson_interval(k, n; z = 1.96)

95% Wilson score interval for a pass rate of k out of n. Better behaved than
the normal approximation when the rate is close to 0 or 1.
"""
function wilson_interval(k::Integer, n::Integer; z::Real = 1.96)
    n == 0 && return (NaN, NaN)
    p = k / n
    denom  = 1 + z^2 / n
    centre = (p + z^2 / (2n)) / denom
    half   = z * sqrt(p * (1 - p) / n + z^2 / (4n^2)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))
end

"""
    summarise_monte_carlo(mc_feeder, mc_bus; output_dir)

Per case: spread of the worst-bus 95th-percentile VUF across seeds, and how
many seeds meet the 2% limit, with a 95% confidence interval on that rate.
"""
function summarise_monte_carlo(mc_feeder::DataFrame, mc_bus::DataFrame; output_dir::AbstractString)
    mkpath(output_dir)
    case_col = string.(mc_feeder.case)

    feeder = DataFrame(Case = String[], Seeds = Int[],
                       Mean_P95_VUF = Float64[], Median_P95_VUF = Float64[], Worst_P95_VUF = Float64[],
                       Mean_peak_VUF = Float64[], Worst_peak_VUF = Float64[],
                       VUF_pass = Int[], Pass_rate = Float64[], CI_low = Float64[], CI_high = Float64[],
                       Voltage_pass = Int[], Both_pass = Int[])

    for c in CASES
        d = mc_feeder[case_col .== String(c.id), :]
        nrow(d) == 0 && continue
        n = nrow(d)
        vuf_ok = Bool.(d.vuf_compliant)
        v_ok   = Bool.(d.voltage_compliant)
        k = count(vuf_ok)
        lo, hi = wilson_interval(k, n)
        push!(feeder, (c.label, n,
                       mean(d.p95_iec), median(d.p95_iec), maximum(d.p95_iec),
                       mean(d.peak_iec), maximum(d.peak_iec),
                       k, k / n, lo, hi, count(v_ok), count(vuf_ok .& v_ok)))
    end

    per_bus = combine(groupby(mc_bus, [:case, :bus]),
                      :p95_iec  => mean    => :mean_p95_iec,
                      :p95_iec  => maximum => :worst_p95_iec,
                      :peak_iec => maximum => :worst_peak_iec,
                      :p95_nema => mean    => :mean_p95_nema)

    write_csv(feeder, joinpath(output_dir, "mc_summary.csv"))
    write_csv(per_bus, joinpath(output_dir, "mc_per_bus.csv"))

    pretty = format_table(feeder; digits = 3)
    write_markdown(pretty, joinpath(output_dir, "mc_summary.md"), "Monte Carlo summary")
    write_latex(pretty, joinpath(output_dir, "mc_summary.tex"), "mc-summary",
                "Monte Carlo results across $(maximum(feeder.Seeds; init = 0)) consumer allocations. " *
                "P95 VUF is the 95th-percentile IEC VUF at the worst bus; CI is the 95\\% Wilson interval on the pass rate.")
    print_table(pretty, "MONTE CARLO SUMMARY")

    return (feeder = feeder, per_bus = per_bus)
end



# ----------------------------------------------------------------------
# Full-year screen summary (seed 42, one row per case)
# ----------------------------------------------------------------------
"""
    summarise_year(year_df; output_dir)

How many of the 52 weeks of 2019 each case meets the 2% VUF limit and the
voltage limits, assessed week by week as AS 61000.3.100 intends.
"""
function summarise_year(year_df::DataFrame; output_dir::AbstractString)
    mkpath(output_dir)
    case_col = string.(year_df.case)
    out = DataFrame(Case = String[], Weeks = Int[], VUF_weeks_pass = Int[], Voltage_weeks_pass = Int[],
                    Both_weeks_pass = Int[], Mean_weekly_P95_VUF = Float64[], Worst_weekly_P95_VUF = Float64[],
                    Lowest_voltage = Float64[], Highest_voltage = Float64[])
    for c in CASES
        d = year_df[case_col .== String(c.id), :]
        nrow(d) == 0 && continue
        vuf_ok = Bool.(d.vuf_compliant)
        v_ok   = Bool.(d.voltage_compliant)
        push!(out, (c.label, nrow(d), count(vuf_ok), count(v_ok), count(vuf_ok .& v_ok),
                    mean(d.p95_iec), maximum(d.p95_iec), minimum(d.min_v), maximum(d.max_v)))
    end
    write_csv(out, joinpath(output_dir, "year_summary.csv"))
    pretty = format_table(out; digits = 2)
    write_markdown(pretty, joinpath(output_dir, "year_summary.md"), "Full-year weekly compliance (seed 42)")
    write_latex(pretty, joinpath(output_dir, "year_summary.tex"), "year-summary",
                "Number of weeks in 2019 meeting each limit, assessed week by week (seed 42).")
    print_table(pretty, "FULL-YEAR WEEKLY COMPLIANCE")
    return out
end
