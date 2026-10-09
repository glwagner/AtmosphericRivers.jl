# # Real solar geometry under Reactant: `ApparentSolarPosition` on a traced clock
#
# `minrepro_radiation.jl` fixed the *schedule* branch — `update_radiation!` can now be traced. This
# file goes after the other half of the radiation story, the one `reactant_downscale.jl` currently
# gives up on (see its "The SOLAR POSITION cannot be `ApparentSolarPosition` under Reactant" note):
#
#     solar_position = FixedCosineZenith(cos_zenith)   # <-- a constant, no diurnal cycle, no calendar
#
# The downscale script settled for that because the calendar path looked impossible:
#
#     compute_datetime(t::Number, epoch::AbstractDateTime) = epoch + Millisecond(round(Int, 1000t))
#
# and with a traced `t` the `round(Int, …)` is `Int64(::TracedRNumber{Int64})` — a `MethodError`. The
# note concluded "a `DateTime` has no traced representation, so there is nothing to add".
#
# That conclusion is now WRONG. Reactant ships `ReactantDatesExt`, whose `ReactantDateTime{I}` is a
# `Dates.AbstractDateTime` whose millisecond field is a *traced* integer, with `Dates.dayofyear`,
# `hour`, `minute`, `second` and `+`/`-` all defined on traced values. So a wall-clock datetime CAN
# be carried through a trace; what is missing is the plumbing on the Breeze side.
#
# This file finds exactly what that plumbing is, installs it as shims, and shows real solar geometry
# — declination, equation of time, hour angle, diurnal cycle — computed inside a compiled Reactant
# executable off a traced clock.
#
#     julia --project -t auto minrepro_solar_datetime.jl
#
# ## The three gaps, and their shims
#
#   1. **Breeze's zenith math is typed `::DateTime`.** `cos_solar_zenith_angle`, `hour_angle`, and
#      `day_of_year` in `Breeze/src/CelestialMechanics/solar_zenith_angle.jl` all annotate the
#      concrete `Dates.DateTime`, so a `ReactantDateTime` does not dispatch — `MethodError`, not a
#      tracing failure. The bodies themselves only call `Dates.dayofyear/hour/minute/second` and
#      arithmetic, every one of which Reactant's Dates extension supports. Widening the annotation to
#      `AbstractDateTime` is the whole fix. **Upstream: change the annotations.**
#
#   2. **`compute_datetime` converts seconds→datetime with `Millisecond(round(Int, …))`.**
#
#      !!! warning "Half of the received diagnosis is wrong — `probe_traced_period.jl` measured it"
#          `reactant_downscale.jl` blames `round(Int, ::TracedRNumber)` for bottoming out in
#          `Int64(::TracedRNumber)`. That is NOT true of the current Reactant: `round(Int64, traced)`
#          works as-is and returns `21600000` for `t = 21600.0`. This file's own use of
#          `trunc(Int64, round(1000t))` was unnecessary defensiveness, not a workaround.
#
#          The real failure is one step later, and it is about TYPES not arithmetic:
#          `Dates.Millisecond` has a concrete `Int64` field, so it cannot hold a traced number, and
#          `DateTime + <traced period>` then tries to pour a
#          `UTInstant{ReactantMillisecond{TracedRNumber}}` into a plain `DateTime`:
#
#              MethodError: no method matching Int64(::UTInstant{ReactantMillisecond{TracedRNumber{Int64}}})
#
#      **Upstream: this belongs entirely in Reactant, not Breeze** — a `Dates.Millisecond(::TracedRNumber)`
#      constructor plus `DateTime ± <Reactant period>` promotion. With those, Breeze's
#      `compute_datetime` line compiles on a traced clock UNCHANGED.
#
#   3. **The per-column path launches a kernel with the datetime as an argument.**
#      `_update_apparent_zenith!(sw_solver, ::Nothing, grid, datetime)` passes `datetime` into a
#      `@kernel`. Whether a `ReactantDateTime` survives KA raising as a kernel argument is the one
#      genuinely uncertain question here, so it gets its own rung rather than being assumed.
#      (Answer, from rungs G and I: the STRUCT is not converted to device scalars, though a bare
#      traced integer is — and even then Base string formatting blocks the kernel. See shim 4.)
#
# ## What this actually establishes (result, not hypothesis)
#
# Rungs A–E PASS, every one of them value-checked against the host: real solar geometry — Spencer
# declination, equation of time, hour angle, and a full 24-hour diurnal cycle — computes correctly
# inside a compiled Reactant executable off a traced clock. **The calendar is not the blocker, and
# the downscale script's "there is nothing to add" note is out of date.** Both shims are small and
# both belong upstream.
#
# Rungs F–H FAIL, and they fail for a reason that has nothing to do with dates. Shim 3 below points
# `rrtmgp_context` at `CPU()`, so RRTMGP allocates its solver workspace as **host `Vector{Float64}`s**
# — and a traced value cannot be written into a host array:
#
#     MethodError: no method matching _copyto!(::Vector{Float64}, ::Broadcasted{…AbstractReactantArrayStyle…})
#
# This is exactly the failure `reactant_downscale.jl`'s shim 12 warned it might only be deferring
# ("the tables then live in HOST arrays while the traced solve wants traced ones"). Rung F is the
# concrete confirmation, and it is worth being precise about the consequence:
#
# > `FixedCosineZenith` does not dodge this blocker by being traceable. It dodges it because
# > `update_solar_zenith_angle!(sw, ::FixedCosineZenith, …)` is a **no-op** — it writes nothing, so
# > there is no traced write to fail. The production config is not "the traceable solar position"; it
# > is the one that never touches the solver arrays.
#
# So making radiation genuinely clock-driven under Reactant needs RRTMGP's workspace on Reactant
# arrays (a ClimaComms device/array-type for `ReactantState`), which is a substantially larger piece
# of work than either datetime shim. Rungs F–I exist to keep that distinction visible rather than
# letting a green A–E read as "radiation works".
#
# ## Summary of where the work actually lies
#
# | # | Blocker | Fix | Status |
# |---|---------|-----|--------|
# | 1 | `::DateTime` annotations in `CelestialMechanics` | widen to `AbstractDateTime` | **solved**, shim 1 |
# | 2 | `compute_datetime` on a traced clock | one method on `TracedRNumber` | **solved**, shim 2 |
# | 3 | KA arg conversion skips `ReactantDateTime`'s payload | `Adapt.adapt_structure` | **solved**, shim 4 |
# | 4 | RRTMGP workspace is host `Vector{Float64}` under `ReactantState` | allocate `ConcreteRArray` | **proven fixable**, rungs J/K |
# | 5 | `update_radiation!` on a real model | — | open, rung H (`StackOverflowError`) |
#
# Blockers 1 and 2 were the ones believed to make this impossible; they are one-liners. Blocker 3 is
# a missing `Adapt` method. Blocker 4 — the one that actually stops radiation today — is NOT a deep
# incompatibility either: rungs J and K put `cos_zenith` on a `ConcreteRArray` and BOTH write paths
# then work, matching host values exactly. `SwBCs` is already parametric in its array types, so
# RRTMGP itself needs no change; what is needed is for `ClimaComms.array_type` to yield
# `ConcreteRArray` under `ReactantState`, since that one function drives every RRTMGP allocation.
#
# !!! danger "Rung G is why every rung asserts on VALUES"
#     With shim 4 in place rung G COMPILES and runs — and writes nothing, because `launch!` hands
#     Reactant a traced constant copy of the host array. An earlier version of this file reported
#     that as OK. It now stamps a sentinel first and fails with "kernel compiled but wrote NOTHING".
#     Compiling is not computing, and a rung that only checks for absence of an exception will
#     happily certify a no-op.
#
# Rungs run in order and each reports independently, so a partial result is still informative.

