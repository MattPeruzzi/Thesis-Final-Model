# -----------------------------------------------------------------------------
# Note on AI assistance:
# An AI assistant (Anthropic's Claude) was used to improve the readability of
# this code — formatting, comments, variable naming, and structural clean-up.
# The underlying logic, methodology, and implementation are the author's own.
# -----------------------------------------------------------------------------

using OpenDSSDirect
using DataFrames
using CSV
using Random
using Statistics
using Dates


# ----------------------------------------------------------------------
# LV bus list — used for bus-level voltage monitors (VUF computation).
# These are the 16 LV buses on the North feeder.
# ----------------------------------------------------------------------
const LV_BUSES = ["TxSecondary", "FN_Trunk",
                  "NorthSpine_1", "NorthSpine_2", "NorthSpine_End",
                  "West_1", "West_2", "West_Junction", "West_End_A", "West_End_B",
                  "East_1", "East_Junction", "East_North_1", "East_North_End",
                  "East_South_1", "East_South_End"]

# Each bus is monitored via the line that terminates at it.
const BUS_TO_LINE = Dict(
    "TxSecondary"      => ("L_TxSecondary__FN_Trunk", 1),
    "FN_Trunk"         => ("L_TxSecondary__FN_Trunk", 2),
    "NorthSpine_1"     => ("L_FN_Trunk__NorthSpine_1", 2),
    "NorthSpine_2"     => ("L_NorthSpine_1__NorthSpine_2", 2),
    "NorthSpine_End"   => ("L_NorthSpine_2__NorthSpine_End", 2),
    "West_1"           => ("L_FN_Trunk__West_1", 2),
    "West_2"           => ("L_West_1__West_2", 2),
    "West_Junction"    => ("L_West_2__West_Junction", 2),
    "West_End_A"       => ("L_West_Junction__West_End_A", 2),
    "West_End_B"       => ("L_West_Junction__West_End_B", 2),
    "East_1"           => ("L_FN_Trunk__East_1", 2),
    "East_Junction"    => ("L_East_1__East_Junction", 2),
    "East_North_1"     => ("L_East_Junction__East_North_1", 2),
    "East_North_End"   => ("L_East_North_1__East_North_End", 2),
    "East_South_1"     => ("L_East_Junction__East_South_1", 2),
    "East_South_End"   => ("L_East_South_1__East_South_End", 2),
)


