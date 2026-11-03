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
# Per-run analysis. Turns the raw monitor data from run_opendss_simulation into
# the thesis metrics and writes tidy CSVs. No plotting happens here: every
# thesis figure is drawn by plot_results.jl from these CSVs, so figures can be
# restyled without rerunning any simulations.
#
# Metrics:
#   - Customer voltage, phase-to-NEUTRAL (what the customer actually receives),
#     assessed against AS 61000.3.100 on 10-minute values:
#       225-244 V for >= 50% of the time, 216-253 V for >= 99% of the time
#   - IEC VUF = |V2|/|V1|, assessed as the 95th percentile of 10-minute values
#     (2% limit, AS/NZS IEC 61000.2.2), with the peak also reported
#   - NEMA line voltage unbalance (LVUR, vuf_nema) from LINE-TO-LINE magnitudes,
#     which is how NEMA MG-1 defines it. Line voltages contain no zero sequence,
#     so neutral shift does not appear in it.
#   - IEEE phase voltage unbalance (PVUR, vuf_pvur) from phase-to-neutral
#     magnitudes. This one DOES include neutral shift, so it shows the spread of
#     voltages customers actually see.
#   - Sequence components |V0|, |V1|, |V2| and the neutral-to-earth voltage |Vn|
# -----------------------------------------------------------------------------

using DataFrames
using CSV
using Statistics

const A_SEQ     = cis(2π / 3)
const BAND_50   = (225.0, 244.0)   # must hold >= 50% of the time
const BAND_99   = (216.0, 253.0)   # must hold >= 99% of the time
const VUF_LIMIT = 2.0              # %, AS/NZS IEC 61000.2.2


# ----------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------
phasor(mag, ang_deg) = mag .* cis.(deg2rad.(ang_deg))

iec_vuf(v1::Complex, v2::Complex) = abs(v1) > 1e-3 ? 100 * abs(v2) / abs(v1) : 0.0

function nema_vuf(a::Real, b::Real, c::Real)
    avg = (a + b + c) / 3
    avg > 1e-3 || return 0.0
    return 100 * max(abs(a - avg), abs(b - avg), abs(c - avg)) / avg
end

"""
    aggregate_10min(x, k)

Combine every k consecutive samples into one 10-minute value using the RMS of
the block (k = 2 for 5-minute data), following the IEC 61000-4-30 approach of
aggregating shorter intervals. An incomplete final block is dropped.
"""
function aggregate_10min(x::AbstractVector{<:Real}, k::Int)
    k <= 1 && return collect(Float64, x)
    nb = length(x) ÷ k
    return [sqrt(mean(abs2, @view x[(i - 1) * k + 1 : i * k])) for i in 1:nb]
end

p95(x) = isempty(x) ? NaN : quantile(x, 0.95)

steps_per_10min(interval_minutes::Int) = max(1, round(Int, 10 / interval_minutes))


# ----------------------------------------------------------------------
# Sequence components and VUF at every LV bus
# ----------------------------------------------------------------------
"""
    compute_sequences(ts, buses)

For each bus, build phase-to-ground phasors Va, Vb, Vc and the neutral Vn from
the 4-conductor line monitor, then compute the sequence components and VUF.
V1 and V2 are the same whether voltages are referenced to ground or to the
neutral; V0 is not, so both versions are kept.
"""
function compute_sequences(ts::Dict, buses)
    out = Dict{String, DataFrame}()
    a = A_SEQ

    for bus in buses
        key = "M_VBUS_$(bus)"
        if !haskey(ts, key)
            @warn "No monitor data for bus $bus, skipping"
            continue
        end
        df = ts[key]
        if !all(c -> hasproperty(df, c), (:V1, :V2, :V3, :VAngle1, :VAngle2, :VAngle3))
            @warn "Bus $bus monitor lacks 3-phase data, skipping"
            continue
        end

        va = phasor(df.V1, df.VAngle1)
        vb = phasor(df.V2, df.VAngle2)
        vc = phasor(df.V3, df.VAngle3)
        vn = (hasproperty(df, :V4) && hasproperty(df, :VAngle4)) ?
             phasor(df.V4, df.VAngle4) : zeros(ComplexF64, nrow(df))

        v0_pg = (va .+ vb .+ vc) ./ 3
        v1    = (va .+ a .* vb .+ a^2 .* vc) ./ 3
        v2    = (va .+ a^2 .* vb .+ a .* vc) ./ 3
        v0_pn = v0_pg .- vn                      # zero sequence seen phase-to-neutral

        out[bus] = DataFrame(
            timestep    = 1:nrow(df),
            v0          = abs.(v0_pn),
            v0_pg       = abs.(v0_pg),
            v1          = abs.(v1),
            v2          = abs.(v2),
            vn          = abs.(vn),
            vuf_iec     = iec_vuf.(v1, v2),
            vuf_nema    = nema_vuf.(abs.(va .- vb), abs.(vb .- vc), abs.(vc .- va)),   # line-to-line
            vuf_pvur    = nema_vuf.(abs.(va .- vn), abs.(vb .- vn), abs.(vc .- vn)),   # phase-to-neutral
        )
    end
    return out
