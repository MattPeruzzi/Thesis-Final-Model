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
# Phasor figures for the theory and the worked operating point.
#     include("plot_phasors.jl")      (after run.jl has finished)
#
# 1. fig_2_sequence_example.pdf
#    An illustrative unbalanced set of phase voltages split into its positive,
#    negative and zero sequence sets (exaggerated so every set is visible).
#
# 2. fig_4_worked_point.pdf + worked_point.csv
#    One real operating point at WORK_BUS: Case 2 against COMPARE_CASE at the
#    timestep where Case 2's negative sequence voltage at that bus is largest.
#    Rows are cases; columns are the phase-to-neutral voltages and their three
#    sequence sets. The CSV holds the numbers quoted in the text: sequence
#    magnitudes, VUF, neutral-to-earth voltage, neutral current, STATCOM kvar,
#    and the sequence currents injected by the STATCOM units (if they all sit
#    at one bus, as in Case 4).
#
# Uses only the base-run outputs in outputs/base/<case>/, nothing is rerun.
# -----------------------------------------------------------------------------

cd(@__DIR__)
using CSV, DataFrames, Plots, Printf, Dates
gr()

# ------------------------------ Settings -------------------------------------
WORK_BUS     = "East_North_End"   # bus where the before/after phasors are drawn
COMPARE_CASE = "case4_nsc"        # STATCOM case compared against Case 2
STATCOM_BUS  = "FN_Trunk"         # where COMPARE_CASE's units sit (for the current check)
TIMESTEP     = nothing            # set an Int to choose the timestep by hand
BASE_DIR     = joinpath("outputs", "base")
FIG_DIR      = joinpath("outputs", "figures")
STEP_MIN     = 5
# ------------------------------------------------------------------------------

mkpath(FIG_DIR)
const A = cis(2π / 3)

default(fontfamily = "Computer Modern", titlefontsize = 9, guidefontsize = 8,
        tickfontsize = 7, legendfontsize = 7, framestyle = :box, grid = true,
        gridalpha = 0.2, linewidth = 1.4,
        foreground_color_legend = nothing, background_color_legend = nothing)
PHASE_COLOUR = [RGB(0.84, 0.37, 0.00), RGB(0.00, 0.62, 0.45), RGB(0.00, 0.45, 0.70)]
figsize(w, h) = (round(Int, 100w), round(Int, 100h))

# Sequence components of a set of three phasors (phase a reference)
seq012(va, vb, vc) = ((va + vb + vc) / 3,
                      (va + A * vb + A^2 * vc) / 3,
                      (va + A^2 * vb + A * vc) / 3)

# The three phasors (a, b, c) that make up each sequence set
pos_set(v1)  = [v1, A^2 * v1, A * v1]
neg_set(v2)  = [v2, A * v2, A^2 * v2]
zero_set(v0) = [v0, v0, v0]

# ------------------------------ Drawing ---------------------------------------
lab(txt, c; sz = 7) = text(txt, font("Computer Modern", sz, c))

# Three ticks per axis (-t, 0, t) at a round number, so labels never collide
function nice_ticks(r)
    m = 10.0^floor(log10(0.8r))
    t = floor(0.8r / m) * m
    return [-t, 0.0, t]
end

function phasor_panel(vs; title = "", lim = nothing, labels = ["a", "b", "c"], unit = "V",
                      overlap = false)
    r = lim === nothing ? 1.3 * maximum(abs.(vs)) : lim
    r = r > 0 ? r : 1.0
    tk = nice_ticks(r)
    p = plot(; aspect_ratio = :equal, xlims = (-r, r), ylims = (-r, r), title = title,
             titlefontsize = 8, legend = false, xticks = tk, yticks = tk,
             xlabel = "Re ($unit)", ylabel = "Im ($unit)")
    hline!(p, [0]; color = :grey70, linewidth = 0.5)
    vline!(p, [0]; color = :grey70, linewidth = 0.5)
    for (k, v) in enumerate(vs)
        abs(v) < 1e-3 * r && continue                 # skip zero-length phasors
        plot!(p, [0, real(v)], [0, imag(v)]; color = PHASE_COLOUR[k], arrow = true,
              linewidth = overlap ? 2.6 - 0.7k : 1.6)
        overlap && k > 1 && continue
        txt = overlap ? "a, b, c" : labels[k]
        u = v / abs(v)
        annotate!(p, real(v + 0.16r * u), imag(v + 0.16r * u), lab(txt, PHASE_COLOUR[k]))
    end
    return p
