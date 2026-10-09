# Reproducer for the compile failure that forces `AR_SPONGE=0` in `reactant_downscale.jl`.
#
# In the full model this surfaces while tracing a step:
#
#   InvalidIRError: compiling MethodInstance for Breeze.CompressibleEquations.gpu__build_vertical_rhs!(…)
#   Reason: unsupported call to an unknown function (call to jl_f_throw_methoderror)
#    [1] sponge_rhs        @ Breeze/src/CompressibleEquations/acoustic_substepping.jl:563
#    [2] macro expansion   @ Breeze/src/CompressibleEquations/acoustic_substepping.jl:909
#    [3] macro expansion   @ KernelAbstractions/src/macros.jl:332
#    [4] gpu__build_vertical_rhs! @ ./none:0
#
# !!! warning "Isolating `sponge_rhs` alone does NOT reproduce it"
#     A first attempt launched a kernel whose entire body was
#     `out[i,j,k] = sponge_rhs(i, j, k, grid, sponge, δτ, ρw)` on a terrain-following Reactant grid
#     with a real `UpperSponge`. It COMPILED (61.5 s). `sponge_rhs` is `@inline`, so the backtrace
#     line is where the offending call was inlined FROM, not necessarily what is unresolvable — the
#     rest of `_build_vertical_rhs!` is equally suspect. That control is kept below as
#     `AR_STAGE=sponge_only`, because "this part is fine" is worth being able to re-check.
#
# So this file launches the REAL kernel with the REAL arguments, assembled exactly as
# `acoustic_rk3_substep_loop!` does (acoustic_substepping.jl:1455), differing from the full model
# only in that there is no nest, no parent atmosphere and no exchanger — a bare Breeze
# `AtmosphereModel`, which builds in seconds instead of ~10 minutes.
#
# The kernel does considerably more than the sponge, and each of these is a candidate:
#
#   ∂r_p′★    = ∇ᶻp′(i, j, k, grid, dynamics, ρθ′★, Πᴸ, γRᵐᴸ, slope_correction)  # terrain metrics
#   ∂z²_ρw′ˢ⁻ = ∂zᶜᶜᶠ(i, j, k, grid, ∂zᶜᶜᶜ, ρw′)                                 # FUNCTION as argument
#   Gρwˢ      = sponge_rhs(i, j, k, grid, sponge, δτˢ⁻, ρw′)                     # the blamed line
#
# MEASURED (CPU backend, login node, Reactant 0.2.280 + custom Reactant_jll):
#
#   AR_STAGE=nest_step  AR_SPONGE=1              FAILED  499.7 s   frames IDENTICAL to the full model:
#                                                  sponge_rhs → macro expansion ×2 → gpu__build_vertical_rhs!
#   AR_STAGE=nest_step  AR_SPONGE=0              no failure in 40 min — gets PAST this kernel and
#                                                  carries on compiling the rest of the step
#   AR_STAGE=nest_step  AR_MODE=hlo  SPONGE=1    TRACED OK  60.1 s
#   AR_STAGE=nest_step  AR_MODE=hlo  SPONGE=0    TRACED OK  58.8 s
#   AR_STAGE=rhs        AR_SPONGE=1|0            COMPILED OK ~58 s   (bare AtmosphereModel)
#   AR_STAGE=sponge_only                         COMPILED OK  61.5 s
#   AR_STAGE=nest_step  AR_SPONGE=1  TERRAIN=0   FAILED  390.1 s   SAME frames as TERRAIN=1
#   AR_STAGE=rhs        AR_SPONGE=1  TERRAIN=0   COMPILED OK  47.1 s
#
# AFTER adding `Base.abs` for `CuTracedRNumber` (Reactant dev'd from `~/Reactant.jl`):
#
#   AR_STAGE=bare_step  AR_SPONGE=1  TERRAIN=0   FAILED  430.6 s   but NO sponge_rhs frame and NO
#                                                  throw_methoderror anywhere — a DIFFERENT bug, an
#                                                  out-of-bounds `stablehlo.slice` in the halo fill
#   AR_STAGE=nest_step  AR_SPONGE=1  TERRAIN=0   FAILED 1225.8 s   IDENTICAL slice error (byte-for-byte
#                                                  the same op and limits), also 0 sponge_rhs frames
#
# So `bare_step` reproduces the CURRENT blocker ~3× faster than `nest_step` and with no nest at all —
# prefer it while chasing the halo slice.
#
# Conclusions, in the order they were forced by the data:
#   * The sponge IS required to trigger it — `AR_SPONGE=0` does not fail, which matches the full
#     model, where `AR_SPONGE=0` is what let the trace through.
#   * But the sponge is NOT sufficient: the same kernel with the same `UpperSponge` compiles fine
#     from a bare `AtmosphereModel`. The NESTED context is the other necessary ingredient — the
#     child's `Interpolated` open boundaries, microphysics and Davies forcing.
#   * It needs the full pipeline. `optimize=false` traces cleanly either way, because the kernel is
#     only handed to GPUCompiler once `lower-kernel` runs.
#   * The TERRAIN is irrelevant: `AR_TERRAIN=0` fails with byte-identical frames. That matters because
#     it exonerates the two things on line 563 that the terrain-following vertical complicates —
#     `rnode(i, j, k, grid, Center(), Center(), Face())` (plain arithmetic on a static z) and the
#     `_to_reactant` shims above. What is left on that line is `sponge.ramp(z, grid.Lz, sponge.depth)`
#     and `ρw_old[i, j, k]`.
#
# !!! success "CONFIRMED AND FIXED: `abs(::CuTracedRNumber)` was the missing method"
#     Adding `Base.abs` to the unary operator list in `ReactantCUDAExt.jl:133` (Reactant dev'd from
#     `~/Reactant.jl`) makes the failure below disappear completely: in the post-fix run the 1.3 MB
#     error text contains ZERO occurrences of `sponge_rhs` and ZERO of `throw_methoderror`. The
#     compile gets substantially further and then dies on something unrelated (see below).
#
#     Note the environment moved with the fix — `Pkg.develop`ing Reactant re-resolved and also bumped
#     Oceananigans 0.110.14→0.110.15 and Thermodynamics 1.2.2→1.3.0. `Reactant_jll` nominally went
#     0.0.405+0→0.0.404+1 but that is cosmetic: `LocalPreferences.toml` overrides
#     `libReactantExtra_path` to a locally built `libReactantExtra.so`.
#
# !!! warning "NEXT failure, unrelated to the sponge: an out-of-bounds halo slice"
#     With the sponge fixed, `AR_STAGE=bare_step` now fails as a `Reactant.Compiler.CompilationError`
#     (NOT an `InvalidIRError` — so `dump_diagnostics` correctly finds no `job`/`errors` to dump):
#
#         CompilationError: MLIR pass pipeline "all" failed
#         error: 'stablehlo.slice' op failed to infer returned types
#         error: limit index 17 is larger than dimension size 16 in dimension 2
#           %1782 = "stablehlo.slice"(%1753)
#             <{start_indices = array<i64: 0, 0, 16>, limit_indices = array<i64: 11, 8, 17>, …}>
#             : (tensor<11x8x16xf32>) -> tensor<11x8x1xf32>
#
#     via `unsafe_store!` → `arrayset_bits`/`arrayset`/`setindex!` (ReactantCUDAExt) → OffsetArrays
#     `setindex!` → `_fill_bottom_halo!` (fill_halo_regions_normal_flow.jl) → `gpu__fill_bottom_and_top_halo!`.
#     The tensor carries only the 16-wide INTERIOR of the x dimension while the halo-fill kernel
#     indexes one element past it, so this looks like the halo extent being lost on the way to the
#     slice — a separate Reactant/Oceananigans issue, in a different kernel, with nothing to do with
#     `sponge_rhs`. `nest_step` fails on the SAME op with the same limits, so it is not an artifact of
#     the `bare_step` stage.
#
#     The kernel's own signature says the field reaching it is fine:
#
#         OffsetArray{Float32, 3, CuTracedArray{Float32, 3, 1, (22, 14, 19)}}
#
#     i.e. the FULL halo'd extent (16+2·3, 8+2·3, 12+2·3+1). Yet the tensor actually sliced is
#     `tensor<11x8x16xf32>`, which carries only the 16-wide INTERIOR in that dimension. Reactant
#     tensors are in reversed index order, so MLIR "dimension 2" is Julia's x: the slice asks for
#     x index 17 (1-based), the first EAST halo column — a perfectly legal index into a 22-wide
#     halo'd array, but out of bounds for the interior-only tensor the op was actually given. The
#     halo extent is being lost somewhere between the `CuTracedArray` and the emitted slice.
#
#     Incidentally the same signature confirms the diagnosis below directly: the grid comes through as
#     `LatitudeLongitudeGrid{CuTracedRNumber{Float32,1}, …}`, so its scalars really are device traced
#     numbers — which is exactly why `abs` had to exist for them.
#
# !!! tip "Original diagnosis, kept because it is what identified the fix"
#     Line 563 is `abs(δτˢ⁻) * sponge.damping_rate * sponge.ramp(...) * ρw_old[i, j, k]`, and `abs` is
#     the FIRST call on it. Reactant's `CuTracedRNumber` (the device counterpart a `TracedRNumber` is
#     adapted into, ReactantCUDAExt.jl:66) forwards a fixed list of operators to `a[]`:
#
#         + - * / ^ min max mod rem isless == !=            (binary, ReactantCUDAExt.jl:95)
#         + - isnan isfinite isinf                          (unary,  ReactantCUDAExt.jl:133)
#         zero one ifelse convert promote_rule unsafe_trunc
#
#     `abs` is in NEITHER list, and `CuTracedRNumber <: Number` is NOT `<: Real`, so it matches none of
#     Base's `abs` methods (`Real`, `Signed`, `Unsigned`, `Complex`, `Rational`, `Bool`, the `Float*`
#     union) — there is no `abs(::Number)` fallback. That is a genuine MethodError, i.e. exactly the
#     `jl_f_throw_methoderror` GPUCompiler refuses to emit.
#
#     It fits every row of the table. `δτˢ⁻` is a host `Float32` in `rhs`/`sponge_only` (passed here as
#     a literal) but is derived from the model's traced `Δt` under `time_step!`, so only the stepping
#     stages hand `abs` a `CuTracedRNumber`. `AR_SPONGE=0` takes `sponge_rhs(…, ::Nothing, …) =
#     zero(grid)` and never calls `abs`. Terrain is irrelevant. `AR_MODE=hlo` passes because
#     GPUCompiler never runs. The other uses of `δτˢ⁻` in the kernel (line 909) are `*` and `+`, which
#     ARE forwarded — which is why line 563 is the only frame blamed.
#
#     `sponge_term_diag` (line 554) opens with the same `abs(δτᵐ⁺)`, so the tridiagonal-coefficient
#     kernel should fail the same way once this one is fixed.
#
#     If confirmed, the fix is upstream in Reactant — add `abs` (and the rest of the unary real ops) to
#     the forwarded list — with a local workaround of dropping `abs` where the sign is already known.
#     `AR_STAGE=bare_step` is the test that matters: if a BARE model's `time_step!` fails identically,
#     the nest is irrelevant to this bug and the reproducer collapses to a few seconds of setup.
#
# Since the types reaching line 563 are IDENTICAL in the `rhs` stage (compiles) and `nest_step` (fails)
# — `nested_atmosphere_model` hands the child the same grid object and the same `dynamics`, sponge and
# all — the unresolved call is unlikely to be a genuine missing method. It looks like inference being
# cut off inside Reactant's `call_with_reactant` overlay under the much deeper `time_step!` trace,
# leaving a MethodError throw path that GPUCompiler then refuses. Confirming that means reading the
# whole message, which is why the `catch` below now dumps it to `minrepro_sponge_error.txt`.
#
# !!! warning "Pass arguments to `@compile` directly, never via a closure"
#     An earlier revision wrapped the call in a zero-argument closure, so Reactant traced `model` and
#     `substepper` as CAPTURES rather than arguments. That produced a completely different, spurious
#     failure (`unsafe_takestring` / `_string_n` / `write_to_host_buffer!`) and briefly supported the
#     wrong conclusion that the sponge was irrelevant. The real script does
#     `@compile first_time_step!(model, Δt)`; match that.
#
#   OMP_NUM_THREADS=1 julia --project minrepro_sponge.jl
#
# AR_STAGE=nest_step|bare_step|rhs|sponge_only
#                            `bare_step` compiles `time_step!(model, Δt)` on the BARE
#                              `AtmosphereModel` — same traced-δτ path as `nest_step` but with none
#                              of the nest, and it builds in seconds. See the `abs` note above.
#                            `nest_step` (default) compiles `time_step!(nest.child, Δt)` on a small
#                              NESTED model — open `Interpolated` boundaries, microphysics, Davies
#                              forcing — which is the context the real failure occurs in;
#                            `rhs` launches `_build_vertical_rhs!` standalone from a bare
#                              `AtmosphereModel` (COMPILES OK — so the kernel alone is not enough);
#                            `sponge_only` isolates `sponge_rhs` (COMPILES OK)
# AR_SPONGE=1|0              `UpperSponge` vs `nothing` — the discriminating knob
# AR_TERRAIN=1|0             terrain-following vertical (as the real model) vs plain static z
# AR_BACKEND=cpu|gpu         default cpu, so it runs on a login node with no queue
# AR_MODE=compile|hlo        `@compile` (full pipeline) or `@code_hlo optimize=false` (trace only)