end


"""
    summarise_buses(seq, buses, k)

Peak and 95th-percentile (10-minute) VUF per bus, plus mean sequence magnitudes.
"""
function summarise_buses(seq::Dict, buses, k::Int)
    bs = DataFrame(bus = String[],
                   peak_iec = Float64[], p95_iec = Float64[],
                   peak_nema = Float64[], p95_nema = Float64[],
                   peak_pvur = Float64[], p95_pvur = Float64[],
                   mean_v0 = Float64[], mean_v2 = Float64[], max_vn = Float64[])
    for bus in buses
        haskey(seq, bus) || continue
        s = seq[bus]
        push!(bs, (bus,
                   maximum(s.vuf_iec),     p95(aggregate_10min(s.vuf_iec, k)),
                   maximum(s.vuf_nema),    p95(aggregate_10min(s.vuf_nema, k)),
                   maximum(s.vuf_pvur),    p95(aggregate_10min(s.vuf_pvur, k)),
                   mean(s.v0), mean(s.v2), maximum(s.vn)))
    end
    return bs
end


# ----------------------------------------------------------------------
# Customer voltages (phase-to-neutral) and AS 61000.3.100 compliance
# ----------------------------------------------------------------------
"""
    customer_voltages(ts, loads, k)

The load monitors record each conductor's voltage to ground, so the customer's
phase-to-neutral voltage is |V_phase - V_neutral|. Compliance is assessed on
10-minute values.
"""
function customer_voltages(ts::Dict, loads, k::Int)
    v_ts = DataFrame(timestep = Int[], load = String[], v_pn = Float64[])
    comp = DataFrame(load = String[], min_v = Float64[], max_v = Float64[], mean_v = Float64[],
                     frac_225_244 = Float64[], frac_216_253 = Float64[],
                     pass_50 = Bool[], pass_99 = Bool[])

    for ld in loads
        key = "M_V_$(ld)"
        if !haskey(ts, key)
            @warn "No voltage monitor for $ld, skipping"
            continue
        end
        df = ts[key]
        va = phasor(df.V1, df.VAngle1)
        v = (hasproperty(df, :V2) && hasproperty(df, :VAngle2)) ?
            abs.(va .- phasor(df.V2, df.VAngle2)) : abs.(va)

        append!(v_ts, DataFrame(timestep = 1:length(v), load = fill(ld, length(v)), v_pn = v))

        v10 = aggregate_10min(v, k)
        f50 = mean(BAND_50[1] .<= v10 .<= BAND_50[2])
        f99 = mean(BAND_99[1] .<= v10 .<= BAND_99[2])
        push!(comp, (ld, minimum(v), maximum(v), mean(v), f50, f99, f50 >= 0.50, f99 >= 0.99))
    end
    return v_ts, comp
end


# ----------------------------------------------------------------------
# Feeder-level headline numbers
# ----------------------------------------------------------------------
function feeder_metrics(bs::DataFrame, cc::DataFrame)
    i = argmax(bs.p95_iec)
    return (
        peak_iec          = maximum(bs.peak_iec),
        p95_iec           = bs.p95_iec[i],            # worst bus
        worst_bus         = bs.bus[i],
        peak_nema         = maximum(bs.peak_nema),
        p95_nema          = maximum(bs.p95_nema),
        peak_pvur         = maximum(bs.peak_pvur),
        p95_pvur          = maximum(bs.p95_pvur),
        vuf_compliant     = bs.p95_iec[i] <= VUF_LIMIT,
        min_v             = minimum(cc.min_v),
        max_v             = maximum(cc.max_v),
        n_pass_50         = count(cc.pass_50),
        n_pass_99         = count(cc.pass_99),
        voltage_compliant = all(cc.pass_50) && all(cc.pass_99),
    )
