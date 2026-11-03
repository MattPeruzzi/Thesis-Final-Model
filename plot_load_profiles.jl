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
using Dates
using DataFrames
using Statistics
using CSV


# Okabe-Ito palette — colour-blind safe, print-friendly
const OI_BLUE    = RGB(0.00, 0.45, 0.70)
const OI_ORANGE  = RGB(0.90, 0.60, 0.00)
const OI_GREEN   = RGB(0.00, 0.62, 0.45)
const OI_PURPLE  = RGB(0.80, 0.47, 0.65)
const OI_RED     = RGB(0.84, 0.37, 0.00)
const OI_SKY     = RGB(0.34, 0.71, 0.91)
const OI_BLACK   = RGB(0.00, 0.00, 0.00)

# Plot style settings for all plots (font, size, margins, grid, etc.)
const BASE_STYLE = (
    titlefont     = font(10, "Computer Modern"),
    tickfont      = font(8, "Computer Modern"),
    guidefont     = font(9, "Computer Modern"),
    legendfont    = font(8, "Computer Modern"),
    size          = (630, 280),
    dpi           = 200,
    left_margin   = 4Plots.mm,
    right_margin  = 2Plots.mm,
    top_margin    = 2Plots.mm,
    bottom_margin = 4Plots.mm,
    gridcolor     = :lightgrey,
    gridlinewidth = 0.8,
    framestyle    = :box,
    background_color_inside = :white,
    legend        = :outertop,
    legend_column = -1,
    foreground_color_legend = nothing,
)

# Legend on its own strip above a multi-panel figure, so it never covers data
# and every panel keeps the same size
function legend_strip(entries; ncol::Int = length(entries))
    p = plot(; framestyle = :none, grid = false, xticks = false, yticks = false,
             xlims = (0, 1), ylims = (0, 1), legend = :top, legend_column = ncol,
             legendfont = font(8, "Computer Modern"), foreground_color_legend = nothing)
    for (lab, col, ls) in entries
        plot!(p, [NaN], [NaN]; label = lab, color = col, linestyle = ls, linewidth = 2.2)
    end
    return p
end

with_strip(body, entries; w = 630, h = 260, strip = 0.12, ncol::Int = length(entries)) =
    plot(legend_strip(entries; ncol = ncol), body; layout = grid(2, 1, heights = [strip, 1 - strip]), size = (w, h))

sc_title(lbl, ratio) = "$(uppercasefirst(lbl)) self-consumption (SC = $(round(ratio, digits = 2)))"
sc_short(lbl, ratio) = "$(uppercasefirst(lbl)) (SC = $(round(ratio, digits = 2)))"



function plot_individual_load_profiles( consumers::Vector{Consumer}; output_dir::AbstractString = "plots", year::Int = 2019,)
    # make directory if it doesn't exist. Wont error if it exists already.
    mkpath(output_dir)

    # making a tuple of all data in a data frame for some
    frames = [(id = c.PV_profile.site_id[1],
               df = prepare_working_frame(c.PV_profile)) for c in consumers]
     # Make data frame to store key metrics for each consumer to be written into a CV @ the end
    summary = DataFrame()
    for f in frames
        # Use promote=true to allow adding rows with different types without error
        push!(summary, compute_summary_row(f.df, f.id); promote=true)
    end

    chosen, labels, ratios = select_spectrum_consumers(summary, frames)

    println("Selected for detailed comparison:")
    for (f, lbl, r) in zip(chosen, labels, ratios)
        println("  $lbl self-consumption: $(f.id) (ratio=$(round(r, digits=3)))")
    end
    # Save figures from function calls
    save_fig(build_fleet_average_day(frames),    output_dir, "fleet_01_average_day")
    save_fig(build_fleet_aggregate_day(frames),  output_dir, "fleet_02_aggregate_day")

    save_fig(build_fleet_season(frames, "Summer"), output_dir, "fleet_03_summer")
    save_fig(build_fleet_season(frames, "Autumn"), output_dir, "fleet_03_autumn")
    save_fig(build_fleet_season(frames, "Winter"), output_dir, "fleet_03_winter")
    save_fig(build_fleet_season(frames, "Spring"), output_dir, "fleet_03_spring")

    # All four seasons in one 2x2 figure (appendix), shared y-axis for comparison
    seasons = [plot(build_fleet_season(frames, s); title = s, legend = false)
               for s in ("Summer", "Autumn", "Winter", "Spring")]
    body = plot(seasons...; layout = (2, 2), link = :y, titlefont = font(9, "Computer Modern"))
    save_fig(with_strip(body, [("Mean load", OI_BLUE, :solid), ("Mean PV", OI_ORANGE, :solid)]; h = 500, strip = 0.06),
             output_dir, "fleet_03_seasons_combined")

    save_fig(build_fleet_duration_curve(frames), output_dir, "fleet_04_duration_curve")

    save_fig(build_spectrum_average_day(chosen, labels, ratios),
             output_dir, "compare_01_average_day")
    save_fig(build_spectrum_weekday_weekend(chosen, labels, ratios),
             output_dir, "compare_02_weekday_vs_weekend")
    save_fig(build_spectrum_scatter(chosen, labels, ratios),
             output_dir, "compare_03_load_vs_pv")

    summary_path = joinpath(output_dir, "consumer_summary.csv")
    CSV.write(summary_path, summary)
    println("Summary written: $summary_path")

    return summary
