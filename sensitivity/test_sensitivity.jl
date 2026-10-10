# # Host-only tests of the region mask and the IWV post-processing (no GPU, no model)
#
#     julia --project=sensitivity sensitivity/test_sensitivity.jl [outdir]
#
# 1. The target polygon on the 12 km landfall grid: area, cell count, and known places in/out.
# 2. `iwv_sensitivity` on synthetic gradients with analytically known answers.
# 3. A synthetic gradient FILE in the AD block's format, rendered by plot_sensitivity.jl end to end,
#    plus a figure of the mask itself.

using Test
using Printf

include(joinpath(@__DIR__, "plot_sensitivity.jl"))   # region.jl, postprocess.jl, plotting, JLD2

outdir = length(ARGS) ≥ 1 ? ARGS[1] : joinpath(@__DIR__, "test_output")
mkpath(outdir)

landfall = ((-148.0, -112.0), (38.0, 56.0))           # case.jl `landfall`
λf, φf = uniform_faces(landfall..., 9)                  # AR_CELLS_PER_DEGREE=9 ≈ 12 km
Nx, Ny = length(λf) - 1, length(φf) - 1
λc, φc = (λf[1:end-1] .+ λf[2:end]) ./ 2, (φf[1:end-1] .+ φf[2:end]) ./ 2

@testset "region" begin
    inside = Dict("Portland" => (-122.68, 45.52), "Salem" => (-123.03, 44.94), "Astoria" => (-123.83, 46.19),
                  "Longview" => (-122.94, 46.14), "Centralia" => (-122.95, 46.72), "Tillamook" => (-123.84, 45.46),
                  "Mt St Helens" => (-122.19, 46.20), "Vancouver WA" => (-122.66, 45.64))
    outside = Dict("Seattle" => (-122.33, 47.61), "Olympia" => (-122.90, 47.04), "Yakima" => (-120.51, 46.60),
                   "Bend" => (-121.31, 44.06), "Eugene" => (-123.09, 44.05), "Hood River" => (-121.52, 45.71),
                   "Pacific 125W" => (-125.0, 46.0), "The Dalles" => (-121.18, 45.60))
    for (name, (λ, φ)) in inside;  @test point_in_polygon(λ, φ, TARGET_POLYGON) end
    for (name, (λ, φ)) in outside; @test !point_in_polygon(λ, φ, TARGET_POLYGON) end

    w, area = region_weights(λf, φf)
    @test sum(w) ≈ 1
    @test all(≥(0), w)
    @printf("region: %.0f km², %d cells touched at 9 cpd\n",
            area / 1e6, count(>(0), w))
    @test 4.5e10 < area < 6.0e10                       # ≈ 5.2×10⁴ km²
    ## Exact areas sum to the spherical-rectangle area.
    A = cell_areas(λf, φf)
    @test sum(A) ≈ EARTH_RADIUS^2 * deg2rad(36) * (sind(56) - sind(38))
    ## Resolution independence of the region area (fractional coverage).
    _, area3 = region_weights(uniform_faces(landfall..., 3)...)
    @test isapprox(area3, area; rtol = 0.03)
end

## A Breeze-like reference column: 60 m at the ground, stretching 15 %/level to 490 m, lid ≈ 19.5 km.
function reference_faces()
    r = [0.0]; Δ = 60.0
    while r[end] < 19525
        push!(r, r[end] + Δ)
        r[end] > 60 && (Δ = min(490, Δ * 1.15))
    end
    return r
end
rf = reference_faces()
Nz = length(rf) - 1
z_top = rf[end]
h = [2000 * exp(-((λ + 121.3) / 0.9)^2) * exp(-((φ - 46.5) / 9)^2) for λ in λc, φ in φc]   # a "Cascades"

@testset "postprocess" begin
    f, Δz = layer_fractions(rf, h, z_top; H = 1000)
    ## The layer always has physical depth H, flat ground or 2 km of terrain.
    @test all(isapprox.(dropdims(sum(f .* Δz; dims = 3); dims = 3), 1000; rtol = 1e-12))
    ## Columns are compressed over terrain: Σ Δz = z_top − h.
    @test all(isapprox.(dropdims(sum(Δz; dims = 3); dims = 3), z_top .- h; rtol = 1e-12))

    ## Physical-face path (grid/z_physical_face) agrees with r + LinearDecay.
    zf = [rf[k] + h[i, j] * (1 - rf[k] / z_top) for i in 1:Nx, j in 1:Ny, k in 1:Nz+1]
    fp, Δzp = layer_fractions_physical(zf, h; H = 1000)
    @test fp ≈ f
    @test Δzp ≈ Δz

    A = cell_areas(λf, φf)
    c =[0.01 * exp(-(rf[k] + rf[k+1]) / 2 / 2000) for i in 1:Nx, j in 1:Ny, k in 1:Nz]   # ρqᵛ, 2 km scale height

    ## J = G ∫ c dz over every column ⇒ g = G Δz ⇒ ∂J/∂IWV = G for both ansätze, everywhere.
    G = 0.37
    s = iwv_sensitivity(G .* Δz, c, rf, h, z_top, A)
    @test all(isapprox.(s.uniform, G; rtol = 1e-10))
    @test all(isapprox.(s.profile, G; rtol = 1e-10))
    @test all(isapprox.(s.dlnq, G .* s.iwv; rtol = 1e-10))

    ## Sensitivity confined above the layer ⇒ zero; confined to the lowest cell ⇒ g₁ f₁ / H.
    g_aloft = zeros(Nx, Ny, Nz); g_aloft[:, :, end] .= 1
    @test all(iszero, iwv_sensitivity(g_aloft, c, rf, h, z_top, A).uniform)
    g_low = zeros(Nx, Ny, Nz); g_low[:, :, 1] .= 2.0
    @test all(isapprox.(iwv_sensitivity(g_low, c, rf, h, z_top, A).uniform, 2.0 / 1000))

    ## FD check of the formula itself: perturb c exactly as ansatz (a) prescribes in one column and
    ## evaluate the linear J = Σ g c directly.
    g = randn(Nx, Ny, Nz)
    i, j, δ = 200, 70, 1e-3
    δc = zeros(Nx, Ny, Nz); δc[i, j, :] .= f[i, j, :] .* δ ./ 1000
    @test sum(δc .* Δz) ≈ δ                              # the perturbation adds exactly δ to IWV₀₋₁ₖₘ
    @test sum(g .* δc) / δ ≈ iwv_sensitivity(g, c, rf, h, z_top, A).uniform[i, j]
