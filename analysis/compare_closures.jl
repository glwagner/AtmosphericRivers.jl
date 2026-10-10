# Compare 24 h `reactant_downscale.jl AR_ARCH=cuda` runs that differ only in the turbulence closure
# (e.g. no closure, Breeze main's `TKEBasedTurbulenceClosure`, Breeze #975's defaults, CATKE
# parameters) against ERA5:
#
#   * 24 h accumulated precipitation maps, zoomed on the Pacific Northwest, with the sensitivity
#     study's target polygon (`sensitivity/region.jl`) outlined, next to ERA5;
#   * the hourly precipitation rate averaged over that polygon (area-weighted, fractional coverage);
#   * IVT ≈ |Σ ρqᵉ u Δz| at the last snapshot;
#   * turbulent kinetic energy e = ρe/ρᵈ profiles and a TKE-based boundary-layer depth at three
#     columns (offshore AR core, coast, Cascades).
#
# Usage: julia --project=.. analysis/compare_closures.jl out.png label1=run1.jld2 label2=run2.jld2 ...

using Oceananigans          # brings JLD2 into the loaded set
using NumericalEarth        # likewise NCDatasets
using CairoMakie
using NaturalEarth, GeoInterface
using Dates
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
const NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")

root = joinpath(@__DIR__, "..")
include(joinpath(root, "sensitivity", "region.jl"))

out_path = ARGS[1]
runs_spec = [split(a, "="; limit = 2) for a in ARGS[2:end]]

# Columns for the profiles: (label, λ, φ)
const columns = (("offshore AR core", -128.0, 45.5),
                 ("coast (Tillamook)", -123.85, 45.45),
                 ("Cascades (W slope)", -122.1, 45.9))

function centers(a, N)        # face-located interior → centers along the first or second axis
    size(a, 1) == N + 1 && return (a[1:end-1, :, :] .+ a[2:end, :, :]) ./ 2
    size(a, 2) == N + 1 && return (a[:, 1:end-1, :] .+ a[:, 2:end, :]) ./ 2
    return a
end

# Physical heights of the terrain-following grid. Prefer the file's own; otherwise reconstruct
# LinearDecay's z = r + h (1 − r / z_top) from the reference coordinate.
function physical_heights(file, h)
    haskey(file, "grid/z_physical_center") &&
        return Float64.(file["grid/z_physical_center"]), Float64.(file["grid/z_physical_face"])
    rc = Float64.(file["grid/z_center"]); rf = Float64.(file["grid/z_face"])
    ztop = haskey(file, "grid/z_top") ? Float64(file["grid/z_top"]) : rf[end]
    zc = [rc[k] + h[i, j] * (1 - rc[k] / ztop) for i in axes(h, 1), j in axes(h, 2), k in eachindex(rc)]
    zf = [rf[k] + h[i, j] * (1 - rf[k] / ztop) for i in axes(h, 1), j in axes(h, 2), k in eachindex(rf)]
    return zc, zf
end

function load_run(label, path)
    JLD2.jldopen(path, "r") do file
        its = sort(parse.(Int, keys(file["timeseries/t"])))
        λc = Float64.(file["grid/lambda_center"]); φc = Float64.(file["grid/phi_center"])
        λf = Float64.(file["grid/lambda_face"]);   φf = Float64.(file["grid/phi_face"])
        h = Float64.(file["grid/terrain_height"])
        Nx, Ny = length(λc), length(φc)
        zc, zf = physical_heights(file, h)
        Δz = diff(zf; dims = 3)
        t = [file["timeseries/t/$n"] for n in its]
        P = [Float64.(file["timeseries/accumulated_precipitation/$n"]) for n in its]
        names = keys(file["timeseries"])
        last = its[end]
        ρ = Float64.(file["timeseries/ρᵈ/$last"])
        ρq = Float64.(file["timeseries/ρqᵉ/$last"])
        u = centers(Float64.(file["timeseries/ρu/$last"]), Nx) ./ ρ
        v = centers(Float64.(file["timeseries/ρv/$last"]), Ny) ./ ρ
        IVT = sqrt.(dropdims(sum(ρq .* u .* Δz; dims = 3); dims = 3) .^ 2 .+
                    dropdims(sum(ρq .* v .* Δz; dims = 3); dims = 3) .^ 2)
        has_tke = "ρe" in names
        tke = has_tke ? [Float64.(file["timeseries/ρe/$n"]) ./ Float64.(file["timeseries/ρᵈ/$n"]) for n in its] : nothing
        (; label, path, λc, φc, λf, φf, h, zc, t, P, IVT, tke,
           start = DateTime(haskey(file, "meta/start_date") ? file["meta/start_date"] : "2025-12-07T12:00:00"))
    end
end

runs = [load_run(String(l), String(p)) for (l, p) in runs_spec]
ref = first(runs)
w, area = region_weights(ref.λf, ref.φf)
regional(field) = sum(w .* field)

# ERA5 hourly total precipitation over the window of the first run
window = (ref.start, ref.start + Second(round(Int, ref.t[end])))
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
        1000 .* Float64.(coalesce.(ndims(tp) == 3 ? tp[:, :, 1] : tp[:, :], NaN))
    end
end
era5_total = sum(era5_hourly)
era5_in = [point_in_polygon(x, y, TARGET_POLYGON) for x in era5_λ, y in era5_φ]
era5_rate = [sum(p[era5_in]) / count(era5_in) for p in era5_hourly]
era5_order = sortperm(era5_φ)

nearest(a, x) = argmin(abs.(a .- x))

