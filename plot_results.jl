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
# All Chapter 4 figures, drawn from the CSVs written by run.jl. Nothing here
# reruns a simulation, so figures can be restyled and re-made in seconds:
#     include("plot_results.jl")
# Every figure is a vector PDF in outputs/figures/, sized for the thesis text
# width, using one fixed colour per case:
#     Case 1 vermillion, Case 2 blue, Case 3 orange, Case 4 green, Case 5 pink
#     Volt-Var = dashed, NSC = solid
# If any figure is missing its input CSV, it is skipped with a warning.
# A full set of verification figures for every case (VUF at every bus, NEMA,
# customer voltages, compliance, transformer power, self-consumption, STATCOM Q)
# goes to outputs/figures/verification/<case>/ for data checks and the appendix.
# The input-data figures (fleet average/aggregate day, seasonal profiles,
# duration curves, illustrative consumers) are made by plot_load_profiles.jl,
# which runs automatically when run.jl loads the consumers.
# -----------------------------------------------------------------------------
 
using CSV
using DataFrames
using Statistics
using Random
using Plots
gr()
 
include(joinpath(@__DIR__, "cases.jl"))
 
OUT_DIR  = joinpath(@__DIR__, "outputs")
BASE_DIR = joinpath(OUT_DIR, "base")
MC_DIR   = joinpath(OUT_DIR, "monte_carlo")
FIG_DIR  = joinpath(OUT_DIR, "figures")
mkpath(FIG_DIR)
 
# ------------------------------ Style -----------------------------------------
TEXT_WIDTH_IN = 6.3       # LaTeX \textwidth in inches; include figures at width=\textwidth
PX_PER_IN     = 100       # Plots.jl size units per inch. If fonts look too small or
                          # too large in the PDF, adjust this one number.
figsize(w_in, h_in) = (round(Int, w_in * PX_PER_IN), round(Int, h_in * PX_PER_IN))
 
default(fontfamily = "Computer Modern", titlefontsize = 9, guidefontsize = 9,
        tickfontsize = 7, legendfontsize = 7, framestyle = :box, grid = true,
        gridalpha = 0.2, linewidth = 1.2,
        foreground_color_legend = nothing, background_color_legend = nothing,
        left_margin = 3Plots.mm, bottom_margin = 3Plots.mm,
        right_margin = 2Plots.mm, top_margin = 1Plots.mm)
 
# Okabe-Ito palette (colour-blind safe)
OI = (vermillion = RGB(0.84, 0.37, 0.00), blue   = RGB(0.00, 0.45, 0.70),
      orange     = RGB(0.90, 0.60, 0.00), green  = RGB(0.00, 0.62, 0.45),
      pink       = RGB(0.80, 0.47, 0.65), sky    = RGB(0.34, 0.71, 0.91),
      yellow     = RGB(0.94, 0.89, 0.26), black  = RGB(0.00, 0.00, 0.00))
 
PLACEMENT_COLOUR = Dict(3 => OI.orange, 4 => OI.green, 5 => OI.pink)
PHASE_COLOUR     = [OI.vermillion, OI.green, OI.blue]
 
# Time axis: hours of day for a 1-day run, days for a multi-day run.
# N_DAYS_PLOT is detected from the data in make_all_figures().
N_DAYS_PLOT = 1
function detect_days()
    d = base_csv(:case2, "transformer_power.csv")
    global N_DAYS_PLOT = d === nothing ? 1 : max(1, ceil(Int, (maximum(d.hour) + 1e-6) / 24))
end
tx(h) = N_DAYS_PLOT > 1 ? h ./ 24 : h
time_label() = N_DAYS_PLOT > 1 ? "Day of assessment week" : "Hour of day"
time_ticks() = N_DAYS_PLOT > 1 ? (xlims = (0, N_DAYS_PLOT), xticks = 0:1:N_DAYS_PLOT) :
                                 (xlims = (0, 24), xticks = 0:3:24)
 
function case_colour(id::Symbol)
    id == :case1 && return OI.vermillion
    id == :case2 && return OI.blue
    return PLACEMENT_COLOUR[parse(Int, string(id)[5])]
end
case_style(id::Symbol) = endswith(string(id), "_vv") ? :dash : :solid
case_name(id::Symbol)  = "$(CASE_BY_ID[id].label): $(CASE_BY_ID[id].name)"
ctrl_name(ctrl::Symbol) = ctrl == :nsc ? "NSC" : "Volt-Var"
 
 
# ------------------------------ I/O helpers -----------------------------------
function load_csv(path::AbstractString)
    if !isfile(path)
        @warn "Missing $path (run run.jl first). Skipping figure."
        return nothing
    end
    return CSV.read(path, DataFrame)
end
 
base_csv(id::Symbol, file::AbstractString) = load_csv(joinpath(BASE_DIR, String(id), file))
 
function load_mc()
    d = load_csv(joinpath(MC_DIR, "mc_feeder.csv"))
    d === nothing && return nothing
    d.case = Symbol.(string.(d.case))
    return d
end
 
present_cases(d::DataFrame) = [c.id for c in CASES if any(d.case .== c.id)]
 
function save_fig(p, name::AbstractString)
    path = joinpath(FIG_DIR, name * ".pdf")
    savefig(p, path)
    println("  saved $path")
end
 
# ------------------------------ Legends and colour keys -----------------------
# Every legend sits on its own strip above the plot area so it never covers
# data, and every heatmap gets its colour key as a separate narrow panel so
# side-by-side heatmaps come out the same width.
line_entry(label; color = :black, linestyle = :solid, linewidth = 1.2) =
    (label = label, kind = :line, color = color, linestyle = linestyle, linewidth = linewidth)
patch_entry(label; color, alpha = 1.0) = (label = label, kind = :patch, color = color, alpha = alpha)
marker_entry(label; color, shape = :circle) = (label = label, kind = :marker, color = color, shape = shape)
 
function legend_strip(entries; ncol::Int = length(entries))
    p = plot(; framestyle = :none, grid = false, xticks = false, yticks = false,
             xlims = (0, 1), ylims = (0, 1), legend = :top, legend_column = ncol,
             top_margin = 0Plots.mm, bottom_margin = 0Plots.mm)
    for e in entries
        if e.kind == :line
            plot!(p, [NaN], [NaN]; color = e.color, linestyle = e.linestyle, linewidth = e.linewidth,
                  label = e.label)
        elseif e.kind == :patch
            scatter!(p, [NaN], [NaN]; markershape = :rect, markersize = 6, markerstrokewidth = 0,
                     color = e.color, markeralpha = e.alpha, label = e.label)
        else
            scatter!(p, [NaN], [NaN]; markershape = e.shape, markersize = 4, markerstrokewidth = 0,
                     color = e.color, label = e.label)
        end
    end
    return p
end
 