using Reactant
using CUDA                       # Reactant's KA raising path lives in its CUDA extension
using Breeze
using Oceananigans
using Dates
using Dates: DateTime, AbstractDateTime
using Oceananigans.Architectures: ReactantState
using Oceananigans.Grids: λnode, φnode, Center
using Oceananigans.TimeSteppers: Clock
using Oceananigans.Utils: launch!
using Oceananigans.Units: kilometers
using Oceananigans.Utils: IterationInterval

## `using RRTMGP` is what loads `BreezeRRTMGPExt` and turns `RadiativeTransferModel` into a real
## solver rather than a stub — rungs F through H need it.
using RRTMGP

## `AllSkyOptics` additionally refuses to construct without NCDatasets loaded, because RRTMGP reads
## its full-spectrum lookup tables from netCDF:
##
##     ArgumentError: Full-spectrum RRTMGP all-sky radiation requires NCDatasets to be loaded
##
## NCDatasets is in this project's MANIFEST (NumericalEarth depends on it) but not in its
## `Project.toml`, so a plain `using NCDatasets` is an `ArgumentError: Package NCDatasets not found`.
## Loading it by UUID sidesteps that without editing the project files — this is a reproducer, and it
## should not be the thing that adds a direct dependency to a shared environment. If radiation with a
## real calendar graduates into `reactant_downscale.jl`, add NCDatasets there properly instead.
const NCDatasets = Base.require(Base.PkgId(Base.UUID("85f8d34a-cbdd-5861-8df4-14fed0d494ab"),
                                           "NCDatasets"))

## Everything here is a TRACING question, not a codegen one, so it needs no GPU. Default to the CPU
## backend so the reproducer runs anywhere (the project's LocalPreferences point Reactant at the GPU).
Reactant.set_default_backend(get(ENV, "AR_BACKEND", "cpu"))

const RDExt = Base.get_extension(Reactant, :ReactantDatesExt)
const RDT = RDExt.ReactantDateTime
const RMS = RDExt.ReactantMillisecond