# TKE boundary-layer depth: the height above ground where e first falls below 10 % of its maximum
# in the lowest 4 km (and below 0.01 m² s⁻²).
function pbl_depth(e, z, hg)
    za = z .- hg
    low = findall(<(4000), za)
    isempty(low) && return NaN
    emax = maximum(e[low])
    emax < 0.01 && return 0.0
    k = findfirst(k -> za[k] > 0 && e[k] < max(0.1emax, 0.01), eachindex(e))
    return k === nothing ? NaN : za[k]
end

println("closure comparison — target polygon area-weighted mean 24 h precipitation:")
@printf("  %-28s %8.2f mm\n", "ERA5", sum(era5_rate))
summary_rows = map(runs) do r
    total = r.P[end] .- r.P[1]
    pbl = map(columns) do (_, λ, φ)
        i, j = nearest(r.λc, λ), nearest(r.φc, φ)
        r.tke === nothing ? NaN : maximum(pbl_depth(e[i, j, :], r.zc[i, j, :], r.h[i, j]) for e in r.tke)
    end
    @printf("  %-28s %8.2f mm   max cell %6.0f mm   max IVT %6.0f kg m⁻¹ s⁻¹   max PBL depth (m) %s\n",
            r.label, regional(total), maximum(total), maximum(r.IVT), join(map(x -> @sprintf("%.0f", x), pbl), " / "))
    (; r.label, regional = regional(total), max = maximum(total))
end

coastλ, coastφ = natural_earth_lines("coastline")
poly_λ = [p[1] for p in TARGET_POLYGON]; poly_φ = [p[2] for p in TARGET_POLYGON]
push!(poly_λ, poly_λ[1]); push!(poly_φ, poly_φ[1])

n = length(runs)
fig = Figure(size = (420 * (n + 1) + 120, 1500), fontsize = 14)
Label(fig[0, 1:n+1], @sprintf("Turbulence closures — 24 h, %s → %s",
                               Dates.format(window[1], "u d HH:MM"), Dates.format(window[2], "u d HH:MM"));
      fontsize = 20, font = :bold)
λlims, φlims = (-129, -118), (42, 50)
hm = nothing
for (c, r) in enumerate(runs)
    total = r.P[end] .- r.P[1]
    ax = Axis(fig[1, c]; title = @sprintf("%s\nregion %.1f mm, max %.0f mm", r.label, regional(total), maximum(total)),
              limits = (λlims, φlims), aspect = DataAspect())
    global hm = heatmap!(ax, r.λc, r.φc, total; colorrange = (0, 120), colormap = :YlGnBu, highclip = :black)
    contour!(ax, r.λc, r.φc, r.h; levels = [1000], color = (:gray30, 0.6), linewidth = 0.6)
    lines!(ax, coastλ, coastφ; color = :black, linewidth = 0.7)
    lines!(ax, poly_λ, poly_φ; color = :red, linewidth = 2)

    axi = Axis(fig[2, c]; title = @sprintf("IVT at +%.0f h (max %.0f)", r.t[end] / 3600, maximum(r.IVT)),
               limits = ((-148, -112), (38, 56)), aspect = DataAspect())
    heatmap!(axi, r.λc, r.φc, r.IVT; colorrange = (0, 1200), colormap = :viridis)
    lines!(axi, coastλ, coastφ; color = :white, linewidth = 0.6)
end
axe = Axis(fig[1, n+1]; title = @sprintf("ERA5 0.25°\nregion %.1f mm, max %.0f mm", sum(era5_rate), maximum(filter(isfinite, era5_total))),
           limits = (λlims, φlims), aspect = DataAspect())
heatmap!(axe, era5_λ, era5_φ[era5_order], era5_total[:, era5_order]; colorrange = (0, 120), colormap = :YlGnBu, highclip = :black)
lines!(axe, coastλ, coastφ; color = :black, linewidth = 0.7)
lines!(axe, poly_λ, poly_φ; color = :red, linewidth = 2)
Colorbar(fig[1, n+2], hm; label = "mm per 24 h")

colors = Makie.wong_colors()
axs = Axis(fig[3, 1:n+1]; xlabel = "hours since " * Dates.format(window[1], "yyyy-mm-dd HH:MM"), ylabel = "mm h⁻¹",
           title = "target-polygon mean precipitation rate")
for (c, r) in enumerate(runs)
    hours = r.t ./ 3600
    rate = [regional(r.P[k+1] .- r.P[k]) / (hours[k+1] - hours[k]) for k in 1:length(hours)-1]
    stairs!(axs, hours[2:end], rate; step = :pre, color = colors[c], linewidth = 2, label = r.label)
end
stairs!(axs, 1:length(era5_rate), era5_rate; step = :pre, color = :black, linewidth = 2, label = "ERA5")
axislegend(axs; position = :rt)

for (c, (name, λ, φ)) in enumerate(columns)
    ax = Axis(fig[4, c]; title = "e profile, " * name * " (+$(round(Int, ref.t[end] ÷ 3600)) h max over time)",
              xlabel = "max_t e (m² s⁻²)", ylabel = "height above ground (m)", limits = (nothing, (0, 4000)))
    for (ir, r) in enumerate(runs)
        r.tke === nothing && continue
        i, j = nearest(r.λc, λ), nearest(r.φc, φ)
        emax = reduce((a, b) -> max.(a, b), (e[i, j, :] for e in r.tke))
        lines!(ax, emax, r.zc[i, j, :] .- r.h[i, j]; color = colors[ir], linewidth = 2, label = r.label)
    end
end
rowsize!(fig.layout, 3, Relative(0.14)); rowsize!(fig.layout, 4, Relative(0.2))
save(out_path, fig)
@info "wrote $out_path"