"""
    run_opendss_simulation(consumers; kwargs...)

Aggregate consumer profiles into the North feeder's 25 LV load points,
inject them into OpenDSS as Loads + (dumb or smart) PV elements, run a
simulation, and return time-series + snapshot results.

# Arguments
- `consumers::Vector{Consumer}` — consumer objects from load_consumer_profiles.jl
- `network_file::String` — path to LVNetwork.dss
- `mode::Symbol` — `:daily` (one day) or `:yearly` (full year)
- `interval_minutes::Int` — time resolution of the data (default 5)
- `transformer_kVA::Float64` — transformer rating (default 200)
- `seed::Int` — RNG seed for reproducible consumer-to-slot assignment
- `pv_mode::Symbol` — `:dumb` (PV as negative load, no inverter response)
                      or `:smart` (PVSystem with AS/NZS 4777.2:2020 control)
- `statcom_scenario::Symbol` — STATCOM placement (`:none`, `:A_end`, `:B_junction`, `:C_decentralised`)
- `statcom_kva_budget::Float64` — total STATCOM kVA split across the scenario's units (default 75)
- `output_dir::String` — where to save result CSVs

# Returns
NamedTuple: (voltages, summary, timeseries, pv_mode, statcom_scenario, statcom_names)
"""
function run_opendss_simulation(
    consumers::Vector{Consumer};
    network_file::AbstractString = "LVNetwork.dss",
    mode::Symbol = :daily,
    interval_minutes::Int = 5,
    transformer_kVA::Float64 = 200.0,
    seed::Int = 42,
    pv_mode::Symbol = :smart,
    statcom_scenario::Symbol = :none,
    statcom_kva_budget::Float64 = 75.0,
    output_dir::AbstractString = "opendss_results",
)
    @assert pv_mode in (:dumb, :smart) "pv_mode must be :dumb or :smart"
    mkpath(output_dir)

    println("PV mode: $pv_mode")

    # ------------------------------------------------------------------
    # Define the 25 North-feeder load slots and assign consumers
    # ------------------------------------------------------------------
    slot_load_names = ["Ld1", "Ld2", "Ld3", "Ld4", "Ld5", "Ld6", "Ld7", "Ld8",
                       "Ld9", "Ld10", "Ld11", "Ld12", "Ld13", "Ld14", "Ld15",
                       "Ld16", "Ld17", "Ld24", "Ld25", "Ld26", "Ld27", "Ld28",
                       "Ld29", "Ld30", "Ld31"]
    n_slots = length(slot_load_names)
    n_consumers = length(consumers)

    rng = MersenneTwister(seed)
    shuffled_indices = shuffle(rng, 1:n_consumers)

    slot_assignments = [Int[] for _ in 1:n_slots]
    for (i, ci) in enumerate(shuffled_indices)
        slot = ((i - 1) % n_slots) + 1
        push!(slot_assignments[slot], ci)
    end

    counts = length.(slot_assignments)
    println("Consumer-to-slot assignment: $(minimum(counts))–$(maximum(counts)) consumers per slot (mean $(round(mean(counts), digits=1)))")

    # ------------------------------------------------------------------
    # Determine simulation horizon
    # ------------------------------------------------------------------
    first_df = consumers[1].PV_profile
    npts_total = nrow(first_df)
    sinterval_seconds = interval_minutes * 60

    npts_to_use = mode == :daily ?
        min(round(Int, 24 * 60 / interval_minutes), npts_total) :
        npts_total

    println("Simulation mode: $mode  ($(npts_to_use) timesteps at $(interval_minutes)-min resolution)")

    # ------------------------------------------------------------------
    # Build aggregated load and PV profiles per slot
    # ------------------------------------------------------------------
    aggregated_load = zeros(Float64, npts_to_use, n_slots)
    aggregated_pv   = zeros(Float64, npts_to_use, n_slots)

    for slot in 1:n_slots
        for ci in slot_assignments[slot]
            df = consumers[ci].PV_profile
            aggregated_load[:, slot] .+= Float64.(df.total_load[1:npts_to_use])
            aggregated_pv[:, slot]   .+= max.(Float64.(df.pv_generation[1:npts_to_use]), 0.0)
        end
    end

    # ------------------------------------------------------------------
    # Compile the existing network
    # ------------------------------------------------------------------
    dss("Clear")
    dss("Compile \"$network_file\"")
    println("Compiled network: $network_file")

    # ------------------------------------------------------------------
    # Set transformer rating
    # ------------------------------------------------------------------
    dss("Edit Transformer.DistTx kVAs=[$(transformer_kVA) $(transformer_kVA)]")
    println("Transformer set to $(transformer_kVA) kVA")

    # ------------------------------------------------------------------
    # Inject loadshapes, update each load, and add PV elements
    # ------------------------------------------------------------------
    daily_or_yearly = mode == :daily ? "daily" : "yearly"

    for slot in 1:n_slots
        load_name = slot_load_names[slot]
        load_data = aggregated_load[:, slot]
        pv_data   = aggregated_pv[:, slot]

        peak_load_kW = max(maximum(load_data), 1e-3)
        peak_pv_kW   = max(maximum(pv_data),   1e-3)

        # Per-unit loadshape multipliers
        load_pu = load_data ./ peak_load_kW
        pv_pu   = pv_data   ./ peak_pv_kW

        # ---- Create the load's loadshape ----
        ls_load_name = "LS_Slot$(slot)"
        dss("New LoadShape.$(ls_load_name) npts=$(npts_to_use) sinterval=$(sinterval_seconds) mult=(0)")
        LoadShape.Name(ls_load_name)
        LoadShape.PMult(load_pu)

        # ---- Create the PV's loadshape ----
        ls_pv_name = "LS_PV$(slot)"
        dss("New LoadShape.$(ls_pv_name) npts=$(npts_to_use) sinterval=$(sinterval_seconds) mult=(0)")
        LoadShape.Name(ls_pv_name)
        LoadShape.PMult(pv_pu)

        # ---- Update existing load with new kW and loadshape ----
        dss("Edit Load.$(load_name) kW=$(round(peak_load_kW, digits=3)) $(daily_or_yearly)=$(ls_load_name)")

        # ---- Add the PV element ----
        Loads.Name(load_name)
        bus = CktElement.BusNames()[1]

        if pv_mode == :dumb
            # PV as negative load (2019-era, no inverter response)
            dss("New Load.PV$(slot) bus1=$(bus) phases=1 kV=0.23 " *
                "kW=-$(round(peak_pv_kW, digits=3)) pf=1.0 model=1 " *
                "$(daily_or_yearly)=$(ls_pv_name)")
        else
            # AS/NZS 4777.2:2020 smart inverter
            inverter_kVA = round(peak_pv_kW * 1.05, digits=3)
            dss("New PVSystem.PV$(slot) bus1=$(bus) phases=1 kV=0.23 " *
                "kVA=$(inverter_kVA) Pmpp=$(round(peak_pv_kW, digits=3)) " *
                "irradiance=1.0 %cutin=0.1 %cutout=0.1 " *
                "VarFollowInverter=true wattpriority=true " *
                "$(daily_or_yearly)=$(ls_pv_name)")
        end
    end

    println("Injected $(n_slots) loadshapes + PV elements ($pv_mode mode)")

    # ------------------------------------------------------------------
    # Define inverter control curves (smart mode only)
    # ------------------------------------------------------------------
    if pv_mode == :smart
        # Volt-Watt curve: full power below 1.06 pu, ramping to 20% at 1.10 pu
        dss("New XYCurve.VW_Curve npts=4 " *
            "Xarray=[0.0, 1.06, 1.10, 2.0] " *
            "Yarray=[1.0, 1.0, 0.20, 0.20]")

        # Volt-Var curve: capacitive below 0.98, deadband 0.98-1.02, inductive above 1.02
        dss("New XYCurve.VV_Curve npts=4 " *
            "Xarray=[0.92, 0.98, 1.02, 1.08] " *
            "Yarray=[0.44, 0.0, 0.0, -0.60]")

        # InvControl applies both curves to all PVSystems
        dss("New InvControl.InvCtrl mode=VOLTVAR voltage_curvex_ref=rated " *
            "vvc_curve1=VV_Curve voltwatt_curve=VW_Curve " *
            "deltaQ_factor=0.7 deltaP_factor=1.0 EventLog=No " *
            "VoltwattYAxis=PMPPPU")

        println("Applied AS/NZS 4777.2:2020 Volt-Watt + Volt-Var control")
    end

    statcom_names = add_statcom_scenario!(statcom_scenario; total_kva_budget = statcom_kva_budget)


    # ------------------------------------------------------------------
    # Add monitors for time-series recording
    # ------------------------------------------------------------------
    # Voltage monitors on every load (mode=0 = V/I)
    for slot in 1:n_slots
        load_name = slot_load_names[slot]
        dss("New Monitor.M_V_$(load_name) element=Load.$(load_name) terminal=1 mode=0")
    end

    # Power monitors on every PV element (Load if dumb, PVSystem if smart)
    pv_class = pv_mode == :dumb ? "Load" : "PVSystem"
    for slot in 1:n_slots
        dss("New Monitor.M_P_PV$(slot) element=$(pv_class).PV$(slot) terminal=1 mode=1")
    end

    for name in statcom_names
        dss("New Monitor.M_Q_$(name) element=Storage.$(name) terminal=1 mode=1")
    end

    # Power monitor on the transformer secondary (mode=1)
    dss("New Monitor.M_P_Tx element=Transformer.DistTx terminal=2 mode=1")

    # Current monitors on key trunk lines (mode=0)
    dss("New Monitor.M_I_FN_Trunk element=Line.L_TxSecondary__FN_Trunk terminal=1 mode=0")
    dss("New Monitor.M_I_West element=Line.L_FN_Trunk__West_1 terminal=1 mode=0")
    dss("New Monitor.M_I_East element=Line.L_FN_Trunk__East_1 terminal=1 mode=0")

    # Bus-level voltage monitors (3-phase) for VUF computation
    for bus in LV_BUSES
        line_name, terminal = BUS_TO_LINE[bus]
        dss("New Monitor.M_VBUS_$(bus) element=Line.$(line_name) terminal=$(terminal) mode=0")
    end

    n_monitors = 2 * n_slots + 4 + length(LV_BUSES) + length(statcom_names)
    println("Added $(n_monitors) monitors")

    # ------------------------------------------------------------------
    # Configure and solve
    # ------------------------------------------------------------------
    Solution.Mode(mode == :daily ? 1 : 2)
    Solution.Number(npts_to_use)
    Solution.StepSize(Float64(sinterval_seconds))
    Solution.Hour(0.0)
    Solution.Seconds(0.0)

    dss("Set MaxControlIter=100")

    println("Solving...")
    Solution.Solve()

    if !Solution.Converged()
        @warn "Solution did not converge!"
    else
        println("Solution converged ✓")
    end

    # ------------------------------------------------------------------
    # Save monitor data
    # ------------------------------------------------------------------
    println("Saving monitor data...")
    dss("Save Monitors")

    # ------------------------------------------------------------------
    # Collect results
    # ------------------------------------------------------------------
    base_results = collect_results(output_dir;
        slot_load_names = slot_load_names, n_slots = n_slots, statcom_names = statcom_names)

    return (
        voltages = base_results.voltages,
        summary = base_results.summary,
        timeseries = base_results.timeseries,
        pv_mode = pv_mode,
        statcom_scenario = statcom_scenario,
        statcom_names = statcom_names,
    )
