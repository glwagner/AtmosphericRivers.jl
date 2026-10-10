# Moisture diagnostics for a `reactant_downscale.jl AR_ARCH=cuda` run against ERA5: IVT and column
# water vapour (IWV) maps at +6, +12 and +24 h, and their means over the northern coastal band
# (46–54°N, 131–122°W) where the 12 km nest comes out drier than ERA5. Also locates the run's
# precipitation maximum and reports the terrain height and slope there.
#
# Model IWV integrates the run's moisture prognostic (ρqᵉ, vapour + cloud condensate, under the default
# saturation-adjustment scheme; ρqᵛ otherwise) over physical layer thicknesses Δz = Δr·(1 − h/z_top).
# ERA5 IVT is the cached single-level vertical integral; ERA5 IWV integrates pressure-level q over
# 1000–70 hPa without a surface-pressure cut (a slight overestimate over high terrain).
#
# Usage: julia --project=.. analysis/diagnose_moisture.jl run.jld2 [out.png]

using Oceananigans
using NumericalEarth
using CairoMakie
using NaturalEarth, GeoInterface
using Dates
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
const NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")

root = joinpath(@__DIR__, "..")
run_path = ARGS[1]
out_path = length(ARGS) ≥ 2 ? ARGS[2] : replace(run_path, ".jld2" => "_moisture.png")

const band_λ = (-131.0, -122.0)
const band_φ = (46.0, 54.0)
const lead_hours = (6, 12, 24)

file = JLD2.jldopen(run_path, "r")
λ = Float64.(file["grid/lambda_center"]); φ = Float64.(file["grid/phi_center"])
rf = Float64.(file["grid/z_face"]); h = Float64.(file["grid/terrain_height"]); z_top = file["grid/z_top"]
start = DateTime(haskey(file, "meta/start_date") ? file["meta/start_date"] : "2025-12-07T12:00:00")
iterations = sort(parse.(Int, keys(file["timeseries/t"])))
times = [file["timeseries/t/$n"] for n in iterations]
moisture = haskey(file, "timeseries/ρqᵉ") ? "ρqᵉ" : "ρqᵛ"
Nx, Ny = length(λ), length(φ)
Δz = [(rf[k+1] - rf[k]) * (1 - h[i, j] / z_top) for i in 1:Nx, j in 1:Ny, k in 1:length(rf)-1]

center_x(a) = size(a, 1) == Nx + 1 ? (a[1:end-1, :, :] .+ a[2:end, :, :]) ./ 2 : a
center_y(a) = size(a, 2) == Ny + 1 ? (a[:, 1:end-1, :] .+ a[:, 2:end, :]) ./ 2 : a

function model_columns(hour)
    n = iterations[argmin(abs.(times .- 3600hour))]
    ρq = Float64.(file["timeseries/$moisture/$n"])
    ρd = Float64.(file["timeseries/ρᵈ/$n"])
    u = center_x(Float64.(file["timeseries/ρu/$n"])) ./ ρd
    v = center_y(Float64.(file["timeseries/ρv/$n"])) ./ ρd
    iwv = dropdims(sum(ρq .* Δz, dims = 3), dims = 3)
    ivt = hypot.(dropdims(sum(ρq .* u .* Δz, dims = 3), dims = 3), dropdims(sum(ρq .* v .* Δz, dims = 3), dims = 3))
    return iwv, ivt
end

stamp(d) = Dates.format(d, "yyyy-mm-ddTHH")
function era5_ivt(date)
    read(component) = NCDatasets.NCDataset(joinpath(root, "era5",
        "vertical_integral_of_$(component)_water_vapour_flux_ERA5HourlySingleLevel_$(stamp(date))_-180.0_-110.0_20.0_62.0.nc")) do ds
        name = first(k for k in keys(ds) if startswith(k, "viw"))
        x = ds[name]
        (Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:]),
         Float64.(coalesce.(ndims(x) == 3 ? x[:, :, 1] : x[:, :], NaN)))
    end
    lo, la, e = read("eastward"); _, _, n = read("northward")
    return lo, la, hypot.(e, n)