const CM = Breeze.CelestialMechanics
const RRT = Base.get_extension(Breeze, :BreezeRRTMGPExt)

## The case `reactant_downscale.jl` actually runs: a December atmospheric river making landfall on
## the Pacific Northwest coast. Chosen deliberately over a "nice" noon case — at this UTC hour the
## domain is PRE-DAWN, so a correct implementation must return cos θ_z ≤ 0 here and swing positive
## about six hours later. A fixed zenith cannot express either.
const EPOCH = DateTime(2025, 12, 7, 12, 0, 0)
const LONGITUDE = -125.0
const LATITUDE = 47.0

## Takes the body FIRST so every rung can be written as `attempt("name") do … end`.
function attempt(f::Function, name)
    try
        result = f()
        @info "$name: OK$(result === nothing ? "" : "\n         $result")"
        return true
    catch err
        ## Generous truncation: the interesting failures here are `InvalidIRError`s whose "Reason:"
        ## lines sit well past the first few hundred characters.
        msg = sprint(showerror, err)
        @warn "$name: FAILED [$(nameof(typeof(err)))]\n$(first(msg, 4000))"
        return false
    end
end

## Host-side truth to check every traced answer against. If the trace produces a number that is not
## this number, the rung "passing" means nothing.
const HOST_COS_θZ = CM.cos_solar_zenith_angle(EPOCH, LONGITUDE, LATITUDE)

@info "reference: host cos(θ_z) at $EPOCH, ($(LONGITUDE)°E, $(LATITUDE)°N) = $(round(HOST_COS_θZ, digits=6)) " *
      "($(HOST_COS_θZ > 0 ? "sun up" : "sun below the horizon — pre-dawn, as expected for this case"))"

# ### Rung A — does Reactant's own datetime arithmetic trace at all?
#
# Before blaming Breeze, confirm the foundation: a `ReactantDateTime` built from a traced integer,
# with the accessors Breeze's zenith math actually calls. If this fails, nothing downstream matters.
a = attempt("rung A  @jit Dates.dayofyear / hour on a ReactantDateTime") do
    ms = Reactant.ConcreteRNumber(Dates.value(EPOCH))
    doy = @jit((m -> Dates.dayofyear(RDT(Dates.UTInstant(RMS(m)))))(ms))
    hr  = @jit((m -> Dates.hour(RDT(Dates.UTInstant(RMS(m)))))(ms))
    doy_h, hr_h = Dates.dayofyear(EPOCH), Dates.hour(EPOCH)
    @assert Reactant.to_number(doy) == doy_h "dayofyear $(doy) ≠ host $doy_h"
    @assert Reactant.to_number(hr) == hr_h "hour $(hr) ≠ host $hr_h"
    "dayofyear = $(Reactant.to_number(doy)), hour = $(Reactant.to_number(hr)) — both match the host"
end

# ### Rung B — Breeze's zenith math on a traced datetime, BEFORE the shim
#
# Expected to fail, and the failure mode is the diagnosis: a `MethodError` on the `::DateTime`
# annotation, NOT a tracing error. That distinction is why gap 1 is a one-line upstream change.
traced_datetime(ms) = RDT(Dates.UTInstant(RMS(ms)))

b = attempt("rung B  @jit cos_solar_zenith_angle(::ReactantDateTime, λ, φ)  [before shim]") do
    ms = Reactant.ConcreteRNumber(Dates.value(EPOCH))
    c = @jit((m -> CM.cos_solar_zenith_angle(traced_datetime(m), LONGITUDE, LATITUDE))(ms))
    "unexpectedly succeeded — Breeze may already have been widened: $(Reactant.to_number(c))"
end

# ### Shim 1 — widen the zenith math to `AbstractDateTime`
#
# Bodies copied verbatim from `Breeze/src/CelestialMechanics/solar_zenith_angle.jl`; only the type
# annotation changes. `DateTime <: AbstractDateTime`, so Breeze's own methods stay more specific and
# the host path is untouched — this adds a traced path rather than replacing anything.
CM.day_of_year(dt::AbstractDateTime) = Dates.dayofyear(dt)

function CM.hour_angle(datetime::AbstractDateTime, longitude)
    hour_utc = Dates.hour(datetime) + Dates.minute(datetime) / 60 + Dates.second(datetime) / 3600
    doy = CM.day_of_year(datetime)
    eot = CM.equation_of_time(doy)
    time_offset = longitude / 15
    solar_time = hour_utc + time_offset + eot / 60
    return deg2rad(15 * (solar_time - 12))
end

function CM.cos_solar_zenith_angle(datetime::AbstractDateTime, longitude, latitude)
    φ = deg2rad(latitude)
    δ = CM.solar_declination(CM.day_of_year(datetime))
    ω = CM.hour_angle(datetime, longitude)
    return sin(φ) * sin(δ) + cos(φ) * cos(δ) * cos(ω)
end

