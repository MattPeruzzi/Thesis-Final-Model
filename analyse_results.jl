# -----------------------------------------------------------------------------
# Note on AI assistance:
# An AI assistant (Anthropic's Claude) was used to improve the readability of
# this code — formatting, comments, variable naming, and structural clean-up.
# The underlying logic, methodology, and implementation are the author's own.
# -----------------------------------------------------------------------------


using DataFrames
using CSV
using Statistics
using Plots
using Dates


"""
    analyse_results(results; output_dir, interval_minutes)

Take the results NamedTuple from run_opendss_simulation and produce
thesis-quality plots and summary statistics.
"""
function analyse_results(
    results;
    output_dir::AbstractString = "analysis_plots",
    interval_minutes::Int = 5,
)
    mkpath(output_dir)

    # Convert timestep numbers to hours-of-day for nicer plots
    ts = results.timeseries
    n_steps = nrow(first(values(ts)))
    hours = collect(0:n_steps-1) .* (interval_minutes / 60)

    # Slot mapping
    slot_load_names = ["Ld1", "Ld2", "Ld3", "Ld4", "Ld5", "Ld6", "Ld7", "Ld8",
                       "Ld9", "Ld10", "Ld11", "Ld12", "Ld13", "Ld14", "Ld15",
                       "Ld16", "Ld17", "Ld24", "Ld25", "Ld26", "Ld27", "Ld28",
                       "Ld29", "Ld30", "Ld31"]
    n_slots = length(slot_load_names)

    # LV bus list for VUF
    lv_buses = ["TxSecondary", "FN_Trunk",
                "NorthSpine_1", "NorthSpine_2", "NorthSpine_End",
                "West_1", "West_2", "West_Junction", "West_End_A", "West_End_B",
                "East_1", "East_Junction", "East_North_1", "East_North_End",
                "East_South_1", "East_South_End"]

    # ------------------------------------------------------------------
    # PLOT 1: Voltage time-series at every load bus
    # ------------------------------------------------------------------
    println("Generating plot 1: Voltage time-series across all buses...")
    p1 = plot(; title="Voltage at all 25 load points across the day",
              xlabel="Hour of day", ylabel="Voltage (pu)",
              xlims=(0, 24), xticks=0:3:24,
              size=(1400, 700), legend=false,
              dpi=200)

    for ld in slot_load_names
        df_v = ts["M_V_$ld"]
        v_pu = df_v.V1 ./ 230
        plot!(p1, hours, v_pu; alpha=0.5, linewidth=1.0, color=:steelblue)
    end

    hline!(p1, [1.10]; color=:red, linewidth=1.5, linestyle=:dash, label="")
    hline!(p1, [0.90]; color=:red, linewidth=1.5, linestyle=:dash, label="")
    hline!(p1, [1.00]; color=:black, linewidth=0.8, linestyle=:dot, label="")
    annotate!(p1, 0.3, 1.10, text("AS 60038 +10%", :red, :left, 9))
    annotate!(p1, 0.3, 0.90, text("AS 60038 −10%", :red, :left, 9))

    savefig(p1, joinpath(output_dir, "01_voltage_envelope.png"))
    println("  saved 01_voltage_envelope.png")

    # ------------------------------------------------------------------
    # PLOT 2: Transformer V-curve (P over the day)
    # ------------------------------------------------------------------
    println("Generating plot 2: Transformer power flow (V-curve)...")
    tx = ts["M_P_Tx"]

    s1 = tx[!, Symbol("S1 (kVA)")]
    a1 = tx[!, :Ang1]
    s2 = tx[!, Symbol("S2 (kVA)")]
    a2 = tx[!, :Ang2]
    has_s3 = "S3 (kVA)" in names(tx)
    s3 = has_s3 ? tx[!, Symbol("S3 (kVA)")] : zeros(n_steps)
    a3 = has_s3 ? tx[!, :Ang3] : zeros(n_steps)

    p1_kw = s1 .* cos.(deg2rad.(a1))
    p2_kw = s2 .* cos.(deg2rad.(a2))
    p3_kw = s3 .* cos.(deg2rad.(a3))
    p_total = p1_kw .+ p2_kw .+ p3_kw

    # Flip sign convention: positive = importing from grid, negative = exporting (PV)
    p1_kw = -p1_kw
    p2_kw = -p2_kw
    p3_kw = -p3_kw
    p_total = -p_total

    p2_plot = plot(hours, p_total;
        title="Transformer power flow across the day",
        xlabel="Hour of day", ylabel="Active power (kW)",
        label="Total P",
        xlims=(0, 24), xticks=0:3:24,
        linewidth=2.5, color=:steelblue,
        size=(1400, 600), dpi=200)

    plot!(p2_plot, hours, p1_kw; label="Phase A", linewidth=1.2, alpha=0.6, color=:red)
    plot!(p2_plot, hours, p2_kw; label="Phase B", linewidth=1.2, alpha=0.6, color=:green)
    plot!(p2_plot, hours, p3_kw; label="Phase C", linewidth=1.2, alpha=0.6, color=:blue)
    hline!(p2_plot, [0]; color=:black, linewidth=0.8, linestyle=:dot, label="")
    hline!(p2_plot, [200]; color=:red, linewidth=1.0, linestyle=:dash, label="200 kVA rating")
    hline!(p2_plot, [-200]; color=:red, linewidth=1.0, linestyle=:dash, label="")

    savefig(p2_plot, joinpath(output_dir, "02_transformer_v_curve.png"))
    println("  saved 02_transformer_v_curve.png")

    # ------------------------------------------------------------------
    # PLOT 3, 6, 7: VUF analysis (IEC and NEMA methods)
    # ------------------------------------------------------------------
    println("Generating VUF analysis (IEC + NEMA)...")
    vuf = compute_vuf(ts, lv_buses)

    # Plot 3: VUF time-series at every bus (IEC method)
    p3 = plot(; title="Voltage Unbalance Factor (IEC) at all LV buses across the day",
              xlabel="Hour of day", ylabel="VUF (%)",
              xlims=(0, 24), xticks=0:3:24,
              size=(1400, 700), legend=false, dpi=200)

    for bus in lv_buses
        if haskey(vuf, bus)
            plot!(p3, hours, vuf[bus].vuf_iec; alpha=0.5, linewidth=1.0, color=:steelblue)
        end
    end
    hline!(p3, [2.0]; color=:red, linewidth=1.5, linestyle=:dash, label="")
    annotate!(p3, 0.3, 2.0, text("AS 60038 limit (2%)", :red, :left, 9))
    savefig(p3, joinpath(output_dir, "03_vuf_iec_timeseries.png"))
    println("  saved 03_vuf_iec_timeseries.png")

    # Plot 6: NEMA VUF time-series
    p6 = plot(; title="Voltage Unbalance (NEMA) at all LV buses across the day",
              xlabel="Hour of day", ylabel="NEMA Unbalance (%)",
              xlims=(0, 24), xticks=0:3:24,
              size=(1400, 700), legend=false, dpi=200)

    for bus in lv_buses
        if haskey(vuf, bus)
            plot!(p6, hours, vuf[bus].vuf_nema; alpha=0.5, linewidth=1.0, color=:goldenrod)
        end
    end
    hline!(p6, [2.0]; color=:red, linewidth=1.5, linestyle=:dash, label="")
    savefig(p6, joinpath(output_dir, "06_vuf_nema_timeseries.png"))
    println("  saved 06_vuf_nema_timeseries.png")

    # Plot 7: Peak VUF per bus, both methods
    peak_data = DataFrame(bus = String[], peak_vuf_iec = Float64[], peak_vuf_nema = Float64[])
    for bus in lv_buses
        if haskey(vuf, bus)
            push!(peak_data, (bus,
                round(maximum(vuf[bus].vuf_iec), digits=3),
                round(maximum(vuf[bus].vuf_nema), digits=3)))
        end
    end

    n_buses = nrow(peak_data)
    bus_x = 1:n_buses
    p7 = plot(; title="Peak VUF per bus (IEC vs NEMA)",
              xlabel="Bus", ylabel="Peak VUF (%)",
              xticks=(bus_x, peak_data.bus),
              size=(1400, 600), dpi=200,
              xrotation=45, legend=:topleft)
    bar!(p7, bus_x .- 0.2, peak_data.peak_vuf_iec;
         label="IEC", color=:steelblue, alpha=0.8, bar_width=0.4)
    bar!(p7, bus_x .+ 0.2, peak_data.peak_vuf_nema;
         label="NEMA", color=:goldenrod, alpha=0.8, bar_width=0.4)
    hline!(p7, [2.0]; color=:red, linewidth=1.5, linestyle=:dash, label="2% limit")
    savefig(p7, joinpath(output_dir, "07_peak_vuf_per_bus.png"))

    CSV.write(joinpath(output_dir, "vuf_per_bus.csv"), peak_data)
    println("  saved 07_peak_vuf_per_bus.png")
    println("  saved vuf_per_bus.csv")

    # ------------------------------------------------------------------
    # PLOT 8: STATCOM reactive power output (only if this run had any)
    # ------------------------------------------------------------------
    if !isempty(results.statcom_names)
        println("Generating plot 8: STATCOM reactive power output...")
        p8 = plot(; title="STATCOM reactive power output across the day",
                  xlabel="Hour of day", ylabel="Q (kvar)",
                  xlims=(0, 24), xticks=0:3:24, size=(1400, 600), dpi=200)
        for name in results.statcom_names
            df_q = ts["M_Q_$(name)"]
            q_kvar = df_q[!, Symbol("S1 (kVA)")] .* sin.(deg2rad.(df_q.Ang1))
            plot!(p8, hours, q_kvar; label=name, linewidth=1.5)
        end
        savefig(p8, joinpath(output_dir, "08_statcom_reactive_output.png"))
        println("  saved 08_statcom_reactive_output.png")
    end

    # ------------------------------------------------------------------
    # PLOT 4: Voltage compliance % at each bus
    # ------------------------------------------------------------------
    println("Generating plot 4: Voltage compliance per bus...")

    compliance_data = DataFrame(
        load = String[],
        min_pu = Float64[],
        max_pu = Float64[],
        mean_pu = Float64[],
        pct_within_band = Float64[],
        pct_under = Float64[],
        pct_over = Float64[],
    )

    for ld in slot_load_names
        df_v = ts["M_V_$ld"]
        v_pu = df_v.V1 ./ 230
        in_band = (0.90 .<= v_pu .<= 1.10)
        under = v_pu .< 0.90
        over = v_pu .> 1.10
        push!(compliance_data, (
            ld,
            round(minimum(v_pu), digits=3),
            round(maximum(v_pu), digits=3),
            round(mean(v_pu), digits=3),
            round(100 * sum(in_band) / length(v_pu), digits=2),
            round(100 * sum(under) / length(v_pu), digits=2),
            round(100 * sum(over) / length(v_pu), digits=2),
        ))
    end

    CSV.write(joinpath(output_dir, "voltage_compliance_per_bus.csv"), compliance_data)
    println("  saved voltage_compliance_per_bus.csv")

    p4 = bar(compliance_data.load, compliance_data.pct_within_band;
        title="Voltage compliance per load (% of timesteps within 0.9-1.1 pu)",
        xlabel="Load", ylabel="% within compliance band",
        ylims=(0, 105),
        rotation=45,
        size=(1400, 600), dpi=200,
        legend=false,
        color=:steelblue)
    hline!(p4, [100]; color=:black, linewidth=0.8, linestyle=:dot, label="")
    savefig(p4, joinpath(output_dir, "04_compliance_per_bus.png"))
    println("  saved 04_compliance_per_bus.png")

    # ------------------------------------------------------------------
    # PLOT 5: Self-consumption per slot
    # ------------------------------------------------------------------
    println("Generating plot 5: Self-consumption per slot...")

    sc_data = DataFrame(
        slot = Int[],
        load_name = String[],
        load_kWh = Float64[],
        pv_kWh = Float64[],
        self_consumption_pct = Float64[],
    )

    dt_hr = interval_minutes / 60

    for slot in 1:n_slots
        ld_name = slot_load_names[slot]
        df_v = ts["M_V_$ld_name"]
        df_pv = ts["M_P_PV$slot"]

        # Load real power
        v_mag = df_v.V1
        i_mag = df_v.I1
        v_ang = df_v.VAngle1
        i_ang = df_v.IAngle1
        load_kW = v_mag .* i_mag .* cos.(deg2rad.(v_ang .- i_ang)) ./ 1000

        # PV power
        pv_s = df_pv[!, Symbol("S1 (kVA)")]
        pv_a = df_pv[!, :Ang1]
        pv_kW = abs.(pv_s .* cos.(deg2rad.(pv_a)))

        used_locally = min.(pv_kW, max.(load_kW, 0))
        load_kWh = sum(max.(load_kW, 0)) * dt_hr
        pv_kWh = sum(pv_kW) * dt_hr
        used_kWh = sum(used_locally) * dt_hr

        sc_pct = pv_kWh > 0 ? 100 * used_kWh / pv_kWh : 0.0

        push!(sc_data, (slot, ld_name, round(load_kWh, digits=2), round(pv_kWh, digits=2), round(sc_pct, digits=1)))
    end

    CSV.write(joinpath(output_dir, "self_consumption_per_slot.csv"), sc_data)
    println("  saved self_consumption_per_slot.csv")

    p5 = bar(sc_data.load_name, sc_data.self_consumption_pct;
        title="Self-consumption ratio per slot (% of PV used locally)",
        xlabel="Load slot", ylabel="Self-consumption (%)",
        ylims=(0, 100),
        rotation=45,
        size=(1400, 600), dpi=200,
        legend=false,
        color=:goldenrod)
    savefig(p5, joinpath(output_dir, "05_self_consumption_per_slot.png"))
    println("  saved 05_self_consumption_per_slot.png")

    println("\nAll analysis outputs written to: $output_dir")

    return (
        compliance = compliance_data,
        self_consumption = sc_data,
        vuf = vuf,
        peak_vuf = peak_data,
    )
