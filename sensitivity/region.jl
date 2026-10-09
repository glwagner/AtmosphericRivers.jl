# # Target region for the precipitation sensitivity
#
# Pure Julia, no packages: included by `loss.jl` (inside the Reactant run, on HOST arrays only), by
# `postprocess.jl`, by `plot_sensitivity.jl`, and by `test_sensitivity.jl`.
#
# ## The region: SW Washington + NW Oregon, west of the Cascade crest
#
# Andrea's target is the lowland/windward area that floods when an AR stalls on the Columbia:
# the Willapa Hills, the lower Columbia, the Chehalis/Cowlitz/Lewis basins, the Portland basin and
# the northern Willamette Valley, together with the windward Coast Range and western Cascade slopes.
#
# It is a HAND-DRAWN polygon rather than a terrain-derived mask, for three reasons:
#
#   * the reactant nest uses idealized orography (`orography` in reactant_downscale.jl: a Gaussian
#     "Cascades" ridge at 121.3°W), so a crest found from the model's terrain would sit at 121.3°W at
#     every latitude, ~0.3–0.5° east of the real crest — the real crest is the better definition for
#     comparing with observations and with the ETOPO-terrain CUDA runs;
#   * the idealized setup has no land/sea mask, so "west of the crest" alone would run into the
#     Pacific; the polygon's west edge is the real coastline;
#   * a polygon is one obvious, editable object. `TARGET_POLYGON` below is the only thing to change.
#
# Vertices (lon °E, lat °N), counterclockwise starting at the SW corner. West edge: the coast
# (Newport → Tillamook → Columbia mouth → Willapa Bay → Grays Harbor latitude). North edge: 47.0°N
# (just south of Olympia/Chehalis-basin divide; Andrea's "southwest Washington"). East edge: the
# Cascade crest — Snoqualmie/White Pass ~121.4°W, Mt Adams 121.5°W, the Columbia Gorge 121.8°W,
# Mt Hood 121.7°W, Mt Jefferson 121.8°W, Santiam Pass 121.87°W. South edge: 44.5°N (Corvallis /
# Newport — the conventional southern end of "northwest Oregon").
#
# Area ≈ 5.2×10⁴ km² (≈ 360 cells-worth, 524 cells touched, at 12 km). Edit freely; everything downstream re-derives from it.

const TARGET_POLYGON = [
    (-124.10, 44.50),   # coast at Newport latitude
    (-121.87, 44.50),   # Santiam Pass
    (-121.80, 44.70),   # Mt Jefferson
    (-121.70, 45.37),   # Mt Hood
    (-121.80, 45.70),   # Columbia Gorge (crest dips west)
    (-121.50, 46.20),   # Mt Adams
    (-121.40, 46.64),   # White Pass
    (-121.45, 47.00),   # crest at 47°N
    (-124.20, 47.00),   # coast at 47°N (south of Grays Harbor entrance)
    (-124.10, 46.70),   # Willapa Bay
    (-124.05, 46.25),   # Columbia mouth
    (-123.97, 45.50),   # Tillamook
    (-124.05, 45.00),   # Lincoln City
]

const TARGET_NAME = "SW Washington + NW Oregon, west of the Cascade crest"

const EARTH_RADIUS = 6.371e6   # m — Oceananigans' default `R_Earth`

"""
    point_in_polygon(λ, φ, polygon)

Even–odd ray casting. `polygon` is a vector of `(λ, φ)` vertices; it need not be closed.
"""
function point_in_polygon(λ, φ, polygon)
    inside = false
    n = length(polygon)
    j = n
    for i in 1:n
        λi, φi = polygon[i]
        λj, φj = polygon[j]
        if (φi > φ) != (φj > φ)
            λcross = λi + (φ - φi) * (λj - λi) / (φj - φi)
            λ < λcross && (inside = !inside)
        end
        j = i
    end
    return inside
end

"""
    region_fraction(λf, φf; polygon = TARGET_POLYGON, subsamples = 8)

Fraction of each lat-lon cell inside `polygon`, given the cell FACES `λf` (length Nx+1) and `φf`
(length Ny+1). Each cell is sampled on a `subsamples²` lattice (uniform in λ and in sin φ, i.e. equal
area) so the region's edge is resolved below the grid scale and the total area does not jump with
resolution.
"""
function region_fraction(λf, φf; polygon = TARGET_POLYGON, subsamples = 8)
    Nx, Ny = length(λf) - 1, length(φf) - 1
    frac = zeros(Nx, Ny)
    s = subsamples
    for j in 1:Ny, i in 1:Nx
        hits = 0
        μ₁, μ₂ = sind(φf[j]), sind(φf[j+1])
        for b in 1:s, a in 1:s
            λ = λf[i] + (a - 0.5) / s * (λf[i+1] - λf[i])
            φ = asind(μ₁ + (b - 0.5) / s * (μ₂ - μ₁))
            hits += point_in_polygon(λ, φ, polygon)
        end
        frac[i, j] = hits / s^2
    end
    return frac
end

"""
    cell_areas(λf, φf; R = EARTH_RADIUS)

Exact spherical areas of lat-lon cells, `R² Δλ (sin φ₂ − sin φ₁)`, in m². Same as Oceananigans' `Azᶜᶜᵃ`.
"""
cell_areas(λf, φf; R = EARTH_RADIUS) =
    [R^2 * deg2rad(λf[i+1] - λf[i]) * (sind(φf[j+1]) - sind(φf[j]))
     for i in 1:length(λf)-1, j in 1:length(φf)-1]

"""
    region_weights(λf, φf; polygon = TARGET_POLYGON)

Normalized area weights `w = f·A / Σ f·A`, so that `Σ w ⋅ P` is the area-mean of `P` over the region.
With `P` an accumulated precipitation in kg m⁻², the result is in kg m⁻² ≡ mm of water.
"""
function region_weights(λf, φf; polygon = TARGET_POLYGON)
    fA = region_fraction(λf, φf; polygon) .* cell_areas(λf, φf)
    total = sum(fA)
    total > 0 || error("target region does not intersect the grid " *
                       "(λ ∈ $(extrema(λf)), φ ∈ $(extrema(φf)))")
    return fA ./ total, total
end

"Faces of a uniform lat-lon grid `cells_per_degree` over `longitude × latitude` (same rule as case.jl)."
function uniform_faces(longitude, latitude, cells_per_degree)
    Δ = 1 / cells_per_degree
    Nx = round(Int, (longitude[2] - longitude[1]) / Δ)
    Ny = round(Int, (latitude[2] - latitude[1]) / Δ)
    return collect(range(longitude[1], longitude[2], length = Nx + 1)),
           collect(range(latitude[1], latitude[2], length = Ny + 1))
end
