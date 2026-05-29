# -----------------------------------------------------------------------------
# Note on AI assistance:
# An AI assistant (Anthropic's Claude) was used to improve the readability of
# this code — formatting, comments, variable naming, and structural clean-up.
# The underlying logic, methodology, and implementation are the author's own.
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
    titlefont     = font(14, "Arial"),
    tickfont      = font(10, "Arial"),
    guidefont     = font(11, "Arial"),
    legendfont    = font(10, "Arial"),
    size          = (1400, 600),
    dpi           = 200,
    left_margin   = 12Plots.mm,
    right_margin  = 6Plots.mm,
    top_margin    = 10Plots.mm,
    bottom_margin = 10Plots.mm,
    gridcolor     = :lightgrey,
    gridlinewidth = 0.8,
    framestyle    = :box,
    background_color_inside = :white,
)



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
        label="Mean Load per household", color=OI_BLUE, linewidth=2.5,
        ribbon=(fleet.load_mean .- fleet.load_p10, fleet.load_p90 .- fleet.load_mean),
        fillalpha=0.18, fillcolor=OI_BLUE,
        xlabel="Time of day (hours)", ylabel="Power per household (kW)",
        title="\nFleet Average Daily Profile (shaded: 10th–90th percentile across $(length(frames)) consumers)",
        xticks=0:3:24, xlims=(0, 24),
        legend=:topright, grid=:both, BASE_STYLE...)

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
        label="Aggregate Load", color=OI_BLUE, linewidth=2.5,
        xlabel="Time of day (hours)", ylabel="Total fleet power (kW)",
        title="\nFleet Aggregate Daily Profile ($(length(frames)) consumers summed)",
        xticks=0:3:24, xlims=(0, 24),
        legend=:topright, grid=:both, BASE_STYLE...)

    plot!(p, hrs, agg.pv_total;
          label="Aggregate PV", color=OI_ORANGE, linewidth=2.5)

    plot!(p, hrs, agg.load_total .- agg.pv_total;
          label="Net Demand (Load − PV)", color=OI_RED,
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
        label="Mean Load", color=OI_BLUE, linewidth=2.5,
        xlabel="Time of day (hours)", ylabel="Power per household (kW)",
        title="\nFleet Average Daily Profile — $season",
        xticks=0:3:24, xlims=(0, 24),
        legend=:topright, grid=:both, BASE_STYLE...)

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
        label="Aggregate Load", color=OI_BLUE, linewidth=2.5,
        xlabel="Percent of year (%)", ylabel="Total fleet power (kW)",
        title="\nFleet Load & PV Duration Curves",
        xticks=0:10:100, xlims=(0, 100),
        legend=:topright, grid=:both, BASE_STYLE...)

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
             title="\nAverage Daily Profile — 3 Consumers (low / medium / high self-consumption)",
             xticks=0:3:24, xlims=(0, 24),
             legend=:outertopright, grid=:both, BASE_STYLE...)

    for (f, lbl, ratio, col) in zip(chosen, labels, ratios, colours)
        g = sort(combine(groupby(f.df, :minute_of_day),
                         :total_load    => mean => :load,
                         :pv_generation => mean => :pv),
                 :minute_of_day)
        hrs = g.minute_of_day ./ 60

        label_load = "Load — $(f.id) ($lbl, SC=$(round(ratio, digits=2)))"
        label_pv   = "PV — $(f.id)"

        plot!(p, hrs, g.load;  label=label_load, color=col, linewidth=2.2)
        plot!(p, hrs, g.pv;    label=label_pv,   color=col,
                               linewidth=1.8, linestyle=:dash)
    end
    return p
end


# Comparison: 3 consumers, weekday vs weekend (3 small panels)
function build_spectrum_weekday_weekend(chosen, labels, ratios)
    panels = []
    for (f, lbl, ratio) in zip(chosen, labels, ratios)
        g = sort(combine(groupby(f.df, [:minute_of_day, :is_weekend]),
                         :total_load => mean => :load),
                 [:is_weekend, :minute_of_day])
        weekday = filter(:is_weekend => ==(false), g)
        weekend = filter(:is_weekend => ==(true),  g)

        pnl = plot(weekday.minute_of_day ./ 60, weekday.load;
            label="Weekday", color=OI_BLUE, linewidth=2.2,
            xlabel="Hour of day", ylabel="Load (kW)",
            title="$(f.id) — $lbl (SC=$(round(ratio, digits=2)))",
            xticks=0:6:24, xlims=(0, 24),
            legend=:outertopright, grid=:both, framestyle=:box,
            titlefont=font(12, "Arial"),
            tickfont=font(9, "Arial"),
            guidefont=font(10, "Arial"),
            legendfont=font(9, "Arial"))

        plot!(pnl, weekend.minute_of_day ./ 60, weekend.load;
              label="Weekend", color=OI_ORANGE, linewidth=2.2, linestyle=:dash)
        push!(panels, pnl)
    end

    return plot(panels...;
                layout=(1, 3),
                size=(1800, 500),
                dpi=200,
                plot_title="Weekday vs Weekend Load — Low / Medium / High Self-Consumption",
                plot_titlefont=font(14, "Arial"),
                left_margin=8Plots.mm,
                right_margin=6Plots.mm,
                top_margin=10Plots.mm,
                bottom_margin=8Plots.mm)
end


# Comparison: 3 consumers, load vs PV scatter (3 small panels)
function build_spectrum_scatter(chosen, labels, ratios)
    lim = maximum(
        maximum(f.df.total_load, init=0.0) |>
        x -> max(x, maximum(f.df.pv_generation, init=0.0))
        for f in chosen
    )

    panels = []
    for (f, lbl, ratio) in zip(chosen, labels, ratios)
        pnl = scatter(f.df.pv_generation, f.df.total_load;
            label="", color=OI_BLUE, markersize=1.2,
            markerstrokewidth=0, alpha=0.06,
            xlabel="PV generation (kW)", ylabel="Total load (kW)",
            title="$(f.id) — $lbl (SC=$(round(ratio, digits=2)))",
            xlims=(0, lim), ylims=(0, lim),
            legend=false, grid=:both, framestyle=:box,
            titlefont=font(12, "Arial"),
            tickfont=font(9, "Arial"),
            guidefont=font(10, "Arial"))

        plot!(pnl, [0, lim], [0, lim];
              color=OI_BLACK, linewidth=1.2, linestyle=:dash, label="")
        push!(panels, pnl)
    end

    return plot(panels...;
                layout=(1, 3),
                size=(1800, 600),
                dpi=200,
                plot_title="Load vs PV per 5-min Sample — Low / Medium / High Self-Consumption",
                plot_titlefont=font(14, "Arial"),
                left_margin=10Plots.mm,
                right_margin=6Plots.mm,
                top_margin=10Plots.mm,
                bottom_margin=10Plots.mm)
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
    out_path = joinpath(output_dir, "$(suffix).png")
    savefig(p, out_path)
    println("Saved: $out_path")
end