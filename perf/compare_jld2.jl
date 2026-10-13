# Compare two JLD2 output files key by key (async vs synchronous snapshot output, AR_ASYNC_OUTPUT).
#
#   julia --project perf/compare_jld2.jl a.jld2 b.jld2
#
# Prints the number of keys, any key present in only one file, and any key whose value differs
# (bitwise, NaN-aware). Exit status 1 if anything differs. A run is not bit-reproducible on the GPU
# in general, so differing snapshot VALUES after the first step point at nondeterminism, not at the
# writer; the key set, order, shapes and element types are the writer's responsibility.
using JLD2

function all_keys(file, prefix = "")
    out = String[]
    for k in keys(prefix == "" ? file : file[prefix])
        path = prefix == "" ? k : prefix * "/" * k
        obj = file[path]
        obj isa JLD2.Group ? append!(out, all_keys(file, path)) : push!(out, path)
    end
    return out
end

same(a, b) = typeof(a) == typeof(b) && (a isa AbstractArray ?
    size(a) == size(b) && all(x -> isequal(x...), zip(a, b)) : isequal(a, b))

a, b = ARGS
ka, kb = jldopen(f -> all_keys(f), a), jldopen(f -> all_keys(f), b)
println("keys: ", length(ka), " vs ", length(kb), "; same order: ", ka == kb)
onlya, onlyb = setdiff(ka, kb), setdiff(kb, ka)
isempty(onlya) || println("only in A: ", first(onlya, 10))
isempty(onlyb) || println("only in B: ", first(onlyb, 10))
ndiff = 0; ntypes = 0
jldopen(a) do fa
    jldopen(b) do fb
        for k in intersect(ka, kb)
            x, y = fa[k], fb[k]
            if typeof(x) != typeof(y) || (x isa AbstractArray && size(x) != size(y))
                global ntypes += 1
                ntypes ≤ 5 && println("type/shape differs: ", k, " ", typeof(x), size(x), " vs ", typeof(y), size(y))
            elseif !same(x, y)
                global ndiff += 1
                ndiff ≤ 5 && println("value differs: ", k)
            end
        end
    end
end
println("compared ", length(intersect(ka, kb)), " keys: ", ntypes, " type/shape differences, ", ndiff, " value differences")
println(filesize(a), " vs ", filesize(b), " bytes")
exit(isempty(onlya) && isempty(onlyb) && ntypes == 0 && ndiff == 0 ? 0 : 1)
