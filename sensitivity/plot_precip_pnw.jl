# # ∂J/∂IWV₀₋₁ₖₘ maps for the Washington + Oregon precipitation loss (AR_AD_REGION=pnw), one per window
#
#     julia --project=sensitivity sensitivity/plot_precip_pnw.jl <outdir> <gradient_1.jld2> [<gradient_2.jld2> ...]
#
# For each AD file (AR_AD_LOSS=precipitation): left, ∂J/∂IWV₀₋₁ₖₘ (uniform-in-layer ansatz, as
# plot_sensitivity.jl) on a vivid diverging scale symmetric about 0 and clipped at the 99.5th percentile of
# |∂| (the colour bar's arrows mark the clipped tails; the true max is in the title), the outer
# `AR_SENS_FRAME` cells (relaxation frame) masked, the WA + OR polygons outlined; right, the primal's
# accumulated precipitation over the window on the shared analysis/precip_colors.jl palette.
# Prints one table row per window: hours, J, non-finite count, max|∂J/∂ρqᵉ| and where, frame share.

include(joinpath(@__DIR__, "plot_sensitivity.jl"))

const FRAME = parse(Int, get(ENV, "AR_SENS_FRAME", "5"))
const COLORS_FILE = joinpath(@__DIR__, "..", "analysis", "precip_colors.jl")
isfile(COLORS_FILE) && include(COLORS_FILE)

# Vivid diverging scale: deep blue → cyan → white → yellow-orange → deep red.
const VIVID = cgrad([colorant"#08085e", colorant"#1d4fd8", colorant"#29b6f6", colorant"#ffffff",
                     colorant"#ffc400", colorant"#f24405", colorant"#7a0000"])

function frame_mask!(f, n = FRAME)
    Nx, Ny = size(f)
    f[1:n, :] .= NaN; f[Nx-n+1:Nx, :] .= NaN; f[:, 1:n] .= NaN; f[:, Ny-n+1:Ny] .= NaN
    return f
end

function frame_share(g; n = FRAME)
    a = abs.(replace(g, NaN => 0.0))
    Nx, Ny, _ = size(a)
    return 1 - sum(a[n+1:Nx-n, n+1:Ny-n, :]) / sum(a)
end

function draw_outline!(ax, polygons)
    for p in polygons
        xs, ys = [first.(p); p[1][1]], [last.(p); p[1][2]]
        if isdefined(@__MODULE__, :outline!)
            outline!(ax, xs, ys; linewidth = 1.8)
        else
            lines!(ax, xs, ys; color = :white, linewidth = 3.8); lines!(ax, xs, ys; color = :black, linewidth = 1.8)
        end
    end
end

function summarize(d, path)
    hours = d.steps * d.Δt / 3600
    nonfinite = count(!isfinite, d.g)
    if nonfinite == length(d.g)
        @printf("%-40s %5.1f h  J = %8.4g mm  ALL %d non-finite\n", basename(path), hours, d.J, nonfinite)
        return nothing
    end
    I = argmax(abs.(replace(d.g, NaN => 0.0)))
    z = isnothing(d.zf_phys) ? NaN : (d.zf_phys[I] + d.zf_phys[I[1], I[2], I[3]+1]) / 2
    @printf("%-40s %5.1f h  J = %8.4g mm  non-finite %d  max|∂J/∂ρqᵉ| = %.3g at %.2f°E %.2f°N z≈%.0f m  frame %.1f%%\n",
            basename(path), hours, d.J, nonfinite, abs(d.g[I]), d.λ[I[1]], d.φ[I[2]], z, 100 * frame_share(d.g))
end