# ### Rung C — the same call, after the shim
#
# Value-checked against the host, not merely "did not throw": the Spencer series and equation of time
# are enough arithmetic that a silently wrong traced result is a real possibility.
c = attempt("rung C  @jit cos_solar_zenith_angle(::ReactantDateTime, λ, φ)  [after shim]") do
    ms = Reactant.ConcreteRNumber(Dates.value(EPOCH))
    cz = Reactant.to_number(@jit((m -> CM.cos_solar_zenith_angle(traced_datetime(m), LONGITUDE, LATITUDE))(ms)))
    @assert isapprox(cz, HOST_COS_θZ; atol=1e-10) "traced $cz ≠ host $HOST_COS_θZ"
    "traced cos(θ_z) = $(round(cz, digits=6)), host $(round(HOST_COS_θZ, digits=6)) — identical"
end

# ### Rung D — the diurnal cycle, which is the entire point
#
# One value proves dispatch; a day's worth proves the clock is actually driving the geometry. Sweeps
# 0–24 h off the traced epoch and reports sunrise. `FixedCosineZenith` would return a flat line here.
d = attempt("rung D  @jit sweeping the traced clock across 24 h") do
    cos_at(hours) = begin
        ms = Reactant.ConcreteRNumber(Dates.value(EPOCH) + round(Int64, 3.6e6 * hours))
        Reactant.to_number(@jit((m -> CM.cos_solar_zenith_angle(traced_datetime(m), LONGITUDE, LATITUDE))(ms)))
    end
    hours = 0:2:24
    traced = [cos_at(h) for h in hours]
    host = [CM.cos_solar_zenith_angle(EPOCH + Millisecond(round(Int64, 3.6e6 * h)), LONGITUDE, LATITUDE) for h in hours]
    @assert all(isapprox.(traced, host; atol=1e-10)) "traced sweep diverges from host"
    up = [h for (h, cz) in zip(hours, traced) if cz > 0]
    "cos(θ_z) over +0…24 h: " * join((string(h, "h:", round(cz, digits=3)) for (h, cz) in zip(hours, traced)), "  ") *
    "\n         sun above the horizon at " * (isempty(up) ? "no sampled hour" : "+$(first(up))…$(last(up)) h — a real diurnal cycle, not a constant")
end

# ### Shim 2 — `compute_datetime` for a traced numeric clock
#
# This is the gap the downscale script hit. A compiled step's clock holds seconds as a
# `TracedRNumber{Float64}`, not a datetime, so the epoch has to be advanced by a traced offset. Both
# failing pieces get replaced: `round(Int, ·)` becomes `trunc(Int64, round(·))` (Reactant defines
# it), and `Dates.Millisecond` — concrete `Int64` field — becomes `ReactantMillisecond`.
RRT.compute_datetime(t::Reactant.TracedRNumber, epoch::AbstractDateTime) =
    RDT(epoch) + RMS(trunc(Int64, round(1000t)))

e = attempt("rung E  @jit compute_datetime(traced seconds, epoch) → cos(θ_z)") do
    seconds_in = Reactant.ConcreteRNumber(6 * 3600.0)   # +6 h: pre-dawn start swung into daylight
    f = t -> CM.cos_solar_zenith_angle(RRT.compute_datetime(t, EPOCH), LONGITUDE, LATITUDE)
    cz = Reactant.to_number(@jit f(seconds_in))
    host = CM.cos_solar_zenith_angle(EPOCH + Second(6 * 3600), LONGITUDE, LATITUDE)
    @assert isapprox(cz, host; atol=1e-10) "traced $cz ≠ host $host"
    "clock.time = 21600.0 s traced → cos(θ_z) = $(round(cz, digits=6)) (host $(round(host, digits=6))) — " *
    "the seconds→calendar conversion the downscale script declared impossible"
end

# ### Shim 3 — an RRTMGP ClimaComms context for `ReactantState`
#
# Not a solar-position problem at all, but it blocks every rung below: `RadiativeTransferModel`
# calls `rrtmgp_context(architecture(grid))`, which `BreezeRRTMGPExt` defines for `CPU` and `GPU`
# only, so radiation fails at CONSTRUCTION before any tracing happens. This is `reactant_downscale.jl`'s
# shim 12, reproduced here so this file stands alone; see that script for why `CPU()` is the right
# context rather than a fallback (Reactant executes through its own PJRT plugin, and its arrays are
# not `CuArray`s, so a CUDA context would allocate the wrong array type even where it worked).
#
# `@eval` runs inside `BreezeRRTMGPExt`, which does not bind `Oceananigans` — so the types are
# SPLICED in from this module rather than named by module path, which would be an `UndefVarError`.
let RS = Oceananigans.Architectures.ReactantState, OceanCPU = Oceananigans.Architectures.CPU
    @eval RRT rrtmgp_context(::$RS) = rrtmgp_context($OceanCPU())
end

