module LoadSmartMeterData
 
# We need includes for time handling
using Dates         # date and time handling
using TimeZones     # must consider timezones when working with timestamps from different locations

#Now we need includes for taking in CSVs and data handling
using CSV           #Package for reading in CSV files
using DataFrames    #Similar to pandas in Python, for data manipulation


export load_site_timeseries #Makes the function available to other modules (public func)

# Create a constant declaration to format the timestamp info string "yyyy-mm-dd HH:MM:SS+zz:zz" using a string macro
const DF_WITH_OFFSET = DateFormat("yyyy-mm-dd HH:MM:SSzzzz")
# The zzzz is the time offset

function parse_zdt(s::AbstractString)
    # Abstract String is the parent type of all string types hence, handle any string type.

    s2 = strip(s) # Remove leading and trailing characters from string 
    # Capture timezone offset which is the last 6 chars, e.g. "+00:00" or "+10:30"
    tz = TimeZone(s2[end-5:end])
    return ZonedDateTime(DateTime(s2, DF_WITH_OFFSET), tz)
end
"""
This comment above is saying that the function load_site_timeseries takes in a file path and an 
optional delimiter (comma is default) and reads the data from the file. 
It then parses the timestamps and returns two DataFrames: df_wide, which contains the original data 
with columns for utc_timestamp, site_id, pv_generation, total_load, and localtime; and df_long, 
which is a long format of the data with columns for utc_timestamp, localtime, site_id, 
variable (indicating whether it's pv_generation or total_load), and value (the corresponding value for that variable). 
"""
function load_site_timeseries(path::AbstractString; delim::Char = ',')
    # We have utc_timestamp,site_id,pv_generation,total_load,localtime
    @assert isfile(path) "File not found: $path" # Throws error msg if file doesn't exist.
    # Load dataframe
    df = CSV.read(path, DataFrame; delim=delim, ignorerepeated=true)

    rename!(df, Symbol.(names(df)))

    # Parse timestamps (ZonedDateTime)
    df.utc_timestamp = parse_zdt.(String.(df.utc_timestamp))
    df.localtime     = parse_zdt.(String.(df.localtime))
    # the . after parse_zdt means that we are applying the function element-wise to each entry in the utc_timestamp 
    # and localtime columns of the dataframe.

    # Clean types
    df.site_id        = string.(df.site_id) # Want a string since a site id is a categorical variable, not a number
    df.pv_generation  = 12*Float64.(df.pv_generation)   # Multiply by 12 to convert to hourly from 5-min data
    df.total_load     = 12*Float64.(df.total_load)      # Multiply by 12 to convert to hourly from 5-min data

    sort!(df, [:site_id, :utc_timestamp]) # ! means modify df in place, not making a new one


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

end