"Put a legend strip above `body` (one plot or a multi-panel plot)."
function with_legend(body, entries; w_in::Real = TEXT_WIDTH_IN, h_in::Real, ncol::Int = length(entries))
    plot!(body; legend = false)
    rows  = cld(length(entries), ncol)
    strip = (0.12 + 0.17 * rows) / h_in
    return plot(legend_strip(entries; ncol = ncol), body;
                layout = grid(2, 1, heights = [strip, 1 - strip]), size = figsize(w_in, h_in))
end
 
"A vertical colour key on its own, to sit beside one or more heatmaps."
function colour_key(grad, clims; label::AbstractString = "")
    v = collect(range(clims[1], clims[2]; length = 256))
    return heatmap([0.0, 1.0], v, repeat(v, 1, 2); color = grad, clims = clims, colorbar = false,
                   xticks = false, ymirror = true, ylabel = label, grid = false,
                   left_margin = 0Plots.mm, right_margin = 4Plots.mm)
end
 
"Heatmap panels side by side, then the colour key."
function heatmaps_with_key(panels, key; w_in::Real = TEXT_WIDTH_IN, h_in::Real, key_frac::Real = 0.07)
    n = length(panels)
    w = vcat(fill((1 - key_frac) / n, n), key_frac)
    return plot(panels..., key; layout = grid(1, n + 1, widths = w), size = figsize(w_in, h_in))
end
 
# Cell labels: never print "-0.0"
cell_text(x::Real; digits::Int = 2) = (r = round(x; digits = digits); r == 0 ? "0" : string(r))
 
# Shading entries that go with shade_periods!
shade_entries() = [patch_entry("Midday (10-15 h)"; color = OI.yellow, alpha = 0.35),
                   patch_entry("Evening (17-21 h)"; color = OI.sky, alpha = 0.35)]
 
# Phase of a STATCOM unit from its name (Statcom_<bus>_<phase>)
function unit_phase(u::AbstractString)
    m = match(r"_(\d)$", u)
    return m === nothing ? 1 : parse(Int, m[1])
end
 
# Highest VUF across all buses at each timestep
feeder_max_vuf(bus_ts::DataFrame) =
    sort(combine(groupby(bus_ts, :hour), :vuf_iec => maximum => :vuf), :hour)
 
# Light shading for the midday (10-15 h) and evening (17-21 h) windows of every day
function shade_periods!(p)
    for day in 0:N_DAYS_PLOT-1
        vspan!(p, tx([24day + 10, 24day + 15]); color = OI.yellow, alpha = 0.18, label = "")
        vspan!(p, tx([24day + 17, 24day + 21]); color = OI.sky,    alpha = 0.15, label = "")
    end
end
 
function wilson(k::Integer, n::Integer; z = 1.96)
    n == 0 && return (NaN, NaN)
    p = k / n
    d = 1 + z^2 / n
    c = (p + z^2 / (2n)) / d
    h = z * sqrt(p * (1 - p) / n + z^2 / (4n^2)) / d
    return (max(0.0, c - h), min(1.0, c + h))
end
 
 
# =============================================================================
# 4.1  Case 1 vs Case 2
# =============================================================================
 
# Customer voltage envelope: min-max band across all 25 loads, median line
function fig_voltage_envelope_pv()
    panels = []
    for id in (:case1, :case2)
        d = base_csv(id, "customer_voltage_timeseries.csv")
        d === nothing && return
        g = sort(combine(groupby(d, :hour),
                         :v_pn => minimum => :lo, :v_pn => median => :med, :v_pn => maximum => :hi), :hour)
        first_panel = id == :case1
        p = plot(tx(g.hour), g.med; ribbon = (g.med .- g.lo, g.hi .- g.med), fillalpha = 0.25,
                 color = case_colour(id), title = case_name(id), xlabel = time_label(),
                 ylabel = first_panel ? "Customer voltage (V)" : "", time_ticks()...)
        hline!(p, [216, 253]; color = :black, linestyle = :dash, linewidth = 0.8)
        hline!(p, [225, 244]; color = :black, linestyle = :dot, linewidth = 0.8)
        push!(panels, p)
    end
    body = plot(panels...; layout = (1, 2), link = :y)
    entries = [line_entry("Median, Case 1"; color = case_colour(:case1)),
               line_entry("Median, Case 2"; color = case_colour(:case2)),
               patch_entry("Min to max across loads"; color = :grey60, alpha = 0.4),
               line_entry("216-253 V (99% band)"; linestyle = :dash, linewidth = 0.8),
               line_entry("225-244 V (50% band)"; linestyle = :dot, linewidth = 0.8)]
    save_fig(with_legend(body, entries; h_in = 3.0, ncol = 3), "fig_4_1a_voltage_envelope")
end
 
# Feeder peak VUF over the day, both PV models on one axis
function fig_vuf_timeseries_pv()
    p = plot(; xlabel = time_label(), ylabel = "Feeder peak VUF, IEC (%)", time_ticks()...)
    shade_periods!(p)
    for id in (:case1, :case2)
        d = base_csv(id, "bus_timeseries.csv")
        d === nothing && return
        f = feeder_max_vuf(d)
        plot!(p, tx(f.hour), f.vuf; color = case_colour(id))
    end
    hline!(p, [2.0]; color = :black, linestyle = :dash, linewidth = 0.8)
    entries = vcat([line_entry(case_name(id); color = case_colour(id)) for id in (:case1, :case2)],
                   [line_entry("2% limit"; linestyle = :dash, linewidth = 0.8)], shade_entries())
    save_fig(with_legend(p, entries; h_in = 3.0, ncol = 3), "fig_4_1b_vuf_timeseries")
end
 
# Bus x time heatmap of VUF, Case 1 and Case 2 on a shared colour scale
function vuf_grid(d::DataFrame; col::Symbol = :vuf_iec)
    hours = sort(unique(d.hour))
    hi = Dict(h => i for (i, h) in enumerate(hours))
    bi = Dict(b => i for (i, b) in enumerate(BUS_ORDER))
    M = fill(NaN, length(BUS_ORDER), length(hours))
    for r in eachrow(d)
        haskey(bi, r.bus) && (M[bi[r.bus], hi[r.hour]] = r[col])
    end
    return hours, M
end
 
# Viridis up to the 2% limit, then a solid red block above it, so every
# bus/time over the limit stands out
function threshold_gradient(cmax::Real; limit::Real = 2.0)
    viridis = [RGB(0.267, 0.005, 0.329), RGB(0.231, 0.322, 0.545), RGB(0.129, 0.569, 0.549),
               RGB(0.369, 0.788, 0.384), RGB(0.992, 0.906, 0.145)]
    cmax <= limit && return cgrad(viridis)
    f = limit / cmax
    cols = vcat(viridis, [RGB(0.84, 0.15, 0.10), RGB(0.55, 0.00, 0.00)])
    pos  = vcat(f .* [0.0, 0.25, 0.5, 0.75, 1.0], [min(f + 1e-4, 1.0), 1.0])
    return cgrad(cols, pos)
