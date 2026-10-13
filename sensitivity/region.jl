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

# ## The PNW region: Washington + Oregon land, both sides of the Cascades
#
#  (read by loss.jl) swaps the target for the land of the two states: the outer rings of
# NaturalEarth 10 m admin-1 "Washington" and "Oregon" (largest part of each — the mainland, Olympic
# Peninsula included, Puget Sound water excluded; the San Juan/Whidbey islands, ~0.3 % of the area, are
# dropped), Douglas–Peucker-simplified at 0.02° (≈2 km, ≪ the 12 km grid). The shared border is the
# Columbia, so the union is the two rings side by side. Area ≈ 4.2×10⁵ km².
# Regenerate: scratchpad script pnw_extract.jl (NaturalEarth.naturalearth("admin_1_states_provinces", 10)).

const WASHINGTON_POLYGON = [
    (-122.753, 48.993), (-117.038, 48.993), (-117.044, 46.378), (-116.942, 46.26), (-116.909, 46.162),
    (-116.961, 46.105), (-116.879, 46.001), (-119.002, 46.0), (-119.093, 45.949), (-119.575, 45.928),
    (-119.662, 45.872), (-119.934, 45.838), (-120.23, 45.737), (-120.47, 45.71), (-120.631, 45.729),
    (-120.9, 45.642), (-121.039, 45.653), (-121.155, 45.622), (-121.224, 45.697), (-121.57, 45.729),
    (-121.821, 45.717), (-121.971, 45.642), (-122.261, 45.566), (-122.673, 45.626), (-122.748, 45.68),
    (-122.807, 45.978), (-122.936, 46.122), (-123.112, 46.186), (-123.298, 46.152), (-123.456, 46.267),
    (-123.603, 46.26), (-123.693, 46.305), (-123.873, 46.24), (-124.009, 46.313), (-124.08, 46.272),
    (-124.063, 46.655), (-124.018, 46.569), (-124.014, 46.385), (-123.958, 46.378), (-123.927, 46.44),
    (-123.847, 46.397), (-123.841, 46.416), (-123.936, 46.472), (-123.896, 46.544), (-123.956, 46.623),
    (-123.895, 46.603), (-123.923, 46.658), (-123.877, 46.692), (-123.826, 46.692), (-123.812, 46.663),
    (-123.764, 46.678), (-123.9, 46.747), (-123.976, 46.741), (-123.973, 46.701), (-124.093, 46.743),
    (-124.127, 46.899), (-124.091, 46.9), (-124.072, 46.843), (-124.021, 46.832), (-124.032, 46.87),
    (-124.057, 46.862), (-124.047, 46.891), (-123.813, 46.959), (-124.013, 46.984), (-124.028, 47.028),
    (-124.117, 47.043), (-124.148, 47.024), (-124.106, 46.933), (-124.178, 46.926), (-124.2, 47.187),
    (-124.299, 47.348), (-124.272, 47.343), (-124.318, 47.357), (-124.423, 47.742), (-124.638, 47.908),
    (-124.735, 48.17), (-124.689, 48.213), (-124.706, 48.246), (-124.661, 48.32), (-124.73, 48.372),
    (-124.697, 48.391), (-123.971, 48.166), (-123.247, 48.115), (-123.108, 48.184), (-123.161, 48.152),
    (-123.063, 48.118), (-123.03, 48.045), (-122.997, 48.039), (-122.999, 48.092), (-122.927, 48.095),
    (-122.854, 47.995), (-122.825, 48.035), (-122.878, 48.107), (-122.77, 48.141), (-122.75, 48.117),
    (-122.792, 48.083), (-122.62, 47.878), (-122.676, 47.862), (-122.8, 47.68), (-122.829, 47.694),
    (-122.806, 47.843), (-122.839, 47.782), (-122.856, 47.826), (-122.839, 47.747), (-123.119, 47.45),
    (-123.161, 47.357), (-123.074, 47.345), (-122.839, 47.432), (-123.052, 47.367), (-123.092, 47.367),
    (-123.111, 47.405), (-122.949, 47.597), (-122.764, 47.669), (-122.734, 47.743), (-122.635, 47.84),
    (-122.571, 47.82), (-122.613, 47.946), (-122.528, 47.906), (-122.504, 47.788), (-122.468, 47.757),
    (-122.558, 47.74), (-122.596, 47.692), (-122.661, 47.73), (-122.592, 47.583), (-122.617, 47.574),
    (-122.682, 47.652), (-122.697, 47.623), (-122.639, 47.577), (-122.682, 47.528), (-122.553, 47.583),
    (-122.508, 47.52), (-122.556, 47.392), (-122.538, 47.371), (-122.586, 47.336), (-122.569, 47.264),
    (-122.686, 47.301), (-122.633, 47.405), (-122.726, 47.339), (-122.753, 47.281), (-122.724, 47.233),
    (-122.773, 47.173), (-122.815, 47.251), (-122.784, 47.315), (-122.806, 47.398), (-122.846, 47.316),
    (-122.92, 47.278), (-122.965, 47.181), (-123.079, 47.13), (-123.018, 47.13), (-123.079, 47.096),
    (-122.93, 47.174), (-123.01, 47.083), (-122.935, 47.13), (-122.893, 47.047), (-122.901, 47.13),
    (-122.853, 47.165), (-122.86, 47.13), (-122.817, 47.166), (-122.722, 47.089), (-122.572, 47.209),
    (-122.538, 47.316), (-122.433, 47.265), (-122.4, 47.281), (-122.422, 47.316), (-122.328, 47.357),
    (-122.409, 47.575), (-122.378, 47.596), (-122.346, 47.562), (-122.34, 47.599), (-122.429, 47.66),
    (-122.381, 47.72), (-122.404, 47.798), (-122.32, 47.942), (-122.213, 47.987), (-122.192, 48.026),
    (-122.34, 48.09), (-122.376, 48.213), (-122.444, 48.232), (-122.469, 48.177), (-122.348, 48.054),
    (-122.51, 48.147), (-122.534, 48.25), (-122.446, 48.261), (-122.401, 48.235), (-122.386, 48.304),
    (-122.534, 48.375), (-122.559, 48.434), (-122.647, 48.404), (-122.683, 48.43), (-122.663, 48.455),
    (-122.702, 48.498), (-122.633, 48.516), (-122.581, 48.458), (-122.568, 48.489), (-122.489, 48.455),
    (-122.494, 48.529), (-122.567, 48.585), (-122.468, 48.555), (-122.44, 48.581), (-122.525, 48.692),
    (-122.509, 48.756), (-122.575, 48.78), (-122.64, 48.722), (-122.667, 48.732), (-122.658, 48.777),
    (-122.705, 48.788), (-122.704, 48.827), (-122.768, 48.874), (-122.746, 48.918), (-122.808, 48.935),
    (-122.801, 48.962), (-122.732, 48.959),
]

