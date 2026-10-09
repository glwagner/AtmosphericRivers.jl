# julia --project=analysis/lifecycle analysis/lifecycle/animate_goes.jl [water_vapor|visible]
using CairoMakie, Dates, NaturalEarth, GeoInterface, TOML, Printf
include("goes_data.jl")
using .GOESData

const GOES_BACKGROUND = colorant"#071019"
# Fixed brightness-temperature enhancement: cold/cloudy white and blue;
# warmer emitting layers (often drier air) charcoal through orange.
const WV_COLORS = cgrad(["#16325d","#497ec0","#8bd2ea","#f5f8f9",
                         "#a8b2bd","#303942","#805143","#e7a660"],
                        [0,0.18,0.34,0.48,0.61,0.74,0.88,1])
const WV_RANGE = (195,280)
const WV_LOOKUP = RGBf.(WV_COLORS[collect(range(0.0,1.0;length=4096))])

function projected_coastlines(projection)
    points = Point2f[]
    function add_geometry(g)
        if GeoInterface.geomtrait(g) isa GeoInterface.LineStringTrait
            for point in GeoInterface.coordinates(g)
                push!(points,Point2f(scan_position(point[1],point[2],projection)))
            end
            push!(points,Point2f(NaN,NaN))
        else
            for i in 1:GeoInterface.ngeom(g)
                add_geometry(GeoInterface.getgeom(g,i))
            end
        end
    end
    for feature in naturalearth("coastline",50)
        add_geometry(GeoInterface.geometry(feature))
    end
    points
end

function annotate_map!(ax,projection,mode)
    lines!(ax,projected_coastlines(projection); color=(:white,0.65),linewidth=0.6)
    labels = mode == :water_vapor ?
        [(-170.0,37.0,"NORTH PACIFIC"),(-152.0,60.0,"ALASKA"),
         (-121.0,50.0,"BRITISH COLUMBIA"),(-118.0,44.0,"PACIFIC NORTHWEST") ] :
        [(-125.5,48.1,"VANCOUVER ISLAND"),(-121.0,47.0,"WASHINGTON"),(-120.9,44.0,"OREGON")]
    for (lon,lat,label) in labels
        x,y = scan_position(lon,lat,projection)
        text!(ax,x,y; text=label,fontsize=mode == :visible ? 16 : 14,
              font=:bold,color=:white,strokecolor=(:black,0.8),strokewidth=0.6,
              align=(:center,:center))
    end
    cities = mode == :visible ? [(-122.33,47.61,"Seattle"),(-123.12,49.28,"Vancouver"),(-122.68,45.52,"Portland")] :
                               [(-122.33,47.61,"Seattle")]
    for (lon,lat,label) in cities
        x,y = scan_position(lon,lat,projection)
        scatter!(ax,[x],[y]; color=:white,strokecolor=:black,strokewidth=0.5,markersize=5)
        text!(ax,x,y; text=label,fontsize=14,font=:bold,color=:white,offset=(5,5),
              strokecolor=:black,strokewidth=0.3)
    end
end

function scan_datetime(start)
    DateTime(replace(start,"Z"=>""))
end

function scene_caption(date,mode)
    mode == :visible && return "Daylight cloud structure at landfall"
    date < DateTime(2025,12,8) && return "Offshore evolution  /  before the December 8 landfall"
    date < DateTime(2025,12,9,18) && return "First landfall period  /  Pacific Northwest"
    date < DateTime(2025,12,11,12) && return "Second pulse and persistent coastal cloud band"
    "Late-event evolution"
end

function display_pixels(scan,mode)
    # Map once to RGB pixels: a numeric Makie heatmap repeatedly interpolates its
    # colour gradient for millions of pixels during every draw. This lookup has
    # <0.011 K rounding error, below ABI band 9's 0.042 K packing step.
    a = scan.values
    pixels = Matrix{RGBf}(undef,size(a))
    background = RGBf(GOES_BACKGROUND)
    @inbounds for j in axes(a,2), i in axes(a,1)
        t = a[i,size(a,2)+1-j] # ABI stores rows north to south; Makie y increases.
        if !isfinite(t)
            pixels[i,j] = background
        elseif mode == :visible
            c = sqrt(clamp(t/0.6f0,0f0,1f0))
            pixels[i,j] = RGBf(c,c,c)
        else
            k = clamp(round(Int,(t-WV_RANGE[1])*4095/(WV_RANGE[2]-WV_RANGE[1]))+1,1,4096)
            pixels[i,j] = WV_LOOKUP[k]
        end
    end
    pixels
