# 24 h precipitation summary for mixed-phase runs: polygon-mean (sensitivity/region.jl, area-weighted),
# the northern band (46–54°N, 131–122°W), the snow share of the surface flux, and a map figure.
#
# Usage: julia --project=<env with JLD2 + CairoMakie> analysis/precip_snow_summary.jl out.png label=run.jld2 …
using JLD2, CairoMakie, Printf
include(joinpath(@__DIR__, "..", "sensitivity", "region.jl"))

out = ARGS[1]
runs = [Pair(split(a, "=", limit = 2)...) for a in ARGS[2:end]]

function summarize(path)
    jldopen(path, "r") do f
        ts = f["timeseries"]
        its = sort(parse.(Int, keys(ts["t"])))
        t = [ts["t/$n"] for n in its]
        n24 = its[argmin(abs.(t .- 86400))]
        P = Float64.(ts["accumulated_precipitation/$n24"]) .- Float64.(ts["accumulated_precipitation/$(first(its))"])
        λc = Float64.(f["grid/lambda_center"]); φc = Float64.(f["grid/phi_center"])
        Δλ = λc[2] - λc[1]; Δφ = φc[2] - φc[1]
        λf = vcat(λc .- Δλ/2, λc[end] + Δλ/2); φf = vcat(φc .- Δφ/2, φc[end] + Δφ/2)
        w, _ = region_weights(λf, φf)
        band = [(-131 ≤ a ≤ -122) && (46 ≤ b ≤ 54) for a in λc, b in φc]
        snowmax = haskey(ts, "ρqˢⁿ") ? maximum(ts["ρqˢⁿ/$n24"]) : 0.0
        (; P, λc, φc, target = sum(w .* P), north = sum(P[band]) / count(band), pmax = maximum(P), snowmax)
    end
end

fig = Figure(size = (450 * length(runs), 480))
for (k, (label, path)) in enumerate(runs)
    r = summarize(path)
    @printf("%-28s polygon %.2f mm  north %.2f mm  max %.0f mm  max ρqˢⁿ(24h) %.2e\n", label, r.target, r.north, r.pmax, r.snowmax)
    ax = Axis(fig[1, k]; title = @sprintf("%s\npolygon %.1f, north %.1f mm", label, r.target, r.north),
              limits = ((-131, -116), (40, 54)), aspect = DataAspect())
    heatmap!(ax, r.λc, r.φc, r.P; colormap = :YlGnBu, colorrange = (0, 80))
    ring = vcat(TARGET_POLYGON, TARGET_POLYGON[1:1])
    lines!(ax, first.(ring), last.(ring); color = :red)
end
Colorbar(fig[1, length(runs) + 1]; colormap = :YlGnBu, limits = (0, 80), label = "mm / 24 h")
save(out, fig)