using Oceananigans
using NumericalEarth
using Breeze
using CloudMicrophysics
using Reactant
using CUDA                      # Reactant needs CUDA.jl loaded to raise KA kernels, on any backend
using Printf
using InteractiveUtils          # `code_typed(::InvalidIRError)`, for the post-mortem below

using Oceananigans.Architectures: ReactantState, on_architecture, architecture
using Oceananigans.Utils: launch!, KernelParameters
using Breeze: materialize_terrain!
using Breeze.TerrainFollowingDiscretization: TerrainFollowingVerticalDiscretization, LinearDecay
using NumericalEarth.NestedModels: nested_atmosphere_model
using Oceananigans.TimeSteppers: time_step!

## KernelAbstractions is not a direct dependency of this project, but Oceananigans re-exports the
## module from `Oceananigans.Utils`, which is enough to define a kernel here without touching
## Project.toml (and without perturbing a Manifest a queued job is using).
const KA = Oceananigans.Utils.KernelAbstractions
using .KA: @kernel, @index

const CE = Breeze.CompressibleEquations

Reactant.set_default_backend(get(ENV, "AR_BACKEND", "cpu"))
Oceananigans.defaults.FloatType = Float32

stage       = Symbol(get(ENV, "AR_STAGE", "nest_step"))
with_sponge = get(ENV, "AR_SPONGE", "1") == "1"
terrain     = get(ENV, "AR_TERRAIN", "1") == "1"
mode        = Symbol(get(ENV, "AR_MODE", "compile"))

