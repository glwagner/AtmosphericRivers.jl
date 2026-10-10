# Whole-event summary of a `reactant_downscale.jl AR_ARCH=cuda` run against ERA5:
#
#   <run>_ivt_leads.png      IVT, model vs ERA5, at matched lead times (default +6, 12, 24, 48, 72 h)
#   <run>_precip.png         24/48/72 h accumulated precipitation, model vs ERA5, and hourly/cumulative
#                            precipitation over the sensitivity target polygon (sensitivity/region.jl)
#                            and the northern coast band
#   <run>_drift.png          boundary noise and closure extremes through the run: max |w| at ~1.6 km in
#                            the outer 10 cells vs the interior, and min/max of ρe
#   <run>_ivt.mp4            side-by-side IVT animation, every 3 h (ERA5's IVT cadence in the cache)
#
# Usage: julia --project=.. analysis/event_summary.jl run.jld2
#        AR_LEADS=6,12,24,48,72 to change the IVT lead times.

using Oceananigans
using NumericalEarth
using CairoMakie
using NaturalEarth, GeoInterface
using Dates
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
const NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")
include(joinpath(@__DIR__, "..", "sensitivity", "region.jl"))   # TARGET_POLYGON, point_in_polygon

root = joinpath(@__DIR__, "..")
run_path = ARGS[1]
stem = replace(run_path, ".jld2" => "")
leads = parse.(Int, split(get(ENV, "AR_LEADS", "6,12,24,48,72"), ','))
const band_λ = (-131.0, -122.0); const band_φ = (46.0, 54.0)

file = JLD2.jldopen(run_path, "r")
λ = Float64.(file["grid/lambda_center"]); φ = Float64.(file["grid/phi_center"])
rf = Float64.(file["grid/z_face"]); zc = Float64.(file["grid/z_center"])
h = Float64.(file["grid/terrain_height"]); z_top = file["grid/z_top"]
start = DateTime(haskey(file, "meta/start_date") ? file["meta/start_date"] : "2025-12-07T12:00:00")
its = sort(parse.(Int, keys(file["timeseries/t"])))
hours = [file["timeseries/t/$n"] for n in its] ./ 3600
moisture = haskey(file, "timeseries/ρqᵉ") ? "ρqᵉ" : "ρqᵛ"
Nx, Ny = length(λ), length(φ)
Δz = [(rf[k+1] - rf[k]) * (1 - h[i, j] / z_top) for i in 1:Nx, j in 1:Ny, k in 1:length(rf)-1]
center_x(a) = size(a, 1) == Nx + 1 ? (a[1:end-1, :, :] .+ a[2:end, :, :]) ./ 2 : a
center_y(a) = size(a, 2) == Ny + 1 ? (a[:, 1:end-1, :] .+ a[:, 2:end, :]) ./ 2 : a
snapshot(hour) = its[argmin(abs.(hours .- hour))]

function model_ivt(n)
    ρq = Float64.(file["timeseries/$moisture/$n"]); ρd = Float64.(file["timeseries/ρᵈ/$n"])
    u = center_x(Float64.(file["timeseries/ρu/$n"])) ./ ρd
    v = center_y(Float64.(file["timeseries/ρv/$n"])) ./ ρd
    return hypot.(dropdims(sum(ρq .* u .* Δz, dims = 3), dims = 3), dropdims(sum(ρq .* v .* Δz, dims = 3), dims = 3))
end
accumulated(n) = Float64.(file["timeseries/accumulated_precipitation/$n"])

stamp(d) = Dates.format(d, "yyyy-mm-ddTHH")
function era5_ivt(date)
    read(c) = NCDatasets.NCDataset(joinpath(root, "era5",
        "vertical_integral_of_$(c)_water_vapour_flux_ERA5HourlySingleLevel_$(stamp(date))_-180.0_-110.0_20.0_62.0.nc")) do ds
        x = ds[first(k for k in keys(ds) if startswith(k, "viw"))]
        (Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:]), Float64.(coalesce.(x[:, :, 1], NaN)))
    end
    lo, la, e = read("eastward"); _, _, nn = read("northward")
    o = sortperm(la)
    return lo, la[o], hypot.(e, nn)[:, o]
end
function era5_tp(date)
    NCDatasets.NCDataset(joinpath(root, "era5",
        "total_precipitation_ERA5HourlySingleLevel_$(stamp(date))_-130.0_-115.0_40.0_52.0.nc")) do ds
        tp = ds["tp"]; la = Float64.(ds["latitude"][:]); o = sortperm(la)
        (Float64.(ds["longitude"][:]), la[o], 1000 .* Float64.(coalesce.(tp[:, :, 1], NaN))[:, o])
    end
end