# ### Rung F — `update_solar_zenith_angle!` through a real RRTMGP shortwave solver
#
# The first rung with an actual `RadiativeTransferModel`: the traced cos(θ_z) has to land in
# `sw_solver.bcs.cos_zenith`, a Reactant array, via the broadcast Breeze already writes. An explicit
# `coordinate` is used so this rung isolates the datetime plumbing from the kernel question (rung G).
arch = ReactantState()
column_grid = RectilinearGrid(arch; size = 16, x = LONGITUDE, y = LATITUDE,
                              z = (0, 10kilometers), topology = (Flat, Flat, Bounded))
constants = Breeze.ThermodynamicConstants()

## Guarded: construction is itself a rung's worth of risk (shim 3 above exists precisely because it
## can fail), and a throw at top level would abort rungs G and H rather than reporting them.
rtm_explicit = try
    RadiativeTransferModel(column_grid, AllSkyOptics(), constants;
                           solar_position = ApparentSolarPosition(coordinate = (LONGITUDE, LATITUDE),
                                                                  epoch = EPOCH),
                           surface_temperature = 285,
                           surface_albedo = 0.1,
                           schedule = IterationInterval(1))
catch err
    @warn "RadiativeTransferModel construction FAILED [$(nameof(typeof(err)))]; rungs F and H cannot run\n" *
          first(sprint(showerror, err), 600)
    nothing
end

traced_clock = Clock(time      = Reactant.ConcreteRNumber(6 * 3600.0),
                     iteration = Reactant.ConcreteRNumber(0),
                     last_Δt   = Reactant.ConcreteRNumber(0.0))

rung_f = attempt("rung F  @jit update_solar_zenith_angle!(sw_solver, ApparentSolarPosition, grid, traced clock)") do
    isnothing(rtm_explicit) && error("no RadiativeTransferModel — construction failed above")
    ## One `RRTMGPSolver` is stored in `longwave_solver`; its `.sws` is the shortwave half, which is
    ## exactly what `_update_radiation!` passes to `update_solar_zenith_angle!`. (`rtm.shortwave_solver`
    ## is `nothing` for the full-spectrum models — a stale guess costs a run to find out.)
    sw = rtm_explicit.longwave_solver.sws

    ## Report the array type BEFORE the call, so the diagnosis is stated rather than inferred from
    ## whatever error comes back. This is the line that matters for everything below.
    @info "         RRTMGP shortwave BC array is a $(typeof(sw.bcs.cos_zenith))"

    @jit RRT.update_solar_zenith_angle!(sw, rtm_explicit.solar_position, column_grid, traced_clock)
    host = max(CM.cos_solar_zenith_angle(EPOCH + Second(6 * 3600), LONGITUDE, LATITUDE), 0)
    got = Array(sw.bcs.cos_zenith)[1]
    @assert isapprox(got, host; atol=1e-6) "solver cos_zenith $got ≠ host $host"
    "sw_solver.bcs.cos_zenith = $(round(got, digits=6)) — written from inside the trace"
end

# ### Rung G — the per-column path: a `ReactantDateTime` as a KA kernel argument
#
# With `coordinate = nothing` Breeze reads (λ, φ) from the grid and launches
# `_update_apparent_zenith_kernel!` with the datetime as an argument. This is the one part of the
# chain whose behaviour is genuinely open: the struct wraps a traced integer and has to survive KA
# raising. A 2D grid, because a single-column grid never exercises the per-column branch.
#
# It must be a `LatitudeLongitudeGrid`: the kernel calls `λnode`/`φnode`, which a `RectilinearGrid`
# does not define. On a rectilinear grid the kernel fails to compile with
# `unsupported call to an unknown function (call to jl_f_throw_methoderror)` — an unelidable
# MethodError branch, which reads like a Reactant limitation but is just the wrong grid type.
plane_grid = LatitudeLongitudeGrid(arch; size = (4, 4, 8),
                                   longitude = (LONGITUDE - 2, LONGITUDE + 2),
                                   latitude = (LATITUDE - 2, LATITUDE + 2),
                                   z = (0, 10kilometers),
                                   topology = (Bounded, Bounded, Bounded))

# ### Shim 4 — adapt `ReactantDateTime` for kernel arguments
#
# THIS is the fix for gap 3, and it is the one Reactant itself prescribes. When a traced value
# survives into a kernel unconverted, Reactant's own diagnostic says:
#
#     GPU kernel argument of type $T contains an unadapted traced value at field: $bad
#     … A surviving traced value means some struct in the hierarchy is missing
#     `Adapt.@adapt_structure`, so its fields were not recursed into during GPU adaptation.
#
# `ReactantDateTime` is exactly such a struct: `Adapt` walks kernel arguments and swaps
# `TracedRNumber` → `CuTracedRNumber`, but it only recurses into types that say how. Without a
# method it treats the datetime as opaque and its payload stays host-side.
#
# It cannot be a bare `Adapt.@adapt_structure ReactantDateTime`, because the traced number is not a
# direct field — it sits two wrappers down, `ReactantDateTime.instant::UTInstant{ReactantMillisecond{I}}`
# — so the constructor has to be rebuilt through both. This mirrors what Reactant already does for
# `TracedStepRangeLen` and `Base.TwicePrecision` (ReactantCUDAExt.jl:614-627).
#
# Written against a generic adaptor rather than `ReactantKernelAdaptor` specifically: adapting a
# wrapper by adapting its payload is correct for ANY adaptor, and it avoids reaching into a
# Reactant-internal type name.
#
# **Upstream: this belongs in `ReactantDatesExt`**, alongside the accessors that already work.
const Adapt = Oceananigans.Architectures.Adapt