arch = ReactantState()

## `on_architecture` for a `LatitudeLongitudeGrid` walks the grid through the Reactant extension's
## private `_to_reactant`, which knows arrays and the STATIC vertical only.
const RA = Base.get_extension(Oceananigans, :OceananigansReactantExt).Architectures

RA._to_reactant(f::LinearDecay) =
    LinearDecay(f.z_top, RA._to_reactant(f.h), RA._to_reactant(f.∂x_h), RA._to_reactant(f.∂y_h))

RA._to_reactant(z::TerrainFollowingVerticalDiscretization) =
    TerrainFollowingVerticalDiscretization(RA._to_reactant(z.cᵃᵃᶠ), RA._to_reactant(z.cᵃᵃᶜ),
                                           RA._to_reactant(z.Δᵃᵃᶠ), RA._to_reactant(z.Δᵃᵃᶜ),
                                           RA._to_reactant(z.formulation))

const SZ = (16, 8, 12)
const Z_TOP = 12_000

grid = if terrain
    host = LatitudeLongitudeGrid(CPU(); longitude = (-10, 10), latitude = (-5, 5),
                                 z = TerrainFollowingVerticalDiscretization((0, Z_TOP)),
                                 size = SZ, halo = (3, 3, 3), topology = (Bounded, Bounded, Bounded))
    materialize_terrain!(host, (λ, φ) -> 300 * exp(-((λ / 3)^2 + (φ / 2)^2)))
    on_architecture(arch, host)
