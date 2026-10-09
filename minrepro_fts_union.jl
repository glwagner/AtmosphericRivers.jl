# # `FieldTimeSeries` time interpolation returns a `Union{Float32, Float64}`
#
# A `Float32` `FieldTimeSeries` with `Float64` `times` — which is what every ERA5-driven
# `PrescribedAtmosphere` is — interpolates in time through
# (`Oceananigans/src/OutputReaders/field_time_series_indexing.jl`, TWO sites:
# `interpolating_getindex` and the `FractionalIndices` method of `Fields.interpolate`):
#
#     ψ̃ = ψ₂ * ñ + ψ₁ * (1 - ñ)
#     return ifelse(n₁ == n₂, ψ₁, ψ̃)      # "don't interpolate if n₁ == n₂"
#
# `ψ₁, ψ₂` are the field's `Float32` samples; `ñ`, the fractional time index, is built from
# `fts.times :: Vector{Float64}`. So `ψ̃ :: Float64` while `ψ₁ :: Float32`, the two branches of the
# `ifelse` have different types, and the expression infers as `Union{Float32, Float64}`.
#
# On the CPU that is a type instability and nothing worse. Under Reactant it is fatal to reverse-mode
# AD. Julia represents such a union as a 64-bit payload plus a type tag, and that survives all the way
# into StableHLO — one 64-bit slot holding either an f32 or an f64:
#
#     %1937 = stablehlo.compare NE, %1599, %1600, SIGNED : (tensor<i64>, tensor<i64>) -> tensor<i1>
#     %1965 = stablehlo.select %1937, <low half of the f64>,  <bits of the f32> : i32
#     %1966 = stablehlo.select %1937, <high half of the f64>, 0                 : i32
#     %1970 = stablehlo.shift_left %1969, 32
#     %1972 = stablehlo.add %1970, %1971
#     %1973 = stablehlo.bitcast_convert %1972 : i64 -> f64
#
# `%1937` is the type tag: it is `n₁ != n₂`, a comparison of two scalar `Int64` time indices, uniform
# over the grid. The FORWARD pass compiles this fine — it is just integer shuffling. Enzyme cannot
# transpose it:
#
#     error: could not compute the adjoint for this operation
#       "stablehlo.bitcast_convert" / "stablehlo.shift_left" / "stablehlo.shift_right_logical"
#
# and no general adjoint exists, because the bitcasts erase the floating-point structure. In the
# nested atmosphere model this union reaches both the Davies `Relaxation` forcing (through
# `Relaxation` → `*` → `promote`) and the `Interpolated` open boundaries (through `left_gradient` →
# `_fill_west_halo!`), so it blocks the adjoint of essentially every tendency kernel.
#
# This script needs none of that to show the defect: no Reactant, no Enzyme, no GPU, ~seconds.
#
#     julia --project -t auto minrepro_fts_union.jl            # reproduces
#     AR_FIX=1 julia --project -t auto minrepro_fts_union.jl   # widen  (value-preserving)
#     AR_FIX=2 julia --project -t auto minrepro_fts_union.jl   # narrow (also removes all f64)
#
# Fix, at both sites: give the `ifelse` two branches of the same type — either
# `ifelse(n₁ == n₂, oftype(ψ̃, ψ₁), ψ̃)` (widen; `Float32 → Float64` is exact and the interpolating
# branch was already `Float64`, so no value changes), or convert `ñ` to `typeof(ψ₁)` first (narrow;
# additionally deletes every `f64` op from these kernels, which on a T4 runs at 1/32 rate — but it
# does change the interpolation weight's precision).

using Oceananigans
using Oceananigans.OutputReaders: interpolating_getindex, Time

const OR = Oceananigans.OutputReaders
fix = parse(Int, get(ENV, "AR_FIX", "0"))

if fix != 0
    ## Upstream's body verbatim except for the branch types.
    @eval OR @inline function interpolating_getindex(fts, i, j, k, time_index)
        ñ, n₁, n₂ = interpolating_time_indices(fts.time_indexing, fts.times, time_index.time)
        @inbounds begin
            ψ₁ = getindex(fts, i, j, k, n₁)
            ψ₂ = getindex(fts, i, j, k, n₂)
        end
        ñ′ = $(fix) == 2 ? oftype(ψ₁, ñ) : ñ
        ψ̃ = ψ₂ * ñ′ + ψ₁ * (1 - ñ′)
        return $(fix) == 2 ? ifelse(n₁ == n₂, ψ₁, oftype(ψ₁, ψ̃)) :
                             ifelse(n₁ == n₂, oftype(ψ̃, ψ₁), ψ̃)
    end
    @info "AR_FIX=$fix: interpolating_getindex redefined ($(fix == 1 ? "widen" : "narrow"))"
end

Oceananigans.defaults.FloatType = Float32

grid = LatitudeLongitudeGrid(CPU(), Float32; size = (4, 4, 4),
                             longitude = (-140, -120), latitude = (40, 52), z = (0, 8000),
                             topology = (Bounded, Bounded, Bounded))

## Float64 times with Float32 data — exactly what `PrescribedAtmosphere(::ERA5…)` builds.
times = [0.0, 3600.0, 7200.0]
fts = FieldTimeSeries{Center, Center, Center}(grid, times)
for n in 1:length(times)
    set!(fts[n], (x, y, z) -> 1 + 0.001f0 * x + 0.01f0 * n)
end

infer(f, T) = isdefined(Base, :infer_return_type) ? Base.infer_return_type(f, T) :
                                                    Core.Compiler.return_type(f, T)
rt = infer(interpolating_getindex, Tuple{typeof(fts), Int, Int, Int, Time{Float64}})

@info "eltype(fts[1]) = $(eltype(fts[1])), eltype(times) = $(eltype(times))"
@info "inferred return type of interpolating_getindex = $rt"

if rt isa Union
    @warn "UNION — this is the blocker: a 64-bit slot tagged by `n₁ != n₂`, which Enzyme cannot transpose"
elseif isconcretetype(rt)
    @info "CONCRETE — the union is closed; the adjoint has ordinary float ops to work with"
else
    @warn "inference gave a non-concrete, non-Union type: $rt"
end

## Values, so a "fix" that changes the answer is visible rather than silent.
between = interpolating_getindex(fts, 2, 2, 2, Time(1800.0))
on_node = interpolating_getindex(fts, 2, 2, 2, Time(3600.0))
@info "between time levels: $between :: $(typeof(between))"
@info "on a time level:     $on_node :: $(typeof(on_node))"