end

function animate_goes(mode; directory=get(ENV,"AR_GOES_DATA",joinpath(@__DIR__,"goes_data")),
                           output=get(ENV,"AR_GOES_OUTPUT",joinpath(@__DIR__,"output")),
                           preview=get(ENV,"AR_GOES_PREVIEW","0")=="1")
    config = movie_config(mode)
    files = cache_files(directory,config)
    isempty(files) && error("No cached GOES scans; run download_goes.jl first")
    preview_index = parse(Int,get(ENV,"AR_GOES_PREVIEW_INDEX","1"))
    firstscan = read_scan(files[preview ? min(preview_index,length(files)) : 1])
    mkpath(output)
    set_theme!(Theme(backgroundcolor=GOES_BACKGROUND,textcolor=:white,fontsize=18))
    fig = Figure(size=(1920,1080),figure_padding=(30,30,20,18))
    title = mode == :water_vapor ? "An atmospheric river develops across the Pacific" : "Inside the cloud band at landfall"
    subtitle = mode == :water_vapor ?
        "GOES-18  /  6.9 µm water-vapour imagery  /  2 km at nadir  /  10-minute scans" :
        "GOES-18  /  0.64 µm visible imagery  /  500 m at nadir  /  5-minute scans"
    Label(fig[1,1:4],title; fontsize=30,font=:bold,halign=:left,tellwidth=false)
    Label(fig[2,1:3],subtitle; fontsize=17,color="#a7bacb",halign=:left,tellwidth=false)
    time_label = Observable("")
    Label(fig[2,4],time_label; fontsize=19,font=:bold,halign=:right,tellwidth=false)
    ax = Axis(fig[3,1:4]; aspect=DataAspect(),backgroundcolor=GOES_BACKGROUND)
    hidedecorations!(ax); hidespines!(ax)
    xmin,xmax,ymin,ymax = config.bounds
    limits!(ax,xmin,xmax,ymin,ymax)
    pixels = Observable(display_pixels(firstscan,mode))
    # Tuple bounds are outer pixel edges, while ABI x/y values are centres.
    dx = (last(firstscan.x)-first(firstscan.x))/(length(firstscan.x)-1)
    dy = (first(firstscan.y)-last(firstscan.y))/(length(firstscan.y)-1)
    range_x = (first(firstscan.x)-dx/2,last(firstscan.x)+dx/2)
    range_y = (last(firstscan.y)-dy/2,first(firstscan.y)+dy/2)
    image!(ax,range_x,range_y,pixels;interpolate=false)
    annotate_map!(ax,firstscan.projection,mode)
    caption = Observable("")
    Label(fig[4,1:2],caption;fontsize=18,font=:bold,halign=:left,tellwidth=false)
    if mode == :water_vapor
        Colorbar(fig[4,3:4];colormap=WV_COLORS,limits=WV_RANGE,vertical=false,label="Brightness temperature (K)",
                 ticks=200:20:280,ticklabelsize=13,labelsize=13,height=10,width=420,
                 tellheight=true,flipaxis=false)
    else
        Label(fig[4,3:4],"Visible reflectance  /  fixed square-root enhancement";
              fontsize=15,color="#a7bacb",halign=:right,tellwidth=false)
    end
    note = mode == :water_vapor ?
        "Cloud and mid-tropospheric moisture patterns; this channel does not measure total-column moisture or IVT." :
        "Native visible-band samples; pixel footprints grow away from nadir. Coastlines mark the surface beneath clouds."
    Label(fig[5,1:4],note;fontsize=14,color="#a7bacb",halign=:left,tellwidth=false)
    Label(fig[6,1:4],"NOAA GOES-18 ABI  •  December 2025  •  Original scan geometry  •  Julia / AtmosphericRivers.jl";
          fontsize=13,color="#7e95a9",halign=:left,tellwidth=false)
    rowgap!(fig.layout,10)
    rowsize!(fig.layout,3,Relative(0.79))
    sources = Dict{String,Any}[]
    function set_scan!(scan)
        scan.x == firstscan.x && scan.y == firstscan.y || error("Satellite grid changed")
        scan.projection == firstscan.projection || error("Satellite projection changed")
        pixels[] = display_pixels(scan,mode)
        date = scan_datetime(scan.start)
        time_label[] = Dates.format(date,dateformat"dd u yyyy  HH:MM") * " UTC"
        caption[] = scene_caption(date,mode)
        push!(sources,Dict("scan_start"=>scan.start,"scan_end"=>scan.stop,
                           "url"=>scan.url,"original_sha256"=>scan.hash))
    end
    set_scan!(firstscan)
    save(joinpath(output,config.stem * ".png"),fig;px_per_unit=2)
    preview && return
    empty!(sources)
    dates = GOESData.key_time.(basename.(files))
    expected = collect(config.start:Minute(config.cadence):config.stop-Minute(config.cadence))
    source_manifest = TOML.parsefile(joinpath(directory,config.stem,"sources.toml"))
    basename.(files) == basename.(source_manifest["source_urls"]) || error("Incomplete animation input")
    by_slot = Dict(floor(t,Minute(config.cadence)) => file for (t,file) in zip(dates,files))
    missing_slots = setdiff(expected,collect(keys(by_slot)))
    sort(missing_slots) == sort(DateTime.(source_manifest["missing_scan_slots"])) || error("Unexplained scan gap")
    gap_label = Observable("")
    text!(ax,(xmin+xmax)/2,(ymin+ymax)/2;text=gap_label,fontsize=30,color=:white,align=(:center,:center))
    fps = mode == :water_vapor ? 12 : 5
    @info "Rendering satellite movie" mode frames=length(expected) scans=length(files) fps
    flush(stderr)
    record(fig,joinpath(output,config.stem * ".mp4"),eachindex(expected);
           framerate=fps,px_per_unit=2,compression=18) do i
        date = expected[i]
        if haskey(by_slot,date)
            scan = i == 1 ? firstscan : read_scan(by_slot[date])
            gap_label[] = ""
            set_scan!(scan)
        else
            pixels[] = fill(RGBf(GOES_BACKGROUND),size(firstscan.values))
            time_label[] = Dates.format(date,dateformat"dd u yyyy  HH:MM") * " UTC"
            gap_label[] = "Scan unavailable in the NOAA archive"
            caption[] = "Data gap  /  no interpolated or repeated imagery"
        end
        if mode == :water_vapor && date == DateTime(2025,12,8,18)
            save(joinpath(output,"goes18_water_vapor_landfall.png"),fig;px_per_unit=2)
        end
        if i % 36 == 0 || i == length(expected)
            @info "Rendered satellite frames" mode frame=i total=length(expected)
            flush(stderr)
        end
    end
    manifest = Dict("satellite"=>"GOES-18", "band"=>config.band,
        "product"=>config.product,"cadence_minutes"=>config.cadence,
        "nominal_resolution"=>config.resolution,"source_pixel_dimensions"=>collect(size(firstscan.values)),
        "pixel_footprint_note"=>"Resolution is quoted at nadir; footprints grow with viewing angle.",
        "scan_bounds_radians"=>collect(config.bounds),"frames"=>length(expected),
        "actual_scans"=>length(files),"missing_scan_slots"=>string.(missing_slots),
        "fps"=>fps,"video_dimensions"=>[3840,2160],"temporal_interpolation"=>false,
        "quality_mask"=>"Keep DQF 0 (good) and 1 (conditionally usable); mask other values.",
        "display"=>mode == :visible ? "sqrt(clamp(reflectance/0.6,0,1)); fixed grayscale" : "Fixed 195–280 K custom enhancement",
        "scans"=>sources)
    open(joinpath(output,config.stem * "_provenance.toml"),"w") do io
        TOML.print(io,manifest)
    end
    @info "Satellite movie complete" mode output
end

if abspath(PROGRAM_FILE) == @__FILE__
    for mode in (isempty(ARGS) ? [:water_vapor,:visible] : Symbol.(ARGS))
        animate_goes(mode)
    end
end
