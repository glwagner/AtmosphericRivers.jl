# Accumulated surface precipitation from a `reactant_downscale.jl AR_ARCH=cuda` run, next to ERA5's
# total precipitation over the same window, plus the hourly rain rate averaged over the
# southwest-Washington / northwest-Oregon target box (land west of the Cascade crest) that the
# adjoint sensitivity study integrates over.
#
# The run file carries `accumulated_precipitation` (kg m⁻² = mm, running total since t = 0) in every
# snapshot, so the window total is a difference of two snapshots. ERA5 `total_precipitation` is
# hourly (metres, accumulated over the hour ENDING at the file's stamp) and is read straight from
# the `era5/` cache.
#
# Usage: julia --project=.. analysis/render_precipitation.jl run.jld2 [out.png]

using Oceananigans          # brings JLD2 into the loaded set (it is not a direct dependency)
using NumericalEarth        # likewise NCDatasets
using CairoMakie
using NaturalEarth, GeoInterface
using Dates
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
const NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")

root = joinpath(@__DIR__, "..")
run_path = ARGS[1]
out_path = length(ARGS) ≥ 2 ? ARGS[2] : replace(run_path, ".jld2" => "_precipitation.png")

# SW Washington + NW Oregon, west of the Cascade crest; land cells only (terrain height > 0).
const target_λ = (-124.2, -121.9)
const target_φ = (44.5, 47.0)

run = JLD2.jldopen(run_path, "r") do file
    iterations = sort(parse.(Int, keys(file["timeseries/t"])))
    (λ = Float64.(file["grid/lambda_center"]),
     φ = Float64.(file["grid/phi_center"]),
     h = Float64.(file["grid/terrain_height"]),
     t = [file["timeseries/t/$n"] for n in iterations],
     P = [Float64.(file["timeseries/accumulated_precipitation/$n"]) for n in iterations],
     start = DateTime(haskey(file, "meta/start_date") ? file["meta/start_date"] : "2025-12-07T12:00:00"))
end

λ, φ, h = run.λ, run.φ, run.h
hours = run.t ./ 3600
total = run.P[end] .- run.P[1]
window = (run.start, run.start + Second(round(Int, run.t[end])))

in_target = [target_λ[1] ≤ λ[i] ≤ target_λ[2] && target_φ[1] ≤ φ[j] ≤ target_φ[2] && h[i, j] > 0
             for i in eachindex(λ), j in eachindex(φ)]
target_mean(field) = sum(field[in_target]) / count(in_target)

# Hourly model rain rate over the target box, from consecutive snapshot differences.
model_rate = [target_mean(run.P[n+1] .- run.P[n]) / (hours[n+1] - hours[n]) for n in 1:length(hours)-1]
model_rate_hours = hours[2:end]

# ERA5 hourly total precipitation over the same window.
era5_box = "-130.0_-115.0_40.0_52.0"
era5_stamps = (window[1] + Hour(1)):Hour(1):window[2]
era5_file(d) = joinpath(root, "era5", "total_precipitation_ERA5HourlySingleLevel_" *
                        Dates.format(d, "yyyy-mm-ddTHH") * "_" * era5_box * ".nc")
era5_λ, era5_φ = NCDatasets.NCDataset(era5_file(first(era5_stamps))) do ds
    Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:])
end
era5_hourly = map(era5_stamps) do d
    NCDatasets.NCDataset(era5_file(d)) do ds
        tp = ds["tp"]
        1000 .* Float64.(coalesce.(ndims(tp) == 3 ? tp[:, :, 1] : tp[:, :], NaN))   # m → mm
    end
end
era5_total = sum(era5_hourly)
era5_target = [target_λ[1] ≤ x ≤ target_λ[2] && target_φ[1] ≤ y ≤ target_φ[2] for x in era5_λ, y in era5_φ]
## ERA5 has no land mask in this cache; within the target box over-ocean cells are few (the box
## starts at the coast), so the box mean is only weakly diluted.
era5_rate = [sum(p[era5_target]) / count(era5_target) for p in era5_hourly]
era5_order = sortperm(era5_φ)

coastλ, coastφ = natural_earth_lines("coastline")
box_λ = [target_λ[1], target_λ[2], target_λ[2], target_λ[1], target_λ[1]]
box_φ = [target_φ[1], target_φ[1], target_φ[2], target_φ[2], target_φ[1]]

fig = Figure(size = (1500, 1000), fontsize = 15)
title = @sprintf("24 h precipitation, %s → %s", Dates.format(window[1], "u d HH:MM"),
                 Dates.format(window[2], "u d HH:MM"))
Label(fig[0, 1:2], title; fontsize = 20, font = :bold)

colorrange = (0, 120)
colormap = :YlGnBu
λlims, φlims = (-131, -115), (40, 52)

ax_model = Axis(fig[1, 1]; title = @sprintf("Breeze 12 km nest (max %.0f mm)", maximum(total)),
                xlabel = "longitude (°E)", ylabel = "latitude (°N)", limits = (λlims, φlims), aspect = DataAspect())
heatmap!(ax_model, λ, φ, total; colorrange, colormap, lowclip = :white, highclip = :black)
contour!(ax_model, λ, φ, h; levels = [1000], color = (:gray30, 0.6), linewidth = 0.6)

ax_era5 = Axis(fig[1, 2]; title = @sprintf("ERA5 0.25° (max %.0f mm)", maximum(filter(isfinite, era5_total))),
               xlabel = "longitude (°E)", limits = (λlims, φlims), aspect = DataAspect())
hm = heatmap!(ax_era5, era5_λ, era5_φ[era5_order], era5_total[:, era5_order]; colorrange, colormap,
              lowclip = :white, highclip = :black)
Colorbar(fig[1, 3], hm; label = "mm per 24 h")

for ax in (ax_model, ax_era5)
    lines!(ax, coastλ, coastφ; color = :black, linewidth = 0.8)
    lines!(ax, box_λ, box_φ; color = :red, linewidth = 2)
end

ax_series = Axis(fig[2, 1:2]; xlabel = "hours since " * Dates.format(window[1], "yyyy-mm-dd HH:MM"),
                 ylabel = "mm h⁻¹",
                 title = @sprintf("target box mean (red): Breeze %.1f mm, ERA5 %.1f mm over the window",
                                  target_mean(total), sum(era5_rate)))
stairs!(ax_series, model_rate_hours, model_rate; step = :pre, color = :royalblue, linewidth = 2.5, label = "Breeze 12 km")
stairs!(ax_series, 1:length(era5_rate), era5_rate; step = :pre, color = :black, linewidth = 2, label = "ERA5")
axislegend(ax_series; position = :lt)
rowsize!(fig.layout, 2, Relative(0.28))

save(out_path, fig)
@info @sprintf("wrote %s — target box: %d land cells, Breeze %.2f mm, ERA5 %.2f mm",
               out_path, count(in_target), target_mean(total), sum(era5_rate))