else
    LatitudeLongitudeGrid(arch; longitude = (-10, 10), latitude = (-5, 5), z = (0, Z_TOP),
                          size = SZ, halo = (3, 3, 3), topology = (Bounded, Bounded, Bounded))
end

sponge = with_sponge ? UpperSponge(damping_rate = 1/5, depth = 3000) : nothing

## Same shape as the real dynamics: split-explicit with a FIXED substep count (a CFL-derived count is
## traced on a Reactant grid — see shim 5 in `reactant_downscale.jl`), no divergence damping.
time_discretization = SplitExplicitTimeDiscretization(Float32;
                                                      substeps = 1,
                                                      sponge,
                                                      damping = NoDivergenceDamping())

dynamics = CompressibleDynamics(time_discretization; surface_pressure = 101325.0)

## A bare Breeze atmosphere: this is what owns `model.dynamics` (with its terrain metrics) and the
## `AcousticSubstepper` holding every perturbation/linearization field the kernel reads.
model = AtmosphereModel(grid; dynamics)
substepper = model.timestepper.substepper

@info "reproducer" stage with_sponge terrain mode backend=get(ENV, "AR_BACKEND", "cpu") summary(grid)

## ---- the control: `sponge_rhs` on its own (known to COMPILE) -------------------------------------
@kernel function _sponge_rhs_kernel!(out, grid, sponge, δτ, ρw)
    i, j, k = @index(Global, NTuple)
    @inbounds out[i, j, k] = CE.sponge_rhs(i, j, k, grid, sponge, δτ, ρw)