end


"""
    compute_metrics(results; interval_minutes = 5)

Everything the thesis needs from one run, without writing any files. Used
directly by the Monte Carlo loop, and by analyse_results for the base runs.
"""
function compute_metrics(results; interval_minutes::Int = 5)
    ts = results.timeseries
    k  = steps_per_10min(interval_minutes)

    seq         = compute_sequences(ts, LV_BUSES)
    bus_summary = summarise_buses(seq, LV_BUSES, k)
    v_ts, comp  = customer_voltages(ts, SLOT_LOAD_NAMES, k)

    return (
        sequences           = seq,
        bus_summary         = bus_summary,
        customer_ts         = v_ts,
        customer_compliance = comp,
        feeder              = feeder_metrics(bus_summary, comp),
    )
end


"""
    mc_record(m, case_id, seed; runtime_s)

One feeder-level row and a per-bus table for the Monte Carlo CSVs.
"""
function mc_record(m, case_id::Symbol, seed::Int; runtime_s::Real = NaN)
    feeder = merge((case = String(case_id), seed = seed), m.feeder, (runtime_s = Float64(runtime_s),))
    bus = select(m.bus_summary, :bus, :peak_iec, :p95_iec, :peak_nema, :p95_nema)
    insertcols!(bus, 1, :case => fill(String(case_id), nrow(bus)), :seed => fill(seed, nrow(bus)))
    return feeder, bus
end


# ----------------------------------------------------------------------
# Extra outputs used only for the base-case figures
# ----------------------------------------------------------------------
"""
    statcom_reactive(results, interval_minutes)

Reactive output of each STATCOM unit from its power monitor. OpenDSS monitors
report power flowing INTO the element, so the sign is flipped to make
+ve = injecting (capacitive). For NSC runs this is checked against the
setpoints the controller actually wrote.
"""
function statcom_reactive(results, interval_minutes::Int)
    ts = results.timeseries
    out = DataFrame(timestep = Int[], hour = Float64[], unit = String[],
                    q_kvar = Float64[], q_setpoint = Float64[])

    for (j, name) in enumerate(results.statcom_names)
        key = "M_Q_$(name)"
        haskey(ts, key) || continue
        m = ts[key]
        q = -(m[!, Symbol("S1 (kVA)")] .* sind.(m.Ang1))
        n = length(q)
        sp = size(results.statcom_q, 1) >= n ? results.statcom_q[1:n, j] : fill(NaN, n)
        append!(out, DataFrame(timestep = 1:n, hour = (0:n-1) .* (interval_minutes / 60),
                               unit = fill(name, n), q_kvar = q, q_setpoint = sp))
    end

    if results.statcom_control == :nsc && nrow(out) > 0
        err = maximum(abs.(out.q_kvar .- out.q_setpoint))
        println("  STATCOM sign check (NSC): max |monitor Q - setpoint| = $(round(err, digits=2)) kvar")
        # A sign error would make the gap about twice the setpoint; small gaps are
        # just the unit's actual output differing slightly from its setpoint
        qmax = maximum(abs.(out.q_setpoint))
        err > max(2.0, 0.5 * qmax) && @warn "Monitor Q and NSC setpoints disagree. If they are equal and opposite, remove the minus sign in statcom_reactive()."
    end
    return out
end


"""
    transformer_power(ts, interval_minutes)

Per-phase active power at the transformer secondary (+ve = importing from grid).
"""
function transformer_power(ts::Dict, interval_minutes::Int)
    tx = ts["M_P_Tx"]
    n = nrow(tx)
    p(col_s, col_a) = -(tx[!, Symbol(col_s)] .* cosd.(tx[!, col_a]))
    pa = p("S1 (kVA)", :Ang1)
    pb = p("S2 (kVA)", :Ang2)
    pc = "S3 (kVA)" in names(tx) ? p("S3 (kVA)", :Ang3) : zeros(n)
    return DataFrame(timestep = 1:n, hour = (0:n-1) .* (interval_minutes / 60),
                     p_a = pa, p_b = pb, p_c = pc, p_total = pa .+ pb .+ pc)