end

# Rotate everything so the positive sequence of phase a sits on the real axis
rotate(v1) = abs(v1) > 0 ? conj(v1) / abs(v1) : 1.0 + 0im


# ========================================================================
# 1. Illustrative example (per unit, exaggerated)
# ========================================================================
let
    va = 1.00 * cis(deg2rad(0))
    vb = 0.80 * cis(deg2rad(-128))
    vc = 1.08 * cis(deg2rad(112))
    v0, v1, v2 = seq012(va, vb, vc)

    panels = [
        phasor_panel([va, vb, vc]; title = "Phase voltages", unit = "pu"),
        phasor_panel(pos_set(v1); title = @sprintf("Positive (%.2f pu)", abs(v1)), unit = "pu"),
        phasor_panel(neg_set(v2); title = @sprintf("Negative (%.2f pu)", abs(v2)), unit = "pu"),
        phasor_panel(zero_set(v0); title = @sprintf("Zero (%.2f pu)", abs(v0)), unit = "pu",
                     overlap = true),
    ]
    p = plot(panels...; layout = (1, 4), size = figsize(6.3, 1.9),
             left_margin = 2Plots.mm, bottom_margin = 3Plots.mm)
    savefig(p, joinpath(FIG_DIR, "fig_2_sequence_example.pdf"))
    @printf("Example: |V0| = %.3f, |V1| = %.3f, |V2| = %.3f pu, VUF = %.1f%%\n",
            abs(v0), abs(v1), abs(v2), 100abs(v2) / abs(v1))
    println("  saved ", joinpath(FIG_DIR, "fig_2_sequence_example.pdf"))
end


# Arrow from z0 to z1 with an optional label at its tip
function arrow!(p, z0, z1; color = :black, label = "", lw = 1.6, ls = :solid, offset = 0.0 + 0.0im)
    plot!(p, [real(z0), real(z1)], [imag(z0), imag(z1)]; color = color, arrow = true,
          linewidth = lw, linestyle = ls)
    isempty(label) || annotate!(p, real(z1 + offset), imag(z1 + offset), lab(label, color; sz = 8))
    return p
end


# ========================================================================
# 1b. How a STATCOM exchanges reactive power (per unit, exaggerated)
#     V_grid = V_conv + jX I, with I the current drawn from the grid.
#     V_conv > V_grid: I leads V_grid (capacitive, injects Q).
#     V_conv < V_grid: I lags V_grid (inductive, absorbs Q).
# ========================================================================
let
    X = 0.25
    panels = Any[]
    for (vc, name) in ((1.25, "Capacitive (Vconv > Vgrid)"), (0.75, "Inductive (Vconv < Vgrid)"))
        vg = 1.0 + 0im
        vconv = vc + 0im
        i = (vg - vconv) / (im * X)                 # current drawn from the grid
        p = plot(; aspect_ratio = :equal, xlims = (-0.4, 1.6), ylims = (-1.25, 1.25), title = name,
                 titlefontsize = 9, legend = false, xlabel = "Re (pu)", ylabel = "Im (pu)",
                 xticks = [0, 0.5, 1.0, 1.5], yticks = [-1, 0, 1])
        hline!(p, [0]; color = :grey70, linewidth = 0.5)
        vline!(p, [0]; color = :grey70, linewidth = 0.5)
        # V_conv drawn slightly above the axis and V_grid slightly below, so both show
        arrow!(p, 0.06im, vconv + 0.06im; color = RGB(0.00, 0.45, 0.70), lw = 2.0, label = "Vconv",
               offset = 0.0 + 0.16im)
        arrow!(p, -0.06im, vg - 0.06im; color = :black, lw = 1.6, label = "Vgrid",
               offset = 0.0 - 0.18im)
        arrow!(p, 0, i; color = RGB(0.84, 0.37, 0.00), lw = 2.0, label = "I",
               offset = 0.12 + 0.0im)
        push!(panels, p)
    end
    p = plot(panels...; layout = (1, 2), size = figsize(6.3, 2.6),
             left_margin = 3Plots.mm, bottom_margin = 3Plots.mm)
    savefig(p, joinpath(FIG_DIR, "fig_2_statcom_phasor.pdf"))
    println("  saved ", joinpath(FIG_DIR, "fig_2_statcom_phasor.pdf"))
end


