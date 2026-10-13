# # Finite-difference check of ∂J/∂IWV₀₋₁ₖₘ: build the perturbation and the prediction
#
#     julia --project=sensitivity sensitivity/fd_direction.jl <gradient.jld2> [λ₁,λ₂,φ₁,φ₂] [δIWV]
#
# Writes `<gradient>_fd_box.jld2`, a direction file for reactant_downscale.jl's existing FD path, and
# prints the predicted finite difference to compare against the job log.
#
# ## The perturbation
#
# δc = δIWV ⋅ fₖ / H in every column of the box (ansatz (a) of postprocess.jl), zero elsewhere — i.e.
# "add δIWV kg m⁻² of water vapour, uniformly through the lowest km, over this box". Default box:
# 2°×2° centred on the largest |∂J/∂IWV| UPSTREAM (west) of the target region; default δIWV = 1 kg m⁻²
# (≈ 5–10 % of IWV₀₋₁ₖₘ in the AR; small enough to stay linear-ish, large enough to beat Float32 noise
# in J by orders of magnitude).
#
# ## How the AD block uses it
#
# `AR_AD_FD_DIR=<file>` reads `ad/gradient` from the file as a direction d, sets v = d/‖d‖, and
# evaluates (J(c + εv) − J(c))/ε for each ε in `AR_AD_FD_EPS`. With d = δc and ε = ‖δc‖ the
# perturbation is exactly δc, so (ΔJ)/ε × ‖δc‖ = ΔJ for that box, to compare against
#
#     ΔJ_pred = Σ_box ∂J/∂IWV ⋅ δIWV = ⟨g, δc⟩.
#
# NOTE: the job log's "ratio" column divides by ‖d‖ assuming d IS the gradient; for this direction
# file it is meaningless — compare (ΔJ)/ε against the `predicted (ΔJ)/ε` printed here instead. Use
# several ε (e.g. ‖δc‖ × {0.25, 0.5, 1, 2}): for a correct gradient, FD/pred → 1 linearly as ε → 0.
#
# Recipe (one primal compile serves all ε; no reverse sweep):
#
#     AR_AD=1 AR_AD_LOSS=precipitation AR_AD_PRIMAL_ONLY=1 AR_AD_STEPS=<same window> \
#     AR_AD_ACCUM_START=<same> AR_AD_FD_DIR=<gradient>_fd_box.jld2 AR_AD_FD_EPS=<printed list> \
#       sbatch slurm/reactant_ad.batch
#
# Do it twice: a box where the sensitivity is large (tests the adjoint) and one where it is ~0 (tests
# that the adjoint is not missing a path; ΔJ should be ≈ 0 there too).

include(joinpath(@__DIR__, "plot_sensitivity.jl"))   # region, postprocess, load_sensitivity (its main block does not run)

path = length(ARGS) ≥ 1 ? ARGS[1] : error("usage: fd_direction.jl <gradient.jld2> [λ₁,λ₂,φ₁,φ₂] [δIWV]")
d = load_sensitivity(path)
s = sensitivity(d)
f, _ = layer(d)
δIWV = length(ARGS) ≥ 3 ? parse(Float64, ARGS[3]) : 1.0

box = if length(ARGS) ≥ 2
    Tuple(parse.(Float64, split(ARGS[2], ',')))
else
    ## Largest |∂J/∂IWV| west of 124.5°W (upstream of the coast), 2°×2° around it.
    S = abs.(replace(s.uniform_density, NaN => 0))
    S[d.λ .> -124.5, :] .= 0
    I = argmax(S)
    (d.λ[I[1]] - 1, d.λ[I[1]] + 1, d.φ[I[2]] - 1, d.φ[I[2]] + 1)
end

inbox = [box[1] ≤ λ ≤ box[2] && box[3] ≤ φ ≤ box[4] for λ in d.λ, φ in d.φ]
δc = δIWV .* f .* inbox ./ LAYER_DEPTH
norm_δc = sqrt(sum(abs2, δc))
ΔJ_pred = sum(d.g .* δc)

@printf("box λ ∈ [%.2f, %.2f], φ ∈ [%.2f, %.2f]: %d columns, δIWV = %.3g kg m⁻² each\n",
        box..., count(inbox), δIWV)
@printf("predicted ΔJ = Σ_box ∂J/∂IWV δIWV = %+.6g mm  (%.3g %% of J = %.4g mm)\n",
        ΔJ_pred, 100 * ΔJ_pred / d.J, d.J)
@printf("‖δc‖ = %.6g  ⇒  predicted (ΔJ)/ε = %+.6g for every ε\n", norm_δc, ΔJ_pred / norm_δc)
println("AR_AD_FD_EPS=", join((@sprintf("%.4g", a * norm_δc) for a in (0.25, 0.5, 1.0, 2.0)), ","),
        "    (= ‖δc‖ × 0.25, 0.5, 1, 2; ε = ‖δc‖ is exactly δIWV over the box)")

out = replace(path, r"\.jld2$" => "") * "_fd_box.jld2"
jldopen(out, "w") do file
    file["ad/gradient"] = Float32.(δc)
    file["fd/box"] = collect(box)
    file["fd/delta_iwv"] = δIWV
    file["fd/predicted_delta_J"] = ΔJ_pred
    file["fd/predicted_dJ_over_eps"] = ΔJ_pred / norm_δc
    file["fd/norm"] = norm_δc
end
println("wrote ", out)