end
 
function fig_vuf_heatmap_pv()
    grids = Dict{Symbol, Any}()
    for id in (:case1, :case2)
        d = base_csv(id, "bus_timeseries.csv")
        d === nothing && return
        grids[id] = vuf_grid(d)
    end
    cmax = maximum(maximum(filter(!isnan, g[2])) for g in values(grids))
    nb = length(BUS_ORDER)
    grad = threshold_gradient(cmax)
    panels = [heatmap(tx(grids[id][1]), 1:nb, grids[id][2];
                      yticks = (1:nb, k == 1 ? BUS_SHORT : fill("", nb)), yflip = true, clims = (0, cmax),
                      color = grad, colorbar = false,
                      title = case_name(id), xlabel = time_label(), time_ticks()...)
              for (k, id) in enumerate((:case1, :case2))]
    key = colour_key(grad, (0, cmax); label = cmax > 2.0 ? "VUF (%), red = above 2%" : "VUF (%)")
    save_fig(heatmaps_with_key(panels, key; h_in = 3.0, key_frac = 0.1), "fig_4_1c_vuf_heatmap")
end
 
# Per-phase transformer power (duck curve), Case 1 and Case 2
function fig_transformer_power_pv()
    panels = []
    for id in (:case1, :case2)
        t = base_csv(id, "transformer_power.csv")
        t === nothing && return
        first_panel = id == :case1
        p = plot(tx(t.hour), t.p_total; color = :black, linewidth = 1.6, title = case_name(id),
                 xlabel = time_label(), ylabel = first_panel ? "Active power (kW, +ve import)" : "",
                 time_ticks()...)
        for (k, col) in enumerate((:p_a, :p_b, :p_c))
            plot!(p, tx(t.hour), t[!, col]; color = PHASE_COLOUR[k])
        end
        hline!(p, [0.0]; color = :grey, linewidth = 0.6)
        push!(panels, p)
    end
    body = plot(panels...; layout = (1, 2), link = :y)
    save_fig(with_legend(body, transformer_entries(); h_in = 2.9), "fig_4_1d_transformer_power")
end
 
transformer_entries() = vcat([line_entry("Total"; linewidth = 1.6)],
                             [line_entry("Phase $("ABC"[k])"; color = PHASE_COLOUR[k]) for k in 1:3])
 
 
# =============================================================================
# 4.2  Why Volt-Var cannot see unbalance: zero vs negative sequence
# =============================================================================
function fig_sequence_components(id::Symbol = :case2)
    s = base_csv(id, "bus_summary.csv")
    s === nothing && return
    lookup = Dict(r.bus => r for r in eachrow(s))
    val(b, col) = haskey(lookup, b) ? lookup[b][col] : NaN
    v0 = [val(b, :mean_v0) for b in BUS_ORDER]
    v2 = [val(b, :mean_v2) for b in BUS_ORDER]
    x = 1:length(BUS_ORDER)
 
    p = bar(x .- 0.2, v0; bar_width = 0.4, color = OI.sky, linecolor = :match)
    bar!(p, x .+ 0.2, v2; bar_width = 0.4, color = OI.vermillion, linecolor = :match)
    plot!(p; xticks = (x, BUS_SHORT), xrotation = 45, ylabel = "Mean magnitude (V)", title = case_name(id))
    entries = [patch_entry("Zero sequence |V0| (phase-to-neutral)"; color = OI.sky),
               patch_entry("Negative sequence |V2|"; color = OI.vermillion)]
    save_fig(with_legend(p, entries; h_in = 2.9), "fig_4_2_sequence_components")
end
 
 
# =============================================================================
# 4.3  STATCOM placements under both control laws
# =============================================================================
 
# 3x2 grid: rows = placement, columns = control law
function fig_statcom_grid_vuf()
    base = base_csv(:case2, "bus_timeseries.csv")
    base === nothing && return
    fb = feeder_max_vuf(base)
    nrows = length(PLACEMENTS)
    panels = []
    for (row, pl) in enumerate(PLACEMENTS), (col, ctrl) in enumerate((:voltvar, :nsc))
        id = statcom_case_id(pl.n, ctrl)
        d = base_csv(id, "bus_timeseries.csv")
        d === nothing && return
        f = feeder_max_vuf(d)
        # Case 2 as a thin black line underneath; the STATCOM case on top in its
        # placement colour. Both solid: the column title already gives the control law.
        p = plot(tx(fb.hour), fb.vuf; color = :black, linewidth = 0.6,
                 title = "$(pl.name), $(ctrl_name(ctrl))",
                 xlabel = row == nrows ? time_label() : "",
                 ylabel = col == 1 ? "Feeder peak VUF (%)" : "", time_ticks()...)
        plot!(p, tx(f.hour), f.vuf; color = case_colour(id), linewidth = 0.9)
        hline!(p, [2.0]; color = :black, linestyle = :dot, linewidth = 0.8)
        push!(panels, p)
    end
    body = plot(panels...; layout = (nrows, 2), link = :all)
    entries = [line_entry("No STATCOM (Case 2)"; color = :black, linewidth = 0.6),
               line_entry("With STATCOM (placement colour)"; color = OI.green, linewidth = 0.9),
               line_entry("2% limit"; linestyle = :dot, linewidth = 0.8)]
    save_fig(with_legend(body, entries; h_in = 7.1, ncol = 3), "fig_4_3a_statcom_vuf_grid")
end
 
function unit_label(u::AbstractString)
    m = match(r"^Statcom_(.+)_(\d)$", u)
    m === nothing && return u
    return "$(replace(m[1], "_" => " ")), phase $("ABC"[parse(Int, m[2])])"
end
 
# Same grid layout, showing what each STATCOM unit is doing
function fig_statcom_grid_q()
    nrows = length(PLACEMENTS)
    panels = []
    for (row, pl) in enumerate(PLACEMENTS), (col, ctrl) in enumerate((:voltvar, :nsc))
        id = statcom_case_id(pl.n, ctrl)
        q = base_csv(id, "statcom_q.csv")
        q === nothing && return
        p = plot(; title = "$(pl.name), $(ctrl_name(ctrl))",
                 xlabel = row == nrows ? time_label() : "",
                 ylabel = col == 1 ? "Reactive power (kvar)" : "", time_ticks()...)
        for u in unique(q.unit)
            d = q[q.unit .== u, :]
            plot!(p, tx(d.hour), d.q_kvar; color = PHASE_COLOUR[unit_phase(u)])
        end
        hline!(p, [0.0]; color = :black, linewidth = 0.5)
        push!(panels, p)
    end
    body = plot(panels...; layout = (nrows, 2), link = :all)
    entries = [line_entry("Phase $("ABC"[k]) unit (+ve injecting)"; color = PHASE_COLOUR[k]) for k in 1:3]
    save_fig(with_legend(body, entries; h_in = 6.9), "fig_4_3b_statcom_q_grid")
