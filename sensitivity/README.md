# Adjoint sensitivity of 1-day regional precipitation to low-level water vapour

The question (Andrea Jenney, for the Dec 2025 AR): how does **1-day accumulated precipitation over
SW Washington + NW Oregon west of the Cascades** depend on the **integrated water vapour between
the surface and 1 km** (a height stand-in for 700 hPa; 850 hPa / pressure levels are step 2) at the
initial time?

## Pieces

| file | role |
|---|---|
| `region.jl` | `TARGET_POLYGON` (the one thing to edit), point-in-polygon, fractional cell coverage, spherical cell areas, normalized weights |
| `loss.jl` | `precipitation_weights(λ, φ, h)`, `include`d by `reactant_downscale.jl`'s AD block (`AR_AD_LOSS=precipitation`) |
| `postprocess.jl` | ∂J/∂ρqᵉ (3D) → ∂J/∂IWV₀₋₁ₖₘ (2D), two vertical ansätze, derivation in the header |
| `plot_sensitivity.jl` | figure + scalar diagnostics from the AD output file |
| `fd_direction.jl` | finite-difference check of the IWV sensitivity over a box |
| `test_sensitivity.jl` | host-only tests (mask, post-processing identities, end-to-end on a synthetic file) |

## Loss

    J = Σᵢⱼ wᵢⱼ Σₙ Δt Fᵢⱼ(tₙ)         [kg m⁻² ≡ mm]

`F = Breeze.bottom_precipitation_flux(child)`: the bottom-face advective flux of every sedimenting
condensate (rain, snow, sedimenting cloud), kg m⁻² s⁻¹, positive down — the water the model actually
removes through the ground. `w = f·A/Σf·A` (f = fraction of the cell inside the polygon on an 8×8
equal-area sub-lattice, A = exact spherical cell area), so J is the region's **area-mean**
accumulated precipitation. The traced accumulation lives in the AD block of `reactant_downscale.jl`.

Region: coast → 47.0°N → Cascade crest (Snoqualmie/White Pass, Mt Adams, Columbia Gorge, Mt Hood,
Mt Jefferson, Santiam Pass) → 44.5°N. ≈ 5.2×10⁴ km², 524 cells touched at 12 km. It is a hand-drawn
polygon, not terrain-derived, because the Reactant nest runs on **idealized** orography (a Gaussian
ridge at 121.3°W with no coastline); see `region.jl`. Mask figure: `test_output/target_region_mask.png`.

## Control and the map

Control: ρqᵉ at t = Δt (Breeze 1M mixed-phase moisture: vapour + equilibrium cloud; = ρqᵛ in
unsaturated air). For column (i,j), with fₖ the fraction of cell k within 1 km of the ground on the
terrain-following grid:

* **uniform** (default): δρqᵉ uniform through the layer ⇒ ∂J/∂IWV = (1/H) Σₖ gₖ fₖ
* **profile**: δρqᵉ ∝ existing vapour (fractional moistening) ⇒ ∂J/∂IWV = Σ gₖcₖfₖ / Σ cₖfₖΔzₖ

Mapped as an **area density** (÷ cell area × 10¹⁰ m²): mm of region-mean precipitation per kg m⁻²
of extra IWV₀₋₁ₖₘ spread over a 100 km × 100 km patch, which does not depend on the grid spacing.

## Running

```bash
# gradient (AD block owned by reactant_downscale.jl; 1 day = 8640 steps at Δt = 10 s)
AR_AD=1 AR_AD_LOSS=precipitation AR_AD_STEPS=8640 AR_PARENT_HOURS=25 AR_CELLS_PER_DEGREE=9 \
    sbatch slurm/reactant_ad.batch            # start with shorter windows: 720,2160,4320

# figure + diagnostics (login node)
julia --project=sensitivity sensitivity/plot_sensitivity.jl <gradient.jld2> [out.png]

# FD check over a box upstream (prints the AR_AD_FD_EPS list and the predicted (ΔJ)/ε)
julia --project=sensitivity sensitivity/fd_direction.jl <gradient.jld2> [λ₁,λ₂,φ₁,φ₂] [δIWV]

# tests
julia --project=sensitivity sensitivity/test_sensitivity.jl
```

`AR_SENS_LAYER_DEPTH` (default 1000 m) changes H in the post-processing without rerunning the
adjoint — the gradient is 3D, so any layer (or a pressure-level layer later) is a re-reduction.
