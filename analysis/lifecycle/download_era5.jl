#=
Download hourly, 0.25-degree ERA5 fields from the public ARCO-ERA5 archive.
Each completed UTC day is cached atomically as a small regional NetCDF file.
No CDS credentials, Python, or model/GPU environment are required.
=#
using Dates, Downloads, JSON3, NCDatasets, Blosc

const ARCO_URL = "https://storage.googleapis.com/gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3"
const VARIABLES = [
    ("ivt_east", "vertical_integral_of_eastward_water_vapour_flux", "kg m-1 s-1"),
    ("ivt_north", "vertical_integral_of_northward_water_vapour_flux", "kg m-1 s-1"),
    ("iwv", "total_column_water_vapour", "kg m-2"),
    ("mslp", "mean_sea_level_pressure", "Pa"),
]

function retry_read(f; attempts=4)
    for attempt in 1:attempts
        try
            return f()
        catch
            attempt == attempts && rethrow()
            sleep(2.0^attempt)
        end
    end
end

# This reader deliberately supports only the validated ARCO layout below, rather
# than silently interpreting a future change to its Zarr encoding incorrectly.
function read_chunk(::Type{T}, variable, key) where T
    retry_read() do
        bytes = IOBuffer()
        Downloads.download("$ARCO_URL/$variable/$key", bytes; timeout=90)
        Blosc.decompress(T, take!(bytes))
    end
end

function validate_encoding(meta, variable, dtype, dimensions)
    a = meta["$variable/.zarray"]
    a["zarr_format"] == 2 && a["order"] == "C" && a["dtype"] == dtype || error("Unsupported encoding for $variable")
    a["compressor"]["id"] == "blosc" && isnothing(a["filters"]) || error("Unsupported codec for $variable")
    collect(meta["$variable/.zattrs"]["_ARRAY_DIMENSIONS"]) == dimensions || error("Unexpected dimensions for $variable")
    return a
end

function download_era5(; directory=get(ENV, "AR_LIFECYCLE_DATA", joinpath(@__DIR__, "data")),
                         first_day=Date(get(ENV, "AR_FIRST_DAY", "2025-12-03")),
                         last_day=Date(get(ENV, "AR_LAST_DAY", "2025-12-12")),
                         longitude=(140.0, 250.0), latitude=(15.0, 65.0), workers=8)
    first_day <= last_day || error("The date range is reversed")
    workers > 0 || error("workers must be positive")
    mkpath(directory)
    metadata_path = joinpath(directory, "arco_metadata.json")
    Downloads.download(ARCO_URL * "/.zmetadata", metadata_path)
    metadata = JSON3.read(read(metadata_path, String)).metadata
    attrs = metadata[".zattrs"]
    first_day >= Date(attrs["valid_time_start"]) || error("Date predates ERA5")
    last_day <= Date(attrs["valid_time_stop"]) || error("Date exceeds finalized ERA5 coverage")

    ENDIAN_BOM == 0x04030201 || error("This archive reader requires a little-endian host")
    for coordinate in ("longitude", "latitude")
        a = validate_encoding(metadata, coordinate, "<f4", [coordinate])
        a["chunks"] == a["shape"] || error("Coordinate requires multiple chunks")
    end
    λall = read_chunk(Float32, "longitude", "0")
    φall = read_chunk(Float32, "latitude", "0")
    for (_, variable, _) in VARIABLES
        a = validate_encoding(metadata, variable, "<f4", ["time", "latitude", "longitude"])
        collect(a["chunks"]) == [1, length(φall), length(λall)] || error("Unsupported field chunking")
    end
    i = findall(x -> longitude[1] <= x <= longitude[2], λall)
    j = findall(y -> latitude[1] <= y <= latitude[2], φall)
    isempty(i) || isempty(j) ? error("Empty spatial selection") : nothing
    all(diff(i) .== 1) && all(diff(j) .== 1) || error("Use continuous 0–360° longitude bounds")
    ir, jr = first(i):last(i), first(j):last(j)
    # C-order Zarr bytes reshape in Julia as longitude, latitude, time.
    time_units = String(metadata["time/.zattrs"]["units"])
    startswith(time_units, "hours since ") || error("Unsupported time units: $time_units")
    epoch = DateTime(replace(time_units[13:end], " " => "T"))
    validate_encoding(metadata, "time", "<i8", ["time"])
    read_chunk(Int64, "time", "0")[1:2] == [0, 1] || error("Unexpected archive time origin or cadence")

    for day in first_day:Day(1):last_day
        path = joinpath(directory, "era5_$(day).nc")
        if isfile(path)
            NCDataset(path) do ds
                ds.attrib["source"] == ARCO_URL || error("Cached source differs")
                ds["longitude"][:] == λall[ir] || error("Cached longitude bounds differ")
                ds["latitude"][:] == reverse(φall[jr]) || error("Cached latitude bounds differ")
                length(ds["time"]) == 24 || error("Incomplete cached day")
            end
            @info "Using cached ERA5 day" day
            continue
        end
        fields = [Array{Float32}(undef, length(i), length(j), 24) for _ in VARIABLES]
        tasks = Channel{Tuple{Int, Int}}(96)
        for v in eachindex(VARIABLES), hour in 0:23
            put!(tasks, (v, hour))
        end
        close(tasks)
        @info "Downloading hourly ERA5" day grid=(length(i), length(j))
        @sync for _ in 1:workers
            @async for (v, hour) in tasks
                date = DateTime(day) + Hour(hour)
                n = div(Dates.value(date - epoch), 3_600_000) # zero-based Zarr chunk
                values = read_chunk(Float32, VARIABLES[v][2], "$n.0.0")
                length(values) == length(λall)*length(φall) || error("Wrong field size")
                field = reshape(values, length(λall), length(φall))[ir, jr]
                all(isfinite, field) || error("Missing/nonfinite ERA5 field at $date: $(VARIABLES[v][2])")
                fields[v][:, :, hour+1] = reverse(field; dims=2)
            end
        end
        partial = path * ".partial"
        NCDataset(partial, "c") do ds
            ds.attrib["source"] = ARCO_URL
            ds.attrib["title"] = "Hourly ERA5: December 2025 Pacific Northwest AR development"
            ds.attrib["history"] = "Regional subset in Julia; no spatial or temporal interpolation"
            ds.attrib["archive_last_updated"] = String(attrs["last_updated"])
            ds.attrib["Conventions"] = "CF-1.10"
            defDim(ds, "longitude", length(i)); defDim(ds, "latitude", length(j)); defDim(ds, "time", 24)
            defVar(ds, "longitude", λall[ir], ("longitude",); attrib=Dict("units" => "degrees_east"))
            defVar(ds, "latitude", reverse(φall[jr]), ("latitude",); attrib=Dict("units" => "degrees_north"))
            times = [div(Dates.value(DateTime(day) + Hour(h) - epoch), 3_600_000) for h in 0:23]
            defVar(ds, "time", times, ("time",); attrib=Dict("units" => time_units, "calendar" => "proleptic_gregorian"))
            for (v, (name, source, units)) in enumerate(VARIABLES)
                defVar(ds, name, fields[v], ("longitude", "latitude", "time");
                       deflatelevel=2, attrib=Dict("units" => units, "source_variable" => source))
            end
        end
        mv(partial, path; force=true)
        @info "Saved ERA5 day" day megabytes=round(filesize(path)/1e6; digits=1)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    download_era5()
end