const OREGON_POLYGON = [
    (-124.492, 42.93), (-124.416, 43.125), (-124.401, 43.31), (-124.342, 43.352), (-124.317, 43.3),
    (-124.309, 43.355), (-124.233, 43.424), (-124.213, 43.375), (-124.14, 43.375), (-124.187, 43.391),
    (-124.209, 43.452), (-124.335, 43.365), (-124.21, 43.657), (-124.14, 43.733), (-124.07, 43.712),
    (-124.149, 43.748), (-124.203, 43.681), (-124.119, 44.006), (-124.114, 44.307), (-124.084, 44.412),
    (-124.054, 44.433), (-124.018, 44.41), (-124.05, 44.449), (-124.083, 44.428), (-124.084, 44.498),
    (-124.063, 44.61), (-124.005, 44.616), (-124.068, 44.618), (-124.078, 44.675), (-124.065, 44.823),
    (-124.018, 44.917), (-124.014, 45.064), (-123.971, 45.154), (-123.96, 45.3), (-124.002, 45.344),
    (-123.958, 45.415), (-123.961, 45.379), (-123.918, 45.418), (-123.971, 45.452), (-123.949, 45.557),
    (-123.939, 45.5), (-123.891, 45.475), (-123.896, 45.56), (-123.958, 45.576), (-123.918, 45.69),
    (-123.871, 45.698), (-123.917, 45.704), (-123.938, 45.661), (-123.942, 45.727), (-123.981, 45.76),
    (-123.957, 45.873), (-123.991, 45.938), (-123.923, 46.014), (-124.023, 46.231), (-123.825, 46.157),
    (-123.799, 46.102), (-123.801, 46.144), (-123.778, 46.143), (-123.865, 46.186), (-123.767, 46.204),
    (-123.706, 46.171), (-123.519, 46.235), (-123.386, 46.146), (-123.256, 46.133), (-123.112, 46.186),
    (-122.967, 46.136), (-122.892, 46.092), (-122.807, 45.978), (-122.722, 45.649), (-122.261, 45.566),
    (-121.793, 45.721), (-121.272, 45.709), (-121.204, 45.685), (-121.155, 45.622), (-121.039, 45.653),
    (-120.9, 45.642), (-120.631, 45.729), (-120.47, 45.71), (-120.23, 45.737), (-119.934, 45.838),
    (-119.662, 45.872), (-119.575, 45.928), (-119.093, 45.949), (-119.002, 46.0), (-116.879, 46.001),
    (-116.839, 45.91), (-116.759, 45.838), (-116.53, 45.752), (-116.455, 45.601), (-116.649, 45.348),
    (-116.717, 45.151), (-116.831, 45.025), (-116.822, 44.967), (-116.864, 44.866), (-117.029, 44.734),
    (-117.122, 44.554), (-117.204, 44.482), (-117.195, 44.298), (-117.14, 44.264), (-117.099, 44.292),
    (-117.044, 44.26), (-116.973, 44.268), (-116.961, 44.224), (-116.892, 44.177), (-116.921, 44.114),
    (-116.969, 44.1), (-116.936, 44.017), (-116.971, 43.893), (-117.031, 43.829), (-117.017, 42.0),
    (-124.215, 42.0), (-124.35, 42.098), (-124.379, 42.22), (-124.412, 42.249), (-124.44, 42.439),
    (-124.4, 42.616), (-124.567, 42.834),
]

"A region made of several polygons (point inside any)."
const PNW_POLYGON = [WASHINGTON_POLYGON, OREGON_POLYGON]

const PNW_NAME = "Washington + Oregon (land, both sides of the Cascades)"

"""
    target_region(name = get(ENV, "AR_AD_REGION", "westside")) -> (polygon, name)

`westside` → `TARGET_POLYGON` (SW WA + NW OR west of the Cascade crest); `pnw` → `PNW_POLYGON`.
"""
function target_region(name = get(ENV, "AR_AD_REGION", "westside"))
    name == "westside" && return TARGET_POLYGON, TARGET_NAME
    name == "pnw"      && return PNW_POLYGON, PNW_NAME
    error("AR_AD_REGION=$(name): use `westside` or `pnw`")
end

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

# Multi-polygon region: inside any part.
point_in_polygon(λ, φ, polygons::AbstractVector{<:AbstractVector{<:Tuple}}) =
    any(p -> point_in_polygon(λ, φ, p), polygons)

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