end
function era5_iwv(date)
    NCDatasets.NCDataset(joinpath(root, "era5",
        "specific_humidity_ERA5HourlyPressureLevels_$(stamp(date))_-170.5_-109.5_24.5_60.5.nc")) do ds
        q = Float64.(coalesce.(ds["q"][:, :, :, 1], NaN))
        p = 100 .* Float64.(ds["pressure_level"][:])                # hPa → Pa
        order = sortperm(p)
        p, q = p[order], q[:, :, order]
        Δp = diff(p)
        iwv = sum((q[:, :, 1:end-1] .+ q[:, :, 2:end]) ./ 2 .* reshape(Δp, 1, 1, :), dims = 3) ./ 9.81
        Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:]), dropdims(iwv, dims = 3)
    end
end

band_mean(x, lo, la) = begin
    m = [band_λ[1] ≤ a ≤ band_λ[2] && band_φ[1] ≤ b ≤ band_φ[2] for a in lo, b in la]
    v = x[m]; v = v[isfinite.(v)]; sum(v) / length(v)
end
sorted(lo, la, x) = (o = sortperm(la); (lo, la[o], x[:, o]))

coastλ, coastφ = natural_earth_lines("coastline")
box_λ = [band_λ[1], band_λ[2], band_λ[2], band_λ[1], band_λ[1]]
box_φ = [band_φ[1], band_φ[1], band_φ[2], band_φ[2], band_φ[1]]

fig = Figure(size = (2000, 1450), fontsize = 14)
Label(fig[0, 1:6], "12 km nest vs ERA5 — IVT and column water vapour; box: 46–54°N, 131–122°W  ($(basename(run_path)))";
      fontsize = 18, font = :bold)
lims = ((-150, -110), (36, 58))
summary_lines = String[]
for (c, hour) in enumerate(lead_hours)
    date = start + Hour(hour)
    iwv, ivt = model_columns(hour)
    eλ, eφ, eivt = era5_ivt(date)
    wλ, wφ, eiwv = era5_iwv(date)
    push!(summary_lines, @sprintf("+%2d h  IVT model %5.0f  ERA5 %5.0f kg m⁻¹ s⁻¹ | IWV model %4.1f  ERA5 %4.1f kg m⁻²",
                                  hour, band_mean(ivt, λ, φ), band_mean(eivt, eλ, eφ),
                                  band_mean(iwv, λ, φ), band_mean(eiwv, wλ, wφ)))
    for (r, (label, field, era, range)) in enumerate((("IVT", ivt, (eλ, eφ, eivt), (0, 1000)),
                                                     ("IWV", iwv, (wλ, wφ, eiwv), (0, 35))))
        for (s, (who, lo, la, x)) in enumerate((("model", λ, φ, field), ("ERA5", sorted(era...)...)))
            ax = Axis(fig[r, 2(c - 1) + s]; title = "$label $who +$(hour) h", limits = lims, aspect = DataAspect())
            hm = heatmap!(ax, lo, la, x; colorrange = range, colormap = :YlGnBu, highclip = :black)
            lines!(ax, coastλ, coastφ; color = :black, linewidth = 0.7)
            lines!(ax, box_λ, box_φ; color = :red, linewidth = 1.5)
            c == 3 && s == 2 && Colorbar(fig[r, 7], hm; label = label == "IVT" ? "kg m⁻¹ s⁻¹" : "kg m⁻²")
        end
    end
end

# Precipitation maximum and the terrain under it.
P = Float64.(file["timeseries/accumulated_precipitation/$(last(iterations))"]) .-
    Float64.(file["timeseries/accumulated_precipitation/$(first(iterations))"])
imax, jmax = Tuple(argmax(P))
Δx = 111e3 * cosd(φ[jmax]) * (λ[2] - λ[1]); Δy = 111e3 * (φ[2] - φ[1])
slope(i, j) = hypot((h[min(i+1, Nx), j] - h[max(i-1, 1), j]) / 2Δx, (h[i, min(j+1, Ny)] - h[i, max(j-1, 1)]) / 2Δy)
push!(summary_lines, @sprintf("precip max %.0f mm at (%.2f°E, %.2f°N): terrain %.0f m, slope %.3f (domain max slope %.3f)",
                              P[imax, jmax], λ[imax], φ[jmax], h[imax, jmax], slope(imax, jmax),
                              maximum(slope(i, j) for i in 2:Nx-1, j in 2:Ny-1)))
second = sort(vec(P), rev = true)[1:5]
push!(summary_lines, "five largest cell totals (mm): " * join((@sprintf("%.0f", x) for x in second), ", "))
close(file)

Label(fig[3, 1:6], join(summary_lines, "\n"); fontsize = 14, halign = :left, justification = :left,
      tellwidth = false)
save(out_path, fig)
foreach(println, summary_lines)
println("wrote ", out_path)