# Masks: target polygon and northern band, on both grids.
target_mask(lo, la) = [point_in_polygon(a, b, TARGET_POLYGON) for a in lo, b in la]
band_mask(lo, la) = [band_λ[1] ≤ a ≤ band_λ[2] && band_φ[1] ≤ b ≤ band_φ[2] for a in lo, b in la]
masked_mean(x, m) = (v = x[m .& isfinite.(x)]; sum(v) / length(v))
mT, mB = target_mask(λ, φ), band_mask(λ, φ)
eλ, eφ, _ = era5_tp(start + Hour(1))
eT, eB = target_mask(eλ, eφ), band_mask(eλ, eφ)

coastλ, coastφ = natural_earth_lines("coastline")
poly_λ = [first.(TARGET_POLYGON); first(TARGET_POLYGON)[1]]
poly_φ = [last.(TARGET_POLYGON); first(TARGET_POLYGON)[2]]
band_rect = ([band_λ[1], band_λ[2], band_λ[2], band_λ[1], band_λ[1]], [band_φ[1], band_φ[1], band_φ[2], band_φ[2], band_φ[1]])
decorate!(ax) = (lines!(ax, coastλ, coastφ; color = :black, linewidth = 0.7);
                 lines!(ax, poly_λ, poly_φ; color = :red, linewidth = 1.5);
                 lines!(ax, band_rect...; color = :orange, linewidth = 1.2, linestyle = :dash))
summary_lines = String[]

# ## IVT at matched leads
fig = Figure(size = (430length(leads) + 120, 820), fontsize = 13)
Label(fig[0, 1:length(leads)], "IVT (kg m⁻¹ s⁻¹), 12 km nest (top) vs ERA5 (bottom) — $(basename(run_path))"; font = :bold)
for (c, L) in enumerate(leads)
    n = snapshot(L); ivt = model_ivt(n); lo, la, e = era5_ivt(start + Hour(L))
    line = @sprintf("IVT +%2d h: north band model %4.0f ERA5 %4.0f | domain max model %5.0f ERA5 %5.0f (inside the nest box)",
                    L, masked_mean(ivt, mB), masked_mean(e, band_mask(lo, la)), maximum(ivt),
                    maximum(e[[λ[1] ≤ a ≤ λ[end] && φ[1] ≤ b ≤ φ[end] for a in lo, b in la]]))
    push!(summary_lines, line)
    for (r, (lo_, la_, x, who)) in enumerate(((λ, φ, ivt, "model"), (lo, la, e, "ERA5")))
        ax = Axis(fig[r, c]; title = "$who +$L h", limits = ((-150, -110), (36, 58)), aspect = DataAspect())
        hm = heatmap!(ax, lo_, la_, x; colorrange = (0, 1000), colormap = :YlGnBu, highclip = :black)
        decorate!(ax)
        c == length(leads) && r == 1 && Colorbar(fig[1:2, length(leads) + 1], hm)
    end
end
save(stem * "_ivt_leads.png", fig)

# ## Precipitation: maps at 24/48/72 h and series
total_hours = floor(Int, last(hours))
windows = filter(≤(total_hours), [24, 48, 72])
era5_hourly = [era5_tp(start + Hour(k))[3] for k in 1:total_hours]
model_hourly_target = Float64[]; model_hourly_band = Float64[]
let previous = accumulated(snapshot(0))
    for k in 1:total_hours
        current = accumulated(snapshot(k))
        push!(model_hourly_target, masked_mean(current .- previous, mT))
        push!(model_hourly_band, masked_mean(current .- previous, mB))
        previous = current
    end
end
era5_hourly_target = [masked_mean(p, eT) for p in era5_hourly]
era5_hourly_band = [masked_mean(p, eB) for p in era5_hourly]

fig = Figure(size = (1500, 560length(windows) + 500), fontsize = 13)
Label(fig[0, 1:2], "Accumulated precipitation (mm) — red: target polygon, orange: northern band"; font = :bold)
for (r, W) in enumerate(windows)
    P = accumulated(snapshot(W)) .- accumulated(snapshot(0))
    E = sum(era5_hourly[1:W])
    push!(summary_lines, @sprintf("precip 0–%2d h: target model %5.1f ERA5 %5.1f mm | north model %5.1f ERA5 %5.1f mm | model interior max %4.0f",
                                  W, masked_mean(P, mT), masked_mean(E, eT), masked_mean(P, mB), masked_mean(E, eB),
                                  maximum(P[11:end-10, 11:end-10])))
    for (c, (lo, la, x, who)) in enumerate(((λ, φ, P, "Breeze 12 km"), (eλ, eφ, E, "ERA5")))
        ax = Axis(fig[r, c]; title = @sprintf("%s, 0–%d h", who, W), limits = ((-131, -115), (40, 54)), aspect = DataAspect())
        hm = heatmap!(ax, lo, la, x; colorrange = (0, 50W / 24), colormap = :YlGnBu, highclip = :black)
        decorate!(ax)
        c == 2 && Colorbar(fig[r, 3], hm)
    end
