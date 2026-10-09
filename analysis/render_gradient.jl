# Render the adjoint sensitivity map that `reactant_downscale.jl AR_AD=1` writes: ∂J/∂c at
# every interior cell of the control field, where J = mean(target²) after AR_AD_STEPS steps.
#
# The gradient file is self-describing — `write_grid_metadata` records the λ/φ/r nodes, the
# terrain height and z_top alongside `ad/gradient` — so nothing here reads `case.jl` or
# rebuilds a grid: the plot is drawn on the coordinates the sweep was computed on.
#
# Usage: julia --project=.. analysis/render_gradient.jl [gradient.jld2]
#        AR_AD_FILE=... julia --project=.. analysis/render_gradient.jl

using Oceananigans          # brings JLD2 into the loaded set (it is not a direct dependency)
using NumericalEarth
using CairoMakie
using NaturalEarth, GeoInterface   # with NumericalEarth → `natural_earth_lines`
using Printf
using Statistics

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")

root = joinpath(@__DIR__, "..")
gradient_path = length(ARGS) ≥ 1 ? ARGS[1] :
    get(ENV, "AR_AD_FILE",
        joinpath(root, "reactant_" * get(ENV, "AR_DOMAIN", "landfall") * "_gradient_ρqᵉ_ρqᵉ.jld2"))

isfile(gradient_path) || error("no gradient file at $(gradient_path); run reactant_downscale.jl with AR_AD=1")

data = JLD2.jldopen(gradient_path, "r") do file
    (g       = Float64.(file["ad/gradient"]),
     c       = Float64.(file["ad/control_initial"]),
     control = file["ad/control"],
     target  = file["ad/target"],
     steps   = file["ad/steps"],
     loss    = file["ad/loss"],
     λ       = Float64.(file["grid/lambda_center"]),
     φ       = Float64.(file["grid/phi_center"]),
     λf      = Float64.(file["grid/lambda_face"]),
     φf      = Float64.(file["grid/phi_face"]),
     r       = Float64.(file["grid/z_center"]),
     rf      = Float64.(file["grid/z_face"]),
     h       = Float64.(file["grid/terrain_height"]),
     z_top   = file["grid/z_top"],
     domain  = file["meta/domain"],
     Δt      = file["meta/dt_seconds"],
     ic      = file["meta/initial_condition"])
end

g, c, λ, φ, r, h = data.g, data.c, data.λ, data.φ, data.r, data.h
Nx, Ny, Nz = size(g)

# ## Physical heights
#
# `grid/z_center` is the terrain-following *reference* coordinate r. Gal-Chen & Somerville's
# linear decay (Breeze's `LinearDecay`, b(r) = 1 − r/z_top) puts the physical height of a cell at
# z(i,j,k) = r(k) + h(i,j)·(1 − r(k)/z_top), so every column has its own vertical axis — which is
# why the sections below are drawn as curvilinear surfaces rather than heatmaps. In km throughout.
physical_z(i, j) = @. (r + h[i, j] * (1 - r / data.z_top)) / 1000
z_ceiling = maximum(physical_z(Tuple(argmax(h))...))   # the tallest column sets the section's roof

# ## Reductions
#
# The gradient spans five decades, so magnitudes are viewed in log₁₀ — but it is NOT necessarily
# one-signed. At one step it is (∂J/∂c → 2c/N > 0); past a few steps, transport and the saturation
# adjustment give some cells a genuinely NEGATIVE sensitivity, and `log10` of those is silently
# `NaN`-or-clipped. So everything below plots |∂J/∂c| and marks the sign separately, which keeps a
# sign flip visible instead of dropping it. Past a few dozen steps the negative population is no
# longer a handful of cells but ~8% of the domain, and marking every one of them swamps the fields
# the markers sit on — so the sign is REPORTED (counts and minimum in the subtitle, the negative
# branch quantified by the ratio quantiles in panel f) rather than scattered over the panels.
# `column_peak` is the largest |sensitivity| anywhere in each column — the honest summary of
# "perturbing this column matters", where a column *integral* of a quantity with a sharp vertical
# maximum mostly reports the layer thickness instead.
column_peak = dropdims(maximum(abs, g, dims = 3), dims = 3)
negative    = g .< 0

