# Stacked bars of GPU time per step by component, one bar per (configuration, GPU), from the table
# written by `python3 perf/analyze_profile.py --table perf/data/components.tsv ...`.
#
#   julia --project=sensitivity perf/plot_profile.jl perf/data/components.tsv perf/profile_components.png

using CairoMakie
using DelimitedFiles

table_path = get(ARGS, 1, "perf/data/components.tsv")
figure_path = get(ARGS, 2, "perf/profile_components.png")

raw = readdlm(table_path, '\t', String)
groups = raw[1, 2:end]
labels = raw[2:end, 1]
values = parse.(Float64, raw[2:end, 2:end])

# Bars ordered by GPU, then configuration
pretty(l) = replace(l, "none-default" => "no closure", "tke-default-prs" => "TKE + PRs",
                       "tke-default" => "TKE default", "tke-catke" => "TKE catke",
                       "_A100-SXM4-80GB" => "\nA100-80GB", "_A100-SXM4-40GB" => "\nA100-40GB", "_H100" => "\nH100")
order = sortperm(labels; by = l -> (occursin("H100", l) ? 0 : 1,
                                    findfirst(c -> startswith(l, c), ["none-default", "tke-default_", "tke-catke", "tke-default-prs"])))
labels, values = labels[order], values[order, :]

# Validated categorical palette (dataviz skill reference instance), fixed order; GPU idle in neutral gray.
palette = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
colors = vcat(palette[1:length(groups) - 1], ["#b9b8b0"])

fig = Figure(size = (1100, 620), fontsize = 14)
ax = Axis(fig[1, 1]; ylabel = "ms per step (Δt = 10 s, 12 km, 2.62 M cells)",
          xticks = (1:length(labels), pretty.(labels)), xticklabelsize = 12,
          title = "Forward step, 12 km, Δt = 10 s: GPU time by component plus GPU idle (Breeze #975 TKE; PRs = Oceananigans #6212 + #6209)",
          titlealign = :left, ygridcolor = (:black, 0.08), xgridvisible = false,
          topspinevisible = false, rightspinevisible = false)

n, m = size(values)
for i in 1:n
    bottom = 0.0
    for j in 1:m
        v = values[i, j]
        v > 0 || continue
        barplot!(ax, [i], [v]; offset = bottom, color = colors[j], width = 0.7,
                 strokecolor = :white, strokewidth = 1.5)
        bottom += v
    end
    text!(ax, i, bottom; text = string(round(bottom; digits = 1)), align = (:center, :bottom),
          offset = (0, 4), fontsize = 12, color = :gray20)
end
ylims!(ax, 0, 1.12 * maximum(sum(values; dims = 2)))
Legend(fig[1, 2], [PolyElement(color = c) for c in colors], groups; framevisible = false,
       labelsize = 12, rowgap = 4)
save(figure_path, fig; px_per_unit = 2)
@info "wrote $figure_path"