end
 
# Change in 95th-percentile VUF at every bus vs Case 2 (blue = better)
function fig_delta_vuf_heatmap()
    ref = base_csv(:case2, "bus_summary.csv")
    ref === nothing && return
    refmap = Dict(zip(ref.bus, ref.p95_iec))
    ids = [statcom_case_id(pl.n, c) for pl in PLACEMENTS for c in (:voltvar, :nsc)]
    nb = length(BUS_ORDER)
    Δ = fill(NaN, nb, length(ids))
    for (j, id) in enumerate(ids)
        s = base_csv(id, "bus_summary.csv")
        s === nothing && return
        m = Dict(zip(s.bus, s.p95_iec))
        for (i, b) in enumerate(BUS_ORDER)
            (haskey(m, b) && haskey(refmap, b)) && (Δ[i, j] = m[b] - refmap[b])
        end
    end
    lim = max(maximum(abs, filter(!isnan, Δ)), 1e-3)
    grad = cgrad(:RdBu, rev = true)
 
    p = heatmap(1:length(ids), 1:nb, Δ; color = grad, clims = (-lim, lim), colorbar = false,
                xticks = (1:length(ids), [CASE_BY_ID[id].label for id in ids]), xrotation = 30,
                yticks = (1:nb, BUS_SHORT), yflip = true)
    for j in eachindex(ids), i in 1:nb
        isnan(Δ[i, j]) && continue
        txt_col = abs(Δ[i, j]) > 0.6 * lim ? :white : :black
        annotate!(p, j, i, text(cell_text(Δ[i, j]), 6, txt_col))
    end
    key = colour_key(grad, (-lim, lim); label = "Change in P95 VUF vs Case 2 (percentage points)")
    save_fig(heatmaps_with_key([p], key; h_in = 4.4, key_frac = 0.1), "fig_4_3c_delta_vuf_heatmap")
end
 
# Minimum customer voltage per case (dot plot against the 216 V limit)
function fig_min_voltage()
    got = Symbol[]
    vals = Float64[]
    for c in CASES
        f = base_csv(c.id, "feeder_summary.csv")
        f === nothing && continue
        push!(got, c.id)
        push!(vals, f.min_v[1])
    end
    isempty(got) && return
    x = 1:length(got)
    p = scatter(x, vals; color = [case_colour(i) for i in got], markersize = 6,
                markerstrokewidth = 0, legend = false,
                xticks = (x, [CASE_BY_ID[i].label for i in got]), xrotation = 30,
                ylabel = "Lowest 5-min customer voltage (V)", xlims = (0.4, length(got) + 0.6),
                size = figsize(TEXT_WIDTH_IN, 2.6))
    hline!(p, [216.0]; color = :black, linestyle = :dash, linewidth = 0.8)
    save_fig(p, "fig_4_3d_min_voltage")
end
 
# IEC VUF against NEMA (line-to-line) and PVUR (phase-to-neutral) at every bus
# and timestep, for Case 2 and one placement under both control laws.
# NEMA should track IEC closely; PVUR also carries the neutral shift.
function fig_iec_vs_nema(n::Int = 5; max_points::Int = 2000)
    ids = [:case2, statcom_case_id(n, :voltvar), statcom_case_id(n, :nsc)]
    data = Dict{Symbol, DataFrame}()
    rng = MersenneTwister(7)
    for id in ids
        d = base_csv(id, "bus_timeseries.csv")
        d === nothing && return
        # Thin the cloud so the PDF stays light: a fixed random sample, plus the
        # highest-VUF points so the tails are always shown
        if nrow(d) > max_points
            top  = partialsortperm(d.vuf_iec, 1:50; rev = true)
            keep = unique(vcat(randperm(rng, nrow(d))[1:max_points], top))
            d = d[keep, :]
        end
        data[id] = d
    end
    style(id) = (id == :case2 ? :grey55 : case_colour(id), endswith(string(id), "_vv") ? :utriangle : :circle)
    panels = []
    for (col, ylab) in ((:vuf_nema, "NEMA line-to-line (%)"), (:vuf_pvur, "PVUR, phase-to-neutral (%)"))
        p = plot(; xlabel = "VUF, IEC (%)", ylabel = ylab)
        for id in ids
            colr, shape = style(id)
            scatter!(p, data[id].vuf_iec, data[id][!, col]; color = colr, markershape = shape,
                     markersize = 1.8, markerstrokewidth = 0, alpha = 0.35)
        end
        xmax = maximum(maximum(data[id].vuf_iec) for id in ids)
        plot!(p, [0, xmax], [0, xmax]; color = :black, linewidth = 0.8)
        push!(panels, p)
    end
    body = plot(panels...; layout = (1, 2))
    entries = vcat([marker_entry(case_name(id); color = style(id)[1], shape = style(id)[2]) for id in ids],
                   [line_entry("1:1 line"; linewidth = 0.8)])
    save_fig(with_legend(body, entries; h_in = 3.4, ncol = 2), "fig_4_5_iec_vs_nema")
end
 
 
# =============================================================================
# 4.4  Monte Carlo
# =============================================================================
 
# Every seed as a dot, with median (bar) and interquartile range (thick line)
function fig_mc_strip()
    d = load_mc()
    d === nothing && return
    ids = present_cases(d)
    rng = MersenneTwister(1)
    p = plot(; ylabel = "P95 VUF at worst bus (%)", legend = false,
             xticks = (1:length(ids), [CASE_BY_ID[i].label for i in ids]), xrotation = 30,
             xlims = (0.4, length(ids) + 0.6), size = figsize(TEXT_WIDTH_IN, 3.0))
    for (x, id) in enumerate(ids)
        y = d.p95_iec[d.case .== id]
        xs = x .+ 0.3 .* (rand(rng, length(y)) .- 0.5)
        scatter!(p, xs, y; color = case_colour(id), markersize = 2, markerstrokewidth = 0, alpha = 0.55)
        q1, q2, q3 = quantile(y, [0.25, 0.5, 0.75])
        plot!(p, [x, x], [q1, q3]; color = :black, linewidth = 3)
        plot!(p, [x - 0.22, x + 0.22], [q2, q2]; color = :black, linewidth = 1.5)
    end
    hline!(p, [2.0]; color = :black, linestyle = :dash, linewidth = 0.8)
    save_fig(p, "fig_4_4a_mc_spread")
end
 
