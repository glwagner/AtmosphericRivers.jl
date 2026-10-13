# Compare two kernel_audit state files: max |Δ| and max |Δ| / max |ref| per prognostic field.
#   julia --project=<env with JLD2> perf/kernel_compare_state.jl ref_state.jld2 test_state.jld2
using Printf
const JLD2 = Base.require(Base.PkgId(Base.UUID("033835bb-8acc-5ee8-8aae-3f567f8a3819"), "JLD2"))
ref, test = ARGS
JLD2.jldopen(ref) do a
    JLD2.jldopen(test) do b
        @printf("iterations: %d vs %d\n", a["iteration"], b["iteration"])
        for name in keys(a["state"])
            x = a["state/$name"]; y = b["state/$name"]
            d = maximum(abs, x .- y); s = maximum(abs, x)
            nb = count(!isfinite, y)
            @printf("%-6s max|ref| %.4e  max|Δ| %.3e  rel %.3e  rms rel %.3e  nonfinite %d\n", name, s, d, d / s,
                    sqrt(sum(abs2, x .- y) / length(x)) / sqrt(sum(abs2, x) / length(x)), nb)
        end
    end
end
