# # From ∂J/∂(ρq) on the 3D grid to ∂J/∂IWV₀₋₁ₖₘ on the map
#
# Pure Julia, no packages. `include`d by plot_sensitivity.jl and test_sensitivity.jl.
#
# ## Derivation
#
# The adjoint returns the DISCRETE gradient gᵢⱼₖ = ∂J/∂cᵢⱼₖ, where c = ρqᵉ [kg m⁻³] is the control
# (Breeze's 1-moment mixed-phase moisture prognostic: vapour plus the cloud condensate in
# equilibrium with it; in unsaturated air it is exactly ρqᵛ). Any perturbation δc gives, to first
# order, δJ = Σᵢⱼₖ gᵢⱼₖ δcᵢⱼₖ.
#
# The layer-integrated water vapour of column (i,j) is IWVᵢⱼ = Σₖ cᵢⱼₖ fᵢⱼₖ Δzᵢⱼₖ, where Δz is the
# PHYSICAL cell thickness and f ∈ [0,1] the fraction of the cell lying within H = 1 km of the ground.
# A change δIWV says nothing about how it is distributed in the vertical, so a sensitivity to IWV
# needs an ansatz for the vertical shape of the perturbation, δcᵢⱼₖ = δIWVᵢⱼ ⋅ φᵢⱼₖ, normalized so it
# changes the layer integral by exactly δIWV and vanishes above the layer. Then
#
#     ∂J/∂IWVᵢⱼ = Σₖ gᵢⱼₖ φᵢⱼₖ.
#
# (a) UNIFORM (default): the added vapour has uniform density δρ through the layer 0 < z − h < H,
#     so δIWV = δρ H exactly. A partially-covered cell holds a cell AVERAGE, and δρ over its covered
#     part fₖΔzₖ raises that average by fₖ δρ. So δcₖ = fₖ δIWV / H and
#
#         ∂J/∂IWV = (1/H) Σₖ gₖ fₖ.
#
# (b) PROFILE: the added vapour has the shape of the vapour already there (a fractional moistening
#     of the layer, what "the AR carried more water" usually means): δcₖ = ε cₖ fₖ, and
#     δIWV = ε Σ cₖ fₖ Δzₖ, so
#
#         ∂J/∂IWV = Σₖ gₖ cₖ fₖ / Σₖ cₖ fₖ Δzₖ.
#
#     IWV × (b) = Σ gₖ cₖ fₖ = ∂J/∂ln(qᵥ) of the layer, in mm per unit fractional moistening.
#
# Units: J in kg m⁻² ≡ mm; g in mm / (kg m⁻³); ∂J/∂IWV in mm / (kg m⁻²), i.e. mm of regional-mean
# precipitation per kg m⁻² (≡ mm) of low-level water vapour added IN THAT COLUMN.
#
# ## Per column vs per unit area
#
# ∂J/∂IWVᵢⱼ is the response to moistening ONE grid column, so it scales with the cell area and halves
# when the resolution doubles. The resolution-independent quantity is the AREA DENSITY
# s = (∂J/∂IWVᵢⱼ) / Aᵢⱼ, with δJ = ∫ s δIWV dA. It is mapped as s × 10¹⁰ m² — "mm of regional-mean
# precipitation per kg m⁻² of extra IWV over a 100 km × 100 km patch" — which is the number to quote.
#
# ## Terrain-following heights
#
# Breeze's `LinearDecay` terrain-following coordinate (the default) maps reference height r to
# physical height z = r + h (1 − r/z_top), so the height ABOVE GROUND is z − h = r (1 − h/z_top) and
# every layer's thickness is compressed by σ = 1 − h/z_top. Only the reference faces (Nz+1), the
# terrain h (Nx×Ny) and z_top are needed.
#
# ## Caveat on t₀
#
# reactant_downscale.jl writes the control AFTER `first_time_step!`, so "initial" means t = Δt (one
# step after the ERA5 initial condition). Irrelevant for a 1-day window.

"""
    layer_fractions(r_faces, h, z_top; H = 1000)

Fraction `f[i,j,k]` of each cell lying within `H` metres of the ground, and the physical thickness
`Δz[i,j,k]`, on a `LinearDecay` terrain-following grid.
"""
function layer_fractions(r_faces, h, z_top; H = 1000.0)
    Nx, Ny = size(h)
    Nz = length(r_faces) - 1
    f = zeros(Nx, Ny, Nz)
    Δz = zeros(Nx, Ny, Nz)
    for j in 1:Ny, i in 1:Nx
        σ = 1 - h[i, j] / z_top
        for k in 1:Nz
            ζ⁻ = (r_faces[k] - r_faces[1]) * σ     # height above ground of the cell's bottom face
            ζ⁺ = (r_faces[k+1] - r_faces[1]) * σ
            Δz[i, j, k] = ζ⁺ - ζ⁻
            f[i, j, k] = clamp((H - ζ⁻) / (ζ⁺ - ζ⁻), 0, 1)
        end
    end
    return f, Δz
end

"""
    layer_fractions_physical(z_faces, h; H = 1000)

Same as `layer_fractions`, from PHYSICAL face heights `z_faces[i,j,k]` (Nx×Ny×(Nz+1)), as written by
the AD block in `grid/z_physical_face` — no assumption about the terrain-following formulation.
"""
function layer_fractions_physical(z_faces, h; H = 1000.0)
    ζ = z_faces .- h                       # heights above ground of every face
    ζ⁻, ζ⁺ = ζ[:, :, 1:end-1], ζ[:, :, 2:end]
    Δz = ζ⁺ .- ζ⁻
    f = clamp.((H .- ζ⁻) ./ Δz, 0, 1)
    return f, Δz
end

"""
    iwv_sensitivity(g, c, f, Δz, areas; H = 1000)
    iwv_sensitivity(g, c, r_faces::AbstractVector, h, z_top, areas; H = 1000)

Returns a NamedTuple of 2D maps:

  * `uniform`   — ∂J/∂IWV per column, ansatz (a)          [mm / (kg m⁻²)]
  * `profile`   — ∂J/∂IWV per column, ansatz (b)          [mm / (kg m⁻²)]
  * `uniform_density`, `profile_density` — the same divided by cell area, × 1e10 m²
                                            [mm / (kg m⁻²) per (100 km)²]
  * `dlnq`      — ∂J/∂ln q of the 0–H layer per column     [mm]
  * `iwv`       — the layer IWV of the control state       [kg m⁻²]
  * `column_dlnq` — Σₖ gₖ cₖ over the WHOLE column per column [mm], for comparison
"""
function iwv_sensitivity(g, c, f, Δz, areas; H = 1000.0)
    @assert size(g) == size(c) == size(f) "gradient $(size(g)), control $(size(c)), layer $(size(f)) differ"
    @assert size(g)[1:2] == size(areas) "horizontal sizes differ: $(size(g)) $(size(areas))"
    uniform = dropdims(sum(g .* f; dims = 3); dims = 3) ./ H
    iwv     = dropdims(sum(c .* f .* Δz; dims = 3); dims = 3)
    dlnq    = dropdims(sum(g .* c .* f; dims = 3); dims = 3)
    profile = dlnq ./ iwv
    return (; uniform, profile, dlnq, iwv,
            uniform_density = uniform ./ areas .* 1e10,
            profile_density = profile ./ areas .* 1e10,
            column_dlnq = dropdims(sum(g .* c; dims = 3); dims = 3))
end

iwv_sensitivity(g, c, r_faces::AbstractVector, h, z_top, areas; H = 1000.0) =
    iwv_sensitivity(g, c, layer_fractions(r_faces, h, z_top; H)..., areas; H)
