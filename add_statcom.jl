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
# All STATCOM scenarios are implemented as single-phase Storage elements with
# kW=0, so that they exchange only reactive power with the network. Placement
# is the only thing that differs between scenarios; the control law is selected
# with `control`:
#   :voltvar  legacy per-phase Volt-Var InvControl (kept for comparison)
#   :nsc      coordinated negative-sequence compensation; no InvControl is
#             created, setpoints are written every timestep by
#             step_timeseries! in nsc_controller.jl
# -----------------------------------------------------------------------------
 
const STATCOM_SITES = Dict{Symbol, Vector{Tuple{String, Int}}}(
    :A_end           => [("NorthSpine_End", 1), ("NorthSpine_End", 2), ("NorthSpine_End", 3)],
    :B_junction      => [("FN_Trunk", 1), ("FN_Trunk", 2), ("FN_Trunk", 3)],
    :C_decentralised => [("NorthSpine_End", 1), ("West_End_B", 2), ("East_South_End", 3)],
)
 
# One single-phase unit, phase-to-neutral. kWrated is tied to kVA and
# %IdlingkW=0, otherwise OpenDSS's defaults (kWrated=25, %IdlingkW=1) make every
# "STATCOM" draw a constant 0.25 kW of idling loss from its phase.
function add_statcom!(bus::String, phase::Int, kva::Float64)
    name = "Statcom_$(bus)_$(phase)"
    k = round(kva, digits=2)
    dss("New Storage.$(name) phases=1 bus1=$(bus).$(phase).4 kV=0.23 " *
        "kVA=$(k) kWrated=$(k) kW=0 kvarMax=$(k) kvarMaxAbs=$(k) " *
        "kWhrated=0.1 %stored=0 %reserve=0 %IdlingkW=0 " *
        # Stay constant-power across the whole voltage range seen. OpenDSS's
        # default (0.9-1.1 pu) switches to constant impedance outside that band,
        # which lets the output scale with V^2 past the unit's rating.
        "Vminpu=0.7 Vmaxpu=1.3 state=idling")
    return name
end
 
"""
    add_statcom_scenario!(scenario; total_kva_budget=75.0, control=:voltvar)
 
Builds the STATCOM units for the chosen placement scenario (:none, :A_end,
:B_junction, :C_decentralised). total_kva_budget is split evenly across the
scenario's units so total capacity is identical across A/B/C.
 
Returns the Storage element names (empty for :none).
"""
function add_statcom_scenario!(scenario::Symbol;
                               total_kva_budget::Float64 = 75.0,
                               control::Symbol = :voltvar)
    scenario == :none && return String[]
    haskey(STATCOM_SITES, scenario) || error("Unknown STATCOM scenario: $scenario")
    control in (:voltvar, :nsc) || error("Unknown STATCOM control: $control")
 
    sites = STATCOM_SITES[scenario]
    kva = total_kva_budget / length(sites)
    statcom_names = [add_statcom!(bus, ph, kva) for (bus, ph) in sites]
 
    if control == :voltvar
        dss("New XYCurve.Statcom_VV_Curve npts=4 " *
            "Xarray=[0.94, 0.98, 1.02, 1.06] Yarray=[1.0, 0.0, 0.0, -1.0]")
        der_list = join(["Storage.$(n)" for n in statcom_names], ", ")
        dss("New InvControl.Statcom_Ctrl mode=VOLTVAR voltage_curvex_ref=rated " *
            "vvc_curve1=Statcom_VV_Curve DERList=[$(der_list)] EventLog=Yes")
    end
    # control == :nsc: nothing else to build, setpoints come from the stepper
 
    println("STATCOM scenario :$scenario ($control), $(length(statcom_names)) unit(s), " *
            "$(round(kva, digits=1)) kVA each")
    return statcom_names
end
 