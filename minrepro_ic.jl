# Minimal reproducer for the INITIAL-CONDITION path of a nested model under Reactant, with a
# `PrescribedAtmosphere` carrying `source = dataset`.
#
# This is the blocker that matters for ingesting real ERA5: `reactant_downscale.jl` writes its
# prognostics from closed-form functions ONLY because the normal route does not work. With real data
# the IC must be interpolated from the parent, i.e. `initialize_nested_child!`, whose body is
#
#   to_child(fts) = (field = CenterField(child_grid); interpolate!(field, fts[Time(t₀)]); field)
#   ρᵈ, ρθ, ρqᵛ, ρu, ρv = to_child.(…)          # parent → child interpolation
#   ρ   = Field(ρᵈ + ρqᵛ)                        # AbstractOperation → compute!
#   qᵗ  = Field(ρqᵛ / ρ);  θˡⁱ = Field(ρθ / ρᵈ)  # AbstractOperation → compute!
#   u   = Field(ρu / ρᵈ);  v   = Field(ρv / ρᵈ)
#   set!(nested_model; ρ, u, v, qᵗ, θˡⁱ, compute_reference_state = true)
#
# Two independent suspects live in there, so this runs them as a LADDER rather than all at once —
# the alloca investigation showed how easily one assumes which rung fails.
#
#   AR_IC_STAGE=abstractop  (default)  `Field(a + b)` on the child grid. No nest, no parent, seconds
#                                      to run. This is the documented caveat: an `AbstractOperation`
#                                      `compute!` on a `LatitudeLongitudeGrid` raises
#                                      `InvalidIRError: unsupported call to jl_f_throw_methoderror`
#                                      (a `RectilinearGrid` was said to be fine — `AR_RECTILINEAR=1`
#                                      tests that claim, and it turns out to be a false negative; see
#                                      DIAGNOSIS below).
#   AR_IC_STAGE=interpolate            `interpolate!(child_field, parent_fts[Time(t₀)])` only.
#                                      Isolates parent→child interpolation from field algebra.
#   AR_IC_STAGE=nest                   Build `PrescribedAtmosphere(source = dataset)` and the nest,
#                                      and stop. Isolates construction (and whether carrying the
#                                      dataset descriptor is itself a problem) from the IC.
#   AR_IC_STAGE=full                   The whole `initialize_nested_child!` sequence.
#   AR_IC_STAGE=broadcast              The FIX: the same field algebra written as a broadcast over
#                                      `interior`, which is what `initialize_nested_child!` now does.
#
# MEASURED (CPU backend, login node, Reactant 0.2.279 + custom Reactant_jll):
#
#   AR_IC_STAGE=abstractop                       FAILED  57.8 s  InvalidIRError / jl_f_throw_methoderror
#   AR_IC_STAGE=abstractop AR_TERRAIN=0          FAILED  52.8 s  same
#   AR_IC_STAGE=abstractop AR_RECTILINEAR=1      OK      67.1 s
#
#   AR_IC_STAGE=full  (source = ERA5HourlyPressureLevels(), terrain-following child):
#       build nest        OK              ← carrying the dataset descriptor is fine at CONSTRUCTION;
#                                           it only bites inside `@trace` (NoFieldMatchError), which
#                                           is why `reactant_downscale.jl` omits `source`
#       to_child          OK    16.7 s    ← parent → child `interpolate!` WORKS
#       Field(ρᵈ + ρqᵛ)   FAILED 6.1 s    ← the one rung that fails
#
# So of everything `initialize_nested_child!` does, only the field algebra is blocked. The
# interpolation from the ERA5-shaped parent onto the child is already fine.
#
# DIAGNOSIS (2026-08-17). The earlier reading here — "the fault is in the lat-lon grid itself, its
# metric operators, reached through the `BinaryOperation`" — is WRONG, and the `RectilinearGrid`
# control was a false negative. `Field(a + b)` never touches a metric: for two `CenterField`s the
# interpolators are `identity`, so the kernel body is `data[i, j, k] = a[i, j, k] + b[i, j, k]` and
# the grid is passed but never indexed. What matters is not lat-lon vs rectilinear, but whether the
# grid carries MATERIALIZED coordinate arrays:
#
#   Field(a+b) on RectilinearGrid, x/y/z given as (0, L) tuples    OK      63.2 s
#   Field(a+b) on RectilinearGrid, x/y/z given as explicit vectors FAILED  11.8 s
#   Field(a+b) on LatitudeLongitudeGrid                            FAILED   7.0 s
#   Field(a+b) on LatitudeLongitudeGrid, precompute_metrics=false  FAILED   5.5 s
#
# A regularly-spaced `RectilinearGrid` keeps its coordinates as `StepRangeLen`, so under Reactant
# there is nothing in the grid to trace and it is handed to the kernel unchanged. A
# `LatitudeLongitudeGrid` ALWAYS materializes its coordinates (`on_architecture` turns them into
# `ConcretePJRTArray`s — the Oceananigans Reactant extension says as much in its `==` override), and
# a stretched `RectilinearGrid` does too. That is the whole difference; the `AR_RECTILINEAR=1` rung
# passed only because it happened to use the regularly-spaced form.
#
# MECHANISM. `compute!` launches Oceananigans' `_compute!` KernelAbstractions kernel, and Reactant
# routes KA kernels through `CUDA.@cuda`/GPUCompiler (hence the `using CUDA` on any backend). At the
# `@jit` boundary the kernel arguments are traced, and tracing the grid CORRUPTS ITS `FT` TYPE
# PARAMETER. That is measurable on its own, with no kernel, no `compute!` and no CUDA compilation —
# `Reactant.traced_type_inner` on the bare grid TYPE is enough:
#
#   tt(T) = Reactant.traced_type_inner(T, Dict{Type,Type}(), Reactant.ConcreteToTraced,
#                                      Union{}, Val(1), Val(:PJRT))
#
#   tt(typeof(latitude_longitude_grid)).parameters[1]  ⇒  Reactant.TracedRNumber{Float32}   # was Float32
#   tt(typeof(regular_rectilinear_grid))               ⇒  returned unchanged
#
# Why only when coordinates are materialized: `traced_type_inner` first walks the FIELD types, and
# returns `T` untouched if none of them changed (Reactant.jl src/Tracing.jl, the `if !changed` early
# return). A regular `RectilinearGrid` has nothing traceable in it, so it takes that early return. As
# soon as one field changes (`ConcretePJRTArray` → `TracedRArray`), it instead re-derives ALL the type
# parameters through `apply_type_with_promotion`, and `FT` comes back promoted to
# `TracedRNumber{Float32}`. The four fields declared `::FT` (`Lx`, `Ly`, `Lz`, `radius`) follow it.
# Note this is NOT the `track_numbers` option: `track_numbers` defaults to `Union{}`, and the probe
# above passes `Union{}` explicitly and still reproduces. The kernel is then compiled for
#
#   LatitudeLongitudeGrid{CuTracedRNumber{Float32, 1}, …}
#   BinaryOperation{Center, Center, Center, typeof(+), …, Reactant.TracedRNumber{Float32}}
#                                                          ↑ the operation's eltype parameter
#
# i.e. host-side traced types with no device methods. Those two argument types are MEASURED (they are
# printed verbatim in the `InvalidIRError` header); that GPUCompiler then fails to devirtualize *on
# them* is inference — the error itself only localizes to the kernel body, since `always_inline` is
# on and the whole body collapses to `gpu__compute!` at `./none:0`.
#
# The stretched-`RectilinearGrid` rung shows the same corruption one step earlier and more legibly:
# there it does not even reach the kernel, it fails in `Adapt.adapt_structure` with
#
#   MethodError: no method matching (RectilinearGrid{Bounded, Bounded, Bounded, Nothing})(::Nothing,
#       ::Int64, …, ::CuTracedRNumber{Float32, 1}, ::CuTracedRNumber{Float32, 1}, …)
#
# — the grid's own inner constructor rejecting the traced `Lx, Ly, Lz`. Same corruption, caught by
# the constructor instead of by the compiler.
#
# FIX. Do not route the field algebra through a KA kernel at all. Broadcasting over `interior`
# stays inside Reactant's own array operations, never builds a kernel, and needs no grid:
#
#   interior(c) .= interior(a) .+ interior(b)      OK   0.8 s
#   parent(c)   .= parent(a)   .+ parent(b)        OK   0.8 s
#   c .= a + b                                     FAILED         ← NOT a fix: Oceananigans routes
#                                                                   broadcast over an AbstractOperation
#                                                                   through its own KA kernel
#                                                                   (`gpu__broadcast_kernel!`)
#
# `initialize_nested_child!` (NumericalEarth.jl, ext/NumericalEarthBreezeExt/breeze_nested_atmosphere.jl)
# now uses the `interior` broadcast; `AR_IC_STAGE=broadcast` is the standing regression test for it.
#
# WHERE THE LADDER STANDS AFTER THAT FIX (AR_IC_STAGE=full, terrain-following child, CPU backend):
#
#       build nest        OK
#       to_child          OK      14.1 s
#       ρ = ρᵈ+ρqᵛ        OK       0.3 s   ← was FAILED 6.1 s; this is the fix
#       set!(nest;…)      FAILED 167.0 s   ← NEW rung, SAME root cause, inside Breeze
#
# The IC's own field algebra is no longer the blocker. `set!` now fails in
# `Oceananigans.Fields.gpu__broadcast_kernel!` over a `BinaryOperation{Center, Center, Center,
# typeof(*), …}` carrying the same corrupted `LatitudeLongitudeGrid{CuTracedRNumber{Float32, 1}, …}`.
# That operation is built inside BREEZE, not here — `Breeze/src/AtmosphereModels/set_atmosphere_model.jl`
# does `set!(model.moisture_density, ρ * qᵛᵉ)` (line 262), and the same `set!(dst, ρ * …)` shape recurs
# at lines 45, 256, 296, plus `PotentialTemperatureFormulations/potential_temperature_tendency.jl:119`
# and `StaticEnergyFormulations/static_energy_tendency.jl:85`.
#
# Rewriting those as `interior` broadcasts is NOT a general fix: line 45 is `set!(ϕ, ρ * u)`, a
# Center density times a Face velocity, so it genuinely needs the interpolation that the
# `AbstractOperation` provides and that a bare `interior` broadcast would silently drop. The general
# fix has to be the type-parameter corruption itself, upstream — see MECHANISM. One fix there
# unblocks `Field(a + b)`, Breeze's `set!`, and every other operation on a lat-lon grid at once,
# without rewriting any physics.
#
# The failing kernel is `Oceananigans.AbstractOperations.gpu__compute!` over a
# `BinaryOperation{Center, Center, Center, typeof(+), …}` — i.e. `Field(a + b)` is enough. No parent,
# no nest, no dataset required, which makes this a ~1 minute reproducer for the blocker.
#
#   AR_SOURCE=1|0        include `source = dataset` in the PrescribedAtmosphere (default 1, as asked)
#   AR_TERRAIN=1|0       terrain-following child vertical, as the real model (default 1)
#   AR_RECTILINEAR=1|0   use a regularly-spaced RectilinearGrid for the `abstractop` stage. It passes,
#                        but NOT because it is rectilinear — because regular spacing keeps the
#                        coordinates as `StepRangeLen` instead of materializing them (see DIAGNOSIS)
#   AR_BACKEND=cpu|gpu   default cpu, so it runs on a login node with no queue
#
#   OMP_NUM_THREADS=1 julia --project minrepro_ic.jl

