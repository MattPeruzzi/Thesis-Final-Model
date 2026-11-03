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

# The 25 single-phase load slots (names kept from the original network)
const SLOT_LOAD_NAMES = ["Ld1", "Ld2", "Ld3", "Ld4", "Ld5", "Ld6", "Ld7", "Ld8",
                         "Ld9", "Ld10", "Ld11", "Ld12", "Ld13", "Ld14", "Ld15",
                         "Ld16", "Ld17", "Ld24", "Ld25", "Ld26", "Ld27", "Ld28",
                         "Ld29", "Ld30", "Ld31"]

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
- `mode::Symbol` — `:daily` (a window of whole days, set by start_day/n_days) or
                   `:yearly` (the whole dataset)
- `start_day::Int` — first day of 2019 to simulate (1 = 1 January)
- `n_days::Int` — number of consecutive days to simulate (e.g. 7 for a week)
- `interval_minutes::Int` — time resolution of the data (default 5)
- `transformer_kVA::Float64` — transformer rating (default 200)
- `tap::Float64` — off-load tap on the LV winding in pu (1.0 = nominal 400 V,
                   1.025 = +2.5%, 1.05 = +5%); fixed for the whole run
- `seed::Int` — RNG seed for reproducible consumer-to-slot assignment
- `allocation::Symbol` — `:all` (every consumer used, dealt round-robin into the
                         25 slots, so 2-3 households per connection point) or
                         `:single` (one household per slot)
- `pv_mode::Symbol` — `:dumb` (PV as negative load, no inverter response),
                      `:smart` (PVSystem with AS/NZS 4777.2:2020 control), or
                      `:smart_unity` (PVSystem at unity pf, no Volt-Var/Volt-Watt;
                      diagnostic only, to isolate inverter/STATCOM interaction)
- `statcom_scenario::Symbol` — STATCOM placement (`:none`, `:A_end`, `:B_junction`, `:C_decentralised`)
- `statcom_kva_budget::Float64` — total STATCOM kVA split across the scenario's units (default 75)
- `statcom_control::Symbol` — `:voltvar` (per-phase Volt-Var InvControl) or `:nsc`
                              (coordinated negative-sequence compensation)
- `nsc_objective_buses` — buses whose negative-sequence voltage `:nsc` minimises
- `output_dir::String` — where to save result CSVs
- `write_files::Bool` — write raw monitor CSVs to disk (set false for Monte Carlo runs)

# Returns
NamedTuple: (voltages, summary, timeseries, pv_mode, statcom_scenario,
            statcom_control, statcom_names, statcom_q)
