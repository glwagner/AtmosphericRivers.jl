module GOESData

using Dates, Downloads, NCDatasets, TOML, SHA, Printf

export download_goes, scan_position, read_scan, cache_files, movie_config

const BUCKET = "https://noaa-goes18.s3.amazonaws.com/"

function movie_config(mode::Symbol)
    mode == :water_vapor && return (
        product="ABI-L2-CMIPF", band=9, cadence=10,
        start=DateTime(2025,12,6), stop=DateTime(2025,12,12),
        bounds=(-0.130,0.085,0.050,0.150), stem="goes18_water_vapor",
        resolution="2 km at nadir", units="K")
    mode == :visible && return (
        product="ABI-L2-CMIPC", band=2, cadence=5,
        start=DateTime(2025,12,8,18), stop=DateTime(2025,12,9),
        bounds=(-0.018,0.044,0.096,0.128), stem="goes18_visible_landfall",
        resolution="500 m at nadir", units="1")
    error("Unknown GOES mode: $mode")
end

"""Geodetic lon/lat → ABI sweep-x scan angles on the product's ellipsoid."""
function scan_position(lon, lat, projection)
    a = projection["semi_major_axis"]
    b = projection["semi_minor_axis"]
    H = projection["perspective_point_height"] + a
    λ = deg2rad(lon - projection["longitude_of_projection_origin"])
    φ = deg2rad(lat)
    φc = atan((b/a)^2 * tan(φ))
    rc = b / sqrt(1 - (1 - (b/a)^2) * cos(φc)^2)
    sx = H - rc*cos(φc)*cos(λ)
    sy = -rc*cos(φc)*sin(λ)
    sz = rc*sin(φc)
    # Surface must face the satellite; reject the invisible far side.
    H*(H-sx) < sy^2 + (a/b)^2*sz^2 + (H-sx)^2 && return (NaN,NaN)
    (asin(-sy/sqrt(sx^2+sy^2+sz^2)), atan(sz,sx))
end

function get_file(url, path; retries=4)
    isfile(path) && return path
    mkpath(dirname(path))
    temporary = path * ".partial"
    for attempt in 1:retries
        try
            Downloads.download(url, temporary; timeout=180)
            mv(temporary, path; force=true)
            return path
        catch
            isfile(temporary) && rm(temporary)
            attempt == retries && rethrow()
            sleep(attempt)
        end
    end
end

function list_hour(config, date, directory)
    prefix = @sprintf("%s/%04d/%03d/%02d/", config.product,year(date),dayofyear(date),hour(date))
    path = joinpath(directory, "listings", replace(prefix,'/'=>'_') * ".xml")
    get_file(BUCKET * "?list-type=2&prefix=" * prefix, path)
    xml = read(path,String)
    occursin("<IsTruncated>false</IsTruncated>",xml) || error("Truncated S3 listing: $prefix")
    needle = @sprintf("M6C%02d_G18",config.band)
    sort!([m.captures[1] for m in eachmatch(r"<Key>(.*?)</Key>",xml) if occursin(needle,m.captures[1])])
end

function key_time(key)
    m = match(r"_s(\d{4})(\d{3})(\d{2})(\d{2})(\d{2})(\d)_",key)
    isnothing(m) && error("Unrecognized GOES filename: $key")
    y,d,h,mi,s,tenth = parse.(Int,m.captures)
    DateTime(y) + Day(d-1) + Hour(h) + Minute(mi) + Second(s) + Millisecond(100tenth)
end

function crop_scan(raw, cache, config, key)
    NCDataset(raw) do source
        source.attrib["platform_ID"] == "G18" || error("Wrong satellite")
        only(source["band_id"][:]) == config.band || error("Wrong band")
        source["CMI"].attrib["units"] == config.units || error("Unexpected calibration")
        projection = Dict(source["goes_imager_projection"].attrib)
        projection["sweep_angle_axis"] == "x" || error("Unsupported projection")
        x, y = source["x"][:], source["y"][:]
        xmin,xmax,ymin,ymax = config.bounds
        ix = findall(v -> xmin <= v <= xmax,x)
        iy = findall(v -> ymin <= v <= ymax,y)
        isempty(ix) || isempty(iy) ? error("Crop outside source") : nothing
        maximum(diff(ix)) == 1 && maximum(diff(iy)) == 1 || error("Noncontiguous crop")
        rx,ry = first(ix):last(ix),first(iy):last(iy)
        # Preserve the packed original samples and calibration, without resampling.
        packed = source["CMI"].var[rx,ry]
        quality = source["DQF"].var[rx,ry]
        attrs = Dict(source["CMI"].attrib)
        attrs["coordinates"] = "y x"
        start = String(source.attrib["time_coverage_start"])
        stop = String(source.attrib["time_coverage_end"])
        NCDataset(cache * ".partial","c") do ds
            defDim(ds,"x",length(ix)); defDim(ds,"y",length(iy))
            defVar(ds,"x",Float32,("x",); attrib=Dict("units"=>"rad"))[:] = x[rx]
            defVar(ds,"y",Float32,("y",); attrib=Dict("units"=>"rad"))[:] = y[ry]
            # Low-level variable assignment avoids applying the scale twice.
            v = defVar(ds,"CMI",Int16,("x","y"); attrib=attrs,deflatelevel=1,shuffle=true)
            v.var[:,:] = packed
            defVar(ds,"DQF",Int8,("x","y"); deflatelevel=1)[:,:] = quality
            defVar(ds,"goes_imager_projection",Int32,(); attrib=projection)[] = 0
            ds.attrib["source_url"] = BUCKET * key
            ds.attrib["source_sha256"] = bytes2hex(open(sha256,raw))
            ds.attrib["time_coverage_start"] = start
            ds.attrib["time_coverage_end"] = stop
            ds.attrib["spatial_resolution"] = String(source.attrib["spatial_resolution"])
            ds.attrib["band_id"] = config.band
            ds.attrib["source_size_bytes"] = filesize(raw)
        end
    end
    mv(cache * ".partial",cache; force=true)