# Share of seeds meeting the 2% VUF limit, and meeting BOTH the VUF limit and
# the AS 61000.3.100 voltage limits, with 95% Wilson intervals
function fig_mc_compliance()
    d = load_mc()
    d === nothing && return
    ids = present_cases(d)
    stats = Dict{Symbol, Any}()
    for (key, test) in ((:vuf, r -> Bool(r.vuf_compliant)),
                        (:both, r -> Bool(r.vuf_compliant) && Bool(r.voltage_compliant)))
        rate = Float64[]; lo = Float64[]; hi = Float64[]
        for id in ids
            s = d[d.case .== id, :]
            k, n = count(test, eachrow(s)), nrow(s)
            l, h = wilson(k, n)
            push!(rate, k / n); push!(lo, l); push!(hi, h)
        end
        stats[key] = (rate = rate, lo = lo, hi = hi)
    end
 
    x = 1:length(ids)
    p = bar(x .- 0.2, 100 .* stats[:vuf].rate; bar_width = 0.4,
            color = [case_colour(i) for i in ids], linecolor = :match)
    bar!(p, x .+ 0.2, 100 .* stats[:both].rate; bar_width = 0.4, color = :grey70, linecolor = :match)
    for (dx, key) in ((-0.2, :vuf), (0.2, :both))
        st = stats[key]
        scatter!(p, x .+ dx, 100 .* st.rate; yerror = (100 .* (st.rate .- st.lo), 100 .* (st.hi .- st.rate)),
                 markersize = 0, color = :black, markerstrokecolor = :black)
    end
    plot!(p; ylabel = "Seeds passing (%)", ylims = (0, 105),
          xticks = (x, [CASE_BY_ID[i].label for i in ids]), xrotation = 30)
    entries = [patch_entry("Meets 2% VUF limit (case colour)"; color = :grey35),
               patch_entry("Meets VUF and voltage limits"; color = :grey70),
               line_entry("95% Wilson interval"; linewidth = 0.8)]
    save_fig(with_legend(p, entries; h_in = 3.2), "fig_4_4b_mc_compliance")
end
 
# Seed-by-seed: Volt-Var (x) vs NSC (y). Below the diagonal = NSC better.
function fig_mc_paired()
    d = load_mc()
    d === nothing && return
    pair_list = []
    allv = Float64[]
    for pl in PLACEMENTS
        vv = d[d.case .== statcom_case_id(pl.n, :voltvar), [:seed, :p95_iec]]
        ns = d[d.case .== statcom_case_id(pl.n, :nsc), [:seed, :p95_iec]]
        j = innerjoin(vv, ns; on = :seed, makeunique = true)
        nrow(j) == 0 && continue
        append!(allv, j.p95_iec, j.p95_iec_1)
        push!(pair_list, (pl, j))
    end
    isempty(pair_list) && return
    lim = (0.0, 1.05 * maximum(allv))
    panels = []
    for (k, (pl, j)) in enumerate(pair_list)
        p = scatter(j.p95_iec, j.p95_iec_1; color = PLACEMENT_COLOUR[pl.n], markersize = 2.5,
                    markerstrokewidth = 0, alpha = 0.7, legend = false, title = pl.name,
                    xlims = lim, ylims = lim, aspect_ratio = :equal,
                    xlabel = "Volt-Var P95 VUF (%)", ylabel = k == 1 ? "NSC P95 VUF (%)" : "")
        plot!(p, [lim...], [lim...]; color = :black, linewidth = 0.8)
        hline!(p, [2.0]; color = :black, linestyle = :dot, linewidth = 0.8)
        vline!(p, [2.0]; color = :black, linestyle = :dot, linewidth = 0.8)
        push!(panels, p)
    end
    p = plot(panels...; layout = (1, length(panels)), size = figsize(TEXT_WIDTH_IN, 2.5))
    save_fig(p, "fig_4_4c_mc_paired")
end
 
# Running pass rate and running mean as seeds are added (appendix)
function fig_mc_convergence()
    d = load_mc()
    d === nothing && return
    ids = present_cases(d)
    nmax = maximum(count(==(id), d.case) for id in ids)
    step = nmax <= 10 ? 1 : nmax <= 50 ? 10 : 20
    ticks = step == 1 ? (1:nmax) : (0:step:nmax)
    p1 = plot(; xlabel = "Number of seeds", ylabel = "Pass rate (%)", ylims = (0, 105),
              xticks = ticks, xlims = (1, max(nmax, 2)))
    p2 = plot(; xlabel = "Number of seeds", ylabel = "Mean P95 VUF (%)",
              xticks = ticks, xlims = (1, max(nmax, 2)))
    for id in ids
        s = sort(d[d.case .== id, :], :seed)
        n = 1:nrow(s)
        plot!(p1, n, 100 .* cumsum(Bool.(s.vuf_compliant)) ./ n; color = case_colour(id), linestyle = case_style(id))
        plot!(p2, n, cumsum(s.p95_iec) ./ n; color = case_colour(id), linestyle = case_style(id))
    end
    body = plot(p1, p2; layout = (1, 2))
    entries = [line_entry(CASE_BY_ID[id].label; color = case_colour(id), linestyle = case_style(id)) for id in ids]
    save_fig(with_legend(body, entries; h_in = 3.0, ncol = 4), "fig_A_mc_convergence")
end
 
 
# How often each bus is the worst bus across the Monte Carlo seeds
function fig_mc_worst_bus()
    d = load_mc()
    d === nothing && return
    ids = present_cases(d)
    nb = length(BUS_ORDER)
    bi = Dict(b => i for (i, b) in enumerate(BUS_ORDER))
    F = zeros(nb, length(ids))
    for (j, id) in enumerate(ids)
        wb = string.(d.worst_bus[d.case .== id])
        for b in wb
            haskey(bi, b) && (F[bi[b], j] += 1)
        end
        F[:, j] .*= 100 / max(length(wb), 1)
    end
    grad = cgrad([RGB(1, 1, 1), OI.blue])
    p = heatmap(1:length(ids), 1:nb, F; color = grad, clims = (0, 100), colorbar = false,
                xticks = (1:length(ids), [CASE_BY_ID[i].label for i in ids]), xrotation = 30,
                yticks = (1:nb, BUS_SHORT), yflip = true)
    for j in eachindex(ids), i in 1:nb
        F[i, j] < 0.5 && continue
        annotate!(p, j, i, text(string(round(Int, F[i, j])), 6, F[i, j] > 60 ? :white : :black))
    end
    key = colour_key(grad, (0, 100); label = "Seeds where bus is worst (%)")
    save_fig(heatmaps_with_key([p], key; h_in = 4.2, key_frac = 0.1), "fig_4_4d_mc_worst_bus")
end
 