Adapt.adapt_structure(to, dt::RDT) =
    RDT(Dates.UTInstant(RMS(Adapt.adapt(to, Dates.value(dt)))))

g = attempt("rung G  @jit update_solar_zenith_angle! with grid coordinates  [KA kernel takes the datetime]") do
    rtm_grid = RadiativeTransferModel(plane_grid, AllSkyOptics(), constants;
                                      solar_position = ApparentSolarPosition(epoch = EPOCH),
                                      surface_temperature = 285,
                                      surface_albedo = 0.1,
                                      schedule = IterationInterval(1))
    sw = rtm_grid.longwave_solver.sws

    ## `initialize_cos_zenith!` is a no-op for `ApparentSolarPosition`, so this array arrives as
    ## `undef` — which can read back as all-zeros and make a kernel that wrote NOTHING look like a
    ## kernel that computed a below-the-horizon sun. Stamp a sentinel so "unwritten" is
    ## distinguishable from "written with a legitimate zero".
    sentinel = -999.0
    sw.bcs.cos_zenith .= sentinel

    @jit RRT.update_solar_zenith_angle!(sw, rtm_grid.solar_position, plane_grid, traced_clock)
    got = Array(sw.bcs.cos_zenith)

    ## COMPILING is not the same as WRITING. Rung F established that this BC array is a host
    ## `Vector{Float64}`; `launch!` hands Reactant a traced CONSTANT copy of it, so a kernel can
    ## compile and run perfectly while its stores land in the copy and never reach this array.
    ## Without these assertions the rung reports OK on exactly that outcome.
    @assert !all(==(sentinel), got) "kernel compiled but wrote NOTHING — every column still holds the sentinel"

    ## Value check against host truth, per column, same as rungs C-F.
    host = [max(CM.cos_solar_zenith_angle(EPOCH + Second(6 * 3600),
                                          λnode(i, j, 1, plane_grid, Center(), Center(), Center()),
                                          φnode(i, j, 1, plane_grid, Center(), Center(), Center())), 0)
            for j in 1:plane_grid.Ny, i in 1:plane_grid.Nx]
    @assert isapprox(sort(vec(got)), sort(vec(host)); atol=1e-6) "traced per-column values ≠ host: $(extrema(got)) vs $(extrema(host))"

    "per-column cos_zenith spans $(round(minimum(got), digits=6))…$(round(maximum(got), digits=6)) " *
    "across $(length(got)) columns, matching host — the spatial gradient a fixed value cannot represent"
end

# ### Rungs J and K — put `cos_zenith` on a `ConcreteRArray` and try both write paths
#
# Rungs F and G both fail on the same thing: `sw.bcs.cos_zenith` is a host `Vector{Float64}`, because
# shim 3 points `rrtmgp_context` at `CPU()`. F fails loudly (`_copyto!` has no method for a host
# array and a traced broadcast); G fails SILENTLY — `launch!` hands Reactant a traced constant copy,
# the kernel compiles and runs, and its stores land in the copy rather than in the solver's array.
#
# So: make the array a `Reactant.ConcreteRArray` and see whether the traced writes land. RRTMGP does
# not stand in the way — `SwBCs{FT, FTA1D, …}` is fully parametric in its array types
# (`RRTMGP/src/optics/BCs.jl:32`), so a `ConcreteRArray` is a legal `FTA1D` with no RRTMGP change.
#
# `update_solar_zenith_angle!` touches exactly one field, `sw_solver.bcs.cos_zenith`, so a two-field
# stub isolates the array-type question from the rest of the solver — no rebuilding of RRTMGP's
# immutable solver structs, and no ambiguity about what is being tested.
#
# If these pass, the fix for the RRTMGP blocker is an allocation-time one:
# `ClimaComms.array_type(grid_params)` drives every RRTMGP allocation, so a ClimaComms device for
# `ReactantState` whose `array_type` is `ConcreteRArray` would put the whole workspace on Reactant
# arrays — and `FixedCosineZenith` would stop being the only solar position that works.
struct StubShortwaveSolver{B}
    bcs :: B
end

concrete_cos_zenith(n) = Reactant.ConcreteRArray(fill(-999.0, n))

