using Dates
using TimeZones
using DataFrames
using Plots

const SYD = tz"Australia/Sydney"

"""
Return the Sydney-local Monday 00:00 start for the calendar week containing `d`.
Weeks are Monday–Sunday (inclusive).
"""
monday_start(d::Date) = d - Day(dayofweek(d) - 1)  # dayofweek: Mon=1 ... Sun=7

"""
Filter one site to a Monday–Sunday calendar week in Sydney time and plot,
clipping negative PV generation to 0.
You can either:
- set `week_containing` to a specific Date (recommended), or
- omit it to plot the week containing the first timestamp in the dataset.
"""
function plot_one_calendar_week(df_wide::DataFrame; site::AbstractString,
                                week_containing::Union{Nothing,Date}=nothing)

    # 1) Filter to the site
    df_site = filter(:site_id => ==(site), df_wide)

    # 2) Create a Sydney-local timestamp column from UTC (robust)
    df_site = transform(df_site, :utc_timestamp => (t -> astimezone.(t, Ref(SYD))) => :ts_syd)

    # 3) Choose which calendar week to plot
    ref_date = isnothing(week_containing) ? Date(minimum(df_site.ts_syd)) : week_containing
    week_start_date = monday_start(ref_date)

    week_start = ZonedDateTime(DateTime(week_start_date), SYD)  # Monday 00:00 Sydney
    week_end   = week_start + Week(1)                           # next Monday 00:00

    # 4) Filter to that week (Monday inclusive, next Monday exclusive)
    df_week = filter(row -> (row.ts_syd >= week_start) && (row.ts_syd < week_end), df_site)

    # 5) Clip negative PV generation
    pv_clip = max.(df_week.pv_generation, 0.0)

    # 6) Plot
    plot(df_week.ts_syd, pv_clip,
         label="PV generation (clipped)", xlabel="Sydney local time", ylabel="Power [kW]")
    plot!(df_week.ts_syd, df_week.total_load, label="Total load")

    return df_week
end

# ---- Example usage (pick ONE):

# A) Plot the week containing a specific Sydney-local date (recommended):
df_week = plot_one_calendar_week(df_wide; site="327043", week_containing=Date(2019, 12, 2))

plot(df_week.localtime, df_week.pv_generation, label="PV generation",
     xlabel="Local time", ylabel="Power [kW]")
plot!(df_week.localtime, df_week.total_load, label="Total load", 
     xlabel="Local time")

# B) Plot the week containing the first timestamp in the file:
# df_week = plot_one_calendar_week(df_wide; site="327043")