end



function prepare_working_frame(df::DataFrame)
    # strips timezone and adds columns for date, minute of day, is_weekend, season, etc.
    dt = DateTime.(df.localtime)
    return DataFrame(
        localtime     = dt,
        date          = Date.(dt),
        minute_of_day = hour.(dt) .* 60 .+ minute.(dt),
        is_weekend    = dayofweek.(Date.(dt)) .>= 6,
        season        = season_name.(Date.(dt)),
        total_load    = df.total_load,
        pv_generation = max.(df.pv_generation, 0.0),
    )
end

function season_name(d::Date)
    # Elects what season the date falls into for season comparison.
    m = month(d)
    m in (12, 1, 2) && return "Summer"
    m in (3, 4, 5)  && return "Autumn"
    m in (6, 7, 8)  && return "Winter"
    return "Spring"
end



# Fleet-level: mean household shape (average across consumers, then plot)
function build_fleet_average_day(frames)
    # groupby minute_of_day for each consumer, then combine to get mean and percentiles across consumers for each minute_of_day
    per_consumer = [combine(groupby(f.df, :minute_of_day),
                            :total_load    => mean => :load,
                            :pv_generation => mean => :pv)
                    for f in frames]
    # merge all per-customer data into one df and group by minute of day to get mean & percentiles across consumers
    merged = vcat(per_consumer...)
    fleet  = combine(groupby(merged, :minute_of_day),
                     :load => mean => :load_mean,
                     :pv   => mean => :pv_mean,
                     :load => (x -> quantile(x, 0.10)) => :load_p10,
                     :load => (x -> quantile(x, 0.90)) => :load_p90,
                     :pv   => (x -> quantile(x, 0.10)) => :pv_p10,
                     :pv   => (x -> quantile(x, 0.90)) => :pv_p90)
    sort!(fleet, :minute_of_day)
    hrs = fleet.minute_of_day ./ 60

    p = plot(hrs, fleet.load_mean;
        label="Mean load per household", color=OI_BLUE, linewidth=2.5,
        ribbon=(fleet.load_mean .- fleet.load_p10, fleet.load_p90 .- fleet.load_mean),
        fillalpha=0.18, fillcolor=OI_BLUE,
        xlabel="Time of day (hours)", ylabel="Power per household (kW)",
        xticks=0:3:24, xlims=(0, 24), grid=:both, BASE_STYLE...)

    plot!(p, hrs, fleet.pv_mean;
        label="Mean PV per household", color=OI_ORANGE, linewidth=2.5,
        ribbon=(fleet.pv_mean .- fleet.pv_p10, fleet.pv_p90 .- fleet.pv_mean),
        fillalpha=0.18, fillcolor=OI_ORANGE)
    return p
end



# Fleet-level: aggregate demand (sum across all consumers)
function build_fleet_aggregate_day(frames)
    per_consumer = [combine(groupby(f.df, :minute_of_day),
                            :total_load    => mean => :load,
                            :pv_generation => mean => :pv)
                    for f in frames]
    agg = per_consumer[1][:, [:minute_of_day]]
    agg.load_total = sum(pc.load for pc in per_consumer)
    agg.pv_total   = sum(pc.pv   for pc in per_consumer)
    sort!(agg, :minute_of_day)
    hrs = agg.minute_of_day ./ 60

    p = plot(hrs, agg.load_total;
        label="Aggregate load", color=OI_BLUE, linewidth=2.5,
        xlabel="Time of day (hours)", ylabel="Total fleet power (kW)",
        xticks=0:3:24, xlims=(0, 24), grid=:both, BASE_STYLE...)
    plot!(p; legend_column = 2)

    plot!(p, hrs, agg.pv_total;
          label="Aggregate PV", color=OI_ORANGE, linewidth=2.5)

    plot!(p, hrs, agg.load_total .- agg.pv_total;
          label="Net demand (load - PV)", color=OI_RED,
          linewidth=2.2, linestyle=:dash)

    return p