end

cache_files(directory,config) = sort(filter(f -> endswith(f,".nc"), readdir(joinpath(directory,config.stem); join=true)))

function read_scan(path)
    NCDataset(path) do ds
        values = Float32.(coalesce.(ds["CMI"][:,:],NaN32))
        quality = ds["DQF"][:,:]
        # NOAA: 0 good, 1 conditionally usable, >=2 invalid, -1 fill.
        values[(quality .< 0) .| (quality .>= 2)] .= NaN32
        (; x=Float32.(ds["x"][:]), y=Float32.(ds["y"][:]), values,
           projection=Dict(ds["goes_imager_projection"].attrib),
           start=String(ds.attrib["time_coverage_start"]),
           stop=String(ds.attrib["time_coverage_end"]),
           url=String(ds.attrib["source_url"]),
           hash=String(ds.attrib["source_sha256"]))
    end
end

function download_goes(mode; directory=get(ENV,"AR_GOES_DATA",joinpath(@__DIR__,"goes_data")), workers=6)
    config = movie_config(mode)
    folder = joinpath(directory,config.stem)
    mkpath(folder)
    hours = collect(config.start:Hour(1):config.stop-Hour(1))
    listings = Vector{Vector{String}}(undef,length(hours))
    @info "Listing NOAA GOES-18 scans" mode hours=length(hours)
    flush(stderr)
    semaphore = Base.Semaphore(workers)
    @sync for i in eachindex(hours)
        @async Base.acquire(semaphore) do
            listings[i] = list_hour(config,hours[i],directory)
        end
    end
    keys = sort!(reduce(vcat,listings))
    filter!(k -> config.start <= key_time(k) < config.stop,keys)
    isempty(keys) && error("No GOES scans found")
    slots = floor.(key_time.(keys),Minute(config.cadence))
    expected = collect(config.start:Minute(config.cadence):config.stop-Minute(config.cadence))
    length(unique(slots)) == length(slots) || error("Duplicate GOES scan slots")
    isempty(setdiff(slots,expected)) || error("Unexpected GOES scan times")
    missing_slots = setdiff(expected,slots)
    isempty(missing_slots) || @warn "NOAA archive has missing scans; movies will show a gap card" missing_slots
    completed = Ref(0)
    @info "Downloading native satellite scans" mode frames=length(keys)
    flush(stderr)
    @sync for key in keys
        @async Base.acquire(semaphore) do
            cache = joinpath(folder,basename(key))
            if !isfile(cache)
                raw = joinpath(directory,"raw",basename(key))
                get_file(BUCKET * key,raw)
                crop_scan(raw,cache,config,key)
                rm(raw) # Only this regenerable original; the regional samples are retained.
            end
            completed[] += 1
            if completed[] % 24 == 0 || completed[] == length(keys)
                @info "Cached GOES scans" mode complete=completed[] total=length(keys)
                flush(stderr)
            end
        end
    end
    manifest = Dict("satellite"=>"GOES-18", "product"=>config.product,
        "band"=>config.band,"start"=>string(config.start),"stop_exclusive"=>string(config.stop),
        "cadence_minutes"=>config.cadence,"resolution"=>config.resolution,
        "scan_bounds_radians"=>collect(config.bounds),"source_urls"=>BUCKET .* keys,
        "missing_scan_slots"=>string.(missing_slots))
    open(joinpath(folder,"sources.toml"),"w") do io
        TOML.print(io,manifest)
    end
    @info "GOES download complete" mode frames=length(keys) folder
end

end