using NumericalEarth
using Oceananigans
using Breeze
using CloudMicrophysics
using Reactant
using CUDA                      # Reactant needs CUDA.jl loaded to raise KA kernels, on any backend
using Printf

using Oceananigans.Architectures: ReactantState, on_architecture
using Oceananigans.Fields: interpolate!
using Oceananigans.Units: Time
using Breeze: materialize_terrain!
using Breeze.TerrainFollowingDiscretization: TerrainFollowingVerticalDiscretization, LinearDecay
using NumericalEarth.NestedModels: nested_atmosphere_model

Reactant.set_default_backend(get(ENV, "AR_BACKEND", "cpu"))
Oceananigans.defaults.FloatType = Float32

stage       = Symbol(get(ENV, "AR_IC_STAGE", "abstractop"))
with_source = get(ENV, "AR_SOURCE", "1") == "1"
terrain     = get(ENV, "AR_TERRAIN", "1") == "1"
rectilinear = get(ENV, "AR_RECTILINEAR", "0") == "1"

arch = ReactantState()
breeze_ext = Base.get_extension(NumericalEarth, :NumericalEarthBreezeExt)

## `on_architecture` for a `LatitudeLongitudeGrid` walks the grid through the Reactant extension's
## private `_to_reactant`, which knows arrays and the STATIC vertical only.
const RA = Base.get_extension(Oceananigans, :OceananigansReactantExt).Architectures