end


# Seasonal plots
function build_fleet_season(frames, season::String)
    merged = reduce(vcat, (f.df for f in frames))
    g = sort(combine(groupby(filter(:season => ==(season), merged), :minute_of_day),
                     :total_load    => mean => :load,
                     :pv_generation => mean => :pv),
             :minute_of_day)
    hrs = g.minute_of_day ./ 60

    p = plot(hrs, g.load;
        label="Mean load", color=OI_BLUE, linewidth=2.5,
        xlabel="Time of day (hours)", ylabel="Power per household (kW)",
        xticks=0:3:24, xlims=(0, 24), grid=:both, BASE_STYLE...)

    plot!(p, hrs, g.pv;
          label="Mean PV", color=OI_ORANGE, linewidth=2.5)
    return p
end



# load duration curve (aggregate)
function build_fleet_duration_curve(frames)
    ref = frames[1].df[:, [:localtime]]
    load_sum = zeros(nrow(ref))
    pv_sum   = zeros(nrow(ref))
    for f in frames
        load_sum .+= f.df.total_load
        pv_sum   .+= f.df.pv_generation
    end

    load_sorted = sort(load_sum; rev=true)
    pv_sorted   = sort(pv_sum;   rev=true)
    pct = (1:length(load_sorted)) ./ length(load_sorted) .* 100

    p = plot(pct, load_sorted;
        label="Aggregate load", color=OI_BLUE, linewidth=2.5,
        xlabel="Percent of year (%)", ylabel="Total fleet power (kW)",
        xticks=0:10:100, xlims=(0, 100), grid=:both, BASE_STYLE...)

    plot!(p, pct, pv_sorted;
          label="Aggregate PV", color=OI_ORANGE, linewidth=2.5)
    return p
end


# Picking 3 consumers spanning the self-consumption range
function select_spectrum_consumers(summary::DataFrame, frames)
    sorted = sort(summary, :self_consumption_ratio)
    n = nrow(sorted)
    idx_lo  = max(1, round(Int, n * 0.25))
    idx_mid = round(Int, n * 0.50)
    idx_hi  = min(n, round(Int, n * 0.75))

    ids = (sorted.id[idx_lo], sorted.id[idx_mid], sorted.id[idx_hi])
    labels = ("low", "medium", "high")
    ratios = (sorted.self_consumption_ratio[idx_lo],
              sorted.self_consumption_ratio[idx_mid],
              sorted.self_consumption_ratio[idx_hi])
    chosen = [first(f for f in frames if f.id == id) for id in ids]
    return chosen, labels, ratios
end


# Comparison: 3 consumers, average daily shape
function build_spectrum_average_day(chosen, labels, ratios)
    colours = (OI_BLUE, OI_GREEN, OI_RED)
    p = plot(; xlabel="Time of day (hours)", ylabel="Power (kW)",
             xticks=0:3:24, xlims=(0, 24), grid=:both,
             merge(BASE_STYLE, (legend = false,))...)

    entries = []
    for (f, lbl, ratio, col) in zip(chosen, labels, ratios, colours)
        g = sort(combine(groupby(f.df, :minute_of_day),
                         :total_load    => mean => :load,
                         :pv_generation => mean => :pv),
                 :minute_of_day)
        hrs = g.minute_of_day ./ 60
        plot!(p, hrs, g.load; color=col, linewidth=2.2)
        plot!(p, hrs, g.pv;   color=col, linewidth=1.8, linestyle=:dash)
        push!(entries, (sc_title(lbl, ratio), col, :solid))
    end
    push!(entries, ("Load (solid) / PV (dashed)", OI_BLACK, :dash))
    return with_strip(p, entries; h = 320, strip = 0.18, ncol = 2)
end