end
r = length(windows) + 1
for (c, (label, m, e)) in enumerate((("target polygon", model_hourly_target, era5_hourly_target),
                                     ("northern band", model_hourly_band, era5_hourly_band)))
    ax = Axis(fig[r, c]; title = "$label: hourly rate", xlabel = "hours since $(start)", ylabel = "mm h⁻¹")
    stairs!(ax, 1:total_hours, m; step = :pre, color = :royalblue, label = "Breeze 12 km")
    stairs!(ax, 1:total_hours, e; step = :pre, color = :black, label = "ERA5")
    axislegend(ax; position = :lt)
    ax2 = Axis(fig[r+1, c]; title = "$label: cumulative", xlabel = "hours", ylabel = "mm")
    lines!(ax2, 1:total_hours, cumsum(m); color = :royalblue, linewidth = 2)
    lines!(ax2, 1:total_hours, cumsum(e); color = :black, linewidth = 2)
end
save(stem * "_precip.png", fig)

# ## Drift: boundary noise and TKE extremes
k = argmin(abs.(zc .- 1600)); frame = 10
wmax_frame = Float64[]; wmax_interior = Float64[]; ρe_min = Float64[]; ρe_max = Float64[]
has_tke = haskey(file, "timeseries/ρe")
for n in its
    ρw = Float64.(file["timeseries/ρw/$n"]); ρd = Float64.(file["timeseries/ρᵈ/$n"])
    w = abs.((ρw[:, :, k] .+ ρw[:, :, k+1]) ./ 2 ./ ρd[:, :, k])
    inner = falses(Nx, Ny); inner[frame+1:Nx-frame, frame+1:Ny-frame] .= true
    push!(wmax_frame, maximum(w[.!inner])); push!(wmax_interior, maximum(w[inner]))
    if has_tke
        ρe = file["timeseries/ρe/$n"]; push!(ρe_min, minimum(ρe)); push!(ρe_max, maximum(ρe))
    end
end
fig = Figure(size = (1300, 450), fontsize = 13)
ax = Axis(fig[1, 1]; title = @sprintf("max |w| at %.1f km", zc[k] / 1000), xlabel = "hours", ylabel = "m s⁻¹")
lines!(ax, hours, wmax_frame; label = "outer $frame cells", color = :firebrick)
lines!(ax, hours, wmax_interior; label = "interior", color = :royalblue)
axislegend(ax; position = :lt)
if has_tke
    ax = Axis(fig[1, 2]; title = "ρe extremes (kg m⁻¹ s⁻²)", xlabel = "hours")
    lines!(ax, hours, ρe_max; label = "max", color = :firebrick)
    lines!(ax, hours, ρe_min; label = "min", color = :royalblue)
    axislegend(ax; position = :lt)
    push!(summary_lines, @sprintf("ρe: max %.3g (at %.0f h), min %.3g (at %.0f h); final max %.3g, min %.3g",
                                  maximum(ρe_max), hours[argmax(ρe_max)], minimum(ρe_min), hours[argmin(ρe_min)],
                                  last(ρe_max), last(ρe_min)))
end
push!(summary_lines, @sprintf("max |w| at %.1f km: frame %.2f → %.2f m/s (peak %.2f at %.0f h), interior %.2f → %.2f (peak %.2f at %.0f h)",
                              zc[k] / 1000, wmax_frame[2], last(wmax_frame), maximum(wmax_frame), hours[argmax(wmax_frame)],
                              wmax_interior[2], last(wmax_interior), maximum(wmax_interior), hours[argmax(wmax_interior)]))
save(stem * "_drift.png", fig)

# ## Side-by-side IVT animation, every 3 h
frames = 0:3:total_hours
frame_hour = Observable(first(frames))
model_frame = Observable(model_ivt(snapshot(0)))
lo, la, e0 = era5_ivt(start)
era5_frame = Observable(e0)
fig = Figure(size = (1400, 560), fontsize = 14)
title = lift(H -> "IVT (kg m⁻¹ s⁻¹) at $(start + Hour(H))  (+$H h)", frame_hour)
Label(fig[0, 1:2], title; font = :bold)
for (c, (lo_, la_, obs, who)) in enumerate(((λ, φ, model_frame, "Breeze 12 km nest"), (lo, la, era5_frame, "ERA5")))
    ax = Axis(fig[1, c]; title = who, limits = ((-150, -110), (36, 58)), aspect = DataAspect())
    hm = heatmap!(ax, lo_, la_, obs; colorrange = (0, 1000), colormap = :YlGnBu, highclip = :black)
    decorate!(ax)
    c == 2 && Colorbar(fig[1, 3], hm)
end
record(fig, stem * "_ivt.mp4", frames; framerate = 4) do H
    model_frame[] = model_ivt(snapshot(H)); era5_frame[] = era5_ivt(start + Hour(H))[3]; frame_hour[] = H
end
close(file)

open(stem * "_summary.txt", "w") do io
    foreach(l -> println(io, l), summary_lines)
end
foreach(println, summary_lines)
