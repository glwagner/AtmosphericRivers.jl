# Side-by-side 24 h accumulated precipitation from several `reactant_downscale.jl AR_ARCH=cuda` runs
# and ERA5, with a table of the SW WA / NW OR target-box mean, the northern-coast band mean
# (46–54°N, 131–122°W, land and sea) and the domain maximum.
#
# Usage: julia --project=.. analysis/compare_precipitation.jl out.png label1=run1.jld2 label2=run2.jld2 …

using Oceananigans
using NumericalEarth
using CairoMakie
using NaturalEarth, GeoInterface
using Dates
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
const NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")

root = joinpath(@__DIR__, "..")
out_path = ARGS[1]
runs = [Pair(split(a, "=", limit = 2)...) for a in ARGS[2:end]]

const target_λ = (-124.2, -121.9); const target_φ = (44.5, 47.0)
const band_λ = (-131.0, -122.0);   const band_φ = (46.0, 54.0)

function load(path)
    JLD2.jldopen(path, "r") do file
        its = sort(parse.(Int, keys(file["timeseries/t"])))
        t = [file["timeseries/t/$n"] for n in its]
        n24 = its[argmin(abs.(t .- 86400))]
        P = Float64.(file["timeseries/accumulated_precipitation/$n24"]) .-
            Float64.(file["timeseries/accumulated_precipitation/$(first(its))"])
        (λ = Float64.(file["grid/lambda_center"]), φ = Float64.(file["grid/phi_center"]),
         h = Float64.(file["grid/terrain_height"]), P = P, hours = t[its .== n24][1] / 3600)
    end
end

mean_in(x, λ, φ, box_λ, box_φ, keep = trues(size(x))) = begin
    m = [box_λ[1] ≤ a ≤ box_λ[2] && box_φ[1] ≤ b ≤ box_φ[2] for a in λ, b in φ] .& keep
    v = x[m]; v = v[isfinite.(v)]; sum(v) / length(v)
end

start = DateTime(2025, 12, 7, 12)
era5_file(d) = joinpath(root, "era5", "total_precipitation_ERA5HourlySingleLevel_" *
                        Dates.format(d, "yyyy-mm-ddTHH") * "_-130.0_-115.0_40.0_52.0.nc")
eλ, eφ = NCDatasets.NCDataset(ds -> (Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:])), era5_file(start + Hour(1)))
era5 = sum(NCDatasets.NCDataset(era5_file(d)) do ds
               tp = ds["tp"]; 1000 .* Float64.(coalesce.(ndims(tp) == 3 ? tp[:, :, 1] : tp[:, :], NaN))
           end for d in (start + Hour(1)):Hour(1):(start + Hour(24)))
o = sortperm(eφ); eφ = eφ[o]; era5 = era5[:, o]

coastλ, coastφ = natural_earth_lines("coastline")
rect(bλ, bφ) = ([bλ[1], bλ[2], bλ[2], bλ[1], bλ[1]], [bφ[1], bφ[1], bφ[2], bφ[2], bφ[1]])

panels = length(runs) + 1
ncol = min(panels, 3)
fig = Figure(size = (650ncol, 560cld(panels, ncol) + 80), fontsize = 14)
lines_out = String[@sprintf("%-26s %9s %9s %8s %s", "run", "target mm", "north mm", "max mm",
                             "interior max (≥10 cells from the walls): mm @ lon, lat, terrain m, slope")]
function panel!(k, title, λ, φ, P)
    ax = Axis(fig[cld(k, ncol), mod1(k, ncol)]; title, limits = ((-131, -115), (40, 54)), aspect = DataAspect())
    hm = heatmap!(ax, λ, φ, P; colorrange = (0, 120), colormap = :YlGnBu, highclip = :black)
    lines!(ax, coastλ, coastφ; color = :black, linewidth = 0.7)
    lines!(ax, rect(target_λ, target_φ)...; color = :red, linewidth = 1.5)
    lines!(ax, rect(band_λ, band_φ)...; color = :orange, linewidth = 1.5, linestyle = :dash)
    return hm
end
for (k, (label, path)) in enumerate(runs)
    r = load(path)
    target = mean_in(r.P, r.λ, r.φ, target_λ, target_φ, r.h .> 0)
    north = mean_in(r.P, r.λ, r.φ, band_λ, band_φ)
    ## The frame-rim maximum is a boundary artefact; the interior maximum is the one over terrain.
    Nx, Ny = size(r.P); f = 10
    Pi = r.P[f+1:Nx-f, f+1:Ny-f]; ii, jj = Tuple(argmax(Pi)) .+ f
    Δx = 111e3 * cosd(r.φ[jj]) * (r.λ[2] - r.λ[1]); Δy = 111e3 * (r.φ[2] - r.φ[1])
    slope = hypot((r.h[ii+1, jj] - r.h[ii-1, jj]) / 2Δx, (r.h[ii, jj+1] - r.h[ii, jj-1]) / 2Δy)
    push!(lines_out, @sprintf("%-26s %9.1f %9.1f %8.0f %6.0f @ %.2f, %.2f, %4.0f m, %.3f", label, target, north,
                              maximum(r.P), r.P[ii, jj], r.λ[ii], r.φ[jj], r.h[ii, jj], slope))
    panel!(k, @sprintf("%s: target %.1f, north %.1f, max %.0f mm", label, target, north, maximum(r.P)), r.λ, r.φ, r.P)
end
target = mean_in(era5, eλ, eφ, target_λ, target_φ)
north = mean_in(era5, eλ, eφ, band_λ, band_φ)
push!(lines_out, @sprintf("%-26s %9.1f %9.1f %8.0f", "ERA5 (0.25°)", target, north, maximum(filter(isfinite, era5))))
hm = panel!(panels, @sprintf("ERA5: target %.1f, north %.1f mm", target, north), eλ, eφ, era5)
Colorbar(fig[1, ncol + 1], hm; label = "mm, Dec 7 12Z → Dec 8 12Z")
Label(fig[0, 1:ncol], "24 h precipitation; red = SW WA/NW OR target (land), orange dashed = northern coast band";
      fontsize = 17, font = :bold)
save(out_path, fig)
foreach(println, lines_out)
println("wrote ", out_path)
