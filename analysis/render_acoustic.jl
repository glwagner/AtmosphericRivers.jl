# GIF of one or two reactant_downscale.jl runs from their extracted slices
# (analysis/extract_acoustic_slices.jl). One column per run; rows: IVT, vertical velocity at 2 km,
# surface density change since t = 0, and a vertical-velocity section near 47.5°N. The boundary
# acoustic signal shows up as rings of Δρ and w marching inward from the walls.
#
# Usage: julia --project=analysis/renderenv analysis/render_acoustic.jl out.gif A_slices.jld2[:label] [B_slices.jld2[:label]]
#
# `AR_ROWS` (comma list, default ivt,w_2km,drho_sfc,w_sec) selects and orders the rows.

using JLD2
using CairoMakie
using Printf
using Statistics

outfile = ARGS[1]
specs = ARGS[2:end]
isempty(specs) && error("give at least one slices file")
length(specs) ≤ 2 || error("at most two runs side by side")

struct Run
    label::String
    λ; φ; z; times; nframes::Int; jsec::Int
    frames::Vector{Dict{String,Any}}
end

function load_run(spec)
    path, label = occursin(':', spec) ? Tuple(split(spec, ':'; limit = 2)) : (spec, replace(basename(spec), r"\.jld2$" => ""))
    jldopen(String(path), "r") do g
        iters = g["iters"]
        frames = [Dict{String,Any}(k => g["frames/$n/$k"] for k in keys(g["frames/$n"])) for n in eachindex(iters)]
        Run(String(label), g["lambda"], g["phi"], g["z"], g["times"], length(iters), g["jsec"], frames)
    end
end

runs = load_run.(specs)
nframes = minimum(r -> r.nframes, runs)

# Shared color ranges across runs so the columns are comparable.
sym(v) = (m = max(v, 1e-9); (-m, m))
qmax(key, p) = maximum(r -> maximum(f -> quantile(vec(abs.(f[key])), p), r.frames[1:nframes]), runs)

row_defs = Dict(
    "ivt"      => (title = "IVT (kg m⁻¹ s⁻¹)",                       cmap = :dense,   range = (0, 1200),                            kind = :map),
    "w_2km"    => (title = "w at 2 km (m s⁻¹)",                       cmap = :balance, range = sym(min(qmax("w_2km", 0.995), 5.0)),  kind = :map),
    "drho_sfc" => (title = "Δρᵈ at the surface since t=0 (kg m⁻³)",   cmap = :balance, range = sym(qmax("drho_sfc", 0.995)),         kind = :map),
    "speed_sfc"=> (title = "|U| at the surface (m s⁻¹)",              cmap = :speed,   range = (0, 40),                              kind = :map),
    "w_sec"    => (title = @sprintf("w section at %.1f°N (m s⁻¹)", runs[1].φ[runs[1].jsec]), cmap = :balance, range = sym(min(qmax("w_sec", 0.995), 5.0)), kind = :sec),
)
row_keys = split(get(ENV, "AR_ROWS", "ivt,w_2km,drho_sfc,w_sec"), ',')
rows = [(key = String(k), row_defs[String(k)]...) for k in row_keys]

ncol = length(runs)
fig = Figure(size = (720 * ncol, 330 * length(rows) + 60), fontsize = 14)
n = Observable(1)
Label(fig[0, 1:2ncol],
      @lift(@sprintf("%s — t = %.2f h", join((r.label for r in runs), "  vs  "), runs[1].times[$n] / 3600)),
      fontsize = 20, tellwidth = false)

for (r, row) in enumerate(rows), (c, run) in enumerate(runs)
    col = 2c - 1
    frame = @lift(run.frames[min($n, run.nframes)][row.key])
    title = ncol == 1 ? row.title : "$(run.label): $(row.title)"
    if row.kind === :map
        ax = Axis(fig[r, col]; title, aspect = DataAspect(), xlabel = "longitude", ylabel = "latitude")
        hm = heatmap!(ax, run.λ, run.φ, frame; colormap = row.cmap, colorrange = row.range)
        hlines!(ax, [run.φ[run.jsec]]; color = :black, linestyle = :dash, linewidth = 0.8)
    else
        ax = Axis(fig[r, col]; title, xlabel = "longitude", ylabel = "z (m, reference)")
        hm = heatmap!(ax, run.λ, run.z, frame; colormap = row.cmap, colorrange = row.range)
    end
    Colorbar(fig[r, col + 1], hm)
end

record(fig, outfile, 1:nframes; framerate = 6) do i
    n[] = i
end

## Stills of the first stepped frame and the last frame, for a quick look without playing the gif.
for (i, tag) in ((min(2, nframes), "early"), (nframes, "final"))
    n[] = i
    save(replace(outfile, r"\.gif$" => "_$(tag).png"), fig)
end
println("RENDER_OK $outfile frames=$nframes runs=$ncol")