# |V0|, |V2| and neutral-to-earth voltage over the day at the worst bus,
# without a STATCOM and with the best NSC case
function fig_neutral_shift(nsc_case::Symbol = :case5_nsc)
    fs = base_csv(:case2, "feeder_summary.csv")
    fs === nothing && return
    bus = string(fs.worst_bus[1])
    panels = []
    for (k, id) in enumerate((:case2, nsc_case))
        d = base_csv(id, "bus_timeseries.csv")
        d === nothing && return
        d = sort(d[d.bus .== bus, :], :hour)
        bi = findfirst(==(bus), BUS_ORDER)
        bus_lab = bi === nothing ? bus : BUS_SHORT[bi]
        p = plot(; title = case_name(id), xlabel = time_label(),
                 ylabel = k == 1 ? "Voltage at $(bus_lab) (V)" : "", time_ticks()...)
        shade_periods!(p)
        plot!(p, tx(d.hour), d.v0; color = OI.sky)
        plot!(p, tx(d.hour), d.v2; color = OI.vermillion)
        plot!(p, tx(d.hour), d.vn; color = :black, linestyle = :dash, linewidth = 0.9)
        push!(panels, p)
    end
    body = plot(panels...; layout = (1, 2), link = :y)
    entries = vcat([line_entry("Zero sequence |V0|"; color = OI.sky),
                    line_entry("Negative sequence |V2|"; color = OI.vermillion),
                    line_entry("Neutral-to-earth |Vn|"; linestyle = :dash, linewidth = 0.9)], shade_entries())
    save_fig(with_legend(body, entries; h_in = 3.0, ncol = 3), "fig_4_2b_neutral_shift")
end
 
# Inverter interaction check: worst-bus P95 VUF with AS/NZS 4777.2 PV vs PV
# held at unity power factor (needs RUN_DIAGNOSTIC = true in run.jl)
function fig_pv_interaction()
    d = load_csv(joinpath(OUT_DIR, "diagnostic_pv_interaction.csv"))
    d === nothing && return
    d.case = Symbol.(string.(d.case))
    d.pv_mode = string.(d.pv_mode)
    ids = [c.id for c in CASES if any(d.case .== c.id)]
    function worst(id, mode)
        v = d.p95_iec[(d.case .== id) .& (d.pv_mode .== mode)]
        return isempty(v) ? NaN : maximum(v)
    end
    smart = [worst(id, "smart") for id in ids]
    unity = [worst(id, "smart_unity") for id in ids]
    x = 1:length(ids)
    p = bar(x .- 0.2, smart; bar_width = 0.4, color = [case_colour(i) for i in ids], linecolor = :match)
    bar!(p, x .+ 0.2, unity; bar_width = 0.4, color = :grey70, linecolor = :match)
    hline!(p, [2.0]; color = :black, linestyle = :dash, linewidth = 0.8)
    plot!(p; ylabel = "P95 VUF at worst bus (%)",
          xticks = (x, [CASE_BY_ID[i].label for i in ids]), xrotation = 30)
    entries = [patch_entry("AS/NZS 4777.2 PV (case colour)"; color = :grey35),
               patch_entry("PV at unity power factor"; color = :grey70),
               line_entry("2% limit"; linestyle = :dash, linewidth = 0.8)]
    save_fig(with_legend(p, entries; h_in = 3.2, ncol = 3), "fig_4_5c_pv_interaction")
end
 
 
# =============================================================================
# Full-year screen (seed 42): weekly compliance for every case across 2019
# =============================================================================
function fig_year_screen()
    y = load_csv(joinpath(OUT_DIR, "year_screen", "year_weekly.csv"))
    y === nothing && return
    y.case = Symbol.(string.(y.case))
    win = isfile(joinpath(OUT_DIR, "assessment_window.csv")) ?
          load_csv(joinpath(OUT_DIR, "assessment_window.csv")) : nothing
    chosen_week = win === nothing ? nothing : win.week[1]
 
    p1 = plot(; ylabel = "Weekly P95 VUF,\nworst bus (%)", xlims = (0.5, 52.5), xticks = 0:4:52)
    p2 = plot(; ylabel = "Loads meeting\n99% band (of 25)", xlabel = "Week of 2019",
              xlims = (0.5, 52.5), xticks = 0:4:52, ylims = (0, 26))
    shown = Symbol[]
    for c in CASES
        d = sort(y[y.case .== c.id, :], :week)
        nrow(d) == 0 && continue
        push!(shown, c.id)
        plot!(p1, d.week, d.p95_iec; color = case_colour(c.id), linestyle = case_style(c.id))
        plot!(p2, d.week, d.n_pass_99; color = case_colour(c.id), linestyle = case_style(c.id))
    end
    hline!(p1, [2.0]; color = :black, linestyle = :dash, linewidth = 0.8)
    entries = Any[line_entry(CASE_BY_ID[id].label; color = case_colour(id), linestyle = case_style(id)) for id in shown]
    push!(entries, line_entry("2% limit"; linestyle = :dash, linewidth = 0.8))
    if chosen_week !== nothing
        vline!(p1, [chosen_week]; color = :black, linestyle = :dot, linewidth = 0.8)
        vline!(p2, [chosen_week]; color = :black, linestyle = :dot, linewidth = 0.8)
        push!(entries, line_entry("Assessment week"; linestyle = :dot, linewidth = 0.8))
    end
    body = plot(p1, p2; layout = (2, 1), link = :x)
    save_fig(with_legend(body, entries; h_in = 5.2, ncol = 4), "fig_4_0_year_screen")
end
 
# Transformer tap choice (appendix): Case 2 at each standard tap position
function fig_tap_selection()
    t = isfile(joinpath(OUT_DIR, "tap_selection", "tap_weekly.csv")) ?
        load_csv(joinpath(OUT_DIR, "tap_selection", "tap_weekly.csv")) : nothing
    t === nothing && return
    ch = isfile(joinpath(OUT_DIR, "tap_choice.csv")) ? load_csv(joinpath(OUT_DIR, "tap_choice.csv")) : nothing
    taps = sort(unique(t.tap))
    cols = [OI.vermillion, OI.green, OI.blue, OI.orange, OI.pink]
    p1 = plot(; ylabel = "Loads meeting\n99% band (of 25)", xlims = (0.5, 52.5), xticks = 0:4:52, ylims = (0, 26))
    p2 = plot(; ylabel = "Weekly customer\nvoltage range (V)", xlabel = "Week of 2019",
              xlims = (0.5, 52.5), xticks = 0:4:52)
    entries = []
    for (k, tp) in enumerate(taps)
        d = sort(t[t.tap .== tp, :], :week)
        chosen = ch !== nothing && ch.tap[1] ≈ tp
        lw = chosen ? 1.8 : 1.0
        plot!(p1, d.week, d.n_pass_99; color = cols[mod1(k, 5)], linewidth = lw)
        plot!(p2, d.week, d.min_v; color = cols[mod1(k, 5)], linewidth = lw)
        plot!(p2, d.week, d.max_v; color = cols[mod1(k, 5)], linewidth = lw, linestyle = :dash)
        lab = "Tap $(round((tp - 1) * 100; digits = 1))%" * (chosen ? " (chosen)" : "")
        push!(entries, line_entry(lab; color = cols[mod1(k, 5)], linewidth = lw))
    end
    hline!(p2, [216, 253]; color = :black, linestyle = :dot, linewidth = 0.8)
    push!(entries, line_entry("Weekly min (solid) / max (dashed)"; color = :grey40, linewidth = 0.8))
    push!(entries, line_entry("216 / 253 V"; linestyle = :dot, linewidth = 0.8))
    body = plot(p1, p2; layout = (2, 1), link = :x)
    save_fig(with_legend(body, entries; h_in = 4.8, ncol = 3), "fig_A_tap_selection")
