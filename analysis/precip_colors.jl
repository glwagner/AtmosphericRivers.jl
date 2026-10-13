# Shared precipitation style for the analysis figures and animations.
#
# A discrete, NWS-like palette (light blue → blue → green → yellow → orange → red → magenta → purple) on
# quasi-logarithmic levels, so 1 mm and 150 mm totals are both readable. Values below the first level are left
# transparent (the white axis shows through); values above the last level get PRECIP_HIGH (near-black purple).
#
#   include(joinpath(@__DIR__, "precip_colors.jl"))     # after `using CairoMakie` (and NaturalEarth/NumericalEarth
#                                                       # for geo_lines!)
#   hm = precip_heatmap!(ax, λ, φ, P)                   # accumulated, mm (ACCUM_LEVELS)
#   hm = precip_heatmap!(ax, λ, φ, R; levels = RATE_LEVELS)   # rate, mm h⁻¹
#   precip_colorbar!(fig[1, 2]; label = "mm")           # or levels = RATE_LEVELS, label = "mm h⁻¹"
#   geo_lines!(ax)                                      # heavy coastline + state/province lines
#
# `precip_heatmap!` also accepts an `Observable` field (for `record`). Use the same `levels` on every panel
# (model and ERA5) so colours compare directly.

const PRECIP_COLORS = [
    colorant"#a6dcff",   # 1  light blue
    colorant"#4fb0f5",   # 2
    colorant"#1a63d6",   # 3  blue
    colorant"#0a9e3c",   # 4  green
    colorant"#78d12a",   # 5  light green
    colorant"#ffee1f",   # 6  yellow
    colorant"#ffb300",   # 7  orange-yellow
    colorant"#ff6a00",   # 8  orange
    colorant"#e3120b",   # 9  red
    colorant"#9e0025",   # 10 dark red
    colorant"#ff3fd0",   # 11 magenta
    colorant"#9b2fd6",   # 12 purple
]
const PRECIP_HIGH = colorant"#3a0057"

# 12 bins each (13 edges).
const ACCUM_LEVELS = [0.5, 1, 2, 5, 10, 20, 30, 50, 75, 100, 150, 200, 300]        # mm
const RATE_LEVELS  = [0.1, 0.25, 0.5, 1, 2, 3, 5, 7.5, 10, 15, 20, 30, 50]          # mm h⁻¹

precip_colormap(levels = ACCUM_LEVELS) = cgrad(PRECIP_COLORS[1:length(levels)-1]; categorical = true)

"Bin index k (levels[k] ≤ p < levels[k+1]); NaN below levels[1] (transparent); length(levels) above (highclip)."
precip_bins(P, levels = ACCUM_LEVELS) =
    map(p -> !isfinite(p) || p < levels[1] ? NaN : Float64(searchsortedlast(levels, p)), P)

function precip_heatmap!(ax, λ, φ, P; levels = ACCUM_LEVELS, kw...)
    B = P isa Observable ? lift(x -> precip_bins(x, levels), P) : precip_bins(P, levels)
    nb = length(levels) - 1
    return heatmap!(ax, λ, φ, B; colormap = precip_colormap(levels), colorrange = (0.5, nb + 0.5),
                    highclip = PRECIP_HIGH, nan_color = :transparent, kw...)
end

level_label(x) = isinteger(x) ? string(Int(x)) : string(x)

function precip_colorbar!(pos; levels = ACCUM_LEVELS, label = "mm", kw...)
    nb = length(levels) - 1
    return Colorbar(pos; colormap = precip_colormap(levels), limits = (0.5, nb + 0.5), highclip = PRECIP_HIGH,
                    ticks = (0.5:1:nb + 0.5, level_label.(levels)), label, kw...)
end

const _GEO_LINES = Ref{Any}(nothing)
function geo_line_data()
    if isnothing(_GEO_LINES[])
        coast = natural_earth_lines("coastline")
        states = try
            natural_earth_lines("admin_1_states_provinces_lines")
        catch err
            @warn "state/province lines unavailable" err
            (Float64[], Float64[])
        end
        _GEO_LINES[] = (coast, states)
    end
    return _GEO_LINES[]
end

function geo_lines!(ax; color = :black, coast_width = 1.4, state_width = 0.9)
    (cλ, cφ), (sλ, sφ) = geo_line_data()
    isempty(sλ) || lines!(ax, sλ, sφ; color, linewidth = state_width)
    lines!(ax, cλ, cφ; color, linewidth = coast_width)
    return nothing
end

# Region outlines that stay visible on every palette colour: a white halo under a black line.
function outline!(ax, xs, ys; linewidth = 1.8, linestyle = :solid)
    lines!(ax, xs, ys; color = :white, linewidth = linewidth + 2)
    lines!(ax, xs, ys; color = :black, linewidth, linestyle)
    return nothing
end