end

function apply_sponge_only!(out, grid, sponge, δτ, ρw)
    launch!(architecture(grid), grid, :xyz, _sponge_rhs_kernel!, out, grid, sponge, δτ, ρw)
    return nothing
end

## ---- the real thing: `_build_vertical_rhs!`, argument for argument ------------------------------
## Mirrors acoustic_substepping.jl:1455. `Δτ`, the CN split weights and `dˢ⁻` are plain scalars there
## too, so concrete values are faithful; `g` comes from the model's own constants.
function build_vertical_rhs!(substepper, model, grid, Δτ, δτᵐ⁺, δτˢ⁻, g, dˢ⁻, apply_pressure_gradient)
    launch!(architecture(grid), grid,
            KernelParameters(1:size(grid, 1), 1:size(grid, 2), 1:size(grid, 3) + 1),
            CE._build_vertical_rhs!,
            substepper.momentum_perturbation.w,
            substepper.density_predictor,
            substepper.density_potential_temperature_predictor,
            substepper.density_perturbation,
            substepper.density_potential_temperature_perturbation,
            substepper.momentum_perturbation.w,
            grid, model.dynamics, Δτ, δτᵐ⁺, δτˢ⁻,
            substepper.linearization_exner, substepper.linearization_gamma_R_mixture,
            g, dˢ⁻, substepper.vertical_momentum_tendency_factor,
            substepper.slow_vertical_momentum_tendency,
            substepper.sponge, apply_pressure_gradient)
    return nothing
end

Δτ  = Float32(10)
ω   = Float32(0.65)
δτᵐ⁺ = ω * Δτ
δτˢ⁻ = (1 - ω) * Δτ
g   = Float32(9.80665)
dˢ⁻ = zero(Float32)          # damping off, matching `NoDivergenceDamping`

## Arguments are passed to `@compile` DIRECTLY, not captured in a zero-argument closure. A closure
## makes Reactant trace `model`/`substepper` as captured state rather than as arguments, which is not
## what the real script does (`@compile first_time_step!(model, Δt)`) — and it produced a completely
## different, spurious failure (`unsafe_takestring`/`_string_n`/`write_to_host_buffer!`) that has
## nothing to do with the bug under investigation.
out = Field{Center, Center, Face}(grid)
ρw  = Field{Center, Center, Face}(grid)