end

## End to end: a synthetic file in the AD block's layout, with a plausible-looking sensitivity
## upstream (SW) of the region in the lowest 2 km, through plot_sensitivity.jl.
let
    w, area = region_weights(λf, φf)
    c = [0.012 * exp(-(rf[k] + rf[k+1]) / 2 / 2000) * (1 + 0.5exp(-((φ - (35 + 0.42(λ + 160))) / 3)^2))
         for λ in λc, φ in φc, k in 1:Nz]
    _, Δz = layer_fractions(rf, h, z_top; H = 1000)
    zc = (rf[1:end-1] .+ rf[2:end]) ./ 2
    g = [exp(-((λ + 128) / 3)^2 - ((φ - 44) / 2)^2) * exp(-zc[k] / 1500) * Δz[i, j, k] * 50
         for (i, λ) in enumerate(λc), (j, φ) in enumerate(φc), k in 1:Nz]
    P = [60 * exp(-((λ + 123) / 1.2)^2 - ((φ - 46) / 1.5)^2) for λ in λc, φ in φc]
    path = joinpath(outdir, "synthetic_gradient.jld2")
    jldopen(path, "w") do file
        file["grid/lambda_face"] = λf; file["grid/phi_face"] = φf; file["grid/z_face"] = rf
        file["grid/terrain_height"] = h; file["grid/z_top"] = z_top
        file["ad/gradient"] = Float32.(g); file["ad/control_initial"] = Float32.(c)
        file["ad/loss"] = sum(w .* P); file["ad/dt"] = 30.0; file["ad/steps"] = round(Int, 86400 / 30.0); file["ad/accum_start"] = 0
        file["sens/weights"] = w; file["sens/precip_accumulated"] = P; file["sens/dt_seconds"] = 10.0
        file["sens/region_polygon"] = TARGET_POLYGON
    end
    d = load_sensitivity(path)
    s = sensitivity(d)
    report(d, s)
    plot_sensitivity(d, s, joinpath(outdir, "synthetic_iwv_sensitivity.png"))
end

## The mask itself, zoomed on the Pacific Northwest, with the 12 km cells and their coverage.
let
    frac = region_fraction(λf, φf)
    coast = natural_earth_lines("coastline", scale = 10)
    states = natural_earth_lines("admin_1_states_provinces_lines")
    rivers = try natural_earth_lines("rivers_lake_centerlines", scale = 10) catch; (Float64[], Float64[]) end
    fig = Figure(size = (900, 900))
    ax = Axis(fig[1, 1]; title = "Target region: $TARGET_NAME\n12 km (9 cells/°) coverage fraction",
              xlabel = "longitude (°E)", ylabel = "latitude (°N)", aspect = AxisAspect(1 / cosd(46)))
    hm = heatmap!(ax, λf, φf, replace(frac, 0.0 => NaN); colormap = :Greens, colorrange = (0, 1))
    contour!(ax, λc, φc, h; levels = 250:250:2000, color = :gray50, linewidth = 0.5)
    lines!(ax, coast...; color = :black, linewidth = 1)
    lines!(ax, states...; color = :black, linewidth = 0.6, linestyle = :dash)
    lines!(ax, rivers...; color = :steelblue, linewidth = 0.8)
    poly = [TARGET_POLYGON; TARGET_POLYGON[1]]
    lines!(ax, first.(poly), last.(poly); color = :darkred, linewidth = 2)
    for (name, (λ, φ)) in ("Portland" => (-122.68, 45.52), "Salem" => (-123.03, 44.94), "Seattle" => (-122.33, 47.61),
                           "Olympia" => (-122.90, 47.04), "Astoria" => (-123.83, 46.19), "Yakima" => (-120.51, 46.60),
                           "Mt Hood" => (-121.70, 45.37), "Mt Rainier" => (-121.76, 46.85), "Mt St Helens" => (-122.19, 46.20))
        scatter!(ax, [λ], [φ]; color = :black, markersize = 6)
        text!(ax, λ + 0.05, φ; text = name, fontsize = 11)
    end
    xlims!(ax, -126, -119.5); ylims!(ax, 43.5, 48.5)
    Colorbar(fig[1, 2], hm; label = "cell fraction inside region (terrain: idealized reactant ridge, 250 m)")
    out = joinpath(outdir, "target_region_mask.png")
    save(out, fig; px_per_unit = 1.5)
    println("wrote ", out)
end