end
 
 
# =============================================================================
# Voltage regulation: what each control law does to the customer voltage band
# (the thing Volt-Var is designed to regulate), one panel per placement
# =============================================================================
function voltage_band(id::Symbol)
    d = base_csv(id, "customer_voltage_timeseries.csv")
    d === nothing && return nothing
    return sort(combine(groupby(d, :hour), :v_pn => minimum => :lo, :v_pn => maximum => :hi), :hour)
end
 
function fig_voltage_regulation()
    # Voltage duration curves: every customer voltage (all loads, all 5-min
    # steps) sorted from highest to lowest. The share of the curve outside
    # 216-253 V is exactly what the 99% compliance test looks at.
    function duration(id)
        d = base_csv(id, "customer_voltage_timeseries.csv")
        d === nothing && return nothing
        pct = collect(0:0.1:100)
        return pct, quantile(d.v_pn, 1 .- pct ./ 100)
    end
    base = duration(:case2)
    base === nothing && return
    panels = []
    for (k, pl) in enumerate(PLACEMENTS)
        vv = duration(statcom_case_id(pl.n, :voltvar))
        ns = duration(statcom_case_id(pl.n, :nsc))
        (vv === nothing || ns === nothing) && return
        col = PLACEMENT_COLOUR[pl.n]
        p = plot(base...; color = :black, linewidth = 1.0, linestyle = :dashdot, title = pl.name,
                 xlabel = "Share of customer-time (%)", ylabel = k == 1 ? "Customer voltage (V)" : "",
                 xlims = (0, 100), xticks = 0:25:100)
        plot!(p, vv...; color = col, linestyle = :dash)
        plot!(p, ns...; color = col)
        hline!(p, [216, 253]; color = :black, linestyle = :dot, linewidth = 0.8)
        vspan!(p, [0, 1]; color = :grey85, alpha = 0.5)
        vspan!(p, [99, 100]; color = :grey85, alpha = 0.5)
        push!(panels, p)
    end
    body = plot(panels...; layout = (1, length(panels)), link = :y)
    entries = [line_entry("No STATCOM (Case 2)"; color = :black, linewidth = 1.0, linestyle = :dashdot),
               line_entry("Volt-Var"; linestyle = :dash),
               line_entry("NSC"),
               line_entry("216 / 253 V"; linestyle = :dot, linewidth = 0.8),
               patch_entry("Top/bottom 1%"; color = :grey85, alpha = 0.8)]
    save_fig(with_legend(body, entries; h_in = 3.5, ncol = 3), "fig_4_3e_voltage_regulation")
end
 
 
# =============================================================================
# Verification figures: one full set per case, for checking the data and for
# the appendix. Saved to outputs/figures/verification/<case>/.
# =============================================================================
function branch_colour(bus::AbstractString)
    startswith(bus, "North") && return OI.orange
    startswith(bus, "West")  && return OI.green
    startswith(bus, "East")  && return OI.pink
    return OI.blue                                # transformer and trunk
end
 
branch_entries() = Any[line_entry(nm; color = c) for (nm, c) in
                    (("Trunk", OI.blue), ("North spine", OI.orange), ("West branch", OI.green), ("East branch", OI.pink))]
 
function save_to(p, dir::AbstractString, name::AbstractString)
    path = joinpath(dir, name * ".pdf")
    savefig(p, path)
    println("  saved $path")
end
 
