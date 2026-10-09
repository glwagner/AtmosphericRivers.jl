# Loaded after animate_goes.jl so the satellite navigation and plotting functions
# are shared with the original movie. The original movie requires no ERA5 input.
import Contour
using SHA
include("data.jl")
using .LifecycleData: ERA5Series

"""Bracket a scan time with hourly analyses; never extrapolate."""
function ivt_bracket(times,date)
    length(times) >= 2 && issorted(times) || error("Need sorted ERA5 times")
    first(times) <= date <= last(times) || error("GOES scan outside ERA5 coverage: $date")
    left = min(searchsortedlast(times,date),length(times)-1)
    right = left+1
    times[right]-times[left] == Hour(1) || error("ERA5 bracket is not one hour")
    weight = Dates.value(date-times[left])/Dates.value(times[right]-times[left])
    (left,right,weight)
end

"""Interpolate east/north transport, then calculate its magnitude."""
function interpolated_ivt(series,date)
    left,right,weight = ivt_bracket(series.dates,date)
    u0,u1 = @view(series.east[:,:,left]),@view(series.east[:,:,right])
    v0,v1 = @view(series.north[:,:,left]),@view(series.north[:,:,right])
    ivt = @. hypot((1-weight)*u0+weight*u1,(1-weight)*v0+weight*v1)
    (; ivt,left,right,weight)
end

"""Extract in geographical coordinates first, then project each contour vertex."""
function projected_ivt_outline(longitude,latitude,ivt,threshold,project)
    size(ivt) == (length(longitude),length(latitude)) || error("IVT grid mismatch")
    all(isfinite,ivt) || error("Nonfinite IVT field")
    isfinite(threshold) && threshold > 0 || error("Invalid IVT threshold")
    points = Point2f[]
    for level in Contour.levels(Contour.contours(longitude,latitude,ivt,[threshold]))
        for segment in Contour.lines(level)
            lon,lat = Contour.coordinates(segment)
            for (λ,φ) in zip(lon,lat)
                push!(points,Point2f(project(λ,φ)))
            end
            # Keep disconnected regions disconnected. Open contours remain open
            # at the ERA5 domain edge; never invent a closing boundary there.
            push!(points,Point2f(NaN,NaN))
        end
    end
    points
end

function make_ivt_overlay(; directory=get(ENV,"AR_LIFECYCLE_DATA",joinpath(@__DIR__,"data")))
    config = movie_config(:water_vapor)
    series = ERA5Series(directory;first_day=Date(config.start),last_day=Date(config.stop))
    threshold = 250.0
    files = map(series.files) do file
        NCDatasets.NCDataset(file) do ds
            for name in ("ivt_east","ivt_north")
                ds[name].attrib["units"] == "kg m-1 s-1" || error("Unexpected IVT units")
            end
            Dict("name"=>basename(file),"sha256"=>bytes2hex(open(sha256,file)),
                 "source"=>String(ds.attrib["source"]))
        end
    end
    provenance = Dict{String,Any}(
        "data"=>"ERA5 vertically integrated eastward and northward water-vapour flux",
        "threshold_kg_m-1_s-1"=>threshold,"grid_degrees"=>0.25,"cadence_minutes"=>60,
        "threshold_reference"=>"https://cw3e.ucsd.edu/arscale/",
        "first_analysis"=>string(first(series.dates)),"last_analysis"=>string(last(series.dates)),
        "longitude_bounds_degrees_east"=>[first(series.longitude),last(series.longitude)],
        "latitude_bounds_degrees_north"=>[first(series.latitude),last(series.latitude)],
        "time_policy"=>"Linear interpolation of east/north IVT components to actual GOES scan start; then hypot. No extrapolation.",
        "spatial_policy"=>"Contour at 250 on the native 0.25-degree ERA5 grid; project vertices into ABI geometry. No spatial smoothing.",
        "classification"=>"Threshold exceedance only, without length/width/duration criteria or event tracking.",
        "gap_policy"=>"Hide the outline on the missing GOES scan card.",
        "style"=>Dict("color"=>"#f2ce78","opacity"=>0.60,"line_width_figure_pixels"=>0.8,"fill"=>false),
        "files"=>files)
    function draw!(ax,projection)
        points = Observable(Point2f[])
        # One fine unfilled line keeps the observed cloud texture unobstructed.
        lines!(ax,points;color=("#f2ce78",0.60),linewidth=0.8)
        (; points,label=Observable(""),project=(λ,φ)->scan_position(λ,φ,projection))
    end
    function update!(state,date;available=true)
        if !available
            state.points[] = Point2f[]
            state.label[] = "IVT outline hidden during the satellite data gap"
            return
        end
        sample = interpolated_ivt(series,date)
        state.points[] = projected_ivt_outline(series.longitude,series.latitude,sample.ivt,threshold,state.project)
        left = Dates.format(series.dates[sample.left],dateformat"dd u HH:MM")
        right = Dates.format(series.dates[sample.right],dateformat"dd u HH:MM")
        state.label[] = "Faint gold: IVT = 250 kg m⁻¹ s⁻¹  •  ERA5 0.25°  •  interpolated between $left and $right UTC"
    end
    credit = "NOAA GOES-18 + ERA5  •  IVT coverage: 15–65°N, 140°E–110°W  •  Threshold regions are not tracked AR events  •  Julia / AtmosphericRivers.jl"
    (; suffix="_ivt250",draw!,update!,credit,provenance)
end