## ---- the nested context: what the real failure actually happens inside --------------------------
## A bare `AtmosphereModel` compiles this kernel fine, so the missing ingredient is the nest: the
## child's fields carry `Interpolated` open boundaries (a whole parent FieldTimeSeries + grid), the
## microphysics the real child uses, and Davies relaxation forcing.
function build_small_nest(sponge)
    pgrid = LatitudeLongitudeGrid(arch; longitude = (-12, 12), latitude = (-7, 7), z = (0, Z_TOP),
                                  size = (12, 7, 8), halo = (3, 3, 3),
                                  topology = (Bounded, Bounded, Bounded))
    times = collect(range(0.0, 7200.0, length = 3))
    fts(v) = (f = FieldTimeSeries{Center, Center, Center}(pgrid, times); set!(f, (λ, φ, z, t) -> v); f)

    atmos = PrescribedAtmosphere(pgrid, times;
                velocities = (u = fts(10.0), v = fts(1.0)),
                temperature = fts(280.0), specific_humidity = fts(0.005),
                microphysical_variables = (qᶜˡ = fts(1.0e-4), qʳ = fts(0.0),
                                           qᶜⁱ = fts(0.0),   qˢ = fts(0.0)),
                pressure = (p = CenterField(pgrid); set!(p, (λ, φ, z) -> 101325 * exp(-z / 8500)); p),
                precipitation_flux = nothing)

    ext = Base.get_extension(NumericalEarth, :NumericalEarthBreezeExt)
    td = SplitExplicitTimeDiscretization(Float32; substeps = 1, sponge,
                                         damping = NoDivergenceDamping())

    return Reactant.@allowscalar nested_atmosphere_model(atmos, grid;
                terrain = nothing, relaxation_rate = 1/300, relaxation_width = 3,
                surface_pressure = 101325.0,
                dynamics = CompressibleDynamics(td; surface_pressure = 101325.0),
                microphysics = ext.default_nested_microphysics(),
                momentum_advection = WENO(order = 5))
end

## `bare_step` needs no nest, which is the whole point of it — it builds in seconds.
nest = stage === :nest_step ? build_small_nest(sponge) : nothing
stage === :nest_step && @info "small nest built"

## ---- turning "call to jl_f_throw_methoderror" into an actual diagnosis -------------------------
## GPUCompiler's `meta` for an `UNKNOWN_FUNCTION` is only the LLVM symbol name, so the printed
## message can never say WHICH method error. Two things do:
##
##   1. `err.job.source` — the kernel's SPECIALIZED signature. If Adapt failed to convert a host
##      `TracedRNumber` into its device counterpart, that shows up right here as a `TracedRNumber`
##      surviving in an argument type next to properly-converted `CuTracedArray`s. Device code has
##      no methods for the host type, so the arithmetic on line 563 falls back to dynamic dispatch
##      and leaves the MethodError throw that GPUCompiler then rejects.
##   2. `code_typed(err)` — GPUCompiler runs this through ITS OWN abstract interpreter and method
##      table (`interactive=false` needs no Cthulhu), so it reproduces the failing inference rather
##      than what plain `code_typed` on the host would infer. Statements typed `Any` are the
##      dynamic calls; the one on acoustic_substepping.jl:563 is the culprit.
##
## Everything goes to a file: the kernel signature alone is thousands of characters and the typed IR
## is far past anything a terminal keeps.
function dump_diagnostics(err, path)
    (isdefined(err, :job) && isdefined(err, :errors)) || return false
    open(path, "w") do io
        mi = err.job.source
        println(io, "### kernel MethodInstance\n", mi, "\n")

        println(io, "### specialized argument types")
        for (n, T) in enumerate(mi.specTypes.parameters)
            println(io, lpad(n, 3), ": ", T)
        end

        ## The Adapt question, answered by counting: a device kernel should carry NO host-side
        ## `TracedRNumber`/`TracedRArray`/`ConcreteR*`. Any nonzero count there is the smoking gun.
        sig = string(mi.specTypes)
        println(io, "\n### Adapt check — host types that should not survive into device code")
        for pat in ("TracedRNumber", "TracedRArray", "ConcreteRNumber", "ConcreteRArray",
                    "CuTracedRNumber", "CuTracedArray")
            println(io, lpad(count(pat, sig), 5), "  ", pat)
        end

        println(io, "\n### reported IR errors")
        for (kind, bt, meta) in err.errors
            println(io, "- ", kind, "  meta=", repr(meta))
            for frame in bt
                println(io, "    ", frame)
            end
        end

        println(io, "\n### typed IR (GPUCompiler's interpreter + method table)")
        try
            for (ci, rt) in InteractiveUtils.code_typed(err)
                println(io, "returns ::", rt, "\n", ci)
            end
        catch e
            println(io, "code_typed(err) itself failed: ", sprint(showerror, e))
        end
    end
    return true
