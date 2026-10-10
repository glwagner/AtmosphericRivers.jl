# The offshore precipitation streaks (~129–124°W) in a `reactant_downscale.jl AR_ARCH=cuda` run: 3-hour
# precipitation increments next to w at ~1.5 km at the end of each increment, over the offshore
# approach, so a streak can be told apart from grid imprinting (fixed in place, aligned with grid
# lines) or a lateral-boundary artefact (anchored to the frame) versus a meteorological band (moving
# with the flow, co-located with ascent).
#
# Usage: julia --project=.. analysis/inspect_streaks.jl run.jld2 [out.png]

using Oceananigans
using CairoMakie
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")

run_path = ARGS[1]
out_path = length(ARGS) ≥ 2 ? ARGS[2] : replace(run_path, ".jld2" => "_streaks.png")
windows = ((3, 6), (9, 12), (15, 18), (21, 24))

fig = Figure(size = (1900, 900), fontsize = 13)
JLD2.jldopen(run_path, "r") do file
    λ = Float64.(file["grid/lambda_center"]); φ = Float64.(file["grid/phi_center"])
    z = Float64.(file["grid/z_center"]); k = argmin(abs.(z .- 1500))
    its = sort(parse.(Int, keys(file["timeseries/t"])))
    t = [file["timeseries/t/$n"] for n in its] ./ 3600
    at(hour) = its[argmin(abs.(t .- hour))]
    for (c, (h₁, h₂)) in enumerate(windows)
        ΔP = Float64.(file["timeseries/accumulated_precipitation/$(at(h₂))"]) .-
             Float64.(file["timeseries/accumulated_precipitation/$(at(h₁))"])
        ρw = Float64.(file["timeseries/ρw/$(at(h₂))"]); ρd = Float64.(file["timeseries/ρᵈ/$(at(h₂))"])
        w = (ρw[:, :, k] .+ ρw[:, :, k+1]) ./ 2 ./ ρd[:, :, k]
        lims = ((-134, -120), (40, 54))
        ax = Axis(fig[1, c]; title = "precip +$(h₁)…+$(h₂) h (mm)", limits = lims, aspect = DataAspect())
        hm = heatmap!(ax, λ, φ, ΔP; colorrange = (0, 15), colormap = :YlGnBu, highclip = :black)
        c == 4 && Colorbar(fig[1, 5], hm)
        ax = Axis(fig[2, c]; title = @sprintf("w at ~%.1f km, +%d h (m/s)", z[k] / 1000, h₂), limits = lims,
                  aspect = DataAspect())
        hm = heatmap!(ax, λ, φ, w; colorrange = (-0.3, 0.3), colormap = :balance)
        c == 4 && Colorbar(fig[2, 5], hm)
    end
end
save(out_path, fig)
println("wrote ", out_path)