j = attempt("rung J  @jit broadcast path (explicit coordinate) → ConcreteRArray cos_zenith") do
    cz = concrete_cos_zenith(16)
    stub = StubShortwaveSolver((; cos_zenith = cz))
    sp = ApparentSolarPosition(coordinate = (LONGITUDE, LATITUDE), epoch = EPOCH)
    @jit RRT.update_solar_zenith_angle!(stub, sp, column_grid, traced_clock)
    got = Array(cz)
    host = max(CM.cos_solar_zenith_angle(EPOCH + Second(6 * 3600), LONGITUDE, LATITUDE), 0)
    @assert !all(==(-999.0), got) "nothing was written — every entry still holds the sentinel"
    @assert all(x -> isapprox(x, host; atol=1e-6), got) "traced $(extrema(got)) ≠ host $host"
    "all $(length(got)) entries = $(round(first(got), digits=6)), matching host — " *
    "the broadcast that fails on a host Vector succeeds on a ConcreteRArray"
end

k = attempt("rung K  @jit kernel path (grid coordinates) → ConcreteRArray cos_zenith") do
    cz = concrete_cos_zenith(plane_grid.Nx * plane_grid.Ny)
    stub = StubShortwaveSolver((; cos_zenith = cz))
    sp = ApparentSolarPosition(epoch = EPOCH)   # coordinate = nothing ⇒ per-column kernel
    @jit RRT.update_solar_zenith_angle!(stub, sp, plane_grid, traced_clock)
    got = Array(cz)
    host = [max(CM.cos_solar_zenith_angle(EPOCH + Second(6 * 3600),
                                          λnode(i, j, 1, plane_grid, Center(), Center(), Center()),
                                          φnode(i, j, 1, plane_grid, Center(), Center(), Center())), 0)
            for j in 1:plane_grid.Ny, i in 1:plane_grid.Nx]
    @assert !all(==(-999.0), got) "kernel compiled but wrote NOTHING — every entry still holds the sentinel"
    @assert isapprox(sort(vec(got)), sort(vec(host)); atol=1e-6) "traced $(extrema(got)) ≠ host $(extrema(host))"
    "per-column cos_zenith spans $(round(minimum(got), digits=6))…$(round(maximum(got), digits=6)) " *
    "across $(length(got)) columns, matching host — the kernel's stores actually land"
end

# ### Shim 4 + rung I — pass the milliseconds, rebuild the datetime inside the kernel
#
# Rung G's error names the cause precisely. Look at the two argument types in its failing
# `MethodInstance`:
#
#     ::LatitudeLongitudeGrid{ReactantCUDAExt.CuTracedRNumber{Float64, 1}, …}   # converted ✓
#     ::ReactantDatesExt.ReactantDateTime{Reactant.TracedRNumber{Int64}}        # NOT converted ✗
#
# Reactant's KA argument conversion recursed into the grid and turned its scalars into device-side
# `CuTracedRNumber`s, but it did NOT recurse into `ReactantDateTime` — that struct still carries a
# HOST-side `TracedRNumber{Int64}`. So every operation on the datetime inside the kernel tries to
# EMIT MLIR rather than compute, and Reactant's own tracing machinery gets dragged into device code:
#
#     Reason: unsupported dynamic function invocation (call to Reactant.MLIR.IR.Location)
#       @ ~/Reactant.jl/src/Ops.jl:153
#
# The GC-frame and `ijl_eqtable_get` reasons are downstream of that, not separate problems.
#
# So this rung passes the raw traced INTEGER — which Reactant does know how to convert — and rebuilds
# the `ReactantDateTime` inside the kernel. That is the only change; the arithmetic is identical.
#
# !!! note "Result: diagnosis confirmed, but a second blocker sits behind it"
#     The conversion half of the diagnosis is CONFIRMED. The milliseconds arrive as
#     `ReactantCUDAExt.CuTracedRNumber{Int64, 1}` — a genuine device scalar — and every
#     `MLIR.IR.Location` / `Ops.jl` / GC-frame reason from rung G disappears. Passing the number
#     instead of the struct is the right shape, and teaching Reactant's kernel-argument conversion to
#     recurse into `ReactantDateTime` (a plain immutable wrapper around one number) would fix rung G
#     without touching Breeze.
#
#     But the kernel still does not compile, now for an unrelated reason: CONSTRUCTING the datetime
#     inside the kernel drags Base's STRING FORMATTING into device code —
#
#         Reason: unsupported call to a lazy-initialized function (call to jl_genericmemory_to_string)
#           [1] unsafe_takestring @ ./strings/string.jl:84
#           [2] hex               @ ./intfuncs.jl:942
#
#     `Base.hex` builds a `String`, which cannot exist on device.
#
# !!! note "SUPERSEDED — keep as a control, do not adopt"
#     Shim 4 (`Adapt.adapt_structure`) is the right fix, and this rung is the evidence for choosing
#     it over the ms-passing workaround. Rung K runs the SAME per-column kernel through Breeze's
#     unmodified code path, with the adapted struct crossing the boundary, and it PASSES — while this
#     rung, which rebuilds the datetime in-kernel, still fails. So the `Base.hex` problem is an
#     artifact of in-kernel construction, not something on the real path. Adapting the struct avoids
#     it entirely.
## KernelAbstractions is reached through `Oceananigans.Utils` rather than by `using KernelAbstractions`
## — like NCDatasets above, it is a transitive dependency and not in this project's `Project.toml`.
const KA = Oceananigans.Utils.KernelAbstractions

