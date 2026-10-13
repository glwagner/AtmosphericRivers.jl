# Compare two state dumps of perf/opt_column_bench.jl (agent OPT-COLUMN): bitwise equality and the
# largest relative difference per field.
#
#   julia --project=sensitivity perf/opt_column_compare.jl perf/data/optcol_base1_A100_state.jld2 perf/data/optcol_opt1_A100_state.jld2

using JLD2
using Printf

a, b = ARGS
ja, jb = jldopen(a), jldopen(b)
@info "iterations: $(ja["iteration"]) vs $(jb["iteration"])"
for group in ("prognostic", "closure")
    haskey(ja, group) || continue
    for name in keys(ja[group])
        haskey(jb, group) && haskey(jb[group], name) || (println("$group/$name missing in b"); continue)
        x = ja["$group/$name"]; y = jb["$group/$name"]
        identical = isequal(x, y)
        scale = maximum(abs, filter(isfinite, x); init = 0.0)
        d = maximum(abs, filter(isfinite, x .- y); init = 0.0)
        @printf("%-11s %-8s identical=%-5s max|Δ| = %.3e  (max|x| = %.3e, rel %.2e)  non-finite %d / %d\n",
                group, name, identical, d, scale, scale > 0 ? d / scale : 0.0,
                count(!isfinite, x), count(!isfinite, y))
    end
end
close(ja); close(jb)
