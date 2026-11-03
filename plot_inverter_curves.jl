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

using Plots
gr()

TEXT_WIDTH_IN = 6.3       # LaTeX \textwidth in inches
PX_PER_IN     = 100       # Plots.jl size units per inch
figsize(w_in, h_in) = (round(Int, w_in * PX_PER_IN), round(Int, h_in * PX_PER_IN))

default(fontfamily = "Computer Modern", titlefontsize = 9, guidefontsize = 9,
        tickfontsize = 7, legendfontsize = 7, framestyle = :box, grid = true,
        gridalpha = 0.2, linewidth = 1.6, legend = false,
        left_margin = 3Plots.mm, bottom_margin = 4Plots.mm)

CURVES_DIR = joinpath(@__DIR__, "outputs", "inverter_curves")
mkpath(CURVES_DIR)

V_NOM = 230.0

# ------------------------- Curve definitions (volts) --------------------------
# PV Volt-Watt: 100% up to 253 V, linear to 20% at 260 V
vw_v = [200.0, 253.0, 260.0, 270.0]
vw_p = [1.00, 1.00, 0.20, 0.20]

# PV Volt-Var: +44% at/below 207 V, zero 220-240 V, -60% at/above 258 V
vv_v = [195.0, 207.0, 220.0, 240.0, 258.0, 270.0]
vv_q = [0.44, 0.44, 0.00, 0.00, -0.60, -0.60]

# STATCOM Volt-Var (add_statcom.jl): 0.94 / 0.98 / 1.02 / 1.06 pu, +/-100%
st_pu = [0.90, 0.94, 0.98, 1.02, 1.06, 1.10]
st_v  = st_pu .* V_NOM
st_q  = [1.00, 1.00, 0.00, 0.00, -1.00, -1.00]

deadband!(p, v_lo, v_hi, ylo, yhi) =
    plot!(p, [v_lo, v_hi, v_hi, v_lo], [ylo, ylo, yhi, yhi];
          seriestype = :shape, fillalpha = 0.12, fillcolor = :grey, linealpha = 0, label = "")

# ------------------------- Volt-Watt -------------------------
p_vw = plot(vw_v, vw_p; color = RGB(0.00, 0.45, 0.70),
    title = "(a) PV Volt-Watt", xlabel = "Voltage (V)", ylabel = "P (pu of rated)",
    xlims = (225, 270), ylims = (0, 1.1),
    xticks = ([230, 240, 253, 260], ["230", "240", "253", "260"]))
vline!(p_vw, [253, 260]; color = :black, linestyle = :dot, linewidth = 0.8)

# ------------------------- Volt-Var (PV) ---------------------
p_vv = plot(vv_v, vv_q; color = RGB(0.80, 0.47, 0.65),
    title = "(b) PV Volt-Var", xlabel = "Voltage (V)", ylabel = "Q (pu of rating)",
    xlims = (195, 270), ylims = (-0.7, 0.55),
    xticks = (vv_v[2:5], string.(Int.(vv_v[2:5]))))
deadband!(p_vv, 220, 240, -0.7, 0.55)
hline!(p_vv, [0.0]; color = :black, linewidth = 0.6)
vline!(p_vv, vv_v[2:5]; color = :black, linestyle = :dot, linewidth = 0.8)

# ------------------------- Volt-Var (STATCOM) ----------------
p_st = plot(st_v, st_q; color = RGB(0.00, 0.62, 0.45),
    title = "(c) STATCOM Volt-Var", xlabel = "Voltage (V)", ylabel = "Q (pu of rating)",
    xlims = (st_v[1], st_v[end]), ylims = (-1.1, 1.1),
    xticks = (st_v[2:5], string.(round.(Int, st_v[2:5]))))
deadband!(p_st, st_v[3], st_v[4], -1.1, 1.1)
hline!(p_st, [0.0]; color = :black, linewidth = 0.6)
vline!(p_st, st_v[2:5]; color = :black, linestyle = :dot, linewidth = 0.8)

# ------------------------- Save ------------------------------
# Separate figures: no "(a)/(b)/(c)" in the title, since they stand alone
for (p, name, solo) in ((p_vw, "pv_voltwatt_curve", "PV Volt-Watt"),
                        (p_vv, "pv_voltvar_curve", "PV Volt-Var"),
                        (p_st, "statcom_voltvar_curve", "STATCOM Volt-Var"))
    q = deepcopy(p)
    plot!(q; title = solo, size = figsize(TEXT_WIDTH_IN / 2, 2.4))
    savefig(q, joinpath(CURVES_DIR, "$(name).pdf"))
end

# PV curves only (Volt-Watt and Volt-Var), for the Case 2 methodology section
p_pv = plot(p_vw, p_vv; layout = (1, 2), size = figsize(TEXT_WIDTH_IN, 2.4),
            left_margin = 4Plots.mm)
savefig(p_pv, joinpath(CURVES_DIR, "pv_curves_combined.pdf"))

p_all = plot(p_vw, p_vv, p_st; layout = (1, 3), size = figsize(TEXT_WIDTH_IN, 2.3),
             left_margin = 4Plots.mm)
savefig(p_all, joinpath(CURVES_DIR, "control_curves_combined.pdf"))

println("Saved curve figures (PDF) to $CURVES_DIR")
