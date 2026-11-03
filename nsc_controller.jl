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
# Time-stepping and coordinated negative-sequence STATCOM control.
#
# step_timeseries! replaces a single Solution.Solve() over the whole day with a
# loop of one-step Solve() calls. With control=:voltvar (or no STATCOMs) it gives
# results identical to the old Solve() call, but also checks convergence at
# every step instead of only the last one.
#
# With control=:nsc, at each timestep the STATCOM reactive setpoints are chosen
# to minimise the negative-sequence voltage at a set of objective buses:
#
#     min_q  sum_b |V2_b(q)|^2  +  lambda * |q|^2      s.t. |q_i| <= kvar_max
#
# solved by a few safeguarded Gauss-Newton iterations (finite-difference
# Jacobian, step accepted only if the objective improves, fallback to q = 0).
# V2 is invariant to neutral displacement, so it does not matter that OpenDSS
# bus voltages are referenced to ground rather than to the neutral.
# -----------------------------------------------------------------------------
 
using LinearAlgebra
 
const A_OP = cis(2π / 3)
 
# Bus.Voltages() is complex in OpenDSSDirect.jl; handle the interleaved-real
# form too so this doesn't break across package versions.
_as_complex(v::AbstractVector{<:Complex}) = ComplexF64.(v)
_as_complex(v::AbstractVector{<:Real}) = ComplexF64.(v[1:2:end], v[2:2:end])
 
function neg_seq_voltage(bus::AbstractString)
    Circuit.SetActiveBus(bus)
    v = _as_complex(Bus.Voltages())
    nodes = Bus.Nodes()
    va = v[findfirst(==(1), nodes)]
    vb = v[findfirst(==(2), nodes)]
    vc = v[findfirst(==(3), nodes)]
    return (va + A_OP^2 * vb + A_OP * vc) / 3
end
 
# Stacked [Re V2; Im V2] over the objective buses, per-unit on 230 V.
function v2_vector(buses)
    f = Float64[]
    for b in buses
        z = neg_seq_voltage(b) / 230.0
        push!(f, real(z), imag(z))
    end
    return f
end
 
# Storage kvar > 0 means injecting (capacitive) reactive power.
function set_statcom_kvar!(names::Vector{String}, q::Vector{Float64})
    for (n, x) in zip(names, q)
        dss("Storage.$(n).kvar=$(round(x, digits=4))")
    end
end
 
# Solve with setpoints q (all controls active) and return sum |V2|^2.
function eval_objective!(names::Vector{String}, q::Vector{Float64}, buses)
    set_statcom_kvar!(names, q)
    Solution.SolveSnap()
    f = v2_vector(buses)
    return sum(abs2, f)
end
 
# One safeguarded Gauss-Newton step. The Jacobian is taken with SolveSnap so
# the PV inverters' Volt-Var response is included in the sensitivity. The step
# is only accepted if the true objective improves on `best`; otherwise it is
# halved up to 5 times, and if nothing improves q is left unchanged.
# Returns (new best objective, whether q changed).
function nsc_update!(q, best, names, objective_buses; kvar_max, lambda, delta)
    set_statcom_kvar!(names, q)
    Solution.SolveSnap()
    f0 = v2_vector(objective_buses)
    J = zeros(length(f0), length(q))
    for j in eachindex(q)
        qp = copy(q)
        qp[j] += delta
        set_statcom_kvar!(names, qp)
        Solution.SolveSnap()
        J[:, j] = (v2_vector(objective_buses) .- f0) ./ delta
    end
    dq = (J' * J + lambda * I) \ (-(J' * f0) .- lambda .* q)
 
    step = 1.0
    for _ in 1:5
        q_try = clamp.(q .+ step .* dq, -kvar_max, kvar_max)
        o_try = eval_objective!(names, q_try, objective_buses)
        if o_try < best
            q .= q_try
            return o_try, true
        end
        step /= 2
    end
    return best, false
end
 
# Set the simulation clock. The text command is used because the typed
# Solution.Hour setter differs between OpenDSSDirect.jl versions.
function set_clock!(t::Float64)
    hr = floor(Int, t / 3600)
    dss("Set hour=$(hr) sec=$(t - 3600.0 * hr)")
end
 
"""
    step_timeseries!(npts, step_seconds; statcom_names, control, objective_buses,
                     kvar_max, max_control_iter, lambda, delta, nsc_iters)
 
Run the time-series one step at a time. Every recorded step is solved with the
engine's own Solution.Solve() (Number=1), which advances the clock, runs all
controls and samples the monitors exactly as the original single Solve() did.
Sampling monitors manually (Monitors.SampleAll after SolveSnap) silently drops
or repeats samples in DSS C-API 0.14.x, so it is not used.
 
With control=:nsc, the STATCOM setpoints for step k are found first with
SolveSnap at step k's time (nothing is recorded), then the clock is wound back
one step and Solve() records step k with those setpoints fixed.
 
Returns an npts x n_statcom matrix of the reactive setpoints used (kvar).
"""
function step_timeseries!(npts::Int, step_seconds::Float64;
                          statcom_names::Vector{String} = String[],
                          control::Symbol = :voltvar,
                          objective_buses = LV_BUSES,
                          kvar_max::Float64 = Inf,
                          max_control_iter::Int = 100,
                          lambda::Float64 = 1e-8,
                          delta::Float64 = 1.0,
                          nsc_iters::Int = 3)
    nsc = control == :nsc && !isempty(statcom_names)
    q = zeros(length(statcom_names))
    q_log = zeros(npts, length(statcom_names))
    bad_steps = Int[]
 
    Solution.Number(1)
    set_clock!(0.0)
 
    for k in 1:npts
        if nsc
            # Optimise at step k's time without recording anything
            set_clock!(k * step_seconds)
 
            # Start from whichever is better: last step's setpoints or all-zero.
            # This guarantees the objective is never worse than no STATCOM.
            o_warm = eval_objective!(statcom_names, q, objective_buses)
            o_zero = eval_objective!(statcom_names, zeros(length(q)), objective_buses)
            if o_zero <= o_warm
                q .= 0.0
                best = o_zero
            else
                best = o_warm
            end
            for _ in 1:nsc_iters
                best, improved = nsc_update!(q, best, statcom_names, objective_buses;
                                             kvar_max = kvar_max, lambda = lambda,
                                             delta = delta)
                improved || break
            end
            set_statcom_kvar!(statcom_names, q)
 
            # Wind back one step so Solve() lands on step k and records it
            set_clock!((k - 1) * step_seconds)
        end
 
        Solution.Solve()
 
        if !Solution.Converged() || Solution.ControlIterations() >= max_control_iter
            push!(bad_steps, k)
        end
        q_log[k, :] .= q
    end
 
    if isempty(bad_steps)
        println("All $(npts) timesteps converged ✓")
    else
        @warn "$(length(bad_steps)) timestep(s) did not converge or hit MaxControlIter: $(bad_steps)"
    end
    return q_log
end