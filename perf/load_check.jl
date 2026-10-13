# Load the production package stack and report the load time and which depot every cache came from
# (portable-pkgimage check, PROFILE_REPORT §9 #10). Any "Precompiling" output means a recompile.
t = @elapsed @eval begin
    using NumericalEarth, Oceananigans, Breeze, CloudMicrophysics, RRTMGP, Reactant, CUDA
end
println("LOAD_SECONDS ", round(t, digits = 1), " on ", Sys.CPU_NAME)
depots = Dict{String, Int}()
for (id, origin) in Base.pkgorigins
    p = origin.cachepath
    p === nothing && continue
    d = first(filter(d -> startswith(p, d), DEPOT_PATH), 1)
    k = isempty(d) ? "other" : d[1]
    depots[k] = get(depots, k, 0) + 1
end
println("CACHE_DEPOTS ", depots)
