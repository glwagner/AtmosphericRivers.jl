# # Map of ∂J/∂IWV₀₋₁ₖₘ for the regional 1-day precipitation loss
#
#     julia --project=sensitivity sensitivity/plot_sensitivity.jl <gradient.jld2> [out.png]
#
# Reads the file written by reactant_downscale.jl with AR_AD=1 AR_AD_LOSS=precip (keys `ad/*`,
# `grid/*`, `sens/*`; see loss.jl) and draws:
#
#   (a) the area density of ∂J/∂IWV₀₋₁ₖₘ (uniform-in-layer ansatz) — diverging, symmetric — with the
#       initial 0–1 km IWV contoured, terrain contours, coastlines/states and the target region;
#   (b) the same for the vapour-profile ansatz (fractional moistening of the layer);
#   (c) the primal's accumulated precipitation over the window, with the target region.
#
# and prints the scalar diagnostics. Only CairoMakie, JLD2, NaturalEarth and GeoInterface are needed
# — no Oceananigans/Breeze — so it runs on a login node.

using CairoMakie
using JLD2
using NaturalEarth
import GeoInterface as GI
using Printf

include(joinpath(@__DIR__, "region.jl"))
include(joinpath(@__DIR__, "postprocess.jl"))

const LAYER_DEPTH = parse(Float64, get(ENV, "AR_SENS_LAYER_DEPTH", "1000"))

function natural_earth_lines(name; scale = 50)
    lons, lats = Float64[], Float64[]
    add!(geom) = add!(GI.geomtrait(geom), geom)
    add!(::GI.LineStringTrait, line) = (for p in GI.getpoint(line)
                                            push!(lons, GI.x(p)); push!(lats, GI.y(p))
                                        end; push!(lons, NaN); push!(lats, NaN))
    add!(::GI.MultiLineStringTrait, ml) = foreach(add!, GI.getgeom(ml))
    add!(::Any, _) = nothing
    for feature in naturalearth(name, scale)
        geom = GI.geometry(feature)
        isnothing(geom) || add!(geom)
    end
    return lons, lats
end

# Keys: REACTANT's AD block (`ad/control_value`, `ad/precip_accumulated`, `ad/weights`, `ad/dt`,
# `ad/accum_start`, `grid/z_physical_face`) with fallbacks to the older/generic layout
# (`ad/control_initial`, `meta/dt_seconds`, reference `grid/z_face` + LinearDecay).
function load_sensitivity(path)
    jldopen(path, "r") do file
        has(k) = haskey(file, k)
        get1(keys...; default = nothing) = (for k in keys; has(k) && return file[k]; end; default)
        λf, φf = Float64.(file["grid/lambda_face"]), Float64.(file["grid/phi_face"])
        h = Float64.(file["grid/terrain_height"])
        z_top = Float64(file["grid/z_top"])
        steps = Int(file["ad/steps"])
        accum_start = Int(get1("ad/accum_start", "sens/spinup_steps"; default = 0))
        weights = get1("ad/weights", "sens/weights")
        weights = isnothing(weights) ? first(region_weights(λf, φf)) : Float64.(weights)
        precip = get1("ad/precip_accumulated", "sens/precip_accumulated")
        zf_phys = get1("grid/z_physical_face")
        rf = Float64.(vec(get1("grid/r_face", "grid/z_face")))
        (; g = Float64.(file["ad/gradient"]),
           c = Float64.(get1("ad/control_value", "ad/control_initial")),
           λf, φf, rf, h, z_top, steps, accum_start, weights,
           λ = (λf[1:end-1] .+ λf[2:end]) ./ 2,
           φ = (φf[1:end-1] .+ φf[2:end]) ./ 2,
           zf_phys = isnothing(zf_phys) ? nothing : Float64.(zf_phys),
           J = Float64(file["ad/loss"]),
           Δt = Float64(get1("ad/dt", "sens/dt_seconds", "meta/dt_seconds")),
           polygon = something(get1("sens/region_polygon"), TARGET_POLYGON),
           precip = isnothing(precip) ? nothing : Float64.(precip))
    end
end

"Layer fractions from physical faces when the file has them, else from r + LinearDecay."
layer(d; H = LAYER_DEPTH) = isnothing(d.zf_phys) ? layer_fractions(d.rf, d.h, d.z_top; H) :
                                                   layer_fractions_physical(d.zf_phys, d.h; H)

sensitivity(d; H = LAYER_DEPTH) = iwv_sensitivity(d.g, d.c, layer(d; H)..., cell_areas(d.λf, d.φf); H)

accumulation_hours(d) = (d.steps - d.accum_start) * d.Δt / 3600