RA._to_reactant(f::LinearDecay) =
    LinearDecay(f.z_top, RA._to_reactant(f.h), RA._to_reactant(f.∂x_h), RA._to_reactant(f.∂y_h))

RA._to_reactant(z::TerrainFollowingVerticalDiscretization) =
    TerrainFollowingVerticalDiscretization(RA._to_reactant(z.cᵃᵃᶠ), RA._to_reactant(z.cᵃᵃᶜ),
                                           RA._to_reactant(z.Δᵃᵃᶠ), RA._to_reactant(z.Δᵃᵃᶜ),
                                           RA._to_reactant(z.formulation))

const CHILD_SIZE = (16, 8, 12)
const Z_TOP = 12_000

function child_grid()
    rectilinear && return RectilinearGrid(arch; x = (0, 1e6), y = (0, 5e5), z = (0, Z_TOP),
                                          size = CHILD_SIZE, halo = (3, 3, 3),
                                          topology = (Bounded, Bounded, Bounded))
    terrain || return LatitudeLongitudeGrid(arch; longitude = (-10, 10), latitude = (-5, 5),
                                            z = (0, Z_TOP), size = CHILD_SIZE, halo = (3, 3, 3),
                                            topology = (Bounded, Bounded, Bounded))

    host = LatitudeLongitudeGrid(CPU(); longitude = (-10, 10), latitude = (-5, 5),
                                 z = TerrainFollowingVerticalDiscretization((0, Z_TOP)),
                                 size = CHILD_SIZE, halo = (3, 3, 3),
                                 topology = (Bounded, Bounded, Bounded))
    materialize_terrain!(host, (λ, φ) -> 300 * exp(-((λ / 3)^2 + (φ / 2)^2)))
    return on_architecture(arch, host)
