module LifecycleData

using Dates, JLD2, NCDatasets, OffsetArrays, Logging, SHA, TOML

export ERA5Series, ModelSeries, era5_frame, model_frame, available_index,
       ivt_magnitude, split_longitudes, write_provenance

ivt_magnitude(east, north) = hypot.(east, north)

"Latest available snapshot, without extrapolating beyond the data window."
function available_index(times, date)
    isempty(times) && return nothing
    first(times) <= date <= last(times) || return nothing
    searchsortedlast(times, date)
end

"Wrap a coastline into 0–360°, breaking segments at the map seam."
function split_longitudes(points)
    x, y = Float64[], Float64[]
    previous = NaN
    for point in points
        λ, φ = mod(point[1], 360), point[2]
        if isfinite(previous) && abs(λ - previous) > 180
            push!(x, NaN); push!(y, NaN)
        end
        push!(x, λ); push!(y, φ)
        previous = λ
    end
    x, y
end

struct ERA5Series
    files::Vector{String}
    longitude::Vector{Float32}
    latitude::Vector{Float32}
    dates::Vector{DateTime}
    east::Array{Float32,3}
    north::Array{Float32,3}
    iwv::Array{Float32,3}
    pressure::Array{Float32,3}
end

function ERA5Series(directory; first_day=Date(2025,12,3), last_day=Date(2025,12,12))
    files = [joinpath(directory, "era5_$(d).nc") for d in first_day:Day(1):last_day]
    all(isfile, files) || error("Missing ERA5 days: run download_era5.jl first")
    λ, φ = NCDataset(first(files)) do ds
        Float32.(ds["longitude"][:]), Float32.(ds["latitude"][:])
    end
    data = [Array{Float32}(undef, length(λ), length(φ), 24length(files)) for _ in 1:4]
    dates = DateTime[]
    for (day, file) in enumerate(files)
        NCDataset(file) do ds
            ds["longitude"][:] == λ && ds["latitude"][:] == φ || error("Grid changes between cached days")
            append!(dates, DateTime.(ds["time"][:]))
            for (v, key) in enumerate(("ivt_east", "ivt_north", "iwv", "mslp"))
                field = ds[key][:, :, :]
                all(isfinite, field) || error("Missing/nonfinite $key in $file")
                data[v][:, :, 24(day-1)+1:24day] = field
            end
        end
    end
    all(diff(dates) .== Hour(1)) || error("ERA5 timestamps are not continuous and hourly")
    first(dates) == DateTime(first_day) && last(dates) == DateTime(last_day)+Hour(23) || error("Wrong ERA5 date window")
    ERA5Series(files, λ, φ, dates, data...)
end

function era5_frame(s::ERA5Series, n)
    east, north = @view(s.east[:,:,n]), @view(s.north[:,:,n])
    (ivt=ivt_magnitude(east, north), east=east, north=north,
     iwv=@view(s.iwv[:,:,n]), pressure=s.pressure[:,:,n] ./ 100)
end

struct ModelSeries
    path::String
    file::JLD2.JLDFile
    longitude::Vector{Float32}
    latitude::Vector{Float32}
    dates::Vector{DateTime}
    iterations::Vector{Int}
    ix::UnitRange{Int}
    iy::UnitRange{Int}
    margin::Int
    raw_size::Tuple{Int,Int,Int}
end

function ModelSeries(path; start_date=DateTime(2025,12,7,12), margin=32)
    file = jldopen(path, "r")
    try
        # Only the serialized grid's plain metadata is needed. JLD2 reconstructs
        # its type without importing Oceananigans, CUDA, or NumericalEarth.
        grid = with_logger(NullLogger()) do
            file["serialized/grid"]
        end
        nx, ny, hx, hy = grid.Nx, grid.Ny, grid.Hx, grid.Hy
        0 <= margin < min(nx, ny)÷2 || error("Invalid model boundary mask")
        λ = Float32.(mod.(grid.λᶜᵃᵃ[1:nx], 360))
        φ = Float32.(grid.φᵃᶜᵃ[1:ny])
        issorted(λ) && issorted(φ) || error("Expected increasing model coordinates")
        iterations = sort(parse.(Int, keys(file["timeseries/t"])))
        times = [Float64(file["timeseries/t/$i"]) for i in iterations]
        dates = start_date .+ Millisecond.(round.(Int, 1000 .* times))
        all(diff(dates) .== Minute(30)) || error("Expected uninterrupted 30-minute model output")
        expected = (nx+2hx, ny+2hy, 1)
        for it in iterations, variable in ("ivt_east", "ivt_north")
            haskey(file, "timeseries/$variable/$it") || error("Incomplete model snapshot $it")
        end
        return ModelSeries(abspath(path), file, λ, φ, dates, iterations,
                           hx+1:hx+nx, hy+1:hy+ny, margin, expected)
    catch
        close(file)
        rethrow()
    end
end

Base.close(s::ModelSeries) = close(s.file)

function model_frame(s::ModelSeries, n)
    it = s.iterations[n]
    arrays = map(("ivt_east", "ivt_north")) do variable
        raw = s.file["timeseries/$variable/$it"]
        size(raw) == s.raw_size || error("Unexpected halo layout at $it")
        Float32.(raw[s.ix, s.iy, 1])
    end
    field = ivt_magnitude(arrays...)
    m = s.margin
    interior = @view field[m+1:end-m, m+1:end-m]
    all(isfinite, interior) || error("Nonfinite model interior at $(s.dates[n])")
    if m > 0
        field[1:m,:] .= NaN; field[end-m+1:end,:] .= NaN
        field[:,1:m] .= NaN; field[:,end-m+1:end] .= NaN
    end
    field
end

function write_provenance(path, era5, model; framerate, dimensions)
    digest(file) = bytes2hex(open(sha256, file))
    record = Dict{String,Any}(
        "event" => "8–12 December 2025 Pacific Northwest atmospheric river",
        "event_reference" => "https://cw3e.ucsd.edu/cw3e-event-summary-8-12-december-2025/",
        "created_at_utc" => string(now(UTC)), "julia_version" => string(VERSION),
        "video" => Dict("fps" => framerate, "width" => dimensions[1], "height" => dimensions[2],
                        "frame_step_minutes" => 30, "temporal_interpolation" => false),
        "era5" => Dict("grid_degrees" => 0.25, "cadence_minutes" => 60,
                        "first_time" => string(first(era5.dates)), "last_time" => string(last(era5.dates)),
                        "frame_policy" => "Hold latest hourly sample; display its actual timestamp",
                        "files" => [Dict("name" => basename(f), "sha256" => digest(f)) for f in era5.files]))
    if !isnothing(model)
        record["landfall_video"] = Dict("fps" => framerate, "width" => 3200, "height" => 2400,
                                         "frames" => length(model.dates), "frame_step_minutes" => 30)
        record["model"] = Dict("file" => basename(model.path), "sha256" => digest(model.path),
            "first_time" => string(first(model.dates)), "last_time" => string(last(model.dates)),
            "cadence_minutes" => 30, "grid_degrees" => Float64(model.longitude[2]-model.longitude[1]),
            "boundary_mask_cells" => model.margin, "frame_policy" => "Unavailable outside simulation dates")
    end
    open(path, "w") do io
        TOML.print(io, record)
    end
end

end # module
