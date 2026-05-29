using CSV
using DataFrames
using Dates
using TimeZones
using Plots

# Timestamp strings look like: "2018-12-31 13:00:00+00:00"
const DF_WITH_OFFSET = DateFormat("yyyy-mm-dd HH:MM:SSzzzz")

function parse_zdt(s::AbstractString)
    s2 = strip(s)
    # timezone offset is the last 6 chars, e.g. "+00:00" or "+10:30"
    tz = TimeZone(s2[end-5:end])
    return ZonedDateTime(DateTime(s2, DF_WITH_OFFSET), tz)
end

"""
    load_site_timeseries(path; delim=',')

Reads the tab-delimited file, parses timestamps, and returns (df_wide, df_long).
- df_wide: utc_timestamp, site_id, pv_generation, total_load, localtime
- df_long: utc_timestamp, localtime, site_id, variable, value
"""
function load_site_timeseries(path::AbstractString; delim::Char = ',')
    @assert isfile(path) "File not found: $path"

    df = CSV.read(path, DataFrame; delim=delim, ignorerepeated=true)

    rename!(df, Symbol.(names(df)))

    # Parse timestamps (ZonedDateTime)
    df.utc_timestamp = parse_zdt.(String.(df.utc_timestamp))
    df.localtime     = parse_zdt.(String.(df.localtime))

    # Clean types
    df.site_id        = string.(df.site_id)
    df.pv_generation  = 12*Float64.(df.pv_generation)
    df.total_load     = 12*Float64.(df.total_load)

    sort!(df, [:site_id, :utc_timestamp])

    df_wide = df

    # Long/tidy format for grouped plotting
    df_long = stack(
        df_wide,
        [:pv_generation, :total_load],
        variable_name = :variable,
        value_name    = :value
    )

    return df_wide, df_long
end

# ---- Your full path (raw string avoids escaping backslashes)
path = path = "/Users/matthewperuzzi/Downloads/COPY/SolarAnalytics/hourly_327043.csv"

df_wide, df_long = load_site_timeseries(path; delim=',')

println(first(df_wide, 5))
println(first(df_long, 5))