# ========================================================================
# 1c. Sequence currents from single-phase reactive injection
#     Row 1: one unit on phase a only.  Row 2: three units with different kvar.
#     Balanced 230 V phase-to-neutral voltages; I = conj(jQ / V) delivered.
# ========================================================================
let
    V = 230.0
    vph = [V, V * A^2, V * A]                         # Va, Vb, Vc (a-b-c sequence)
    current(q) = [conj(im * 1e3 * q[k] / vph[k]) for k in 1:3]
    rows = (([25.0, 0.0, 0.0], "One unit: 25 kvar on a"),
            ([20.0, -10.0, 5.0], "Three units: 20, -10, 5 kvar"))
    lim = 1.3 * maximum(maximum(abs.(current(q))) for (q, _) in rows)
    slim = 1.4 * maximum(maximum(abs.(seq012(current(q)...))) for (q, _) in rows)
    panels = Any[]
    for (q, name) in rows
        I = current(q)
        i0, i1, i2 = seq012(I...)
        @printf("%s: |I0| = %.1f A, |I1| = %.1f A, |I2| = %.1f A\n", name, abs(i0), abs(i1), abs(i2))
        push!(panels,
              phasor_panel(I; title = name, lim = lim, unit = "A"),
              phasor_panel(pos_set(i1); title = @sprintf("Positive (%.1f A)", abs(i1)), lim = slim, unit = "A"),
              phasor_panel(neg_set(i2); title = @sprintf("Negative (%.1f A)", abs(i2)), lim = slim, unit = "A"),
              phasor_panel(zero_set(i0); title = @sprintf("Zero (%.1f A)", abs(i0)), lim = slim, unit = "A",
                           overlap = true))
    end
    p = plot(panels...; layout = (2, 4), size = figsize(6.3, 3.6),
             left_margin = 2Plots.mm, bottom_margin = 2Plots.mm)
    savefig(p, joinpath(FIG_DIR, "fig_3_reactive_sequence.pdf"))
    println("  saved ", joinpath(FIG_DIR, "fig_3_reactive_sequence.pdf"))
end

# The worked point below needs the base-run outputs; skip it if they are missing
if !isfile(joinpath(BASE_DIR, "case2", "raw", "timeseries", "M_VBUS_$(WORK_BUS).csv"))
    @warn "No base-run outputs found, so the worked point (fig_4_worked_point) was skipped."
else


# ========================================================================
# 2. Worked operating point from the simulation
# ========================================================================
# Column lookup that ignores stray spaces in OpenDSS monitor headers
function col(df, name)
    for c in names(df)
        strip(c) == name && return df[!, c]
    end
    error("Column $name not found. Columns are: $(names(df))")
end
phasors(df, m, a) = col(df, m) .* cis.(deg2rad.(col(df, a)))

function bus_data(case, bus)
    f = joinpath(BASE_DIR, case, "raw", "timeseries", "M_VBUS_$(bus).csv")
    isfile(f) || error("Missing $f. Run run.jl with RUN_BASE = true first.")
    df = CSV.read(f, DataFrame)
    (va = phasors(df, "V1", "VAngle1"), vb = phasors(df, "V2", "VAngle2"),
     vc = phasors(df, "V3", "VAngle3"), vn = phasors(df, "V4", "VAngle4"),
     in_ = phasors(df, "I4", "IAngle4"))
end

function time_label(k)
    w = joinpath("outputs", "assessment_window.csv")
    mins = (k - 1) * STEP_MIN
    if isfile(w)
        sd = Int(CSV.read(w, DataFrame).start_day[1])
        t = DateTime(2019, 1, 1) + Day(sd - 1) + Minute(mins)
        return Dates.format(t, "d u yyyy, HH:MM")
    end
    return @sprintf("day %d, %02d:%02d", mins ÷ 1440 + 1, (mins % 1440) ÷ 60, mins % 60)
end

