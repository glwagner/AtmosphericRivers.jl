# Run with julia --project=analysis/lifecycle analysis/lifecycle/animate.jl
using CairoMakie, Dates, NaturalEarth, GeoInterface, Printf
include("data.jl")
using .LifecycleData

const INK = colorant"#203448"
const MUTED = colorant"#617386"
const ACCENT = colorant"#087f91"
const IVT_COLORS = cgrad(["#f0f4f8", "#add8e6", "#59b8bf", "#209391", "#528c50",
                         "#c4b64a", "#f8ca55", "#ed873d", "#cb433f", "#8c2853"])
const IVT_LIMITS = (0, 1600)
const COAST = (235.25f0, 48.0f0)

include("landfall.jl")

function coastlines()
    x, y = Float64[], Float64[]
    coast = naturalearth("coastline", 50)
    function add_geometry(g)
        trait = GeoInterface.geomtrait(g)
        if trait isa GeoInterface.LineStringTrait
            points = GeoInterface.coordinates(g)
            a, b = split_longitudes(points)
            append!(x, a); append!(y, b); push!(x, NaN); push!(y, NaN)
        else
            for k in 1:GeoInterface.ngeom(g)
                add_geometry(GeoInterface.getgeom(g, k))
            end
        end
    end
    for feature in coast
        add_geometry(GeoInterface.geometry(feature))
    end
    x, y
end

longitude_label(x) = x == 180 ? "180°" : x < 180 ? "$(Int(x))°E" : "$(Int(360-x))°W"
function map_axis(position, title; longitude=(140,250), latitude=(15,65), fontsize=16)
    xticks = longitude[2]-longitude[1] > 60 ? collect(140:20:240) : collect(220:5:240)
    yticks = latitude[2]-latitude[1] > 30 ? collect(20:10:60) : collect(40:4:52)
    ax = Axis(position; title, titlealign=:left, titlefont=:bold, titlesize=fontsize+2,
              xticks=(xticks, longitude_label.(xticks)), yticks=(yticks, ["$(y)°N" for y in yticks]),
              xticklabelsize=fontsize-2, yticklabelsize=fontsize-2,
              xgridvisible=false, ygridvisible=false,
              aspect=AxisAspect((longitude[2]-longitude[1])*cosd(40)/(latitude[2]-latitude[1])))
    xlims!(ax, longitude...); ylims!(ax, latitude...)
    ax
end

function overlays!(ax, coastline; detail=false)
    lines!(ax, coastline...; color=(INK, 0.8), linewidth=detail ? 1.2 : 0.8)
    cities = detail ? [(237.67,47.61,"Seattle"), (236.88,49.28,"Vancouver"), (237.33,45.52,"Portland")] :
                      [(157.0,37.5,"NORTH PACIFIC"), (202.0,19.0,"Hawai‘i"), (238.0,51.8,"PNW")]
    for (x,y,name) in cities
        text!(ax, x,y; text=name, fontsize=detail ? 15 : 17, color=INK,font=:bold,
              strokecolor=(:white,0.8), strokewidth=0.45, align=(:left,:bottom), offset=(5,3))
    end
    scatter!(ax, [COAST[1]], [COAST[2]]; color=:white, strokecolor=INK, strokewidth=1.5, markersize=10)
end

function arrows(era5, east, north)
    locations, vectors = Point2f[], Vec2f[]
    for i in 9:16:length(era5.longitude)-8, j in 5:12:length(era5.latitude)-4
        magnitude = hypot(east[i,j], north[i,j])
        magnitude < 250 && continue
        φ = era5.latitude[j]
        # Convert east/north directions to lon/lat map directions. Arrow lengths
        # are fixed on the map; transport strength is encoded only by color.
        dx, dy = east[i,j]/cosd(φ), north[i,j]
        norm = hypot(dx,dy)
        push!(locations, Point2f(era5.longitude[i], φ))
        push!(vectors, Vec2f(1.6dx/norm, 1.6dy/norm))
    end
    locations, vectors
end

function event_caption(date)
    date < DateTime(2025,12,7) && return "Offshore evolution across the Pacific"
    date < DateTime(2025,12,8) && return "The moisture corridor approaches the Pacific Northwest"
    date < DateTime(2025,12,9,18) && return "First landfall  •  Washington and Oregon"
    date < DateTime(2025,12,11,12) && return "A second pulse prolongs coastal moisture transport"
    "Late-event evolution along the coast"
end

