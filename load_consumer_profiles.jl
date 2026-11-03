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
using CSV
using DataFrames
using Dates
using TimeZones

# Struct for consumer info, mutable since we want the ability to update the PV_profile after cleaning.
mutable struct Consumer
    id::Int
    PV_profile::DataFrame    # kW demand
end

function load_consumer_load_profile(path::AbstractString, num_consumers::Int)
    consumers = Consumer[]
    
    # Get list of all CSV files in the directory:
    PV_data_files = filter(f -> endswith(f, ".csv"), readdir(path, join=true))
    
    # Filter to inner Sydney postcodes (2000–2299) for geographic consistency
    site_details_path = joinpath(path, "site_details_USYD_202010.csv")
    sites_properties = CSV.read(site_details_path, DataFrame; delim=",", ignorerepeated=true)
    filtered_site_ids = filter(row -> row.postcode >= 2000 && row.postcode <= 2299, sites_properties).site_id
    data_from_chosen_pool = filter(f -> any(id -> occursin("5min_$(id).csv", f), filtered_site_ids), readdir(path, join=true))
    println("Inner Sydney candidate consumers (postcode 2000-2299): $(length(data_from_chosen_pool))")

# Cleaning consumer profiles and creating Consumer objects.
# Use a while loop tied to target count, walking the file list linearly.
# Stops gracefully if we run out of valid consumers.
    i = 1
    while length(consumers) < num_consumers
        if i > length(data_from_chosen_pool)
            @warn "Ran out of valid consumers after loading $(length(consumers)) of $num_consumers requested. Returning what we have."
            break
        end
        
        path_data_file = data_from_chosen_pool[i]
        @assert isfile(path_data_file) "File not found: $path_data_file"
        df = CSV.read(path_data_file, DataFrame; delim=",", ignorerepeated=true)
        rename!(df, Symbol.(names(df)))
        df.utc_timestamp = parse_zdt.(String.(df.utc_timestamp))
        df.localtime     = parse_zdt.(String.(df.localtime))
        df.site_id       = string.(df.site_id)
        df.pv_generation = 12 * Float64.(df.pv_generation) ./ 1000
        df.total_load    = 12 * Float64.(df.total_load)    ./ 1000
        sort!(df, [:site_id, :utc_timestamp])
        
        df = data_cleaning(df)
        
        if df !== nothing
            push!(consumers, Consumer(length(consumers) + 1, df))
        end
        i += 1
    end

    println("\nLoaded $(length(consumers)) of $num_consumers requested consumers.")
    return consumers
end

# Convert string timestamps to ZonedDateTime objects
# Don't need to manually parse the timezone offset since ZonedDateTime can handle it directly with the right format string.
function parse_zdt(s::AbstractString)
    return ZonedDateTime(s, "yyyy-mm-dd HH:MM:SSzzzz")
end

# 
function data_cleaning(dataset::DataFrame)
    df = dataset
    println("\n===Consumer ID: ", df.site_id[1], "===")
    # Check for missing 5 minute timestamps in the local time column:
    zone = TimeZones.timezone(df.localtime[1])
    local_start = ZonedDateTime(2019, 1, 1, 0, 5, 0, zone)
    local_end   = ZonedDateTime(2020, 1, 1, 0, 0, 0, zone)
    standard_timestamps = Set(collect(local_start:Minute(5):local_end))

    println("Expected timestamps: ", length(standard_timestamps))
    df_local_set = Set(df.localtime)
    missing_set = setdiff(standard_timestamps, df_local_set)
    missing_sorted = sort(collect(missing_set))
    println("Total timestamps: ", nrow(df))
    println("Missing count: ", length(missing_sorted), "\n")

    # Find missing timestamps and fill them with avg of previous and next timestamp vals. 
    if length(missing_sorted) > 20
        println("Warning: Missing timestamps detected for consumer $(df.site_id[1]). Assigning a new load profile for this consumer ...")
        return nothing
    else
        println("Less than 20 missing timestamps detected for consumer $(df.site_id[1]).")
    end

    if !isempty(missing_sorted)
        println("First 10 missing timestamps:")
        for t in first(missing_sorted, min(10, length(missing_sorted)))
            println(Dates.format(t, "yyyy-mm-dd HH:MM:SS"))
        end

        site_id = df.site_id[1]

        for miss in missing_sorted
            prev_idx = findlast(t -> t < miss, df.localtime)
            next_idx = findfirst(t -> t > miss, df.localtime)

            if prev_idx !== nothing && next_idx !== nothing
                avg_pv   = (df.pv_generation[prev_idx] + df.pv_generation[next_idx]) / 2
                avg_load = (df.total_load[prev_idx] + df.total_load[next_idx]) / 2
            elseif prev_idx !== nothing
                avg_pv   = df.pv_generation[prev_idx]
                avg_load = df.total_load[prev_idx]
            elseif next_idx !== nothing
                avg_pv   = df.pv_generation[next_idx]
                avg_load = df.total_load[next_idx]
            else
                continue
            end

            utc_miss = astimezone(miss, tz"UTC")
            push!(df, (utc_timestamp=utc_miss, localtime=miss, site_id=site_id,
                    pv_generation=avg_pv, total_load=avg_load))
        end
        sort!(df, :localtime)
    end
    return df
end


num_consumers = 53
path = joinpath(@__DIR__, "SolarAnalytics", "5minutes")
consumers = load_consumer_load_profile(path, num_consumers)

include(joinpath(@__DIR__, "plot_load_profiles.jl"))
plots_path = joinpath(@__DIR__, "outputs", "input_plots")
plot_individual_load_profiles(consumers; output_dir = plots_path)