"""
function run_opendss_simulation(
    consumers::Vector{Consumer};
    network_file::AbstractString = "LVNetwork.dss",
    mode::Symbol = :daily,
    start_day::Int = 1,
    n_days::Int = 1,
    interval_minutes::Int = 5,
    transformer_kVA::Float64 = 200.0,
    tap::Float64 = 1.0,
    seed::Int = 42,
    allocation::Symbol = :all,
    pv_mode::Symbol = :smart,
    statcom_scenario::Symbol = :none,
    statcom_kva_budget::Float64 = 75.0,
    statcom_control::Symbol = :voltvar,
    nsc_objective_buses = LV_BUSES,
    output_dir::AbstractString = "opendss_results",
    write_files::Bool = true,
)
    @assert pv_mode in (:dumb, :smart, :smart_unity) "pv_mode must be :dumb, :smart or :smart_unity"
    write_files && mkpath(output_dir)

    println("PV mode: $pv_mode")

    # ------------------------------------------------------------------
    # Define the 25 North-feeder load slots and assign consumers
    # ------------------------------------------------------------------
    slot_load_names = SLOT_LOAD_NAMES
    n_slots = length(slot_load_names)
    n_consumers = length(consumers)

    @assert allocation in (:all, :single) "allocation must be :all or :single"
    @assert n_consumers >= n_slots "Need at least $n_slots consumers, have $n_consumers"
    rng = MersenneTwister(seed)
    shuffled = shuffle(rng, 1:n_consumers)

    if allocation == :all
        # Every consumer is used. The shuffled pool is dealt round-robin into the
        # slots, so each connection point serves 2-3 households (summed), as at a
        # pole or pit feeding several dwellings. The seed changes who shares a slot
        # and which phase they land on.
        slot_assignments = [Int[] for _ in 1:n_slots]
        for (i, ci) in enumerate(shuffled)
            push!(slot_assignments[mod1(i, n_slots)], ci)
        end
    else
        # One household per connection point
        slot_assignments = [[ci] for ci in shuffled[1:n_slots]]
    end

    counts = length.(slot_assignments)
    println("Consumer-to-slot assignment: $(minimum(counts))-$(maximum(counts)) households per slot " *
            "($(sum(counts)) of $n_consumers consumers used, seed $seed)")

    # ------------------------------------------------------------------
    # Determine simulation horizon
    # ------------------------------------------------------------------
    first_df = consumers[1].PV_profile
    npts_total = nrow(first_df)
    sinterval_seconds = interval_minutes * 60

    steps_per_day = round(Int, 24 * 60 / interval_minutes)
    if mode == :daily
        offset      = (start_day - 1) * steps_per_day
        npts_to_use = n_days * steps_per_day
        @assert start_day >= 1 && offset + npts_to_use <= npts_total "Days $start_day to $(start_day + n_days - 1) run past the end of the data"
    else
        offset      = 0
        npts_to_use = npts_total
    end
    window = (offset + 1):(offset + npts_to_use)

    # Daily mode is built around a 24 h clock, so to be safe anything longer than
    # one day runs in yearly mode (same solver; the clock just keeps counting)
    use_yearly = mode == :yearly || n_days > 1

    println("Simulation window: day $(offset ÷ steps_per_day + 1), $(npts_to_use ÷ steps_per_day) day(s), " *
            "$(npts_to_use) timesteps at $(interval_minutes)-min resolution")

    # ------------------------------------------------------------------
    # Build aggregated load and PV profiles per slot
    # ------------------------------------------------------------------
    aggregated_load = zeros(Float64, npts_to_use, n_slots)
    aggregated_pv   = zeros(Float64, npts_to_use, n_slots)
    pv_rating_kW    = zeros(Float64, n_slots)   # full-year peak, so inverter size doesn't depend on the window

    for slot in 1:n_slots
        for ci in slot_assignments[slot]
            df = consumers[ci].PV_profile
            aggregated_load[:, slot] .+= Float64.(df.total_load[window])
            aggregated_pv[:, slot]   .+= max.(Float64.(df.pv_generation[window]), 0.0)
            pv_rating_kW[slot]       += maximum(max.(Float64.(df.pv_generation), 0.0))
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

    # Off-load tap on the LV winding. Real distribution transformers are set a
    # few percent high to leave room for voltage drop along the feeder.
    dss("Edit Transformer.DistTx wdg=2 tap=$(tap)")
    println("Transformer LV tap set to $(tap) pu ($(round(Int, 230 * tap)) V phase-to-neutral at no load)")

    # ------------------------------------------------------------------
    # Inject loadshapes, update each load, and add PV elements
    # ------------------------------------------------------------------
    daily_or_yearly = use_yearly ? "yearly" : "daily"

    for slot in 1:n_slots
        load_name = slot_load_names[slot]
        load_data = aggregated_load[:, slot]
        pv_data   = aggregated_pv[:, slot]

        peak_load_kW = max(maximum(load_data), 1e-3)
        peak_pv_kW   = max(pv_rating_kW[slot], 1e-3)   # system rating = household's full-year peak

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
        # DERList is left empty on purpose: in this OpenDSS version an empty
        # DERList resolves to PVSystems only, so the STATCOM Storage units are
        # not also driven by this controller.

        # Volt-Watt (AS/NZS 4777.2:2020 Australia A): 100% up to 253 V, 20% at 260 V
        dss("New XYCurve.VW_Curve npts=4 " *
            "Xarray=[0.0, 1.1000, 1.1304, 2.0] " *
            "Yarray=[1.0, 1.0, 0.20, 0.20]")

        # Volt-Var (AS/NZS 4777.2:2020 Australia A): 207/220/240/258 V, +44% / -60%
        # Flat end points hold the output at its limits outside 207-258 V
        dss("New XYCurve.VV_Curve npts=6 " *
            "Xarray=[0.50, 0.9000, 0.9565, 1.0435, 1.1217, 1.50] " *
            "Yarray=[0.44, 0.44, 0.0, 0.0, -0.60, -0.60]")

        # InvControl applies both curves to all PVSystems
        dss("New InvControl.InvCtrl mode=VOLTVAR voltage_curvex_ref=rated " *
            "vvc_curve1=VV_Curve voltwatt_curve=VW_Curve " *
            "deltaQ_factor=0.7 deltaP_factor=1.0 EventLog=No " *
            "VoltwattYAxis=PMPPPU")

        println("Applied AS/NZS 4777.2:2020 Volt-Watt + Volt-Var control")
    end

    statcom_names = add_statcom_scenario!(statcom_scenario;
        total_kva_budget = statcom_kva_budget, control = statcom_control)


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
    Solution.Mode(use_yearly ? 2 : 1)
    Solution.Number(1)
    Solution.StepSize(Float64(sinterval_seconds))

    max_control_iter = 100
    dss("Set MaxControlIter=$(max_control_iter)")

    unit_kva = isempty(statcom_names) ? 0.0 : statcom_kva_budget / length(statcom_names)

    println("Solving...")
    statcom_q = step_timeseries!(npts_to_use, Float64(sinterval_seconds);
        statcom_names = statcom_names,
        control = statcom_control,
        objective_buses = nsc_objective_buses,
        kvar_max = unit_kva,
        max_control_iter = max_control_iter)

    # ------------------------------------------------------------------
    # Save monitor data
    # ------------------------------------------------------------------
    dss("Save Monitors")

    # ------------------------------------------------------------------
    # Collect results
    # ------------------------------------------------------------------
    base_results = collect_results(output_dir;
        slot_load_names = slot_load_names, n_slots = n_slots, statcom_names = statcom_names,
        write_files = write_files)

    return (
        voltages = base_results.voltages,
        summary = base_results.summary,
        timeseries = base_results.timeseries,
        pv_mode = pv_mode,
        statcom_scenario = statcom_scenario,
        statcom_control = statcom_control,
        statcom_names = statcom_names,
        statcom_q = statcom_q,
        start_day = offset ÷ steps_per_day + 1,
        n_days = npts_to_use ÷ steps_per_day,
        tap = tap,
        allocation = allocation,
    )
end


"""
    collect_results(output_dir; slot_load_names, n_slots, statcom_names)

After Solve(), pull bus voltages, summary, and monitor time-series into DataFrames.
"""
function collect_results(output_dir::AbstractString;
                         slot_load_names::Vector{String} = String[],
                         n_slots::Int = 0,
                         statcom_names::Vector{String} = String[],
                         write_files::Bool = true)
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

    # ----- Time-series from monitors -----
    monitor_data = read_all_monitors(slot_load_names, n_slots, statcom_names)

    if write_files
        CSV.write(joinpath(output_dir, "node_voltages.csv"), voltages)
        CSV.write(joinpath(output_dir, "summary.csv"), summary)
        ts_dir = joinpath(output_dir, "timeseries")
        mkpath(ts_dir)
        for (name, df) in pairs(monitor_data)
            CSV.write(joinpath(ts_dir, "$(name).csv"), df)
        end
        println("Raw results written to $output_dir ($(length(monitor_data)) monitors)")
    end

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