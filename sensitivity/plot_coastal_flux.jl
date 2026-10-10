# # Map + section of ∂J/∂ρqᵉ for the coastal moisture-flux loss (AR_AD_LOSS=coastal_flux)
#
#     julia --project=sensitivity sensitivity/plot_coastal_flux.jl <gradient.jld2> [out.png]
#
# J is the time-mean, segment-mean eastward moisture flux ∫ u ρqᵉ dz (kg m⁻¹ s⁻¹) through the u-face
# column at `ad/plane_lambda`, latitudes `ad/plane_phi_band`. Draws
#
#   (a) ∂J/∂IWV₀₋₁ₖₘ (uniform-in-layer ansatz, as plot_sensitivity.jl), the plane in green, the outer
#       `AR_SENS_FRAME` cells (default 5: the relaxation/open-boundary frame) masked;
#   (b) a longitude–height section of ∂J/∂ρqᵉ averaged over the plane's latitude band;
#
# and prints J, max|∂| and where, and the share of Σ|∂| inside the frame.

include(joinpath(@__DIR__, "plot_sensitivity.jl"))

const FRAME = parse(Int, get(ENV, "AR_SENS_FRAME", "5"))

function load_plane(path)
    jldopen(path, "r") do file
        (; λ = Float64(file["ad/plane_lambda"]), band = Float64.(file["ad/plane_phi_band"]),
           rows = Int.(file["ad/plane_rows"]), steps = Int(file["ad/steps"]),
           dt = Float64(file["ad/dt"]), units = file["ad/loss_units"])
    end
end

function frame_share(g; n = FRAME)
    a = abs.(replace(g, NaN => 0.0))
    Nx, Ny, _ = size(a)
    inner = sum(a[n+1:Nx-n, n+1:Ny-n, :])
    return 1 - inner / sum(a)
end

function report_coastal(d, p)
    println("── coastal moisture-flux sensitivity ─────────────────────────────────────")
    @printf("plane λ = %.3f°, %.2f–%.2f°N (%d rows); window %d steps × %.0f s = %.2f h\n",
            p.λ, p.band..., length(p.rows), p.steps, p.dt, p.steps * p.dt / 3600)
    @printf("J = %.5g %s\n", d.J, p.units)
    finite = filter(isfinite, d.g)
    @printf("gradient: %d non-finite of %d\n", length(d.g) - length(finite), length(d.g))
    if !isempty(finite)
        I = argmax(abs.(replace(d.g, NaN => 0.0)))
        z = isnothing(d.zf_phys) ? NaN : (d.zf_phys[I] + d.zf_phys[I[1], I[2], I[3]+1]) / 2
        @printf("max|∂J/∂ρqᵉ| = %.4g at %.2f°E %.2f°N z ≈ %.0f m (k = %d)\n",
                abs(d.g[I]), d.λ[I[1]], d.φ[I[2]], z, I[3])
        @printf("share of Σ|∂| in the outer %d-cell frame: %.1f%%\n", FRAME, 100 * frame_share(d.g))
    end
    println("───────────────────────────────────────────────────────────────────────────")
end

function plot_coastal(d, s, p, out)
    coast = natural_earth_lines("coastline")
    states = try natural_earth_lines("admin_1_states_provinces_lines") catch; (Float64[], Float64[]) end
    Nx, Ny, Nz = size(d.g)
    masked(field) = (f = copy(field); f[1:FRAME, :] .= NaN; f[Nx-FRAME+1:Nx, :] .= NaN;
                     f[:, 1:FRAME] .= NaN; f[:, Ny-FRAME+1:Ny] .= NaN; f)
    aspect = AxisAspect((d.λf[end] - d.λf[1]) * cosd((d.φf[1] + d.φf[end]) / 2) / (d.φf[end] - d.φf[1]))
    hours = p.steps * p.dt / 3600

    fig = Figure(size = (1500, 1200), fontsize = 15)
    Label(fig[0, 1:2], @sprintf("Sensitivity of the %.0f h mean coastal moisture flux (%.1f°, %.1f–%.1f°N; J = %.1f kg m⁻¹ s⁻¹) to initial IWV 0–%.1f km",
                                hours, p.λ, p.band..., d.J, LAYER_DEPTH / 1000); fontsize = 17, font = :bold)

    field = masked(s.uniform_density)
    lim = maximum(abs, filter(isfinite, field)); lim = lim > 0 ? lim : 1.0
    ax = Axis(fig[1, 1]; title = "∂J/∂IWV₀₋₁ₖₘ (uniform-in-layer), frame masked", xlabel = "longitude (°E)",
              ylabel = "latitude (°N)", aspect)
    hm = heatmap!(ax, d.λf, d.φf, field; colormap = :balance, colorrange = (-lim, lim))
    contour!(ax, d.λ, d.φ, s.iwv; levels = 5:5:40, color = :purple, linewidth = 0.8, labels = true, labelsize = 10)
    contour!(ax, d.λ, d.φ, d.h; levels = 500:500:3000, color = (:gray35, 0.6), linewidth = 0.5)
    lines!(ax, coast...; color = :black, linewidth = 0.8)
    lines!(ax, states...; color = (:black, 0.5), linewidth = 0.4)
    lines!(ax, [p.λ, p.λ], collect(p.band); color = :green, linewidth = 4)
    xlims!(ax, extrema(d.λf)...); ylims!(ax, extrema(d.φf)...)
    Colorbar(fig[1, 2], hm; label = "kg m⁻¹ s⁻¹ per (kg m⁻²) per (100 km)²")

    ## Longitude–height section averaged over the plane's rows, on physical heights.
    sec = dropdims(sum(d.g[:, p.rows, :]; dims = 2); dims = 2) ./ length(p.rows)
    zc = isnothing(d.zf_phys) ? repeat(reshape((d.rf[1:end-1] .+ d.rf[2:end]) ./ 2, 1, :), Nx, 1) :
         dropdims(sum((d.zf_phys[:, p.rows, 1:end-1] .+ d.zf_phys[:, p.rows, 2:end]) ./ 2; dims = 2); dims = 2) ./ length(p.rows)
    sec[1:FRAME, :] .= NaN; sec[Nx-FRAME+1:Nx, :] .= NaN
    slim = maximum(abs, filter(isfinite, sec)); slim = slim > 0 ? slim : 1.0
    ax2 = Axis(fig[2, 1]; title = "∂J/∂ρqᵉ per cell, mean over the plane's latitude band",
               xlabel = "longitude (°E)", ylabel = "height (km)")
    λsec = repeat(d.λ, 1, Nz)
    hm2 = scatter!(ax2, vec(λsec), vec(zc) ./ 1e3; color = vec(sec), colormap = :balance,
                   colorrange = (-slim, slim), marker = :rect, markersize = 6)
    vlines!(ax2, [p.λ]; color = :green, linewidth = 2)
    ylims!(ax2, 0, 10)
    Colorbar(fig[2, 2], hm2; label = "kg m⁻¹ s⁻¹ per (kg m⁻³)")

    save(out, fig; px_per_unit = 1.5)
    println("wrote ", out)
end

if abspath(PROGRAM_FILE) == @__FILE__
    path = length(ARGS) ≥ 1 ? ARGS[1] : error("usage: plot_coastal_flux.jl <gradient.jld2> [out.png]")
    out = length(ARGS) ≥ 2 ? ARGS[2] : replace(path, r"\.jld2$" => "") * "_coastal_flux.png"
    d = load_sensitivity(path)
    p = load_plane(path)
    report_coastal(d, p)
    any(isfinite, d.g) && plot_coastal(d, sensitivity(d), p, out)
end
