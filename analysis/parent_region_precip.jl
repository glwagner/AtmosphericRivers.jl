# Region-mean 24 h precipitation over the sensitivity target (sensitivity/region.jl polygon: SW Washington +
# NW Oregon west of the Cascade crest, area-weighted with fractional coverage) for several
# `reactant_downscale.jl AR_ARCH=cuda` runs — the number the adjoint's loss J measures.
#
# Usage: julia --project=.. analysis/parent_region_precip.jl label1=run1.jld2 label2=run2.jld2 …

using Printf
using Oceananigans   # loads JLD2
const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
include(joinpath(@__DIR__, "..", "sensitivity", "loss.jl"))

for arg in ARGS
    label, path = split(arg, "=", limit = 2)
    JLD2.jldopen(path, "r") do file
        λ = Float64.(file["grid/lambda_center"]); φ = Float64.(file["grid/phi_center"])
        its = sort(parse.(Int, keys(file["timeseries/t"])))
        t = [file["timeseries/t/$n"] for n in its]
        n24 = its[argmin(abs.(t .- 86400))]
        P = Float64.(file["timeseries/accumulated_precipitation/$n24"]) .-
            Float64.(file["timeseries/accumulated_precipitation/$(first(its))"])
        w = precipitation_weights(λ, φ)
        @printf("%-12s J(24 h) = %6.2f mm over the target polygon (t = %.1f h, max %.0f mm in the domain)\n",
                label, sum(w .* P), t[its .== n24][1] / 3600, maximum(P))
    end
end