KA.@kernel function _traced_zenith_kernel!(rrtmgp_cos_θz, grid, datetime_ms)
    i, j = KA.@index(Global, NTuple)
    λ = λnode(i, j, 1, grid, Center(), Center(), Center())
    φ = φnode(i, j, 1, grid, Center(), Center(), Center())
    ## Rebuilt HERE, from an argument Reactant converted properly, rather than crossing the boundary
    ## as a struct. Same `cos_solar_zenith_angle` call as Breeze's kernel.
    cos_θz = CM.cos_solar_zenith_angle(RDT(Dates.UTInstant(RMS(datetime_ms))), λ, φ)
    c = RRT.rrtmgp_column_index(i, j, grid.Nx)
    @inbounds rrtmgp_cos_θz[c] = max(cos_θz, 0)
end

i_rung = attempt("rung I  @jit per-column kernel taking traced MILLISECONDS instead of the struct") do
    rtm_grid = RadiativeTransferModel(plane_grid, AllSkyOptics(), constants;
                                      solar_position = ApparentSolarPosition(epoch = EPOCH),
                                      surface_temperature = 285,
                                      surface_albedo = 0.1,
                                      schedule = IterationInterval(1))
    sw = rtm_grid.longwave_solver.sws
    f = (cz, ms) -> (launch!(arch, plane_grid, :xy, _traced_zenith_kernel!, cz, plane_grid, ms); nothing)
    @jit f(sw.bcs.cos_zenith, Reactant.ConcreteRNumber(Dates.value(EPOCH + Second(6 * 3600))))
    got = Array(sw.bcs.cos_zenith)
    "per-column cos_zenith spans $(round(minimum(got), digits=6))…$(round(maximum(got), digits=6)) " *
    "across $(length(got)) columns"
end

# ### Rung H — the whole thing: `update_radiation!` on a real `AtmosphereModel`
#
# What the downscale script would actually call, and the only rung that proves the claim end to end.
# A stub model is not enough here: `_update_radiation!` reads the gas and cloud state off the model
# (`update_rrtmgp_gas_state!`, `update_rrtmgp_cloud_state!`) before it ever reaches the sun position,
# so this needs a real `AtmosphereModel` with dynamics, microphysics, and a thermodynamic state.
#
# `minrepro_radiation.jl` rung A established that the SCHEDULE branch traces. This adds the calendar
# to it: success means a compiled radiation update whose sun position comes from the model clock
# rather than from a constant baked into the executable at compile time.
h = attempt("rung H  @jit update_radiation!(rtm, model)  [real AtmosphereModel, traced clock + ApparentSolarPosition]") do
    isnothing(rtm_explicit) && error("no RadiativeTransferModel — construction failed above")

    reference_state = ReferenceState(column_grid, constants;
                                     surface_pressure = 101325, potential_temperature = 288)
    model = AtmosphereModel(column_grid;
                            clock = traced_clock,
                            dynamics = AnelasticDynamics(reference_state),
                            microphysics = SaturationAdjustment(equilibrium = WarmPhaseEquilibrium()),
                            radiation = rtm_explicit)

    ## A moist profile, so the all-sky path has cloud to act on rather than a trivially dry column.
    set!(model; θ = 288, qᵗ = z -> 0.012 * exp(-z / 3000))

    @jit Breeze.AtmosphereModels.update_radiation!(rtm_explicit, model)

    cz = Array(rtm_explicit.longwave_solver.sws.bcs.cos_zenith)[1]
    lw = Array(interior(rtm_explicit.upwelling_longwave_flux))
    sw = Array(interior(rtm_explicit.downwelling_shortwave_flux))
    "complete radiation update traced end to end; cos_zenith = $(round(cz, digits=6)), " *
    "upwelling LW $(round(maximum(lw), digits=2)) W/m², downwelling SW $(round(maximum(sw), digits=2)) W/m²"
end

rungs = ["A Reactant datetime accessors" => a,
         "B before shim (expected to fail)" => b,
         "C after shim" => c,
         "D diurnal sweep" => d,
         "E compute_datetime on traced seconds" => e,
         "F solver BC write" => rung_f,
         "G per-column kernel (datetime struct as kernel arg)" => g,
         "J broadcast → ConcreteRArray cos_zenith" => j,
         "K kernel → ConcreteRArray cos_zenith" => k,
         "I per-column kernel (traced ms as kernel arg)" => i_rung,
         "H full update_radiation!" => h]

@info "summary\n" * join(("  $(ok ? "ok    " : "FAILED") $name" for (name, ok) in rungs), "\n")