end


"""
    collect_results(output_dir; slot_load_names, n_slots, statcom_names)

After Solve(), pull bus voltages, summary, and monitor time-series into DataFrames.
"""
function collect_results(output_dir::AbstractString;
                         slot_load_names::Vector{String} = String[],
                         n_slots::Int = 0,
                         statcom_names::Vector{String} = String[])
    bus_names    = Circuit.AllBusNames()
    node_vmag_pu = Circuit.AllBusMagPu()
    node_names   = Circuit.AllNodeNames()

    voltages = DataFrame(node = node_names, vmag_pu = node_vmag_pu)

    phase_mask = [!startswith(name, "0.") &&
                  (endswith(name, ".1") || endswith(name, ".2") || endswith(name, ".3"))
                  for name in node_names]
    phase_vmag = node_vmag_pu[phase_mask]

    total_power  = Circuit.TotalPower()
    total_losses = Circuit.Losses()

    total_p  = real(total_power)
    total_q  = imag(total_power)
    losses_p = real(total_losses)
    losses_q = imag(total_losses)

    summary = DataFrame(
        metric = ["total_active_power_kW", "total_reactive_power_kvar",
                  "total_losses_W", "total_losses_var",
                  "min_phase_voltage_pu", "max_phase_voltage_pu",
                  "mean_phase_voltage_pu", "n_buses", "n_phase_nodes",
                  "n_total_nodes"],
        value  = [total_p, total_q, losses_p, losses_q,
                  minimum(phase_vmag), maximum(phase_vmag),
                  mean(phase_vmag),
                  Float64(length(bus_names)),
                  Float64(length(phase_vmag)),
                  Float64(length(node_vmag_pu))],
    )

    CSV.write(joinpath(output_dir, "node_voltages.csv"), voltages)
    CSV.write(joinpath(output_dir, "summary.csv"), summary)
    println("Snapshot results written to $output_dir")

    # ----- Time-series from monitors -----
    monitor_data = read_all_monitors(slot_load_names, n_slots, statcom_names)

    ts_dir = joinpath(output_dir, "timeseries")
    mkpath(ts_dir)
    for (name, df) in pairs(monitor_data)
        CSV.write(joinpath(ts_dir, "$(name).csv"), df)
    end
    println("Time-series data written to $ts_dir ($(length(monitor_data)) monitors)")

    return (voltages = voltages, summary = summary, timeseries = monitor_data)