end


"""
    compute_vuf(ts, lv_buses)

Compute Voltage Unbalance Factor (VUF) at each bus using two methods:
- IEEE/IEC: |V_negative_seq| / |V_positive_seq| × 100%
- NEMA:    max|V_phase - V_avg| / V_avg × 100%
"""
function compute_vuf(ts::Dict, lv_buses::Vector{String})
    vuf_results = Dict{String, DataFrame}()

    for bus in lv_buses
        m_name = "M_VBUS_$(bus)"
        if !haskey(ts, m_name)
            @warn "No monitor data for bus $bus — skipping VUF"
            continue
        end

        df_v = ts[m_name]
        n = nrow(df_v)

        # Need 3-phase data (V1/V2/V3 + their angles)
        required_cols = [:V1, :V2, :V3, :VAngle1, :VAngle2, :VAngle3]
        if !all(c -> hasproperty(df_v, c), required_cols)
            @warn "Bus $bus monitor lacks 3-phase data — skipping"
            continue
        end

        vuf_iec = zeros(Float64, n)
        vuf_nema = zeros(Float64, n)

        for t in 1:n
            va_mag = df_v.V1[t]
            vb_mag = df_v.V2[t]
            vc_mag = df_v.V3[t]
            va_ang = deg2rad(df_v.VAngle1[t])
            vb_ang = deg2rad(df_v.VAngle2[t])
            vc_ang = deg2rad(df_v.VAngle3[t])

            Va = va_mag * exp(im * va_ang)
            Vb = vb_mag * exp(im * vb_ang)
            Vc = vc_mag * exp(im * vc_ang)

            # Symmetrical components: a = e^(j*120°)
            a = exp(im * 2π / 3)
            V1_seq = (Va + a*Vb + a^2*Vc) / 3   # positive sequence
            V2_seq = (Va + a^2*Vb + a*Vc) / 3   # negative sequence

            # IEC VUF
            vuf_iec[t] = abs(V1_seq) > 1e-3 ? 100 * abs(V2_seq) / abs(V1_seq) : 0.0

            # NEMA VUF
            v_avg = (va_mag + vb_mag + vc_mag) / 3
            max_dev = maximum(abs.([va_mag, vb_mag, vc_mag] .- v_avg))
            vuf_nema[t] = v_avg > 1e-3 ? 100 * max_dev / v_avg : 0.0
        end

        vuf_results[bus] = DataFrame(
            timestep = 1:n,
            vuf_iec = vuf_iec,
            vuf_nema = vuf_nema,
        )
    end

    return vuf_results
end