function report(d, s)
    println("── precipitation sensitivity ─────────────────────────────────────────────")
    @printf("window: %d steps × %.0f s = %.2f h; precipitation accumulated over the last %.2f h\n",
            d.steps, d.Δt, d.steps * d.Δt / 3600, accumulation_hours(d))
    @printf("J (region-mean accumulated precipitation) = %.4g mm\n", d.J)
    isnothing(d.precip) ||
        @printf("   check: Σ w·P from the stored field      = %.4g mm\n", sum(d.weights .* d.precip))
    nonfinite = count(!isfinite, d.g)
    @printf("gradient: %d cells, %d non-finite, max|g| = %.3g mm/(kg m⁻³)\n",
            length(d.g), nonfinite, maximum(abs, filter(isfinite, d.g)))
    for (name, field) in (("uniform", s.uniform_density), ("profile", s.profile_density))
        I = argmax(abs.(replace(field, NaN => 0)))
        @printf("max |∂J/∂IWV| (%s) = %+.3g mm per kg m⁻² per (100 km)² at %.2f°E %.2f°N\n",
                name, field[I], d.λ[I[1]], d.φ[I[2]])
    end
    ## Linearization checks: what the gradient predicts for a uniform 10% moistening.
    @printf("δJ for +10%% vapour in 0–%.0f m everywhere   ≈ %+.3g mm (%.1f%% of J)\n",
            LAYER_DEPTH, 0.1 * sum(s.dlnq), 10 * sum(s.dlnq) / d.J)
    @printf("δJ for +10%% vapour through the whole column ≈ %+.3g mm (%.1f%% of J)\n",
            0.1 * sum(s.column_dlnq), 10 * sum(s.column_dlnq) / d.J)
    @printf("δJ for +1 kg m⁻² IWV₀₋₁ₖₘ over the whole domain ≈ %+.3g mm\n", sum(s.uniform))
    println("───────────────────────────────────────────────────────────────────────────")
end

function plot_sensitivity(d, s, out)
    coast = natural_earth_lines("coastline")
    states = try natural_earth_lines("admin_1_states_provinces_lines") catch; (Float64[], Float64[]) end
    polyλ = [first.(d.polygon); first(d.polygon)[1]]
    polyφ = [last.(d.polygon); first(d.polygon)[2]]

    function decorate!(ax; λlims = extrema(d.λf), φlims = extrema(d.φf))
        contour!(ax, d.λ, d.φ, d.h; levels = 500:500:3000, color = (:gray35, 0.6), linewidth = 0.5)
        lines!(ax, coast...; color = :black, linewidth = 0.8)
        lines!(ax, states...; color = (:black, 0.5), linewidth = 0.4)
        lines!(ax, polyλ, polyφ; color = :darkgreen, linewidth = 2)
        xlims!(ax, λlims...); ylims!(ax, φlims...)
    end
    ## Equal-distance aspect at the map's central latitude.
    map_aspect(λlims, φlims) = AxisAspect((λlims[2] - λlims[1]) * cosd(sum(φlims) / 2) / (φlims[2] - φlims[1]))
    full_aspect = map_aspect(extrema(d.λf), extrema(d.φf))

    fig = Figure(size = (1500, 1300), fontsize = 15)
    hours = accumulation_hours(d)
    Label(fig[0, 1:4], @sprintf("Sensitivity of %.0f h precipitation over %s (J = %.2f mm) to initial IWV 0–%.1f km",
                                hours, TARGET_NAME, d.J, LAYER_DEPTH / 1000); fontsize = 18, font = :bold)

    for (row, (field, title)) in enumerate(((s.uniform_density, "uniform-in-layer perturbation"),
                                            (s.profile_density, "perturbation ∝ existing vapour profile")))
        lim = maximum(abs, filter(isfinite, field))
        lim = lim > 0 ? lim : 1.0
        ax = Axis(fig[row, 1:2]; title = "∂J/∂IWV₀₋₁ₖₘ, $title", xlabel = "longitude (°E)", ylabel = "latitude (°N)",
                  aspect = full_aspect)
        hm = heatmap!(ax, d.λf, d.φf, field; colormap = :balance, colorrange = (-lim, lim))
        contour!(ax, d.λ, d.φ, s.iwv; levels = 5:5:40, color = :purple, linewidth = 0.9, labels = true,
                 labelsize = 10, labelcolor = :purple)
        decorate!(ax)
        Colorbar(fig[row, 3], hm; label = "mm per (kg m⁻²) per (100 km)²")
    end

    ## Precipitation zoomed on the Pacific Northwest, where the region is.
    zoom = ((-127.5, -119.0), (42.0, 49.5))
    ax = Axis(fig[1:2, 4]; title = @sprintf("accumulated precipitation, %.0f h (primal)", hours),
              xlabel = "longitude (°E)", aspect = map_aspect(zoom...))
    if isnothing(d.precip)
        text!(ax, 0.5, 0.5; text = "no sens/precip_accumulated in file", space = :relative, align = (:center, :center))
    else
        hm = heatmap!(ax, d.λf, d.φf, d.precip; colormap = Reverse(:deep),
                      colorrange = (0, max(1e-3, quantile_hi(d.precip))))
        Colorbar(fig[3, 4], hm; vertical = false, label = "mm", flipaxis = false)
    end
    decorate!(ax; λlims = zoom[1], φlims = zoom[2])
    colsize!(fig.layout, 4, Relative(0.28))

    save(out, fig; px_per_unit = 1.5)
    println("wrote ", out)
end

quantile_hi(x) = (v = sort(vec(filter(isfinite, x))); v[clamp(round(Int, 0.995 * length(v)), 1, length(v))])

if abspath(PROGRAM_FILE) == @__FILE__
    path = length(ARGS) ≥ 1 ? ARGS[1] : error("usage: plot_sensitivity.jl <gradient.jld2> [out.png]")
    out = length(ARGS) ≥ 2 ? ARGS[2] : replace(path, r"\.jld2$" => "") * "_iwv_sensitivity.png"
    d = load_sensitivity(path)
    s = sensitivity(d)
    report(d, s)
    plot_sensitivity(d, s, out)
end