# Comparison: 3 consumers, weekday vs weekend (3 small panels)
function build_spectrum_weekday_weekend(chosen, labels, ratios)
    panels = []
    for (k, (f, lbl, ratio)) in enumerate(zip(chosen, labels, ratios))
        g = sort(combine(groupby(f.df, [:minute_of_day, :is_weekend]),
                         :total_load => mean => :load),
                 [:is_weekend, :minute_of_day])
        weekday = filter(:is_weekend => ==(false), g)
        weekend = filter(:is_weekend => ==(true),  g)

        pnl = plot(weekday.minute_of_day ./ 60, weekday.load;
            color=OI_BLUE, linewidth=2.0,
            xlabel="Hour of day", ylabel=k == 1 ? "Load (kW)" : "",
            title=sc_short(lbl, ratio),
            xticks=0:6:24, xlims=(0, 24), legend=false, grid=:both, framestyle=:box,
            titlefont=font(8, "Computer Modern"),
            tickfont=font(7, "Computer Modern"),
            guidefont=font(8, "Computer Modern"))
        plot!(pnl, weekend.minute_of_day ./ 60, weekend.load;
              color=OI_ORANGE, linewidth=2.0, linestyle=:dash)
        push!(panels, pnl)
    end
    body = plot(panels...; layout=(1, 3), left_margin=3Plots.mm, bottom_margin=4Plots.mm)
    return with_strip(body, [("Weekday", OI_BLUE, :solid), ("Weekend", OI_ORANGE, :dash)];
                      h = 260, strip = 0.12)
end


# Comparison: 3 consumers, load vs PV scatter (3 small panels)
function build_spectrum_scatter(chosen, labels, ratios)
    lim = maximum(
        maximum(f.df.total_load, init=0.0) |>
        x -> max(x, maximum(f.df.pv_generation, init=0.0))
        for f in chosen
    )

    panels = []
    for (k, (f, lbl, ratio)) in enumerate(zip(chosen, labels, ratios))
        pnl = scatter(f.df.pv_generation, f.df.total_load;
            label="", color=OI_BLUE, markersize=1.2,
            markerstrokewidth=0, alpha=0.06,
            xlabel="PV generation (kW)", ylabel=k == 1 ? "Total load (kW)" : "",
            title=sc_short(lbl, ratio),
            xlims=(0, lim), ylims=(0, lim), aspect_ratio=:equal,
            legend=false, grid=:both, framestyle=:box,
            titlefont=font(8, "Computer Modern"),
            tickfont=font(7, "Computer Modern"),
            guidefont=font(8, "Computer Modern"))
        plot!(pnl, [0, lim], [0, lim];
              color=OI_BLACK, linewidth=1.2, linestyle=:dash, label="")
        push!(panels, pnl)
    end
    body = plot(panels...; layout=(1, 3), left_margin=3Plots.mm, bottom_margin=4Plots.mm)
    return with_strip(body, [("Load = PV (above the line, all PV is used on site)", OI_BLACK, :dash)];
                      h = 260, strip = 0.1)
end



# Summary row per consumer
function compute_summary_row(df::DataFrame, id)
    # All units in kW / kWh (total_load and pv_generation are in kW from upstream loader)
    total_load_kwh = sum(df.total_load)    * (5 / 60)
    total_pv_kwh   = sum(df.pv_generation) * (5 / 60)

    daily = combine(groupby(df, :date),
                    :total_load    => maximum => :peak_load,
                    :pv_generation => maximum => :peak_pv)

    pv_used_onsite   = sum(min.(df.pv_generation, df.total_load)) * (5 / 60)
    self_consumption = total_pv_kwh > 0 ? pv_used_onsite / total_pv_kwh : 0.0

    return (
        id                     = id,
        annual_load_kWh        = round(total_load_kwh, digits=2),
        annual_pv_kWh          = round(total_pv_kwh,   digits=2),
        peak_load_kW           = round(maximum(daily.peak_load), digits=3),
        peak_load_date         = daily.date[argmax(daily.peak_load)],
        peak_pv_kW             = round(maximum(daily.peak_pv), digits=3),
        peak_pv_date           = daily.date[argmax(daily.peak_pv)],
        self_consumption_ratio = round(self_consumption, digits=3),
    )
end



# Helper function to save a plot with a consistent naming convention in the output directory.
function save_fig(p, output_dir, suffix)
    # Vector PDF for the thesis. The load-vs-PV scatter has ~300k points, which
    # makes a huge, slow PDF, so that one is saved as a high-resolution PNG.
    if occursin("load_vs_pv", suffix)
        out_path = joinpath(output_dir, "$(suffix).png")
        savefig(plot(p; dpi = 300), out_path)
    else
        out_path = joinpath(output_dir, "$(suffix).pdf")
        savefig(p, out_path)
    end
    println("Saved: $out_path")
end