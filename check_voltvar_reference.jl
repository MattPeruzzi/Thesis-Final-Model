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
# Which voltage does the OpenDSS Volt-Var controller respond to?
#     include("check_voltvar_reference.jl")      (after run.jl has finished)
#
# For every Volt-Var STATCOM unit, the recorded reactive output is compared with
# what the Volt-Var curve gives for two candidate voltages at the unit's bus:
#   phase-to-neutral  |V_phase - V_neutral|   (what a real device measures)
#   phase-to-ground   |V_phase|               (what OpenDSS may be using)
# Whichever gives the smaller error is the voltage the controller is reading.
# Uses only the saved base-run outputs; nothing is rerun.
# -----------------------------------------------------------------------------

cd(@__DIR__)
using CSV, DataFrames, Statistics, Printf

BASE_DIR = joinpath("outputs", "base")
CASES_VV = ["case3_vv", "case4_vv", "case5_vv"]
V_BASE   = 230.0
Q_RATED  = 25.0

# STATCOM Volt-Var curve (add_statcom.jl), flat outside the end points
curve_x = [0.94, 0.98, 1.02, 1.06]
curve_y = [1.0, 0.0, 0.0, -1.0]
function vv_curve(vpu)
    vpu <= curve_x[1]   && return curve_y[1]
    vpu >= curve_x[end] && return curve_y[end]
    i = findlast(x -> x <= vpu, curve_x)
    t = (vpu - curve_x[i]) / (curve_x[i + 1] - curve_x[i])
    return curve_y[i] + t * (curve_y[i + 1] - curve_y[i])
end

function col(df, name)
    for c in names(df)
        strip(c) == name && return df[!, c]
    end
    error("Column $name not found in $(names(df))")
end
ph(df, k) = col(df, "V$k") .* cis.(deg2rad.(col(df, "VAngle$k")))

results = DataFrame()
for case in CASES_VV
    qf = joinpath(BASE_DIR, case, "statcom_q.csv")
    isfile(qf) || (@warn "No $qf, skipping $case"; continue)
    q = CSV.read(qf, DataFrame)
    for unit in unique(q.unit)
        m = match(r"^Statcom_(.+)_(\d)$", unit)
        m === nothing && continue
        bus, phase = m[1], parse(Int, m[2])
        vf = joinpath(BASE_DIR, case, "raw", "timeseries", "M_VBUS_$(bus).csv")
        isfile(vf) || (@warn "No $vf"; continue)
        v  = CSV.read(vf, DataFrame)
        vp = ph(v, phase); vn = ph(v, 4)

        qu = q[q.unit .== unit, :]
        n  = min(nrow(qu), length(vp))
        actual = qu.q_kvar[1:n]
        v_pn = abs.(vp[1:n] .- vn[1:n]) ./ V_BASE
        v_pg = abs.(vp[1:n]) ./ V_BASE
        pred_pn = Q_RATED .* vv_curve.(v_pn)
        pred_pg = Q_RATED .* vv_curve.(v_pg)

        rmse(p) = sqrt(mean((p .- actual) .^ 2))
        push!(results, (case = case, unit = unit,
                        rmse_phase_neutral = rmse(pred_pn),
                        rmse_phase_ground  = rmse(pred_pg),
                        mean_gap_V = mean(abs.(v_pn .- v_pg)) * V_BASE,
                        max_gap_V  = maximum(abs.(v_pn .- v_pg)) * V_BASE))
    end
end

println("\nError between recorded kvar and the Volt-Var curve (kvar, lower = better match):")
show(results; allcols = true); println()

if nrow(results) > 0
    pn = mean(results.rmse_phase_neutral); pg = mean(results.rmse_phase_ground)
    @printf("\nAverage error: phase-to-neutral %.2f kvar, phase-to-ground %.2f kvar\n", pn, pg)
    println(pn < pg ? "=> The controller is responding to the PHASE-TO-NEUTRAL voltage." :
                      "=> The controller is responding to the PHASE-TO-GROUND voltage.")
    println("(mean_gap_V is how far apart the two voltages are; if it is tiny the test can't tell them apart.)")
end
