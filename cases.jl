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
# Case definitions shared by run.jl, compare_results.jl and plot_results.jl.
# Cases 3-5 are each run under both STATCOM control laws, giving 8 runs in total.
# These are plain globals (not const) so the file can be re-included freely.
# -----------------------------------------------------------------------------

CASES = [
    (id = :case1,     label = "Case 1",       name = "Legacy PV",
     pv = :dumb,  scenario = :none,            control = :voltvar),
    (id = :case2,     label = "Case 2",       name = "AS/NZS 4777.2 PV",
     pv = :smart, scenario = :none,            control = :voltvar),
    (id = :case3_vv,  label = "Case 3 (VV)",  name = "End of north spine, Volt-Var",
     pv = :smart, scenario = :A_end,           control = :voltvar),
    (id = :case3_nsc, label = "Case 3 (NSC)", name = "End of north spine, NSC",
     pv = :smart, scenario = :A_end,           control = :nsc),
    (id = :case4_vv,  label = "Case 4 (VV)",  name = "Main junction, Volt-Var",
     pv = :smart, scenario = :B_junction,      control = :voltvar),
    (id = :case4_nsc, label = "Case 4 (NSC)", name = "Main junction, NSC",
     pv = :smart, scenario = :B_junction,      control = :nsc),
    (id = :case5_vv,  label = "Case 5 (VV)",  name = "Distributed, Volt-Var",
     pv = :smart, scenario = :C_decentralised, control = :voltvar),
    (id = :case5_nsc, label = "Case 5 (NSC)", name = "Distributed, NSC",
     pv = :smart, scenario = :C_decentralised, control = :nsc),
]

CASE_BY_ID = Dict(c.id => c for c in CASES)

# The three STATCOM placements (case number -> code scenario)
PLACEMENTS = [
    (n = 3, scenario = :A_end,           name = "End of north spine"),
    (n = 4, scenario = :B_junction,      name = "Main junction"),
    (n = 5, scenario = :C_decentralised, name = "Distributed"),
]

# e.g. statcom_case_id(3, :nsc) -> :case3_nsc
statcom_case_id(n::Int, control::Symbol) = Symbol("case$(n)_", control == :nsc ? "nsc" : "vv")

# Buses in feeder order (trunk, north spine, west branch, east branch) and the
# short names used on the topology figure
BUS_ORDER = ["TxSecondary", "FN_Trunk",
             "NorthSpine_1", "NorthSpine_2", "NorthSpine_End",
             "West_1", "West_2", "West_Junction", "West_End_A", "West_End_B",
             "East_1", "East_Junction", "East_North_1", "East_North_End",
             "East_South_1", "East_South_End"]

BUS_SHORT = ["Tx", "FN",
             "N1", "N2", "N end",
             "W1", "W2", "Wj", "Wa", "Wb",
             "E1", "Ej", "EN1", "EN end",
             "ES1", "ES end"]
