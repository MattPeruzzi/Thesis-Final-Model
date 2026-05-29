using DataFrames, Dates, Statistics, Plots, Printf, Measures, Statistics

# 1) Load the modules
include("src/LoadSmartMeterData.jl")
include("src/PlotSelectedData.jl")
using .LoadSmartMeterData
using .PlotSelectedData

# 2) Load the data
path = "/Users/matthewperuzzi/Downloads/COPY/SolarAnalytics/5minutes/5min_327043.csv"

df_wide, df_long = LoadSmartMeterData.load_site_timeseries(path; delim=',')

# println(first(df_wide, 5))
# println(first(df_long, 5))

# 3) Annual averages (overall, across all sites and all timestamps)
overall_avg_demand_kW = mean(skipmissing(df_wide.total_load))
overall_avg_pv_kW     = mean(skipmissing(df_wide.pv_generation))

# println("Overall annual average demand (kW): ", overall_avg_demand_kW)
# println("Overall annual average PV (kW):     ", overall_avg_pv_kW)

# ---- Example usage (pick ONE):

# A) Plot the week containing a specific Sydney-local date (recommended):
df_week = PlotSelectedData.plot_one_calendar_week(df_wide; site="327043", week_containing=Date(2019, 12, 2))

p1 = plot(df_week.localtime,
    df_week.pv_generation, 
    label="PV generation",
    xlabel="Local time", 
    ylabel="Power [kW]", 
    guidefontsize = 36,     # axis-label font size (xlabel + ylabel)
    tickfontsize  = 24,     # tick-label font size
    legendfontsize = 24,    # legend font size
    legend = :topright,
    size=(3000, 1500),
    left_margin = 30mm,
    bottom_margin = 30mm,
    linewidth = 3)

plot!(df_week.localtime, 
    df_week.total_load, 
    label="Total load", 
    xlabel="Local time",
    linewidth = 3)

    display(p1)
savefig(p1, "weekly_5min_demand_pv.png")   # PNG

# B) Plot the week containing the first timestamp in the file:
# df_week = plot_one_calendar_week(df_wide; site="327043")


# --- Average daily demand profile (all sites, all year) ---
df = df_wide
# --- Create a "minute of day" key from local time ---
# localtime is ZonedDateTime; convert to DateTime to use Dates.hour/minute
dt = DateTime.(df.localtime)
df.minute_of_day = Dates.hour.(dt) .* 60 .+ Dates.minute.(dt)  # 0..1439

# --- Average demand profile over the whole year (all sites combined) ---
avg_day = combine(
    groupby(df, :minute_of_day),
    :total_load => (x -> mean(skipmissing(x))) => :avg_demand_kW
)
sort!(avg_day, :minute_of_day)

# --- Nice HH:MM x-axis ticks (every 2 hours) ---
xt = collect(0:120:1440)
xl = [@sprintf("%02d:%02d", t ÷ 60, t % 60) for t in xt]
xhours = avg_day.minute_of_day ./ 60.0

p2 = plot(
    xhours, avg_day.avg_demand_kW,
    xlabel = "Local time of day",
    ylabel = "Average demand [kW]",
    title  = "Average demand profile (annual mean over time-of-day)",
    legend = false,
    xticks = (xt ./ 60.0, xl),
    linewidth = 3,
    guidefontsize = 36,     # axis-label font size (xlabel + ylabel)
    tickfontsize  = 24,     # tick-label font size
    legendfontsize = 24,    # legend font size
    size=(3000, 1500),
    left_margin = 30mm,
    bottom_margin = 30mm
)
display(p2)

savefig(p2, "average_5min_daily_demand.png")   # PNG

# --- Average weekly demand profile (all sites, all year) ---
df = df_wide
# Convert ZonedDateTime -> DateTime for easy extraction
dt = DateTime.(df.localtime)

# Minute-of-week key: Monday 00:00 = 0, ..., Sunday 23:55 = 10075
# dayofweek(): Monday=1 ... Sunday=7
dow = dayofweek.(Date.(dt))                         # 1..7
minute_of_day = hour.(dt) .* 60 .+ minute.(dt)      # 0..1439
df.minute_of_week = (dow .- 1) .* 1440 .+ minute_of_day  # 0..10079

# Average weekly profile (all sites combined)
avg_week = combine(
    groupby(df, :minute_of_week),
    :total_load => (x -> mean(skipmissing(x))) => :avg_demand_kW
)
sort!(avg_week, :minute_of_week)

x_days = avg_week.minute_of_week ./ 1440.0  # x-axis in days (0..7)

# X ticks at day boundaries with labels
day_ticks = 0:1:7
day_labels = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun","Mon"]

p3 = plot(
    x_days, avg_week.avg_demand_kW,
    xlabel = "Day of week",
    ylabel = "Average demand [kW]",
    title  = "Average weekly demand profile (annual mean over minute-of-week)",
    legend = false,
    xticks = (collect(day_ticks), day_labels),
    linewidth = 3,
    size = (1400, 600),
    ylims = (0, :auto)
)

# Optional: vertical lines at day boundaries

for d in 1:6
    vline!(p3, [d], label=false, linestyle=:dash)
end

display(p3)
savefig(p3, "average_5min_weekly_demand.png")   # PNG