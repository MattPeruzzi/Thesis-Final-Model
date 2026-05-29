using CSV
using DataFrames
using Dates
using TimeZones
using Statistics
using Plots
# This script reads the CSV data, parses timestamps with time zones, and 
# creates heatmaps of demand and PV generation for a specified site and date range.
# manually adjust the 'path' variable to change the site, also change on line 135.
# Can change start and end dates on lines 138-139 to adjust the window (calendar year, FY-style, etc.)



# ----------------------------
# Load + parse (tab-delimited)
# ----------------------------
path = path = "/Users/matthewperuzzi/Downloads/COPY/SolarAnalytics/hourly_327043.csv"
df = CSV.read(path, DataFrame; delim=',', ignorerepeated=true, normalizenames=true, stripwhitespace=true)

# Remove UTF-8 BOM if present
nms = names(df)
first_name = String(nms[1])
if startswith(first_name, '\ufeff')
    rename!(df, nms[1] => Symbol(replace(first_name, "\ufeff" => "")))
end

const DF_WITH_OFFSET = dateformat"yyyy-mm-dd HH:MM:SSzzzz"

function parse_zdt(s::AbstractString)
    s2 = strip(s)
    tz = TimeZone(s2[end-5:end])  # "+00:00", "+10:00", "+11:00", etc.
    return ZonedDateTime(DateTime(s2, DF_WITH_OFFSET), tz)
end

df.utc_timestamp = parse_zdt.(String.(df.utc_timestamp))
df.site_id = string.(df.site_id)
df.pv_generation = Float64.(df.pv_generation)
df.total_load    = Float64.(df.total_load)

# ----------------------------
# Heatmap builder (Date × TimeOfDay)
# ----------------------------
const SYD = tz"Australia/Sydney"

monday_start(d::Date) = d - Day(dayofweek(d) - 1)  # Mon=1 ... Sun=7

function year_heatmap(df::DataFrame;
        site::AbstractString,
        value_col::Symbol,
        tz_local::TimeZone = SYD,
        start_date::Date,
        end_date::Date,
        clip_negative::Bool,
        title_str::AbstractString,
        cbar_title::AbstractString,
        cmap = :turbo
    )

    d = filter(:site_id => ==(site), df)
    isempty(d) && error("No rows for site_id = $site")

    # Local time axis derived from UTC timestamps (robust)
    ts_local   = astimezone.(d.utc_timestamp, Ref(tz_local))
    date_local = Date.(ts_local)
    tod_local  = Time.(DateTime.(ts_local))

    d2 = DataFrame(
        date = date_local,
        tod  = tod_local,
        val  = d[!, value_col]
    )

    d2 = filter(row -> (row.date >= start_date) && (row.date <= end_date), d2)

    # Aggregate duplicates by (date, tod)
    g = combine(groupby(d2, [:date, :tod]), :val => mean => :val)

    # Infer time step (minutes) from time-of-day grid
    times_u = sort(unique(g.tod))
    step_minutes = 60
    if length(times_u) >= 2
        diffs_ns = [Dates.value(times_u[i+1] - times_u[i]) for i in 1:length(times_u)-1]
        diffs_ns = filter(>(0), diffs_ns)
        if !isempty(diffs_ns)
            step_minutes = Int(round(minimum(diffs_ns) / 60e9))  # ns -> minutes
            step_minutes = max(step_minutes, 1)
        end
    end

    date_grid = collect(start_date:Day(1):end_date)
    nsteps = Int(24*60 ÷ step_minutes)
    time_grid = [Time(0) + Minute(step_minutes)*i for i in 0:(nsteps-1)]

    Z = fill(NaN, length(date_grid), length(time_grid))
    date_idx = Dict(d => i for (i, d) in enumerate(date_grid))
    time_idx = Dict(t => j for (j, t) in enumerate(time_grid))

    for r in eachrow(g)
        i = get(date_idx, r.date, nothing)
        j = get(time_idx, r.tod,  nothing)
        if i !== nothing && j !== nothing
            v = r.val
            if clip_negative
                v = max(v, 0.0)
            end
            Z[i, j] = v
        end
    end

    # x ticks at each hour (works for any resolution)
    xt = [Time(h,0) for h in 0:23]
    xtlbl = [Dates.format(t, dateformat"HH:MM") for t in xt]

    # Monthly y-ticks (1st of each month)
    month_starts = Date(year(start_date), month(start_date), 1):Month(1):Date(year(end_date), month(end_date), 1)
    yt = [d for d in month_starts if d >= start_date && d <= end_date]
    ytlbl = [Dates.format(d, dateformat"dd-u") for d in yt]  # "01-Jan", etc.

    heatmap(
        time_grid, date_grid, Z;
        xlabel="Time of day (Sydney)",
        ylabel="Date",
        title=title_str,
        xticks=(xt, xtlbl),
        yticks=(yt, ytlbl),
        colorbar_title=cbar_title,
        right_margin=10Plots.mm,
        size=(1100, 650),
        c = cmap
    )
end

# ----------------------------
# Produce two plots and show them together
# ----------------------------
site = "327043"

# Choose your window (examples):
# Calendar year:
start_date = Date(2019, 1, 1)
end_date   = Date(2019, 12, 31)

# Or FY-style (May–Apr) like your example:
# start_date = Date(2023, 5, 1)
# end_date   = Date(2024, 4, 30)

p_load = year_heatmap(df;
    site=site,
    value_col=:total_load,
    start_date=start_date,
    end_date=end_date,
    clip_negative=false,
    title_str="Electricity demand (site $site)",
    cbar_title="Demand"
)

p_pv = year_heatmap(df;
    site=site,
    value_col=:pv_generation,
    start_date=start_date,
    end_date=end_date,
    clip_negative=true,   # clip PV < 0 to 0
    title_str="PV generation (site $site, clipped at 0)",
    cbar_title="PV"
)

plt = plot(p_load, p_pv; layout=(2,1), size=(1150, 1250))
display(plt)

# Optional: save the combined figure
# savefig(plt, "demand_and_pv_heatmaps.png")