function animate(; data_dir=get(ENV,"AR_LIFECYCLE_DATA",joinpath(@__DIR__,"data")),
                   model_path=get(ENV,"AR_LIFECYCLE_MODEL",""),
                   output_dir=get(ENV,"AR_LIFECYCLE_OUTPUT",joinpath(@__DIR__,"output")),
                   first_day=Date(get(ENV,"AR_FIRST_DAY","2025-12-03")),
                   last_day=Date(get(ENV,"AR_LAST_DAY","2025-12-12")),
                   fps=parse(Int,get(ENV,"AR_FPS","8")),
                   preview=get(ENV,"AR_PREVIEW","0")=="1")
    mkpath(output_dir)
    era5 = ERA5Series(data_dir; first_day, last_day)
    model = isempty(model_path) ? nothing : ModelSeries(model_path)
    coastline = coastlines()
    set_theme!(Theme(fontsize=17, textcolor=INK, backgroundcolor=:white,
                     Axis=(spinewidth=0.8, spinecolor=(:gray,0.5), titlecolor=INK,
                           xticklabelcolor=MUTED, yticklabelcolor=MUTED)))

    dates = collect(first(era5.dates):Minute(30):last(era5.dates))
    h = Dates.value.(era5.dates .- first(dates)) ./ 3_600_000
    ci, cj = argmin(abs.(era5.longitude .- COAST[1])), argmin(abs.(era5.latitude .- COAST[2]))
    coastal = hypot.(era5.east[ci,cj,:], era5.north[ci,cj,:])
    model_coastal = Float32[]
    if !isnothing(model)
        mi, mj = argmin(abs.(model.longitude .- COAST[1])), argmin(abs.(model.latitude .- COAST[2]))
        @info "Validating all 3 km model snapshots" count=length(model.dates)
        for n in eachindex(model.dates)
            push!(model_coastal, model_frame(model,n)[mi,mj])
        end
    end

    first_frame = era5_frame(era5,1)
    ivt, iwv, pressure = Observable(first_frame.ivt), Observable(copy(first_frame.iwv)), Observable(first_frame.pressure)
    positions, directions = arrows(era5, first_frame.east, first_frame.north)
    date_label = Observable("")
    sample_label = Observable("")
    caption = Observable("")
    detail_title = Observable("Landfall detail  |  3 km hindcast")
    detail_notice = Observable("")
    nest = isnothing(model) ? Observable(fill(NaN32,2,2)) : Observable(fill(NaN32,length(model.longitude),length(model.latitude)))
    cursor = Observable([0.0])

    fig = Figure(size=(1920,1080), figure_padding=(35,30,20,20))
    Label(fig[0,1:4], "An atmospheric river takes shape", fontsize=34, font=:bold, halign=:left, tellwidth=false)
    Label(fig[1,1:2], "December 2025  /  Pacific Northwest", fontsize=20, color=MUTED, halign=:left, tellwidth=false)
    Label(fig[1,3:4], date_label, fontsize=22, font=:bold, halign=:right, tellwidth=false)
    ax = map_axis(fig[2:4,1:2], "Moisture transport  |  hourly ERA5, 0.25°")
    hm = heatmap!(ax, era5.longitude,era5.latitude,ivt; colormap=IVT_COLORS, colorrange=IVT_LIMITS, interpolate=false, highclip=last(IVT_COLORS))
    contour!(ax, era5.longitude,era5.latitude,pressure; levels=952:8:1048, color=(INK,0.30), linewidth=0.9)
    # Update both arrays atomically: the number of qualifying arrows changes.
    arrowplot = arrows2d!(ax,positions,directions; color=(INK,0.66), shaftwidth=0.7, tiplength=6, tipwidth=4)
    overlays!(ax,coastline)
    lines!(ax,[218,242,242,218,218],[40,40,54,54,40]; color=(INK,0.55),linestyle=:dash,linewidth=1.2)

    axq = map_axis(fig[2,3], "Water vapour reservoir  |  ERA5";fontsize=15)
    hmq = heatmap!(axq,era5.longitude,era5.latitude,iwv;colormap=:Blues,colorrange=(0,60),interpolate=false)
    lines!(axq,coastline...;color=(INK,0.7),linewidth=0.6)
    Colorbar(fig[2,4],hmq;label="Column water vapour (kg m⁻²)",labelsize=14,ticklabelsize=12,width=15)

    axm = map_axis(fig[3:4,3],detail_title;longitude=(218,242),latitude=(40,54),fontsize=16)
    if !isnothing(model)
        heatmap!(axm,model.longitude,model.latitude,nest;colormap=IVT_COLORS,colorrange=IVT_LIMITS,
                 interpolate=false,nan_color=colorant"#eff2f5",highclip=last(IVT_COLORS))
    end
    overlays!(axm,coastline;detail=true)
    text!(axm,Point2f(0.04,0.05);text=detail_notice,space=:relative,fontsize=15,color=INK,
          strokecolor=:white,strokewidth=0.45,align=(:left,:bottom))
    Colorbar(fig[3:4,4],hm;label="IVT (kg m⁻¹ s⁻¹)",ticks=0:400:1600,width=17)

    Label(fig[5,1:2],sample_label;fontsize=15,color=MUTED,halign=:left,tellwidth=false)
    Label(fig[5,3:4],"Arrows: transport direction  •  Grey contours: sea-level pressure, 8 hPa",fontsize=12,color=MUTED,tellwidth=false)

    day_ticks = collect(first(dates):Day(1):last(dates))
    tick_h = Dates.value.(day_ticks .- first(dates)) ./ 3_600_000
    axt = Axis(fig[6,1:4];title="At the Washington coast  •  48°N, 124.75°W",titlealign=:left,titlesize=17,
               ylabel="IVT (kg m⁻¹ s⁻¹)",ylabelsize=15,xticks=(tick_h,Dates.format.(day_ticks,dateformat"u d")),
               xticklabelsize=14,yticklabelsize=13,ygridcolor=(:gray,0.12),xgridvisible=false)
    lines!(axt,h,coastal;color=ACCENT,linewidth=2.5,label="ERA5 • hourly")
    if !isnothing(model)
        mh = Dates.value.(model.dates .- first(dates)) ./ 3_600_000
        lines!(axt,mh,model_coastal;color=colorant"#b3503d",linewidth=1.7,label="3 km hindcast • 30 min")
    end
    hlines!(axt,[250];color=(MUTED,0.55),linestyle=:dash,linewidth=1)
    vlines!(axt,cursor;color=INK,linewidth=2)
    xlims!(axt,0,last(h)); ylims!(axt,0,max(1500,100ceil(maximum(coastal)/100),isempty(model_coastal) ? 0 : 100ceil(maximum(model_coastal)/100)))
    axislegend(axt;position=:lt,orientation=:horizontal,framevisible=false,labelsize=13,patchsize=(22,10))
    Label(fig[7,1:4],caption;fontsize=22,font=:bold,halign=:left,tellwidth=false)
    Label(fig[8,1:4],"ERA5 / ECMWF via ARCO-ERA5   •   NumericalEarth.jl / Breeze.jl hindcast   •   No temporal interpolation   •   AtmosphericRivers.jl",fontsize=13,color=MUTED,halign=:left,tellwidth=false)
    colsize!(fig.layout,1,Relative(0.315)); colsize!(fig.layout,2,Relative(0.315))
    colsize!(fig.layout,4,65)
    rowsize!(fig.layout,2,210); rowsize!(fig.layout,3,160); rowsize!(fig.layout,4,160); rowsize!(fig.layout,6,125)
    rowgap!(fig.layout,12); colgap!(fig.layout,20)

    last_era5 = Ref(0)
    function update_frame(date)
        n = available_index(era5.dates,date)
        isnothing(n) && error("No ERA5 coverage at $date")
        if n != last_era5[]
            f = era5_frame(era5,n)
            ivt[] = f.ivt; iwv[] = copy(f.iwv); pressure[] = f.pressure
            p,d = arrows(era5,f.east,f.north)
            CairoMakie.update!(arrowplot,p,d)
            last_era5[] = n
        end
        date_label[] = Dates.format(date,dateformat"u d, yyyy   HH:MM") * " UTC"
        sample_label[] = "ERA5 sample: " * Dates.format(era5.dates[n],dateformat"u d HH:MM") * " UTC  •  250 kg m⁻¹ s⁻¹ reference shown below"
        caption[] = event_caption(date)
        cursor[] = [Dates.value(date-first(dates))/3_600_000]
        m = isnothing(model) ? nothing : available_index(model.dates,date)
        if isnothing(m)
            nest[] = fill(NaN32,size(nest[]))
            detail_notice[] = isnothing(model) ? "No model file supplied" : "3 km output available\nDec 7 12:00 – Dec 10 12:00 UTC"
        else
            nest[] = model_frame(model,m)
            detail_notice[] = Dates.format(model.dates[m],dateformat"u d HH:MM") * " UTC\n30-minute output • boundary zone masked"
        end
    end

    try
        for (name,date) in [("development",DateTime(2025,12,6,12)),("landfall",DateTime(2025,12,8,12)),("second_pulse",DateTime(2025,12,10,0))]
            first(dates) <= date <= last(dates) || continue
            update_frame(date)
            save(joinpath(output_dir,"ar_$(name).png"),fig)
        end
        if preview
            animate_landfall(era5,model,coastline,output_dir;fps,preview=true)
            return nothing
        end
        record(fig,joinpath(output_dir,"ar_lifecycle.mp4"),dates;framerate=fps,compression=18,px_per_unit=2) do date
            update_frame(date)
            minute(date)==0 && hour(date)%12==0 && @info "Rendered" date
        end
        animate_landfall(era5,model,coastline,output_dir;fps)
        write_provenance(joinpath(output_dir,"provenance.toml"),era5,model;framerate=fps,dimensions=(3840,2160))
        @info "Animation complete" output_dir frames=length(dates)
    finally
        !isnothing(model) && close(model)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    animate()
end