end

## Parent must BRACKET the child horizontally (`validate_source_bracket`).
function parent_atmosphere_and_grid()
    pgrid = LatitudeLongitudeGrid(arch; longitude = (-12, 12), latitude = (-7, 7), z = (0, Z_TOP),
                                  size = (12, 7, 8), halo = (3, 3, 3),
                                  topology = (Bounded, Bounded, Bounded))
    times = collect(range(0.0, 7200.0, length = 3))   # the exchanger's 3-level resident window

    fts(v) = (f = FieldTimeSeries{Center, Center, Center}(pgrid, times); set!(f, (λ, φ, z, t) -> v); f)

    kw = (; velocities = (u = fts(10.0), v = fts(1.0)),
            temperature = fts(280.0),
            specific_humidity = fts(0.005),
            ## `default_parent_condensates` reads these by name off the parent, so the nest cannot be
            ## built without them (`FieldError: type NamedTuple has no field qᶜˡ`).
            microphysical_variables = (qᶜˡ = fts(1.0e-4), qʳ = fts(0.0),
                                       qᶜⁱ = fts(0.0),   qˢ = fts(0.0)),
            pressure = (p = CenterField(pgrid); set!(p, (λ, φ, z) -> 101325 * exp(-z / 8500)); p),
            precipitation_flux = nothing)

    ## `source = dataset` — the ERA5 descriptor a real run carries. `AR_SOURCE=0` drops it.
    atmos = with_source ?
        PrescribedAtmosphere(pgrid, times; source = ERA5HourlyPressureLevels(), kw...) :
        PrescribedAtmosphere(pgrid, times; kw...)

    return atmos, pgrid
end

@info "reproducer" stage with_source terrain rectilinear backend=get(ENV, "AR_BACKEND", "cpu")