## A genuine column integral, not a bare sum over k. `Δr` is stretched — 60 m at the surface to
## 490 m aloft — so summing cells over-weights the thin near-surface layers by up to 8×, exactly
## where the moisture is largest. The terrain-following metric supplies the rest: with
## z = r + h(1 − r/z_top), dz/dr = 1 − h/z_top, so Δz(i,j,k) = Δr(k)·σ(i,j). Result in kg m⁻².
Δr = diff(data.rf)
σ  = @. 1 - h / data.z_top
column_water = [sum(c[i, j, k] * Δr[k] for k in 1:Nz) * σ[i, j] for i in 1:Nx, j in 1:Ny]

iₚ, jₚ, kₚ = Tuple(argmax(abs.(g)))
zₚ = physical_z(iₚ, jₚ)[kₚ]
φ_section = φ[jₚ]
z_column = physical_z(iₚ, jₚ)

profile_max  = [maximum(abs, view(g, :, :, k)) for k in 1:Nz]
profile_mean = [mean(abs, view(g, :, :, k))    for k in 1:Nz]
profile_ctrl = [mean(view(c, :, :, k))         for k in 1:Nz]

# Share of the total sensitivity magnitude held by the strongest 1% of cells: how concentrated the
# adjoint is is the result, so it belongs in the caption rather than in the reader's eye.
sorted = sort(abs.(vec(g)), rev = true)
top1 = sum(view(sorted, 1:max(1, length(sorted) ÷ 100))) / sum(sorted)

# ## The one-step analytic limit
#
# With J = ⟨c²⟩ over N cells and the target the same field as the control, a single step barely
# moves the state, so ∂J/∂c → 2c/N cell by cell — which at `steps = 1` turns panel (f) into a check
# of the whole Enzyme-through-XLA pipeline rather than a picture of it. At more steps the same line
# is a BASELINE, not a check: departure from it is exactly the dynamics the adjoint has picked up,
# so the quartiles of the ratio say more than its median.
N = length(g)
ratio = vec(g) ./ (2 .* vec(c) ./ N)
analytic_ratio = median(ratio)
ratio_q = (quantile(ratio, 0.05), quantile(ratio, 0.95))

coastλ, coastφ = natural_earth_lines("coastline")

# ## Figure

set_theme!(Theme(fonts = (regular = "DejaVu Sans", bold = "DejaVu Sans Bold"),
                 Axis = (xgridvisible = false, ygridvisible = false,
                         topspinevisible = false, rightspinevisible = false,
                         titlefont = :regular, titlealign = :left, titlesize = 15,
                         xlabelsize = 12, ylabelsize = 12,
                         xticklabelsize = 11, yticklabelsize = 11)))

fig = Figure(size = (1500, 1210), backgroundcolor = :white, figure_padding = (26, 26, 20, 20))

Label(fig[1, 1:2],
      @sprintf("Adjoint sensitivity of the %s downscale:  ∂J/∂%s,   J = ⟨%s²⟩ after %d step%s of Δt = %g s",
               data.domain, data.control, data.target, data.steps, data.steps == 1 ? "" : "s", data.Δt),
      fontsize = 22, halign = :left, tellwidth = false)

Label(fig[2, 1:2],
      @sprintf("reverse mode, Enzyme through XLA   •   J = %.4g   •   peak |∂J/∂%s| = %.3g at %.1f°E, %.1f°N, z = %.2f km   •   strongest 1%% of cells carry %.0f%% of the total   •   %d of %d cells negative (min %.3g)",
               data.loss, data.control, maximum(abs, g), λ[iₚ], φ[jₚ], zₚ, 100top1,
               count(negative), N, minimum(g)),
      fontsize = 13, color = :gray35, halign = :left, tellwidth = false)

log_g = log10.(max.(abs.(g), eps()))
sens_range = (quantile(vec(log_g), 0.02), maximum(log_g))