let
    cases = ["case2", COMPARE_CASE]
    d = Dict(c => bus_data(c, WORK_BUS) for c in cases)

    # Timestep: where Case 2's negative sequence voltage at WORK_BUS peaks
    c2 = d["case2"]
    v2_c2 = [abs(seq012(c2.va[i] - c2.vn[i], c2.vb[i] - c2.vn[i], c2.vc[i] - c2.vn[i])[3])
             for i in eachindex(c2.va)]
    k = TIMESTEP === nothing ? argmax(v2_c2) : TIMESTEP
    println("\nWorked point: $WORK_BUS, timestep $k ($(time_label(k)))")

    rows = DataFrame()
    sets = Dict{String, Any}()
    for c in cases
        x = d[c]
        van, vbn, vcn = x.va[k] - x.vn[k], x.vb[k] - x.vn[k], x.vc[k] - x.vn[k]
        v0, v1, v2 = seq012(van, vbn, vcn)          # phase-to-neutral sequences
        v0g, _, _  = seq012(x.va[k], x.vb[k], x.vc[k])  # phase-to-earth zero sequence
        r = rotate(v1)
        sets[c] = (ph = r .* [van, vbn, vcn], v0 = r * v0, v1 = r * v1, v2 = r * v2)
        push!(rows, (case = c, V_an = abs(van), V_bn = abs(vbn), V_cn = abs(vcn),
                     V0_pn = abs(v0), V0_pg = abs(v0g), V1 = abs(v1), V2 = abs(v2),
                     VUF_pct = 100abs(v2) / abs(v1), V_ng = abs(x.vn[k]),
                     I_neutral_line = abs(x.in_[k])); promote = true)
    end

    # STATCOM output at this step, and the sequence currents it injects
    qf = joinpath(BASE_DIR, COMPARE_CASE, "statcom_q.csv")
    if isfile(qf)
        q = CSV.read(qf, DataFrame)
        q = q[q.timestep .== k, :]
        println("STATCOM output at this step (kvar, +ve injecting):")
        for r in eachrow(q)
            @printf("  %-28s %7.2f\n", r.unit, r.q_kvar)
        end
        units = [u for u in q.unit if occursin(STATCOM_BUS, u)]
        if length(units) == 3
            s = bus_data(COMPARE_CASE, STATCOM_BUS)
            vpn = [s.va[k] - s.vn[k], s.vb[k] - s.vn[k], s.vc[k] - s.vn[k]]
            qk = [q.q_kvar[q.unit .== "Statcom_$(STATCOM_BUS)_$(ph)"][1] for ph in 1:3]
            # S = V I*  ->  I = conj(jQ / V), current delivered into the network
            I = [conj(im * 1e3 * qk[ph] / vpn[ph]) for ph in 1:3]
            i0, i1, i2 = seq012(I...)
            @printf("Injected at %s: |I0| = %.1f A, |I1| = %.1f A, |I2| = %.1f A, |Ia+Ib+Ic| = %.1f A\n",
                    STATCOM_BUS, abs(i0), abs(i1), abs(i2), abs(sum(I)))
            rows.I0_inj = [missing, abs(i0)]
            rows.I1_inj = [missing, abs(i1)]
            rows.I2_inj = [missing, abs(i2)]
        end
    end
    show(rows; allcols = true); println()
    CSV.write(joinpath(FIG_DIR, "worked_point.csv"), rows)

    # Shared limits per column so the change between rows is visible
    lim_ph = 1.25 * maximum(maximum(abs.(sets[c].ph)) for c in cases)
    lim_v1 = 1.25 * maximum(abs(sets[c].v1) for c in cases)
    lim_v2 = 1.25 * maximum(abs(sets[c].v2) for c in cases)
    lim_v0 = 1.25 * maximum(abs(sets[c].v0) for c in cases)

    name(c) = c == "case2" ? "Case 2" :
              replace(uppercasefirst(c), "_nsc" => " NSC", "_vv" => " Volt-Var", "Case" => "Case ")
    panels = Any[]
    for c in cases
        s = sets[c]
        push!(panels,
              phasor_panel(s.ph; title = "$(name(c))", lim = lim_ph),
              phasor_panel(pos_set(s.v1); title = @sprintf("Positive (%.1f V)", abs(s.v1)), lim = lim_v1),
              phasor_panel(neg_set(s.v2); title = @sprintf("Negative (%.2f V)", abs(s.v2)), lim = lim_v2),
              phasor_panel(zero_set(s.v0); title = @sprintf("Zero (%.2f V)", abs(s.v0)), lim = lim_v0,
                           overlap = true))
    end
    p = plot(panels...; layout = (2, 4), size = figsize(6.3, 3.6),
             left_margin = 2Plots.mm, bottom_margin = 2Plots.mm)
    savefig(p, joinpath(FIG_DIR, "fig_4_worked_point.pdf"))
    println("  saved ", joinpath(FIG_DIR, "fig_4_worked_point.pdf"),
            " and ", joinpath(FIG_DIR, "worked_point.csv"))
end

end   # worked point
