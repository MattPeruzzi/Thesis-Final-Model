# -----------------------------------------------------------------------------
# Note on AI assistance:
# An AI assistant (Anthropic's Claude) was used to improve the readability of
# this code — formatting, comments, variable naming, and structural clean-up.
# The underlying logic, methodology, and implementation are the author's own.
# -----------------------------------------------------------------------------

using Plots
using Plots.PlotMeasures


# ----------------------------------------------------------------------
# AS/NZS 4777.2:2020 default inverter response curves
# Generates the methodology figure for the thesis
# ----------------------------------------------------------------------

# Volt-Watt curve
# Below 1.06 pu: full power (1.0 pu)
# 1.06 to 1.10 pu: linear ramp from 1.0 down to 0.20
# Above 1.10 pu: limited to 0.20 pu
vw_x = [0.90, 1.06, 1.10, 1.15]
vw_y = [1.00, 1.00, 0.20, 0.20]

# Volt-Var curve
# Below 0.92 pu: 0.44 pu capacitive Q (positive)
# 0.92 to 0.98 pu: linear ramp from 0.44 to 0
# 0.98 to 1.02 pu: deadband (Q = 0)
# 1.02 to 1.08 pu: linear ramp from 0 to -0.60
# Above 1.08 pu: -0.60 pu inductive Q
vv_x = [0.85, 0.92, 0.98, 1.02, 1.08, 1.15]
vv_y = [0.44, 0.44, 0.00, 0.00, -0.60, -0.60]


# Output folder for the methodology figure
const CURVES_DIR = joinpath("outputs", "inverter_curves")
mkpath(CURVES_DIR)

# ------------------------- Volt-Watt -------------------------
p_vw = plot(vw_x, vw_y;
    title="Volt-Watt Response (AS/NZS 4777.2:2020 Default)",
    xlabel="Local voltage (pu)",
    ylabel="Real power output (pu of rated)",
    legend=false,
    linewidth=2.5, color=:steelblue,
    xlims=(0.90, 1.15),
    ylims=(0, 1.1),
    grid=true, gridalpha=0.3,
    size=(800, 500), dpi=200,
    left_margin=8mm, bottom_margin=6mm)

vline!(p_vw, [1.06]; color=:red, linewidth=1, linestyle=:dash, label="")
vline!(p_vw, [1.10]; color=:red, linewidth=1, linestyle=:dash, label="")
hline!(p_vw, [1.0]; color=:gray, linewidth=0.8, linestyle=:dot, label="")

annotate!(p_vw, 1.06, 0.55, text("V = 1.06 pu", :red, :center, 9, rotation=90))
annotate!(p_vw, 1.10, 0.55, text("V = 1.10 pu", :red, :center, 9, rotation=90))
annotate!(p_vw, 0.96, 1.05, text("Full power", :black, :left, 10))
annotate!(p_vw, 1.12, 0.25, text("20% min", :black, :left, 10))

savefig(p_vw, joinpath(CURVES_DIR, "inverter_voltwatt_curve.png"))
println("Saved $(joinpath(CURVES_DIR, "inverter_voltwatt_curve.png"))")

# ------------------------- Volt-Var -------------------------
p_vv = plot(vv_x, vv_y;
    title="Volt-Var Response (AS/NZS 4777.2:2020 Default)",
    xlabel="Local voltage (pu)",
    ylabel="Reactive power (pu of rated, +ve = capacitive)",
    legend=false,
    linewidth=2.5, color=:purple,
    xlims=(0.85, 1.15),
    ylims=(-0.7, 0.55),
    grid=true, gridalpha=0.3,
    size=(800, 500), dpi=200,
    left_margin=8mm, bottom_margin=6mm)

# Deadband shading
plot!(p_vv, [0.98, 1.02, 1.02, 0.98], [-0.7, -0.7, 0.55, 0.55];
    seriestype=:shape, fillalpha=0.1, fillcolor=:gray, linealpha=0, label="")

vline!(p_vv, [0.92, 0.98, 1.02, 1.08]; color=:red, linewidth=1, linestyle=:dash, label="")
hline!(p_vv, [0.0]; color=:black, linewidth=0.8, linestyle=:dot, label="")

annotate!(p_vv, 0.92, -0.4, text("V = 0.92 pu", :red, :center, 9, rotation=90))
annotate!(p_vv, 0.98, -0.4, text("V = 0.98 pu", :red, :center, 9, rotation=90))
annotate!(p_vv, 1.02, 0.30, text("V = 1.02 pu", :red, :center, 9, rotation=90))
annotate!(p_vv, 1.08, 0.30, text("V = 1.08 pu", :red, :center, 9, rotation=90))
annotate!(p_vv, 1.00, 0.45, text("Deadband", :gray, :center, 10))
annotate!(p_vv, 0.87, 0.46, text("Capacitive +0.44", :black, :left, 10))
annotate!(p_vv, 1.09, -0.55, text("Inductive −0.60", :black, :left, 10))

savefig(p_vv, joinpath(CURVES_DIR, "inverter_voltvar_curve.png"))
println("Saved $(joinpath(CURVES_DIR, "inverter_voltvar_curve.png"))")

# ------------------------- Combined 2-panel -------------------------
p_combined = plot(p_vw, p_vv; layout=(2, 1), size=(900, 1000), dpi=200)
savefig(p_combined, joinpath(CURVES_DIR, "inverter_curves_combined.png"))
println("Saved $(joinpath(CURVES_DIR, "inverter_curves_combined.png"))")

println("\nAll done. Three PNGs in $CURVES_DIR/:")
println("  inverter_voltwatt_curve.png       (Volt-Watt only)")
println("  inverter_voltvar_curve.png        (Volt-Var only)")
println("  inverter_curves_combined.png      (both stacked — use for thesis methodology figure)")