## The control is drawn in log₁₀ too. It spans as many decades as the gradient does — on a linear
## scale the whole free troposphere collapses into the lightest tone of the colormap and panel (d)
## stops saying anything — and matching (c)'s treatment is what makes the two directly comparable.
log_c = log10.(max.(c, eps()))
ctrl_range = (quantile(vec(log_c), 0.02), maximum(log_c))

"Draw a curvilinear (λ, z) section at row `j`: one physical height column per grid column."
function section!(ax, j, field, colorrange, colormap)
    X = repeat(λ, 1, Nz)
    Z = reduce(vcat, (physical_z(i, j)' for i in 1:Nx))
    return surface!(ax, X, Z, zeros(Nx, Nz); color = field[:, j, :], colorrange, colormap,
                    shading = NoShading)
end

"Fill the terrain below the section and outline its skyline."
function terrain!(ax, j)
    band!(ax, λ, zeros(Nx), h[:, j] ./ 1000; color = (:gray25, 0.9))
    lines!(ax, λ, h[:, j] ./ 1000; color = :black, linewidth = 1.2)
end

function map_axis(pos, title)
    ax = Axis(pos; title, aspect = DataAspect(),
              xlabel = "longitude (°)", ylabel = "latitude (°)")
    limits!(ax, extrema(data.λf)..., extrema(data.φf)...)
    return ax
end

function section_axis(pos, title)
    ax = Axis(pos; title, xlabel = "longitude (°)", ylabel = "z (km)")
    limits!(ax, extrema(data.λf)..., 0, z_ceiling)
    return ax
end

thin_colorbar(pos, plt, label) =
    Colorbar(pos, plt; label, labelsize = 11, ticklabelsize = 11, width = 11)

# ### (a) where, in the horizontal, the loss is sensitive
#
# Its own colour range, not the 3D one: the column peaks occupy a fraction of a decade, and
# borrowing the sections' range flattens the map to a single tone.

ax_map = map_axis(fig[3, 1][1, 1], "(a)  column-peak |∂J/∂$(data.control)| — the adjoint's footprint")
hm_map = heatmap!(ax_map, λ, φ, log10.(column_peak);
                  colormap = :magma, colorrange = extrema(log10.(column_peak)), interpolate = true)
contour!(ax_map, λ, φ, h; levels = 250:500:2000, color = (:white, 0.35), linewidth = 0.7)
lines!(ax_map, coastλ, coastφ; color = :white, linewidth = 1.2)
hlines!(ax_map, φ_section; color = :cyan, linestyle = :dash, linewidth = 1.4)
scatter!(ax_map, [λ[iₚ]], [φ[jₚ]]; markersize = 13, color = (:white, 0),
         strokecolor = :cyan, strokewidth = 2)
text!(ax_map, λ[iₚ], φ[jₚ] + 0.9; text = @sprintf("peak · section at %.1f°N", φ_section),
      color = :cyan, fontsize = 11, align = (:center, :bottom))
thin_colorbar(fig[3, 1][1, 2], hm_map, "log₁₀ |∂J/∂$(data.control)|")

# ### (b) the state the sensitivity is taken at

ax_ctrl = map_axis(fig[3, 2][1, 1], "(b)  column ∫$(data.control) dz of the control state — where the gradient is evaluated")
hm_ctrl = heatmap!(ax_ctrl, λ, φ, column_water; colormap = :dense, interpolate = true)
contour!(ax_ctrl, λ, φ, h; levels = 250:500:2000, color = (:white, 0.3), linewidth = 0.7)
lines!(ax_ctrl, coastλ, coastφ; color = :white, linewidth = 1.2)
hlines!(ax_ctrl, φ_section; color = :cyan, linestyle = :dash, linewidth = 1.4)
thin_colorbar(fig[3, 2][1, 2], hm_ctrl, "∫$(data.control) dz (kg m⁻²)")

# ### (c, d) the same two quantities in the vertical, along the peak's latitude

ax_sec = section_axis(fig[4, 1][1, 1], @sprintf("(c)  |∂J/∂%s| at %.1f°N", data.control, φ_section))
hm_sec = section!(ax_sec, jₚ, log_g, sens_range, :magma)
terrain!(ax_sec, jₚ)
scatter!(ax_sec, [λ[iₚ]], [zₚ]; marker = :cross, markersize = 15, color = :cyan)
thin_colorbar(fig[4, 1][1, 2], hm_sec, "log₁₀ |∂J/∂$(data.control)|")

ax_secc = section_axis(fig[4, 2][1, 1],
                       @sprintf("(d)  %s of the control state at %.1f°N", data.control, φ_section))
hm_secc = section!(ax_secc, jₚ, log_c, ctrl_range, :dense)
terrain!(ax_secc, jₚ)
thin_colorbar(fig[4, 2][1, 2], hm_secc, "log₁₀ $(data.control) (kg m⁻³)")

# ### (e) vertical structure
#
# Sensitivity and state differ by four orders of magnitude in units that are not comparable
# anyway, so each curve is normalized by its own maximum: the question here is the SHAPE — does
# the adjoint decay with height the way the moisture it is differentiating does?

ax_prof = Axis(fig[5, 1][1, 1]; title = "(e)  vertical structure, each curve ÷ its own maximum",
               xlabel = "normalized magnitude", ylabel = "z (km)", xscale = log10)
lines!(ax_prof, profile_max ./ maximum(profile_max), z_column;
       color = :darkorange3, linewidth = 2.2, label = "max |∂J/∂$(data.control)|")
lines!(ax_prof, profile_mean ./ maximum(profile_mean), z_column;
       color = :black, linewidth = 2.2, label = "mean |∂J/∂$(data.control)|")
lines!(ax_prof, profile_ctrl ./ maximum(profile_ctrl), z_column;
       color = :seagreen, linewidth = 2.2, linestyle = :dash, label = "mean $(data.control)")
limits!(ax_prof, 10.0^floor(log10(minimum(profile_mean) / maximum(profile_mean))), 1.6, 0, z_ceiling)
axislegend(ax_prof; position = :rt, framevisible = false, labelsize = 11)

# ### (f) is the adjoint just tracking the moisture?
#
# Yes, and quantitatively so — see the analytic limit above. Loudest cells drawn last so the
# top of the distribution is not buried under the free troposphere.

ax_rel = Axis(fig[5, 2][1, 1]; title = "(f)  sensitivity vs. state, one point per interior cell",
              xlabel = "$(data.control) (kg m⁻³)", ylabel = "|∂J/∂$(data.control)|",
              xscale = log10, yscale = log10)
zcell = [physical_z(i, j)[k] for i in 1:Nx, j in 1:Ny, k in 1:Nz]
order = sortperm(abs.(vec(g)))
sc = scatter!(ax_rel, vec(c)[order], abs.(vec(g))[order]; color = vec(zcell)[order],
              colormap = :viridis, markersize = 3.5, alpha = 0.6)
cline = [minimum(c), maximum(c)]
lines!(ax_rel, cline, 2 .* cline ./ N; color = :crimson, linewidth = 1.6, linestyle = :dash,
       label = data.steps == 1 ?
           @sprintf("2%s/N, the one-step limit (median ratio %.3f)", data.control, analytic_ratio) :
           @sprintf("2%s/N, the one-step limit (ratio %.2f, 5–95%%: %.2f–%.1f)",
                    data.control, analytic_ratio, ratio_q...))
axislegend(ax_rel; position = :lt, framevisible = false, labelsize = 10)
thin_colorbar(fig[5, 2][1, 2], sc, "z (km)")

Label(fig[6, 1:2],
      "Source: " * basename(gradient_path) *
      @sprintf("   •   %d×%d×%d interior cells   •   initial condition: %s   •   heights from the Gal-Chen–Somerville linear decay, z_top = %.2f km",
               Nx, Ny, Nz, data.ic, data.z_top / 1000),
      fontsize = 11, color = :gray45, halign = :left, tellwidth = false)

rowgap!(fig.layout, 1, 2)     # title → subtitle
rowgap!(fig.layout, 2, 16)    # subtitle → panels
rowgap!(fig.layout, 5, 10)    # panels → caption
colgap!(fig.layout, 28)

out = replace(gradient_path, r"\.jld2$" => "") * "_sensitivity.png"
save(out, fig; px_per_unit = 2)
@info "wrote $(out)"
