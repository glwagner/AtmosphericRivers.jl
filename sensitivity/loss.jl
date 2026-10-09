# # Regional accumulated-precipitation loss: the WEIGHTS
#
# `include`d by the `AR_AD=1` block of reactant_downscale.jl when `AR_AD_LOSS=precipitation`
# (`AR_AD_LOSS_FILE` overrides the path). The traced part lives in that block, which computes
#
#     P[i,j] = Σ_{n > AR_AD_ACCUM_START} Δt F[i,j](tₙ),   F = Breeze.bottom_precipitation_flux(child)
#     J      = Σᵢⱼ w[i,j] P[i,j]
#
# F is Breeze's own bottom-face advective flux of every sedimenting condensate (rain, snow, and any
# sedimenting cloud), kg m⁻² s⁻¹ ≡ mm s⁻¹, positive downward — the moisture mass the model actually
# removes through the ground. With the weights below, w = f·A / Σ f·A (f = cell fraction inside the
# region, A = spherical cell area), J is the AREA-MEAN accumulated precipitation over the region in mm.
#
# This file only builds `w`, on the host, from plain arrays. It is include-safe: no top-level code
# touches the model, and it needs no packages.

include(joinpath(@__DIR__, "region.jl"))

"""
    precipitation_weights(λ, φ, h) -> w :: Matrix{Float64}

Contract with reactant_downscale.jl's AD block. `λ`, `φ` are the child's cell-CENTRE longitudes and
latitudes (uniform lat-lon grid), `h` its terrain (unused: the region is a fixed polygon — see
region.jl for why the idealized terrain is not used to find the crest). Returns normalized area
weights over `TARGET_POLYGON`, summing to 1.
"""
function precipitation_weights(λ, φ, h = nothing)
    w, area = region_weights(centres_to_faces(λ), centres_to_faces(φ))
    @info "sensitivity: target region '$TARGET_NAME' — $(round(Int, area / 1e6)) km², " *
          "$(count(>(0), w)) cells with weight > 0"
    return w
end

"Faces of a uniform 1D grid from its centres."
function centres_to_faces(x)
    x = collect(Float64, x)
    Δ = length(x) > 1 ? (x[end] - x[1]) / (length(x) - 1) : 1.0
    @assert all(isapprox.(diff(x), Δ; rtol = 1e-6)) "expected uniformly spaced cell centres"
    return [x .- Δ / 2; x[end] + Δ / 2]
end