end


"""
    read_all_monitors(slot_load_names, n_slots, statcom_names)

Pull every monitor's data into Julia DataFrames.
"""
function read_all_monitors(slot_load_names::Vector{String}, n_slots::Int,
                           statcom_names::Vector{String} = String[])
    data = Dict{String, DataFrame}()

    for load_name in slot_load_names
        m_name = "M_V_$(load_name)"
        df = read_monitor_to_df(m_name)
        if df !== nothing
            data[m_name] = df
        end
    end

    for slot in 1:n_slots
        m_name = "M_P_PV$(slot)"
        df = read_monitor_to_df(m_name)
        if df !== nothing
            data[m_name] = df
        end
    end

    for m_name in ["M_P_Tx", "M_I_FN_Trunk", "M_I_West", "M_I_East"]
        df = read_monitor_to_df(m_name)
        if df !== nothing
            data[m_name] = df
        end
    end

    for bus in LV_BUSES
        m_name = "M_VBUS_$(bus)"
        df = read_monitor_to_df(m_name)
        if df !== nothing
            data[m_name] = df
        end
    end

    for name in statcom_names
        m_name = "M_Q_$(name)"
        df = read_monitor_to_df(m_name)
        if df !== nothing
            data[m_name] = df
        end
    end

    return data
end


"""
    read_monitor_to_df(monitor_name)

Read one monitor's data into a DataFrame. Returns nothing if read fails.
"""
function read_monitor_to_df(monitor_name::AbstractString)
    try
        Monitors.Name(monitor_name)
        headers = Monitors.Header()
        n_channels = Monitors.NumChannels()
        n_samples  = Monitors.SampleCount()

        if n_samples == 0
            @warn "Monitor $monitor_name has no samples"
            return nothing
        end

        df = DataFrame(timestep = 1:n_samples)
        for ch in 1:n_channels
            channel_data = Monitors.Channel(ch)
            df[!, Symbol(headers[ch])] = channel_data
        end

        return df
    catch e
        @warn "Could not read monitor $monitor_name: $e"
        return nothing
    end
end