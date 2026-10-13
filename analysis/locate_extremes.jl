# Where do a run's prognostics go bad? For each snapshot: the extreme value of every prognostic, its
# (i, j, k), its distance in cells from the nearest lateral wall, and the terrain height there.
#
# Usage: julia --project=.. analysis/locate_extremes.jl run.jld2 [first_hour last_hour]
using Oceananigans
using Printf
const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")

JLD2.jldopen(ARGS[1], "r") do file
    λ = file["grid/lambda_center"]; φ = file["grid/phi_center"]; h = file["grid/terrain_height"]
    Nx, Ny = length(λ), length(φ)
    its = sort(parse.(Int, keys(file["timeseries/t"])))
    t = [file["timeseries/t/$n"] for n in its] ./ 3600
    h₁, h₂ = length(ARGS) ≥ 3 ? parse.(Float64, ARGS[2:3]) : (0.0, Inf)
    names = filter(k -> k ∉ ("t", "precipitation_flux", "accumulated_precipitation"), keys(file["timeseries"]))
    for (n, tn) in zip(its, t)
        h₁ ≤ tn ≤ h₂ || continue
        println(@sprintf("--- t = %.2f h (iteration %d)", tn, n))
        for name in names
            x = file["timeseries/$name/$n"]
            bad = count(!isfinite, x)
            y = map(v -> isfinite(v) ? v : zero(v), x)
            for (label, idx) in (("min", argmin(y)), ("max", argmax(y)))
                i, j, k = Tuple(idx)
                ic, jc = min(i, Nx), min(j, Ny)
                wall = min(i - 1, Nx - i, j - 1, Ny - j)
                println(@sprintf("%-6s %s %11.4g at (%3d,%3d,%2d) %.2f°E %.2f°N  %2d cells from wall  terrain %4.0f m%s",
                                 name, label, y[idx], i, j, k, λ[ic], φ[jc], wall, h[ic, jc],
                                 bad > 0 ? "  [$bad non-finite]" : ""))
            end
        end
    end
end