end

start = time_ns()
try
    if mode === :hlo
        mod = if stage === :sponge_only
            @code_hlo optimize = false raise = true apply_sponge_only!(out, grid, sponge, δτˢ⁻, ρw)
        else
            @code_hlo optimize = false raise = true build_vertical_rhs!(substepper, model, grid, Δτ,
                                                                        δτᵐ⁺, δτˢ⁻, g, dˢ⁻, true)
        end
        write("minrepro_sponge.mlir", repr(mod))
        @info @sprintf("TRACED OK in %.1f s — wrote minrepro_sponge.mlir", 1e-9 * (time_ns() - start))
    else
        if stage === :bare_step
            @compile sync = true raise = true time_step!(model, Δτ)
        elseif stage === :nest_step
            @compile sync = true raise = true time_step!(nest.child, Δτ)
        elseif stage === :sponge_only
            @compile sync = true raise = true apply_sponge_only!(out, grid, sponge, δτˢ⁻, ρw)
        else
            @compile sync = true raise = true build_vertical_rhs!(substepper, model, grid, Δτ,
                                                                  δτᵐ⁺, δτˢ⁻, g, dˢ⁻, true)
        end
        @info @sprintf("COMPILED OK in %.1f s", 1e-9 * (time_ns() - start))
    end
catch err
    msg = sprint(showerror, err)
    kind = occursin("jl_f_throw_methoderror", msg) ? "InvalidIRError / jl_f_throw_methoderror (the reported failure)" :
           occursin("InvalidIRError", msg) ? "InvalidIRError, different reason" : string(typeof(err))
    @info @sprintf("FAILED in %.1f s — %s", 1e-9 * (time_ns() - start), kind)
    ## The mangled kernel signature is thousands of characters, so printing the HEAD of the message
    ## truncates away the `Reason:` and the blamed frames — which are the only interesting part.
    ## Print from `Reason:` instead, and note which kernel it was separately.
    ## The full message is also written out verbatim: the printed excerpt below truncates, and when
    ## several `Reason:` blocks are present only the first survives — the later ones are often the
    ## informative ones. The kernel name is mangled (`gpu__build_vertical_rhs!##…`), so the match is
    ## deliberately loose about what characters a name may contain.
    write("minrepro_sponge_error.txt", msg)
    if dump_diagnostics(err, "minrepro_sponge_diag.txt")
        println("wrote minrepro_sponge_diag.txt — kernel signature, Adapt check, typed IR")
    else
        println("no `job`/`errors` on a ", typeof(err), " — no GPUCompiler diagnostics to dump")
    end
    m = match(r"compiling MethodInstance for (\S+?)\(", msg)
    m === nothing || println("kernel: ", m.captures[1])
    println("Reason: blocks in message: ", count(_ -> true, eachmatch(r"Reason:", msg)),
            " — full text in minrepro_sponge_error.txt (", length(msg), " chars)")
    i = findfirst("Reason:", msg)
    println(i === nothing ? first(msg, 1500) : first(msg[first(i):end], 1800))
end
