# Census of halo fills in one forward step: who calls `fill_halo_regions!`, on which fields, with
# which boundary conditions. Needs an Oceananigans that defines `BoundaryConditions.HALO_CENSUS`
# (the opt/halo-fusion development branch).
#
#   AR_* production env … julia --project=<env> perf/halo_census.jl
#
# Writes <AR_PROF_OUT>_halo_census.tsv: one row per call with the field's data pointer, location,
# BC types per side and the first few caller frames outside Oceananigans' halo machinery.

include(joinpath(@__DIR__, "..", "reactant_downscale.jl"))

using CUDA
using Printf

const BC = Oceananigans.BoundaryConditions
out = get(ENV, "AR_PROF_OUT", "perf/data/halo")
mkpath(dirname(out))

step_for!(model, Δt, 3)          # warm
CUDA.synchronize()

ptrint(p) = try UInt(p) catch; reinterpret(UInt, p) end

## Count the per-field fills of the unfused path (the baseline the fusion is measured against)
fused_flag = isdefined(Oceananigans.Fields, :FUSED_HALO_FILLING) ? Oceananigans.Fields.FUSED_HALO_FILLING : Ref(false)
fused_flag[] = parse(Bool, get(ENV, "AR_FUSED_HALOS", "false"))
@info "census with FUSED_HALO_FILLING = $(fused_flag[])"

census = []
BC.HALO_CENSUS[] = census
step_for!(model, Δt, 1)
CUDA.synchronize()
BC.HALO_CENSUS[] = nothing

skip(fr) = begin
    f = string(fr.file)
    occursin("BoundaryConditions/fill_halo", f) || occursin("Fields/field.jl", f) ||
        occursin("Fields/field_tuples.jl", f) || occursin("essentials.jl", f) || fr.func === :fill_halo_regions!
end

callers(st) = begin
    frs = [fr for fr in st if !skip(fr)]
    join([string(fr.func, "@", basename(string(fr.file)), ":", fr.line) for fr in frs[1:min(6, end)]], " < ")
end

short(x) = replace(string(x), r"\{.*" => "")
function bcdesc(bc)
    bc isa Type || return "?"
    bc <: Nothing && return "nothing"
    if bc <: Oceananigans.BoundaryConditions.BoundaryCondition
        C, Tc = bc.parameters
        return string(C) * "(" * short(Tc) * ")"
    end
    return short(bc)
end
bcsides(T) = begin
    if T <: NamedTuple && :ordered_bcs in fieldnames(T)
        O = fieldtype(T, :ordered_bcs)
        out = String[]
        for (n, P) in zip(fieldnames(O), fieldtypes(O))
            push!(out, string(n, "=(", join(map(bcdesc, fieldtypes(P)), " | "), ")"))
        end
        return join(out, " ")
    end
    try
        ps = T.parameters
        join(["$(n)=$(bcdesc(ps[i]))" for (i, n) in enumerate((:W, :E, :S, :N, :B, :T))], ",")
    catch
        string(T)
    end
end

open(out * "_halo_census.tsv", "w") do io
    println(io, "n\tptr\tloc\tsize\tbcs\tcallers")
    for (n, (p, T, loc, sz, st)) in enumerate(census)
        println(io, n, '\t', ptrint(p), '\t', loc, '\t', join(sz, "x"), '\t', bcsides(T), '\t', callers(st))
    end
end
@info "halo census: $(length(census)) fill_halo_regions! calls in one step → $(out)_halo_census.tsv"