function fig_verification(id::Symbol)
    dir = joinpath(FIG_DIR, "verification", String(id))
    mkpath(dir)
    title = case_name(id)
 
    # 1-3. Unbalance at every bus over the day (IEC, NEMA, PVUR), coloured by branch.
    # The 2% limit applies to IEC VUF (and NEMA, which tracks it), not to PVUR.
    bt = base_csv(id, "bus_timeseries.csv")
    if bt !== nothing
        for (col, ylab, fname) in ((:vuf_iec,  "VUF, IEC (%)",                       "vuf_iec_all_buses"),
                                   (:vuf_nema, "Unbalance, NEMA line-to-line (%)",   "vuf_nema_all_buses"),
                                   (:vuf_pvur, "Phase voltage unbalance, PVUR (%)",  "vuf_pvur_all_buses"))
            p = plot(; title = title, xlabel = time_label(), ylabel = ylab, time_ticks()...)
            for b in BUS_ORDER
                d = bt[bt.bus .== b, :]
                nrow(d) == 0 && continue
                plot!(p, tx(d.hour), d[!, col]; color = branch_colour(b), alpha = 0.75, linewidth = 0.8)
            end
            entries = branch_entries()
            if col != :vuf_pvur
                hline!(p, [2.0]; color = :black, linestyle = :dash, linewidth = 0.8)
                push!(entries, line_entry("2% limit"; linestyle = :dash, linewidth = 0.8))
            end
            save_to(with_legend(p, entries; h_in = 3.1), dir, fname)
        end
    end
 
    # 4. Distribution of VUF at each bus as a box-and-whisker plot.
    #    Box = 25th-75th percentile of the 10-minute IEC VUF, line = median,
    #    whiskers = 5th-95th percentile (so the top whisker is the P95 that is
    #    assessed against the 2% limit), dot = peak 5-minute value, diamond = P95
    #    of the NEMA line-to-line measure. Boxes are coloured by branch.
    if bt !== nothing
        agg10(x) = (n = length(x) ÷ 2; [sqrt((x[2i-1]^2 + x[2i]^2) / 2) for i in 1:n])
        x = 1:length(BUS_ORDER)
        w = 0.32
        p = plot(; title = "VUF at each bus, $(CASE_BY_ID[id].label)", ylabel = "VUF (%)",
                 xticks = (x, BUS_SHORT), xrotation = 90, tickfontsize = 7,
                 xlims = (0.3, length(BUS_ORDER) + 0.7), ylims = (0, Inf), legend = false)
        hline!(p, [2.0]; color = :black, linestyle = :dash, linewidth = 0.8)
        for (i, b) in enumerate(BUS_ORDER)
            d = sort(bt[bt.bus .== b, :], :timestep)
            nrow(d) == 0 && continue
            iec  = agg10(d.vuf_iec)
            nema = agg10(d.vuf_nema)
            q05, q25, q50, q75, q95 = quantile(iec, [0.05, 0.25, 0.50, 0.75, 0.95])
            c = branch_colour(b)
            plot!(p, [i, i], [q05, q25]; color = :black, linewidth = 0.8)            # lower whisker
            plot!(p, [i, i], [q75, q95]; color = :black, linewidth = 0.8)            # upper whisker
            plot!(p, [i - w/2, i + w/2], [q05, q05]; color = :black, linewidth = 0.8) # caps
            plot!(p, [i - w/2, i + w/2], [q95, q95]; color = :black, linewidth = 0.8)
            plot!(p, Shape([i - w, i + w, i + w, i - w], [q25, q25, q75, q75]);
                  fillcolor = c, fillalpha = 0.6, linecolor = :black, linewidth = 0.6)
            plot!(p, [i - w, i + w], [q50, q50]; color = :black, linewidth = 1.2)    # median
            scatter!(p, [i], [maximum(d.vuf_iec)]; color = :black, markersize = 2.5,
                     markerstrokewidth = 0)                                           # peak (5-min)
            scatter!(p, [i + w + 0.12], [quantile(nema, 0.95)]; color = OI.vermillion,
                     markershape = :diamond, markersize = 3, markerstrokewidth = 0)  # NEMA P95
        end
        entries = vcat(Any[patch_entry(nm; color = c, alpha = 0.6) for (nm, c) in
                           (("Trunk", OI.blue), ("North spine", OI.orange), ("West branch", OI.green), ("East branch", OI.pink))],
                       [line_entry("5th-95th percentile"; linewidth = 0.8),
                        marker_entry("Peak"; color = :black),
                        marker_entry("NEMA P95"; color = OI.vermillion, shape = :diamond),
                        line_entry("2% limit"; linestyle = :dash, linewidth = 0.8)])
        save_to(with_legend(p, entries; h_in = 3.4, ncol = 4), dir, "vuf_per_bus")
    end
 
    # 5. Customer voltage at every load over the day
    cv = base_csv(id, "customer_voltage_timeseries.csv")
    if cv !== nothing
        p = plot(; title = title, xlabel = time_label(), ylabel = "Customer voltage (V)", time_ticks()...)
        for ld in unique(cv.load)
            d = cv[cv.load .== ld, :]
            plot!(p, tx(d.hour), d.v_pn; color = case_colour(id), alpha = 0.45, linewidth = 0.7)
        end
        hline!(p, [216, 253]; color = :black, linestyle = :dash, linewidth = 0.8)
        hline!(p, [225, 244]; color = :black, linestyle = :dot,  linewidth = 0.8)
        entries = [line_entry("Each load"; color = case_colour(id), linewidth = 0.7),
                   line_entry("216-253 V (99% band)"; linestyle = :dash, linewidth = 0.8),
                   line_entry("225-244 V (50% band)"; linestyle = :dot, linewidth = 0.8)]
        save_to(with_legend(p, entries; h_in = 3.1), dir, "customer_voltage_all_loads")
    end
 
    # 6. Voltage compliance per load against both AS 61000.3.100 bands
    cc = base_csv(id, "customer_compliance.csv")
    if cc !== nothing
        x = 1:nrow(cc)
        p = bar(x .- 0.2, 100 .* cc.frac_225_244; bar_width = 0.4, color = OI.sky, linecolor = :match)
        bar!(p, x .+ 0.2, 100 .* cc.frac_216_253; bar_width = 0.4, color = OI.blue, linecolor = :match)
        hline!(p, [50, 99]; color = :black, linestyle = :dash, linewidth = 0.8)
        plot!(p; title = title, xticks = (x, cc.load), xrotation = 45, ylims = (0, 105),
              ylabel = "Time within band (%)")
        entries = [patch_entry("Time in 225-244 V (need >= 50%)"; color = OI.sky),
                   patch_entry("Time in 216-253 V (need >= 99%)"; color = OI.blue),
                   line_entry("50% and 99% requirements"; linestyle = :dash, linewidth = 0.8)]
        save_to(with_legend(p, entries; h_in = 3.3, ncol = 2), dir, "voltage_compliance_per_load")
    end
 
    # 7. Per-phase transformer power
    t = base_csv(id, "transformer_power.csv")
    if t !== nothing
        p = plot(tx(t.hour), t.p_total; color = :black, linewidth = 1.6, title = title,
                 xlabel = time_label(), ylabel = "Active power (kW, +ve import)", time_ticks()...)
        for (k, col) in enumerate((:p_a, :p_b, :p_c))
            plot!(p, tx(t.hour), t[!, col]; color = PHASE_COLOUR[k])
        end
        hline!(p, [0.0]; color = :grey, linewidth = 0.6)
        save_to(with_legend(p, transformer_entries(); h_in = 2.9), dir, "transformer_power")
    end
 
    # 8. PV self-consumption per slot
    sc = base_csv(id, "self_consumption.csv")
    if sc !== nothing
        p = bar(1:nrow(sc), sc.self_consumption_pct; color = OI.orange, linecolor = :match, legend = false,
                title = title, xticks = (1:nrow(sc), sc.load_name), xrotation = 45, ylims = (0, 100),
                ylabel = "PV used locally (%)", size = figsize(TEXT_WIDTH_IN, 2.6))
        save_to(p, dir, "self_consumption_per_slot")
    end
 
    # 9. STATCOM reactive output (STATCOM cases only)
    q = isfile(joinpath(BASE_DIR, String(id), "statcom_q.csv")) ? base_csv(id, "statcom_q.csv") : nothing
    if q !== nothing
        p = plot(; title = title, xlabel = time_label(), ylabel = "Reactive power (kvar, +ve injecting)",
                 time_ticks()...)
        units = unique(q.unit)
        for u in units
            d = q[q.unit .== u, :]
            plot!(p, tx(d.hour), d.q_kvar; color = PHASE_COLOUR[unit_phase(u)])
        end
        hline!(p, [0.0]; color = :black, linewidth = 0.5)
        entries = [line_entry(unit_label(u); color = PHASE_COLOUR[unit_phase(u)]) for u in units]
        save_to(with_legend(p, entries; h_in = 2.9), dir, "statcom_q")
    end
end
 
 
# =============================================================================
# Make everything
# =============================================================================
function make_all_figures()
    println("Making figures in $FIG_DIR")
    detect_days()
    println("  time axis: $(N_DAYS_PLOT) day(s)")
    fig_voltage_envelope_pv()
    fig_vuf_timeseries_pv()
    fig_vuf_heatmap_pv()
    fig_transformer_power_pv()
    fig_sequence_components()
    fig_statcom_grid_vuf()
    fig_statcom_grid_q()
    fig_delta_vuf_heatmap()
    fig_min_voltage()
    fig_iec_vs_nema()
    fig_mc_strip()
    fig_mc_compliance()
    fig_mc_paired()
    fig_mc_convergence()
    fig_mc_worst_bus()
    fig_neutral_shift()
    fig_pv_interaction()
    fig_year_screen()
    fig_tap_selection()
    fig_voltage_regulation()
    for c in CASES
        fig_verification(c.id)
    end
    println("Done.")
end
 
make_all_figures()
 