end


"""
    self_consumption(ts, interval_minutes)

Share of each slot's PV used locally over the simulated period.
"""
function self_consumption(ts::Dict, interval_minutes::Int)
    sc = DataFrame(slot = Int[], load_name = String[], load_kWh = Float64[],
                   pv_kWh = Float64[], self_consumption_pct = Float64[])
    dt_hr = interval_minutes / 60

    for (slot, ld) in enumerate(SLOT_LOAD_NAMES)
        df_v  = ts["M_V_$ld"]
        df_pv = ts["M_P_PV$slot"]
        load_kW = df_v.V1 .* df_v.I1 .* cosd.(df_v.VAngle1 .- df_v.IAngle1) ./ 1000
        pv_kW   = abs.(df_pv[!, Symbol("S1 (kVA)")] .* cosd.(df_pv.Ang1))

        used     = min.(pv_kW, max.(load_kW, 0))
        load_kWh = sum(max.(load_kW, 0)) * dt_hr
        pv_kWh   = sum(pv_kW) * dt_hr
        sc_pct   = pv_kWh > 0 ? 100 * sum(used) * dt_hr / pv_kWh : 0.0
        push!(sc, (slot, ld, load_kWh, pv_kWh, sc_pct))
    end
    return sc
end


# ----------------------------------------------------------------------
# Main entry point for the base (single-seed) runs
# ----------------------------------------------------------------------
"""
    analyse_results(results; output_dir, interval_minutes = 5)

Compute all metrics for one run and write them as CSVs in `output_dir`:
  bus_timeseries.csv               VUF and sequence magnitudes, every bus and step
  bus_summary.csv                  peak / P95 VUF and mean sequence magnitudes per bus
  customer_voltage_timeseries.csv  phase-to-neutral voltage, every load and step
  customer_compliance.csv          AS 61000.3.100 compliance per load
  feeder_summary.csv               headline numbers for the run
  statcom_q.csv                    STATCOM reactive output (STATCOM cases only)
  transformer_power.csv            per-phase transformer power
  self_consumption.csv             per-slot PV self-consumption
"""
function analyse_results(results; output_dir::AbstractString, interval_minutes::Int = 5)
    mkpath(output_dir)
    m = compute_metrics(results; interval_minutes = interval_minutes)
    to_hour(t) = (t - 1) * interval_minutes / 60

    bus_ts = vcat([insertcols!(copy(m.sequences[b]), 1, :bus => fill(b, nrow(m.sequences[b])))
                   for b in LV_BUSES if haskey(m.sequences, b)]...)
    bus_ts.hour = to_hour.(bus_ts.timestep)

    cust_ts = copy(m.customer_ts)
    cust_ts.hour = to_hour.(cust_ts.timestep)

    q  = statcom_reactive(results, interval_minutes)
    tx = transformer_power(results.timeseries, interval_minutes)
    sc = self_consumption(results.timeseries, interval_minutes)

    CSV.write(joinpath(output_dir, "bus_timeseries.csv"), bus_ts)
    CSV.write(joinpath(output_dir, "bus_summary.csv"), m.bus_summary)
    CSV.write(joinpath(output_dir, "customer_voltage_timeseries.csv"), cust_ts)
    CSV.write(joinpath(output_dir, "customer_compliance.csv"), m.customer_compliance)
    CSV.write(joinpath(output_dir, "feeder_summary.csv"), DataFrame([m.feeder]))
    nrow(q) > 0 && CSV.write(joinpath(output_dir, "statcom_q.csv"), q)
    CSV.write(joinpath(output_dir, "transformer_power.csv"), tx)
    CSV.write(joinpath(output_dir, "self_consumption.csv"), sc)

    f = m.feeder
    println("  P95 VUF (worst bus $(f.worst_bus)): $(round(f.p95_iec, digits=3))%   " *
            "peak VUF: $(round(f.peak_iec, digits=3))%   " *
            "customer V: $(round(f.min_v, digits=1))-$(round(f.max_v, digits=1)) V   " *
            "voltage compliant: $(f.voltage_compliant)")
    println("  Analysis written to $output_dir")

    return merge(m, (statcom_q = q, transformer = tx, self_consumption = sc))
end