## Returns `(ok, value)` so a rung can hand its result to the next one without top-level
## `local`/`global` gymnastics (which is what made the first `full` run die with an UndefVarError
## inside the closure rather than in Reactant).
function attempt(label, f)
    start = time_ns()
    try
        v = f()
        @info @sprintf("%-12s OK in %.1f s", label, 1e-9 * (time_ns() - start))
        return (true, v)
    catch err
        msg = sprint(showerror, err)
        kind = occursin("jl_f_throw_methoderror", msg) ? "InvalidIRError / jl_f_throw_methoderror" :
               occursin("NoFieldMatchError", msg) ? "NoFieldMatchError" :
               occursin("Scalar indexing", msg) ? "Scalar indexing is disallowed" :
               string(typeof(err))
        @info @sprintf("%-12s FAILED in %.1f s — %s", label, 1e-9 * (time_ns() - start), kind)
        println(first(msg, 2000))
        return (false, nothing)
    end
end

if stage === :abstractop
    ## The narrowest form of the documented caveat: no parent, no nest, no dataset — just field
    ## algebra on the child grid, which is what `Field(ρᵈ + ρqᵛ)` reduces to.
    grid = child_grid()
    a = CenterField(grid); b = CenterField(grid)
    attempt("Field(a+b)", () -> (c = Field(a + b); Oceananigans.Fields.compute!(c); c))

elseif stage === :broadcast
    ## The fix, in the same narrow form: no kernel, no grid, just Reactant array broadcasting.
    grid = child_grid()
    a = CenterField(grid); b = CenterField(grid)
    attempt("interior .+", () -> (c = CenterField(grid); interior(c) .= interior(a) .+ interior(b); c))
    attempt("interior ./", () -> (c = CenterField(grid); interior(c) .= interior(a) ./ interior(b); c))

elseif stage === :interpolate
    cgrid = child_grid()
    atmos, _ = parent_atmosphere_and_grid()
    src = atmos.temperature
    t₀ = first(src.times)
    attempt("interpolate!", () -> (f = CenterField(cgrid); interpolate!(f, src[Time(t₀)]); f))

elseif stage === :nest
    cgrid = child_grid()
    atmos, _ = parent_atmosphere_and_grid()
    attempt("build nest", () -> Reactant.@allowscalar nested_atmosphere_model(atmos, cgrid;
                terrain = nothing, relaxation_rate = 1/300, relaxation_width = 3,
                surface_pressure = 101325.0,
                microphysics = breeze_ext.default_nested_microphysics(),
                momentum_advection = WENO(order = 5)))

elseif stage === :full
    cgrid = child_grid()
    atmos, _ = parent_atmosphere_and_grid()
    nest = Reactant.@allowscalar nested_atmosphere_model(atmos, cgrid;
                terrain = nothing, relaxation_rate = 1/300, relaxation_width = 3,
                surface_pressure = 101325.0,
                microphysics = breeze_ext.default_nested_microphysics(),
                momentum_advection = WENO(order = 5))
    @info "nest built"

    ## Exactly `initialize_nested_child!`'s body, step by step, so the failing rung is named.
    prognostic = nest.exchanger.prognostic
    t₀ = first(prognostic.ρᵈ.times)
    to_child(fts) = (f = CenterField(cgrid); interpolate!(f, fts[Time(t₀)]); f)

    ok, f = attempt("to_child", () -> (ρᵈ  = to_child(prognostic.ρᵈ),
                                       ρqᵛ = to_child(prognostic.ρqᵛ),
                                       ρθ  = to_child(prognostic.ρθ),
                                       ρu  = to_child(prognostic.ρu),
                                       ρv  = to_child(prognostic.ρv)))
    ok || exit(1)

    ## The field algebra, as `initialize_nested_child!` now writes it: a broadcast over `interior`
    ## rather than `Field(::AbstractOperation)`, which cannot be `compute!`d on this grid.
    binary(op, a, b) = (c = CenterField(cgrid); interior(c) .= op.(interior(a), interior(b)); c)

    ok, ρ = attempt("ρ = ρᵈ+ρqᵛ", () -> binary(+, f.ρᵈ, f.ρqᵛ))
    ok || exit(1)

    attempt("set!(nest;…)", () -> set!(nest; ρ, u = binary(/, f.ρu, f.ρᵈ), v = binary(/, f.ρv, f.ρᵈ),
                                       qᵗ = binary(/, f.ρqᵛ, ρ), θˡⁱ = binary(/, f.ρθ, f.ρᵈ),
                                       compute_reference_state = true))
else
    error("unknown AR_IC_STAGE=$stage")
end