function plot_window(d, s, out)
    coast = natural_earth_lines("coastline")
    states = try natural_earth_lines("admin_1_states_provinces_lines") catch; (Float64[], Float64[]) end
    hours = d.steps * d.Δt / 3600
    field = frame_mask!(copy(s.uniform_density))
    vals = sort(abs.(filter(isfinite, field)))
    lim = isempty(vals) ? 1.0 : max(vals[clamp(round(Int, 0.995 * length(vals)), 1, length(vals))], eps())
    aspect = AxisAspect((d.λf[end] - d.λf[1]) * cosd((d.φf[1] + d.φf[end]) / 2) / (d.φf[end] - d.φf[1]))

    fig = Figure(size = (1700, 760), fontsize = 15)
    Label(fig[0, 1:4], @sprintf("12 km: sensitivity of %.0f h precipitation over Washington + Oregon (J = %.2f mm, area mean) to initial IWV 0–%.0f km",
                                hours, d.J, LAYER_DEPTH / 1000); fontsize = 18, font = :bold)
    ax = Axis(fig[1, 1]; aspect, xlabel = "longitude (°E)", ylabel = "latitude (°N)",
              title = @sprintf("∂J/∂IWV₀₋₁ₖₘ (uniform-in-layer); max |·| = %.3g, colour clipped at 99.5th pct",
                               maximum(vals; init = 0.0)))
    hm = heatmap!(ax, d.λf, d.φf, field; colormap = VIVID, colorrange = (-lim, lim),
                  lowclip = colorant"#000033", highclip = colorant"#3d0000", nan_color = (:gray80, 0.6))
    contour!(ax, d.λ, d.φ, s.iwv; levels = 5:5:40, color = :purple, linewidth = 0.8, labels = true, labelsize = 10)
    contour!(ax, d.λ, d.φ, d.h; levels = 500:500:3000, color = (:gray30, 0.6), linewidth = 0.5)
    lines!(ax, coast...; color = :black, linewidth = 0.8)
    lines!(ax, states...; color = (:black, 0.5), linewidth = 0.4)
    draw_outline!(ax, PNW_POLYGON)
    xlims!(ax, extrema(d.λf)...); ylims!(ax, extrema(d.φf)...)
    Colorbar(fig[1, 2], hm; label = "mm per (kg m⁻²) per (100 km)²")

    zoom = ((-127.5, -115.5), (41.0, 50.0))
    ax2 = Axis(fig[1, 3]; xlabel = "longitude (°E)", title = @sprintf("accumulated precipitation, %.0f h (primal)", hours),
               aspect = AxisAspect((zoom[1][2] - zoom[1][1]) * cosd(45.5) / (zoom[2][2] - zoom[2][1])))
    if !isnothing(d.precip)
        if isdefined(@__MODULE__, :precip_heatmap!)
            precip_heatmap!(ax2, d.λf, d.φf, d.precip)
            precip_colorbar!(fig[1, 4]; label = "mm")
        else
            hm2 = heatmap!(ax2, d.λf, d.φf, d.precip; colormap = Reverse(:deep))
            Colorbar(fig[1, 4], hm2; label = "mm")
        end
    end
    contour!(ax2, d.λ, d.φ, d.h; levels = 500:500:3000, color = (:gray30, 0.6), linewidth = 0.5)
    lines!(ax2, coast...; color = :black, linewidth = 0.8)
    lines!(ax2, states...; color = (:black, 0.5), linewidth = 0.4)
    draw_outline!(ax2, PNW_POLYGON)
    xlims!(ax2, zoom[1]...); ylims!(ax2, zoom[2]...)
    save(out, fig; px_per_unit = 1.5)
    println("wrote ", out)
end

if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) ≥ 2 || error("usage: plot_precip_pnw.jl <outdir> <gradient.jld2>...")
    outdir = ARGS[1]; mkpath(outdir)
    for path in ARGS[2:end]
        d = load_sensitivity(path)
        summarize(d, path)
        any(isfinite, d.g) || continue
        out = joinpath(outdir, @sprintf("precip_pnw_%02dh_", round(Int, d.steps * d.Δt / 3600)) *
                               replace(basename(path), r"_\d+steps\.jld2$" => "", r"\.jld2$" => "") * ".png")
        plot_window(d, sensitivity(d), out)
    end
end
