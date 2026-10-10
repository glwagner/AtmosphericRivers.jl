# # Reactant twin of the 12 km PNW downscale: the same model, no data, XLA-compiled
#
# This is `downscale.jl`'s model — the same LAM grid, the same Breeze child nested in a parent
# `PrescribedAtmosphere` through open lateral boundaries + Davies relaxation, the same
# `PrescribedOcean` lower boundary coupled through Monin–Obukhov fluxes — with two changes:
#
#  1. **Nothing is read from disk.** The ERA5 parent, the ETOPO2022 terrain, the ERA5 SST snapshot
#     and the CGLS albedo are replaced by closed-form analytic fields: an idealized atmospheric
#     river (a tilted moisture/jet filament translating east) on ERA5's native pressure-level
#     geometry, an idealized coastal-range + Cascade orography, and an analytic SST. So the script
#     runs anywhere — no `era5/` cache, no CDS credentials, no network.
#  2. **The architecture is `ReactantState()`.** The model is traced into StableHLO and compiled by
#     XLA once, then stepped as a compiled executable, instead of launching CUDA/KA kernels per step.
#
# Because the state is analytic, this is a *configuration and performance* twin, not a hindcast:
# use it to compile, profile, and benchmark the nested-model machinery, or to reproduce a stepping
# bug without a 20 GB download. `downscale.jl` remains the scientific run.
#
# ## Running it
#
# ```
# AR_BACKEND=gpu AR_DOMAIN=landfall AR_CELLS_PER_DEGREE=3 julia --project -t auto reactant_downscale.jl
# ```
#
# Model construction is the slow part: on `ReactantState` every eager kernel launch
# (`fill_halo_regions!`, the exchanger's window fill, each `set!`) is compiled as its own XLA
# executable before the traced step loop is ever reached, so the stage markers below exist to show
# where the time goes.
#
# !!! warning "CPU backend needs OMP_NUM_THREADS=1 (macOS, Reactant 0.2.278)"
#     With `AR_BACKEND=cpu` and OpenMP left to its own devices, this deadlocks during nest
#     construction inside XLA's own CPU execution of a raised KernelAbstractions kernel —
#     `CustomCallThunk::Execute → __kmpc_fork_call → __kmpc_barrier → __kmp_suspend_64` — with the
#     process pinned at 0% CPU. It is not Julia-thread-count dependent (`-t 1` and `-t 4` hang
#     alike) and not in Oceananigans; it is an OpenMP barrier inside the XLA CPU custom call.
#     `OMP_NUM_THREADS=1` serializes those custom calls and gets through (at a cost: the parent
#     stage goes from 29 s to 151 s). The GPU backend does not use that path.
#
# ## Inspecting the trace instead of compiling it
#
# ```
# AR_HLO=1 OMP_NUM_THREADS=1 AR_DOMAIN=landfall AR_CELLS_PER_DEGREE=1 julia --project -t 4 reactant_downscale.jl
# ```
#
# writes the UNOPTIMIZED StableHLO for one step to `unopt_ar.mlir` (`AR_HLO_PATH` to redirect) and
# stops before the XLA compile — the cheap way to see exactly which kernels a step of the nest emits,
# without waiting out the optimizer and codegen. Kernels stay as `enzymexla.kernel_call`s there, so
# the file is for READING, not for feeding to another compiler.
#
# `AR_HLO=optimized` instead runs Reactant's full pipeline (the raise included) and writes the plain
# StableHLO that XLA itself receives, to `stablehlo_ar_optimized.mlir` plus a `.gz`. That one IS a
# standalone reproducer: `hlo-opt`/`run_hlo_module` take it with no Julia and no Reactant. Use it to
# hand off the coupled model's pathological XLA compile — see `slurm/coupled_hlo_dump.batch`.
#
# ## Gradients instead of a trajectory
#
# ```
# AR_AD=1 AR_AD_STEPS=2 julia --project -t auto reactant_downscale.jl
# ```
#
# differentiates the compiled run in REVERSE mode with Enzyme — `∂/∂(initial field)` of a scalar loss
# on the state a few steps later — and stops instead of running the forward trajectory. See the
# `AR_AD` section near the bottom for what the control and loss are, and why `raise_first=true` is
# what makes it work on a model built entirely from KernelAbstractions kernels.
#
# ## What Reactant changes about the driver
#
# `run!` is not supported on `ReactantState` (Oceananigans errors out), and a `ReactantSimulation`
# takes no callbacks, no output writers, no `stop_time`, and no time-step wizard: everything that
# branches on the clock host-side is incompatible with a traced clock. So the driver here compiles
# `first_time_step!` plus a `@trace`d fixed-length step loop, runs the loop in chunks, and prints
# progress between chunks (a host-side sync point). Δt is therefore FIXED — pick it below the
# advective CFL by hand (`AR_DT`), since the wizard cannot run inside the trace.
#
# ## Reactant caveats hit while porting (all upstream, all listed here so they are easy to retire)
# - `on_architecture(ReactantState(), grid)` has no `_to_reactant` for Breeze's terrain-following
#   vertical, so the shim below adds one; the terrain is materialized on a CPU twin of the grid and
#   moved over (`materialize_terrain!` itself is happy either way).
# - `NestedModel`'s `time_step!` and the `StateExchanger` branch on host-side comparisons of the
#   clock (`Δt_parent > 0`, "did the resident window move?"), which a traced clock cannot answer.
#   The shims below specialize both for the traced path, where Δt is fixed and the parent window
#   holds every time level — the two conditions that make those branches decidable in advance.
# - RETIRED: `RadiativeTransferModel`'s schedule was checked with `model.clock.iteration == 0 ||
#   schedule(model)` — a traced `Bool` under Reactant, so the host-side `if` threw. Breeze's
#   `update_radiation!` now uses `@trace track_numbers=false if …`; `minrepro_radiation.jl` is the
#   regression test. `AR_RADIATION=1` is off by default on COST now, not correctness.
# - A Field-level broadcast on a `LatitudeLongitudeGrid` — `compute!` of an `AbstractOperation`, or
#   `set!(field, other_field * scalar_field)` — does not compile under Reactant: the KA kernel raises
#   `InvalidIRError: unsupported call to jl_f_throw_methoderror`, eagerly and inside `@jit` alike, on
#   a plain LLG as much as a terrain-following one (a `RectilinearGrid` compiles fine, which is why
#   Breeze's own Reactant tests do not hit this). That rules out `initialize_nested_child!` AND
#   `set!(model; ρ, θˡⁱ, qᵗ, …)`, so the initial condition below is written straight into the
#   density-weighted prognostics from analytic functions, and the progress readout reduces over raw
#   prognostic interiors instead of online diagnostics.
# - Reactant needs `using CUDA` loaded to raise KernelAbstractions kernels even on the CPU backend;
#   without it every launch fails in `ka_with_reactant`. CUDA.jl only has to LOAD, not be functional:
#   the GPU backend runs through Reactant's own PJRT plugin, so `CUDA.functional() == false` (CUDA.jl's
#   JLLs precompiled without a driver, the usual login-node artifact) does not stop this script.
# - Breeze's split-explicit dynamics sizes its acoustic substep loop from the acoustic CFL, i.e. from
#   `minimum_xspacing(grid)` — traced here, so the loop's trip count is a traced `Int` and
#   `for substep in 1:Nτ` throws `TypeError: non-boolean (TracedRNumber{Bool}) used in boolean
#   context`. Shim 5 evaluates Breeze's own formula on the CPU twin and passes the answer in as a
#   plain `substeps`, which is the branch that never consults the grid.
# - An error raised INSIDE the trace is likely to reach you disguised. Reactant reports a failed trace
#   by `string`-ifying the exception, and if that exception's message embeds a traced grid — a
#   `MethodError` names its argument types, and `show(::LatitudeLongitudeGrid)` calls
#   `coordinate_summary`, which is `minimum(::TracedRArray)` — the stringification itself throws
#   `Scalar indexing is disallowed`, and THAT is what surfaces. When a trace dies on scalar indexing
#   somewhere in `Base.show`/`print_to_string`, the real failure is the `caused by:` MethodError
#   underneath it, not the reduction in the backtrace.
# - Two host-side reductions over grid node vectors hit `Scalar indexing is disallowed`, because on
#   `ReactantState` those vectors are `ConcretePJRTArray`s: `summary(::PrescribedAtmosphere)` (via
#   `horizontal_domain_summary`) and `NestedModels.validate_source_bracket` (via `extrema(xnodes(…))`,
#   reached while regularizing the `Interpolated` lateral boundaries). The first is only a printout, so
#   the parent's stage line is assembled from host-side numbers instead; the second is a real check
#   worth keeping, so the nest is built inside `Reactant.@allowscalar`.
# - Coupling the nest to the ocean WORKS now (job 6118); it did not for most of this script's life,
#   and the fallback below is kept for checkouts where it still does not. Three separate failures had
#   to be cleared, each hidden behind the one before it:
#     * NumericalEarth's Breeze↔ESM interface not being defined for a `NestedModel` atmosphere, so
#       `AtmosphereOceanModel` threw a `MethodError` (`thermodynamics_parameters`) — `downscale.jl`'s
#       "coupling a `NestedModel` to an ocean is an untested code path" caveat, met. The
#       `NestedModel` → child forwards on NumericalEarth `pb/cleanup` supply it.
#     * The exchanger's eager `surface_precipitation_flux` computation not compiling
#       (`InvalidIRError: … jl_f_throw_methoderror`), fixed upstream by Oceananigans b2ea52a84.
#     * `PrescribedOcean`'s own exchanger scalar-indexing a `FieldTimeSeries` view, fixed in
#       NumericalEarth's `copy_prescribed_time_level!`.
#   `minrepro_coupled.jl` is the write-up, and `slurm/coupling_probe.batch` re-answers "does it
#   couple" in ~25 min without paying for the compile.

using NumericalEarth
using Oceananigans
using Oceananigans.Units
using Breeze
using CloudMicrophysics          # nested_atmosphere_model's default 1-moment mixed-phase microphysics
using RRTMGP                     # Breeze's radiative-transfer extension
using Reactant
using CUDA                       # Reactant needs CUDA.jl loaded to raise KA kernels — on ANY backend
## `AR_KERNEL_TUNING=1` / `AR_KERNEL_BLOCKS_PER_SM` / `AR_KERNEL_MAXREGS`: per-kernel register caps (launch bounds)
## for the eager CUDA path — see perf/kernel_tuning.jl. Must load before the first kernel compiles.
if any(k -> get(ENV, k, "") ∉ ("", "0"), ("AR_KERNEL_TUNING", "AR_KERNEL_BLOCKS_PER_SM", "AR_KERNEL_MAXREGS")) &&
   !isdefined(Main, :tuned_launch_kwargs)
    include(joinpath(@__DIR__, "perf", "kernel_tuning.jl"))
end
using Printf
using Dates: DateTime, Hour   # `Hour` builds the ERA5 parent's 3-level hourly window
import Dates                 # `Dates.format` for ERA5 file stamps

using Oceananigans.Advection: AdaptiveVerticallyImplicitDiscretization
using Oceananigans.Architectures: ReactantState, on_architecture
using Oceananigans.Fields: interior
using Oceananigans.TimeSteppers: Clock, first_time_step!, time_step!
using Oceananigans: prognostic_fields
using Breeze: materialize_terrain!
using Breeze.TerrainFollowingDiscretization: TerrainFollowingVerticalDiscretization, LinearDecay
using NumericalEarth.NestedModels: NestedModel
using Reactant: @code_hlo, @compile, @jit, @trace

include("case.jl")

# ## `AR_FUSED_HALOS` (default 1): fused tuple halo filling
#
# With an Oceananigans that has fused tuple halo filling (`Fields.FUSED_HALO_FILLING`, the
# opt/halo-fusion branch), `fill_halo_regions!` on a tuple of fields launches one kernel per
# side-pair for every run of fields whose boundary conditions are "local" — read only their own
# data — instead of one launch per field per side-pair. NumericalEarth's parent lateral-BC
# condition `Interpolated` reads only its own parent FieldTimeSeries, so it is declared local here.
# `AR_FUSED_HALOS=0` restores the per-field path (bitwise-identical results).
if isdefined(Oceananigans.BoundaryConditions, :halo_condition_locality)
    Oceananigans.BoundaryConditions.halo_condition_locality(::NumericalEarth.NestedModels.Interpolated) =
        Oceananigans.BoundaryConditions.LocalHalo()
    Oceananigans.Fields.FUSED_HALO_FILLING[] = get(ENV, "AR_FUSED_HALOS", "1") == "1"
end

## AR_BACKEND=gpu compiles for the GPU (the cluster case); "cpu" keeps everything host-side, which
## is what makes this script runnable on a laptop.
# ## `AR_ARCH=cuda`: the same model with Reactant taken out of the loop
#
# A CONTROL, not a production mode. Everything in this script — grid, nest, open boundaries, Davies
# relaxation, coupling — is identical; only the architecture and the execution strategy change:
# `ReactantState()` becomes `GPU()`, `@compile` becomes a direct call, `@jit` becomes a direct call,
# and `step_for!`'s `@trace`d loop becomes an ordinary `for`. Kernels launch eagerly through
# CUDA.jl/KernelAbstractions, which is what `downscale.jl` has always done.
#
# It exists to answer one question: when a result looks wrong, is Reactant responsible? Because
# nothing else differs, a vanilla run that reproduces the same wrong answer exonerates the entire
# Reactant stack, and one that does not localizes the fault to it.
#
# Two consequences worth knowing:
#   * No XLA compile. The hours of `first_time_step!`/`step_for!` compilation disappear; the cost
#     becomes ordinary Julia+PTX codegen on the first step, minutes rather than hours.
#   * No fusion, and one kernel launch per operation per step, so the STEP is slower and every
#     `@trace`-related constraint is lifted. `AR_PARENT_UNIFORM_Z=0` is reachable here for the same
#     reason it is reachable under `AR_RAISE=0` — no raise, so no `scf.while` to fail on.
const VANILLA = get(ENV, "AR_ARCH", "reactant") == "cuda"

# ## `AR_NATIVE_PARENT=1`: build the parent the way `downscale.jl` does
#
# Everything below this file's `AR_PARENT=era5` block is a WORKAROUND. The natural call is
# `nested_atmosphere_model(child_grid, dataset; dates, dir, …)`, which builds the parent
# `PrescribedAtmosphere` through Oceananigans on the child grid's architecture — ERA5's true
# per-column geopotential heights, real halos, `parent_padding` defaulting to the dataset's own
# `default_horizontal_padding` (1/2° for ERA5, exactly what the cached files were downloaded with).
# `downscale.jl` has always used it. This file could not: `architecture(child_grid)` is
# `ReactantState()` there, and converting a `per_column_geopotential_discretization` to Reactant
# allocated without bound — OOM-killed at 180 GB (job 4749) where the same parent builds on `CPU()`
# in 33 s. Hence the hand-rolled substitute: read on the host, build a grid at standard-atmosphere
# heights, `copyto!` whole arrays.
#
# Under `AR_ARCH=cuda` that constraint is GONE — `architecture(child_grid)` is `GPU()`, and the
# native constructor is the same one `downscale.jl` runs every day. So this is the direct test of
# the workaround itself: same grid, same physics settings, same dates, only the parent differs.
#
# It matters because the workaround is measurably producing bad forcing data. The Davies relaxation
# and the `Interpolated` open BCs both drive the child toward `exchanger.prognostic`, and on the
# hand-rolled parent those targets carry `ρᵈ` up to 2.76 kg/m³ (impossible for air), 172 non-finite
# values per field, and θ = ρθ/ρᵈ down to 126 K where raw ERA5's minimum is 201 K — and
# `p/(Rᵈ·126) = 2.76` closes the arithmetic, so both extremes are one phenomenon: real air
# interpolated against zeros. Jobs 6707/6709 measured it; `AR_TARGET_PROBE_ONLY=1` re-measures it.
#
# This method also OWNS the initial condition (`initialize_nested_child!` runs inside it), so the
# `AR_IC` branch below is skipped — `AR_BALANCER` still selects whether the DFI balance runs.
#
# `AR_PARENT_KIND` picks the parent explicitly (default `handrolled`, the one built below):
#   * `native`   — NumericalEarth's full-domain `PrescribedAtmosphere` over the padded child box;
#   * `boundary` — NumericalEarth #750's `BoundaryPrescribedAtmosphere`: the parent held only on four
#                  strips covering the boundary and relaxation zone, the Davies relaxation launched over
#                  those strips only, and the IC interpolated from a two-date full-domain snapshot.
# Both use ERA5's true per-column geopotential levels over `AR_PARENT_HOURS + 1` hourly dates.
# `AR_NATIVE_PARENT=1` remains a synonym for `AR_PARENT_KIND=native`.
const PARENT_KIND = Symbol(get(ENV, "AR_PARENT_KIND", get(ENV, "AR_NATIVE_PARENT", "0") == "1" ? "native" : "handrolled"))
PARENT_KIND in (:handrolled, :native, :boundary) ||
    error("AR_PARENT_KIND must be handrolled, native or boundary, got $(PARENT_KIND)")
const NATIVE_PARENT = PARENT_KIND !== :handrolled

## Skipped under AR_ARCH=cuda: this initializes an XLA GPU client, which reserves device memory that
## CUDA.jl would then be competing with for no reason — nothing is compiled through XLA in that mode.
VANILLA || Reactant.set_default_backend(get(ENV, "AR_BACKEND", "cpu"))
Oceananigans.defaults.FloatType = Float32

arch = VANILLA ? GPU() : ReactantState()
smoke = get(ENV, "AR_SMOKE", "0") == "1"

# ## Workgroup alignment (`AR_ALIGN`)
#
# OFF BY DEFAULT, because on the Reactant backend it cannot do what it was written to do. Kept only
# so it is ready the day the upstream cause is fixed. Read this before turning it on.
#
# A KernelAbstractions kernel tagged `DynamicCheck` opens with a `__validindex` guard: index
# arithmetic and an `scf.if` wrapped around the entire body. KA decides the tag by divisibility —
# `dynamic |= mod(ndrange[I], workgroupsize[I]) != 0` in `NDIteration.partition` — and Oceananigans'
# `OffsetKernel` override returns that same flag. So on a normal backend, making `Nx`, `Ny`, `Nz`
# multiples of the workgroup (16) really would drop the guard from most launches.
#
# Reactant throws that flag away:
#
#     # Reactant/ext/ReactantKernelAbstractionsExt.jl
#     KA.mkcontext(kernel::KA.Kernel{ReactantBackend}, _ndrange, iterspace) =
#         KA.CompilerMetadata{KA.ndrange(kernel), KA.DynamicCheck}(_ndrange, iterspace)
#
# `DynamicCheck` is hardcoded. Every kernel traced through Reactant carries the guard no matter what
# the grid is — confirmed directly: a `(1:288, 1:144, 1:1)` ndrange at `(16, 16, 1)` workgroups,
# blocks `(18, 9, 1)`, an exact fit in every dimension, still came out `DynamicCheck`. The whole
# module has `NoDynamicCheck: 0`, and that is upstream, not the grid's doing.
#
# Two independent limits remain even once that is fixed, both measured on the 36×18×50 dump:
#
#   * 567 of 792 launches (72%) would lose the guard with `Nx`, `Ny`, `Nz` all multiples of 16.
#   * The other 225 cannot be fixed by ANY grid size. Center-located fields launch over `N` and
#     Face-located fields over `N+1`, and both appear on every axis (36 and 37, 18 and 19, 50 and
#     51) — consecutive integers are never both multiples of 16. Those need a per-launch workgroup
#     choice, i.e. Oceananigans' `work_layout`, not a grid dimension.
#
# The mechanism, for when it becomes useful: the horizontal is aligned by EXTENDING the east/north
# edge at fixed Δ, preserving spacing and the southwest corner, and a span that already divides
# evenly needs no extension (the `landfall` box is 36° × 18°, so `AR_CELLS_PER_DEGREE=8` lands on
# 288 × 144 exactly). The vertical is aligned by lowering the lid until `length(z)` is a multiple —
# the `z` section below owns that search, since `Nz` is an output of the stretching, not an input.

align = parse(Int, get(ENV, "AR_ALIGN", "0"))
align_up(n, a) = a ≤ 1 ? n : cld(n, a) * a

if align > 1
    Nx_aligned = align_up(Nx, align)
    Ny_aligned = align_up(Ny, align)

    if (Nx_aligned, Ny_aligned) != (Nx, Ny)
        @info @sprintf("AR_ALIGN=%d: extending the child domain east/north to align the horizontal — \
                        %d×%d → %d×%d cells, longitude %.3f→%.3f°E, latitude %.3f→%.3f°N",
                       align, Nx, Ny, Nx_aligned, Ny_aligned,
                       longitude[2], longitude[1] + Nx_aligned * Δ,
                       latitude[2],  latitude[1]  + Ny_aligned * Δ)
    end

    ## A top-level `if` is not a new scope, so these rebind the `case.jl` globals directly.
    longitude = (longitude[1], longitude[1] + Nx_aligned * Δ)
    latitude  = (latitude[1],  latitude[1]  + Ny_aligned * Δ)
    Nx, Ny = Nx_aligned, Ny_aligned
end

# ## Reactant shims
#
# Three small specializations that let today's Oceananigans/NumericalEarth/Breeze trace this model.
# Each one is a candidate to upstream and to delete from here; none changes the physics.

# ## `AR_PATCH_SROA_INSTCOMBINE=1`: let InstCombine erase the dead allocas that block the raise
#
# `@compile` fails with 147 × `cannot raise op to stablehlo … "llvm.alloca" … elem_type = f32`. The
# post-pipeline module (`reactant_dumps/*/module_000_nxc9_post_all_pm.mlir`) shows what is really
# going on, and it is far better than the error suggests:
#
#   * 792 of 792 kernels RAISE — the module holds 793 `func.func` and 147 `affine.parallel`, and not
#     one `enzymexla.kernel_call` survives. `sroa-wrappers` also cleared 3417 → 269 allocas and every
#     one of the 3417 type-punned byte-blob stores.
#   * The 269 survivors are DEAD: across the whole module there are 0 `llvm.load`, 0 `llvm.store` and
#     0 `llvm.call`, and exactly 269 `llvm.intr.lifetime.start` / 269 `llvm.intr.lifetime.end`. Their
#     only remaining users are lifetime markers, so they carry no semantics at all.
#
# Nothing in the pipeline erases them. `canonicalize` will not: `llvm.alloca` has memory effects, so
# it is not trivially dead, and the lifetime intrinsics count as uses. LLVM's InstCombine DOES erase
# an alloca whose only uses are lifetime intrinsics — but Reactant pins both of its `sroa-wrappers`
# invocations to `instcombine=false instsimplify=true`, deliberately, to keep InstCombine's more
# aggressive rewrites away from the raiser (GPUCompiler's own `optimization_options` doc says exactly
# that: "useful e.g. for downstream rewriters like Enzyme that get confused by InstCombine").
#
# So this flips that one flag, in place, with no `Pkg.develop` and no recompile: re-read
# `OptimizationPasses.jl`, string-replace the option, and re-evaluate ONLY the `optimization_passes`
# method into `Reactant.Compiler`. The `const … = Ref(…)` toggles in that file are left untouched,
# since redefining them would error.
#
# MEASURED RESULT: it works, and it is not enough. With the patch the module goes from 269 allocas to
# 0 and the 147 alloca errors disappear — but two further blockers, present all along and merely
# reported second, then surface. Neither is helped by the obvious lever:
#
#   | op in post-pipeline module | baseline | +instcombine | +instcombine, --check-bounds=no,
#   |                            |          |              |  prefer_while_raising=true
#   | llvm.alloca                |   269    |      0       |      0
#   | llvm.intr.trap             |   131    |    131       |    131
#   | scf.while                  |   269    |    269       |    269
#   | affine.parallel            |   147    |    162       |    162
#
#   * `llvm.intr.trap` — Julia's throwing paths, which on device cannot throw and become a trap.
#     `--check-bounds=no` does NOT remove them, so they are not (only) `@boundscheck`.
#   * `scf.while` — a `searchsortedfirst` BINARY SEARCH over the parent's `memref<38xf32>` vertical
#     coordinates, finding the bracketing level for the `Interpolated` lateral boundary. Its trip
#     count depends on loaded data, so it is inherently non-affine, and
#     `raise-affine-to-stablehlo{prefer_while_raising=true}` does not lift it either.
#
# Everything else raises: the module holds 794 `func.func` and no `enzymexla.kernel_call`.
#
# Three upstream asks, in increasing difficulty:
#   1. `raise-affine-to-stablehlo` should ignore an `llvm.alloca` whose only uses are
#      `llvm.intr.lifetime.*` — it is dead, and this alone is a one-pattern fix.
#   2. It should treat `llvm.intr.trap` as an assumed-not-taken error edge rather than an op to lift.
#   3. It needs a genuine data-dependent `while` lowering, or NumericalEarth needs to hoist the
#      vertical interpolation index out of the kernel (the same "decide it on the host" move this
#      script already makes for the terrain, the polar branch and the acoustic substep count).
if get(ENV, "AR_PATCH_SROA_INSTCOMBINE", "0") == "1"
    let path = joinpath(pkgdir(Reactant), "src", "compiler", "OptimizationPasses.jl")
        src = read(path, String)
        patched = replace(src, "instcombine=false instsimplify=true" => "instcombine=true instsimplify=true")
        @assert patched != src "no `instcombine=false instsimplify=true` found in $path"

        found = false
        for ex in Meta.parseall(patched).args
            ex isa Expr && ex.head === :function || continue
            sig = ex.args[1]
            name = sig isa Expr ? (sig.args[1] isa Expr ? sig.args[1].args[1] : sig.args[1]) : nothing
            if name === :optimization_passes
                Core.eval(Reactant.Compiler, ex)
                found = true
            end
        end
        @assert found "could not find `optimization_passes` to re-evaluate"
        @info "AR_PATCH_SROA_INSTCOMBINE: sroa-wrappers will run with instcombine=true"
    end
end

breeze_extension = Base.get_extension(NumericalEarth, :NumericalEarthBreezeExt)

## `AR_FT_FORCING=1` also builds the atmosphere–ocean similarity-theory parameters at the atmosphere's own
## float type: NumericalEarth hard-codes `AtmosphereThermodynamicsParameters(Float64)` for a Breeze
## atmosphere, which makes the coupled-flux kernel (`compute_atmosphere_ocean_interface_state`) ~2400
## f64 instructions long. Upstream fix: `AtmosphereThermodynamicsParameters(eltype(atmos.grid))`.
if get(ENV, "AR_FT_FORCING", "0") == "1"
    @eval NumericalEarth.EarthSystemModels.thermodynamics_parameters(atmos::Breeze.AtmosphereModel) =
        NumericalEarth.Atmospheres.AtmosphereThermodynamicsParameters(eltype(atmos.grid))
end

## 1. Move Breeze's terrain-following vertical coordinate onto Reactant. `on_architecture` for a
##    `LatitudeLongitudeGrid` walks the grid's fields through the extension's private `_to_reactant`,
##    which knows about arrays and the static vertical only.
const ReactantArchitecturesExt = Base.get_extension(Oceananigans, :OceananigansReactantExt).Architectures

ReactantArchitecturesExt._to_reactant(f::LinearDecay) =
    LinearDecay(f.z_top,
                ReactantArchitecturesExt._to_reactant(f.h),
                ReactantArchitecturesExt._to_reactant(f.∂x_h),
                ReactantArchitecturesExt._to_reactant(f.∂y_h))

ReactantArchitecturesExt._to_reactant(z::TerrainFollowingVerticalDiscretization) =
    TerrainFollowingVerticalDiscretization(ReactantArchitecturesExt._to_reactant(z.cᵃᵃᶠ),
                                           ReactantArchitecturesExt._to_reactant(z.cᵃᵃᶜ),
                                           ReactantArchitecturesExt._to_reactant(z.Δᵃᵃᶠ),
                                           ReactantArchitecturesExt._to_reactant(z.Δᵃᵃᶜ),
                                           ReactantArchitecturesExt._to_reactant(z.formulation))

## 2. The state exchanger's per-step job is to slide a 3-level resident window over the parent's time
##    axis and recompute the derived child prognostics when it moves — decided by comparing indices
##    derived from the clock, which is traced here. The parent below carries exactly as many time
##    levels as the window holds, so the window is filled once at construction (`force=true`, outside
##    any trace) and can never move: under tracing there is nothing left to do. Dispatching on the
##    traced time keeps the eager, host-side calls (construction, `update_state!`) on the real path.
NumericalEarth.NestedModels.exchange_state!(::breeze_extension.StateExchanger,
                                           ::Reactant.TracedRNumber) = nothing

## 3. The north/south `default_auxiliary_bc` for a `LatitudeLongitudeGrid` asks whether the boundary
##    sits on a pole — `φnode(...) ≈ ±90` — while building a field's boundary conditions. That is a
##    static property of the grid, but the query happens inside the traced step, where `φnode` returns
##    a `TracedRNumber` and `≈` does not work on one. Not because `isapprox` lacks a method — Base's
##    `isapprox(::Number, ::Number)` matches, since `TracedRNumber <: Number` — but because its keyword
##    body wants `rtol::Real`, and Reactant's `rtoldefault(::Type{<:TracedRNumber})` returns a
##    `TracedRNumber`, which is `<: Number` but NOT `<: Real` (`MethodError: #isapprox#716`, with the
##    mismatch on the rtol slot). Supplying a plain `rtol` only moves the failure one step: Base's body
##    is `x == y || (… && … <= …)`, and `||`/`&&` cannot short-circuit a `TracedRNumber{Bool}`. Even a
##    traced-aware `isapprox` returning `TracedRNumber{Bool}` would not rescue THIS call site, which
##    feeds the answer straight into a ternary. The
##    answer is decided here instead, on the host grid, and asserted rather than assumed: this domain
##    is a mid-latitude LAM, nowhere near a pole, so both sides take the non-polar branch.
##
##    ONE METHOD PER SIDE, not one method taking `Union{Val{:north}, Val{:south}}`. Oceananigans
##    defines the polar check as a separate method per side, so a Union method is more specific than
##    upstream in the GRID argument and less specific in the SIDE argument — neither dominates, and
##    the call is an ambiguity error rather than a dispatch to this shim. Splitting ties the side
##    argument and lets the grid argument decide.
const TracedLatitudeLongitudeGrid = Oceananigans.LatitudeLongitudeGrid{<:Reactant.TracedRNumber}

for side in (:north, :south)
    @eval Oceananigans.BoundaryConditions.default_auxiliary_bc(grid::TracedLatitudeLongitudeGrid,
                                                               ::Val{$(QuoteNode(side))}, loc) =
        Oceananigans.BoundaryConditions._default_auxiliary_bc(Oceananigans.topology(grid, 2)(), loc[2])
end

## 3b. `find_time_index` on a traced clock, without Base's throwing float→Int conversion.
##
##     Pinpointed with MLIR debug locations (`resolve_mlir_locs.jl` over the dumped module): all 131
##     `llvm.intr.trap` ops that `raise-affine-to-stablehlo` refuses resolve to ONE chain,
##
##       float.jl:923  ←  rounding.jl  ←  sort.jl:266  ←  sort.jl:310
##                     ←  Oceananigans field_time_series_indexing.jl:94 ← :66 ← :36
##
##     i.e. `find_time_index(times::StepRangeLen, t)` → `searchsortedfirst(::AbstractRange, t)`, whose
##     O(1) specialization is `n = round(Integer, (x - f) / h + 1)` (`sort.jl:266`). That conversion
##     carries an `InexactError` branch (`float.jl:923`), and a throw cannot unwind on device, so it
##     lowers to a trap. The branch is unreachable in practice — the raiser just cannot know that.
##
##     For a range the index is pure arithmetic: the first `n` with `times[n] ≥ t` is
##     `ceil((t - t₀) / Δ) + 1`. Computing it that way, with the non-throwing `unsafe_trunc`, emits no
##     trap.
##
##     DISPATCH ON `::Real`, NOT ON A TRACED TYPE. This runs INSIDE the halo-fill kernel, where the
##     clock time is an ordinary `Float32` — traced values exist only outside the kernel, so a
##     `TracedRNumber` method never fires and the trap survives (measured: 131 → 131). `::Real` is
##     still strictly more specific than upstream's untyped `t`, so this adds a method rather than
##     overwriting one, and leaves the `DateTime` time-axis path alone.
##
##     Verified against Base over 213 sample times, including exact level hits and out-of-range
##     values: identical to `min(Nt, searchsortedfirst(times, t))` everywhere.
@inline function Oceananigans.OutputReaders.find_time_index(times::StepRangeLen, t::Real)
    Nt = length(times)
    t₀ = first(times)
    Δ  = step(times)

    ## `searchsortedfirst` for a range, then Oceananigans' own `min(Nt, …)` cap, fused.
    n₂ = Base.unsafe_trunc(Int, ceil((t - t₀) / Δ)) + 1
    n₂ = clamp(n₂, 1, Nt)
    n₁ = max(1, n₂ - 1)

    ## `times[n]` on a range is `t₀ + (n-1)Δ`, so a traced index needs no gather.
    t₁ = t₀ + (n₁ - 1) * Δ
    t₂ = t₀ + (n₂ - 1) * Δ

    δt_t1 = Oceananigans.Utils.time_difference_seconds(t, t₁)
    δt_12 = Oceananigans.Utils.time_difference_seconds(t₂, t₁)
    ñ = δt_t1 / δt_12
    ñ = ifelse(n₂ == n₁, zero(ñ), ñ)

    return ñ, n₁, n₂
end

## 3c. Cyclic longitude wrapping without a truncating division.
##
##     With Reactant 0.2.280 the whole MLIR pass pipeline succeeds — 80,692 StableHLO ops, no
##     `enzymexla.kernel_call`, no `affine.for`, no `scf.while`, no `llvm.*` — and the compile then
##     fails at StableHLO → XLA EXPORT on a single op:
##
##       error: 'math.trunc' op unsupported op for export to XLA
##       note:  %957 = "math.trunc"(%956) : (tensor<f64>) -> tensor<f64>
##
##     Exactly one such op in the module. It is Oceananigans' cyclic longitude helper
##     (`Fields/interpolate.jl`):
##
##       find_λ_range(λ) = ifelse((λ < 0) & (mod(λ, 360) != 0), λ ÷ 360 - 1, λ ÷ 360)
##
##     `λ ÷ 360` is a TRUNCATING division, hence `math.trunc`; the surrounding `- 1`/`ifelse` and the
##     `mod(λ, 360) != 0` show up in the IR as the matching `subtract`/`select`/`remainder`.
##
##     That expression is precisely `floor(λ/360)` — truncation and flooring agree for λ ≥ 0, and for
##     λ < 0 the `- 1` correction is applied exactly when the remainder is non-zero, which is the
##     definition of floor. `floor` lowers to `stablehlo.floor`, which exports fine. Checked against
##     the original over 16,022 values in Float32 and Float64, including ±0.0 and exact multiples.
##
##     Dispatching on `::AbstractFloat` adds a method rather than overwriting upstream's, and leaves
##     the `Integer` path (where `÷` is integer division) alone.
##     `AR_LAMBDA_FLOOR=0` disables this, so a Reactant/enzyme-jax build that lowers `math.trunc`
##     itself can be tested without the workaround masking it.
if get(ENV, "AR_LAMBDA_FLOOR", "1") == "1"
    @eval @inline Oceananigans.Fields.find_λ_range(λ::AbstractFloat) = floor(λ / 360)
end

## 4. `time_step!(::NestedModel, Δt)` advances the parent by `Δt_parent = child.clock.time -
##    parent.clock.time` only `if Δt_parent > 0` — a traced comparison. A compiled run steps at a
##    fixed Δt, so parent and child clocks advance in lockstep and the guard is known to hold.
##    NumericalEarth #750 added a `child_callbacks` field (and type parameter) to `NestedModel` — the
##    boundary-strip relaxation runs through it — so the architecture is the 7th parameter there and
##    the 6th before; the callbacks must be passed on as the upstream method does.
const ReactantNestedModel = hasfield(NestedModel, :child_callbacks) ?
    NestedModel{<:Any, <:Any, <:Any, <:Any, <:Any, <:Any, <:ReactantState} :
    NestedModel{<:Any, <:Any, <:Any, <:Any, <:Any, <:ReactantState}

nested_child_callbacks(nest) = hasfield(typeof(nest), :child_callbacks) ? nest.child_callbacks : ()

function Oceananigans.TimeSteppers.time_step!(nest::ReactantNestedModel, Δt; callbacks = (), kw...)
    NumericalEarth.NestedModels.exchange_state!(nest.exchanger, nest.clock.time + Δt)
    time_step!(nest.child, Δt; callbacks = (callbacks..., nested_child_callbacks(nest)...), kw...)
    time_step!(nest.parent, Δt)
    return nothing
end

## 6. `set!(dst, src)` between two Reactant fields at DIFFERENT locations (here Breeze's
##    `set_velocity!` writing our Center-located `u` into the model's Face-located velocity) takes
##    Oceananigans' CPU interpolation fallback in `OceananigansReactantExt.Fields.set_to_field!`,
##    because `interpolate!`'s KA kernel does not trace. That fallback stages the source on the host
##    with
##
##        copyto!(interior(cpu_v), interior(v))
##
##    — a `SubArray`-to-`SubArray` copy whose source is device-backed. Base's `copyto!` first calls
##    `unalias`/`mightalias`, which reaches
##
##        _parentsmatch(A::DenseArray, B::DenseArray) = elsize(A) == elsize(B) && pointer(A) == …
##
##    and `ConcretePJRTArray <: DenseArray`, so it asks a PJRT buffer for a host pointer:
##    `ERROR: conversion to pointer not defined for ConcretePJRTArray{Float32, 3, 1}`.
##
##    Only this DIRECTION is broken. The mirror-image write in `set_to_function!`
##    (`copyto!(interior(u), interior(cpu_u))`, host source into a device destination) is what the
##    analytic initial condition uses on the GPU today, so Reactant specializes writes INTO a device
##    `SubArray` but leaves reads OUT of one to Base's generic path.
##
##    So change only the read, to the whole-parent transfer that is already used elsewhere here:
##    `Array(parent(v))` materializes the buffer in one shot (no aliasing check, no element loop),
##    and the halo cells it carries along are strictly more than the interior-only copy gave
##    `interpolate!`. The write-back is left exactly as upstream has it.
##
##    This belongs upstream in Oceananigans; it is patched here to avoid `dev`ing it.
const ReactantFieldsExt = Base.get_extension(Oceananigans, :OceananigansReactantExt).Fields

## Oceananigans renamed this predicate `broadcast_compatible` → `copyable_fields` ("Name the
## copy-versus-interpolate cases and share them with Reactant", #5878), which broke this shim with an
## `UndefVarError` the moment the environment drifted to a newer version (job 5143, killed at the
## initial condition). Resolve whichever name the LOADED version has, so the shim survives the rename
## in both directions instead of pinning the project to one Oceananigans.
const AR_COPYABLE = isdefined(ReactantFieldsExt, :copyable_fields)      ? :copyable_fields :
                    isdefined(ReactantFieldsExt, :broadcast_compatible) ? :broadcast_compatible :
                    error("neither `copyable_fields` nor `broadcast_compatible` is defined in the \
                           Oceananigans Reactant extension — shim 6 needs updating")

@eval ReactantFieldsExt function set_to_field!(u::ReactantField, v::ReactantField)
    if $(AR_COPYABLE)(u, v)
        interior(u) .= interior(v)
    else
        cpu_grid_u = on_architecture(CPU(), u.grid)
        cpu_grid_v = on_architecture(CPU(), v.grid)
        cpu_u = Field(Oceananigans.Fields.instantiated_location(u), cpu_grid_u;
                      indices=Oceananigans.Fields.indices(u))
        cpu_v = Field(Oceananigans.Fields.instantiated_location(v), cpu_grid_v;
                      indices=Oceananigans.Fields.indices(v))
        copyto!(parent(cpu_v), Array(parent(v)))
        ## The generic `set_to_field!` fills v's halos before interpolating (they are read by the
        ## boundary-adjacent stencils); the Reactant extension skipped that, interpolating from
        ## halos left at zero. Fill them on the CPU twin — same result as upstream for
        ## non-distributed boundary conditions, and no device kernel.
        Oceananigans.BoundaryConditions.fill_halo_regions!(cpu_v)
        interpolate!(cpu_u, cpu_v)
        copyto!(interior(u), interior(cpu_u))
    end
    return u
end

## 7. `set!(field, ::AbstractOperation)` — Breeze's `set_velocity!` does `set!(ρu, ρ * u)`, and ρ
##    (Center) has to be interpolated to ρu's Face location, so the operation carries a real `ℑxᶠᵃᵃ`
##    and CANNOT be flattened into a `parent` broadcast the way the same-location ρ·qᵛᵉ writes were.
##    Oceananigans' generic `set!(u::Field, v) = (u .= v)` broadcasts it, which launches
##    `gpu__broadcast_kernel!` over a `BinaryOperation` whose grid has been retyped to
##    `CuTracedRNumber{Float32}` — and that kernel does not compile:
##
##        InvalidIRError: compiling … gpu__broadcast_kernel!(… BinaryOperation{Face, Center, Center,
##          *, …, ℑxᶠᵃᵃ, identity5, LatitudeLongitudeGrid{CuTracedRNumber{Float32}, …}} …)
##
##    This is the same "KA kernel + materialized grid coordinates" wall as everywhere else, but here
##    the answer is not to hand-write the stencil: `on_architecture` is defined for every operation
##    node (binary, unary, multiary, kernel-function, derivative, conditional) and for `Field`, so the
##    WHOLE operation tree — operands, interpolation operators and grid — can be rebuilt on the CPU
##    and evaluated by Oceananigans' own code. That keeps `ℑxᶠᵃᵃ` exactly as upstream defines it
##    rather than reimplementing it here, where a wrong averaging stencil would be a silent physics
##    bug rather than an error.
##
##    Hooking `set!` (not `set_to_field!`) catches every operation-valued `set!` in Breeze and
##    NumericalEarth at one point, instead of patching each call site as it is discovered.
##
##    Eager-only, like the CPU fallbacks it mirrors: mid-trace there is no host data to move, but
##    every one of these calls happens during initialization, outside `@compile`.
@eval ReactantFieldsExt function Oceananigans.Fields.set!(u::ReactantField,
                                                          v::Oceananigans.AbstractOperations.AbstractOperation)
    cpu_grid = on_architecture(CPU(), u.grid)
    cpu_u = Field(Oceananigans.Fields.instantiated_location(u), cpu_grid;
                  indices=Oceananigans.Fields.indices(u))
    cpu_v = on_architecture(CPU(), v)
    cpu_u .= cpu_v
    copyto!(interior(u), interior(cpu_u))
    return u
end

## 8. `set!(model; compute_reference_state=true)` — which `initialize_nested_child!` passes — calls
##    `reset_reference_state!`, and on a terrain-following model that whole path is out of reach
##    under Reactant. Three independent blockers, not one:
##
##      a. `horizontal_mean_profile` opens with `minimum!(z̄, KernelFunctionOperation(physical_heightᶜᶜᶜ))`.
##         Traced, that reduction reaches Oceananigans' ARRAY-mode `rnode(i::AbstractArray, j::AbstractArray, …)`,
##         which assumes `rnode(k, grid, ℓz)` is a vector: it stacks it twice and calls
##         `permutedims(toperm, (3, 2, 1))`. Here `k` arrives as a 3-D index array, so `toperm` is
##         5-D and the permutation is rejected — `ArgumentError: no valid permutation of dimensions`.
##      b. The next line of the same function is `launch!(arch, grid, :xy, _interpolate_columns_to_heights!, …)`.
##      c. `compute_terrain_reference_state!` ends in `launch!(arch, grid, :xy, _compute_terrain_reference_state!, …)`.
##
##    (b) and (c) are the usual KA-kernel-on-a-materialized-coordinate-grid wall, so repairing (a)
##    would only move the failure one line down.
##
##    Skipping is sound rather than merely expedient, and Breeze says so itself in
##    `compressible_dynamics.jl`: with the default `AutoReference()` the reference is built from the
##    standard 288 K profile and is "usable immediately after model construction";
##    `compute_reference_state=true` REPLACES it with one deduced from the initial state's
##    height-resolved horizontal mean. So the recompute sharpens the reference/perturbation split —
##    better conditioning for the pressure-gradient and buoyancy tendencies — but the model is
##    well-defined without it. The analytic-IC run that compiled and stepped never called it either
##    (it bypasses Breeze's `set!` entirely), so skipping puts the interpolated IC on exactly the
##    same footing as the configuration already known to work.
##
##    `AR_REFERENCE_STATE=1` restores the real call, for testing once upstream can trace it.
##    Not installed under `AR_ARCH=cuda`: nothing there is a Reactant grid, and the copied upstream
##    body below is a drift hazard (it broke once when Breeze 0.11 renamed `surface_pressure` →
##    `base_pressure` and added `ref.surface_pressure` to the call), so the control run should see
##    Breeze's own method.
if get(ENV, "AR_REFERENCE_STATE", "0") != "1" && !VANILLA
    @eval Breeze.CompressibleEquations function AtmosphereModels.reset_reference_state!(model::TerrainCompressibleModel)
        if Oceananigans.Architectures.architecture(model.grid) isa Oceananigans.Architectures.ReactantState
            @info "reset_reference_state!: SKIPPED on a Reactant grid — keeping the constructor's \
                   standard-288 K AutoReference (AR_REFERENCE_STATE=1 to attempt the recompute)"
            return nothing
        end

        ## Upstream body (Breeze 0.11, `terrain_compressible_physics.jl`), so a CPU model still gets
        ## the real reference state. Re-check against upstream whenever Breeze moves.
        dynamics = model.dynamics
        ref = dynamics.reference_state
        ref === nothing && return nothing

        ref_spec = terrain_reference_mean_profiles(model)
        compute_terrain_reference_state!(ref.pressure, ref.density, ref.exner_function,
                                         ref.surface_pressure, model.grid,
                                         base_pressure(dynamics),
                                         ref_spec,
                                         standard_pressure(dynamics),
                                         model.thermodynamic_constants)
        return nothing
    end
end

## 9. `enzymexla.math.fmuladd` has no lowering in the EAGER kernel path.
##
##    Oceananigans writes every advection reconstruction stencil with `@muladd`, so the centered,
##    upwind-biased and WENO interpolations all contain `Base.muladd`. CUDACore overrides that for
##    the device with `ccall("llvm.fmuladd.f32", …)`, which becomes `enzymexla.math.fmuladd` in MLIR:
##
##        CompilationError: MLIR pass pipeline "all" failed
##        error: Failed to lower enzymexla math operation
##          note: see current operation: "enzymexla.math.fmuladd"(…) : (f32, f32, f32) -> f32
##
##    Only the EAGER path is affected — `first_time_step!` compiles these same stencils fine inside
##    an explicit `@compile` (2512 s in run 4683). `minrepro_fmuladd.jl` reduces it to one `muladd`
##    in one KA kernel, no Oceananigans involved.
##
##    That matters here because `balance_adiabatically!` (AR_BALANCER=1) calls `time_step!(model, ±Δt)`
##    four times per cycle OUTSIDE any trace, and each of those computes momentum-advection
##    tendencies. Without this the balancer cannot run at all.
##
##    Replacing the override with the unfused `x * y + z` is within `muladd`'s contract — the docs
##    define it as computing `x * y + z` with the fusion left to the implementation, which is exactly
##    why `@device_override` is allowed to substitute an FMA in the first place. The cost is one
##    extra rounding step per stencil term; the CPU reference Oceananigans runs against makes no FMA
##    guarantee either.
##
##    `AR_FMULADD_FIX=0` restores CUDACore's FMA override, for testing once enzymexla can lower it.
##    Off by default under `AR_ARCH=cuda`: no Reactant kernel runs there, so the override would only
##    de-fuse every stencil of the production run (≈2% of the GPU step on an A100, job 2266).
if get(ENV, "AR_FMULADD_FIX", VANILLA ? "0" : "1") == "1"
    ## CUDACore is a transitive dependency (of CUDA.jl), so `import CUDACore` fails; reach it through
    ## the loaded-module table. `@device_override` is CUDACore's own macro, so evaluating inside that
    ## module resolves it, and the identical signature replaces the overlay entry in place.
    let CUDACore = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "CUDACore")
        @eval CUDACore @device_override Base.muladd(x::Float32, y::Float32, z::Float32) = x * y + z
    end
    ## `@info`, not `stage`: the shims run above `stage`'s own definition.
    @info "muladd: CUDACore's Float32 FMA device override replaced with x * y + z " *
          "(eager kernels cannot lower enzymexla.math.fmuladd)"
end

## 10. The adiabatic balancer's AUTO Δt cannot be evaluated on a traced terrain grid.
##
##     `balance_adiabatically!` derives its step as `0.85 · Δz_min / c` via
##     `resolve_balance_Δt(::Nothing, model)`, and `minimum_zspacing(grid)` builds a
##     `KernelFunctionOperation` over `Δz`. Reduced under Reactant, `eval_kernel_function` feeds it
##     INDEX ARRAYS rather than scalars, so Breeze's `terrain_following_σ` — written for scalar
##     `(i, j, k)` — evaluates `1 + σ` with σ a 2-D traced array:
##
##         MethodError: no method matching +(::Int64, ::Reactant.TracedRArray{Float32, 2})
##
##     Same shape of failure as the `rnode`/`permutedims` one in shim 8: a scalar stencil function
##     reached through an array-mode evaluation it was never written for.
##
##     `resolve_balance_Δt(Δt, model) = Δt` means an explicit number bypasses all of it, so the fix
##     is to source the SAME formula from the host rather than to invent a step size:
##
##       * Δz_min from a CPU twin of the grid — `on_architecture(CPU(), grid)` — where
##         `minimum_zspacing` evaluates with ordinary arrays, exactly as it does for a CPU run.
##       * T★ = max temperature, read back with the whole-parent transfer used elsewhere here.
##         Taken over the parent (halos included): temperature is positive, so halo zeros cannot
##         raise the maximum, and any halo garbage would only RAISE T★ ⇒ raise c ⇒ SHORTEN Δt,
##         which errs toward the conservative side of the acoustic CFL.
##
##     The constants and the 0.85 safety factor are Breeze's own, so the resulting step is the one
##     Breeze would have chosen; only the two reductions move to the host.
if get(ENV, "AR_BALANCER", "0") == "1"
    @eval Breeze.AtmosphereModels function resolve_balance_Δt(::Nothing, model)
        grid      = model.grid
        constants = model.thermodynamic_constants
        Rᵈ  = Thermodynamics.dry_air_gas_constant(constants)
        cᵖᵈ = constants.dry_air.heat_capacity
        cᵛᵈ = cᵖᵈ - Rᵈ
        γᵈ  = cᵖᵈ / cᵛᵈ

        T★ = maximum(Array(parent(model.temperature)))
        c  = sqrt(γᵈ * Rᵈ * T★)

        cpu_grid = Oceananigans.Architectures.on_architecture(Oceananigans.Architectures.CPU(), grid)
        Δt = convert(eltype(grid), acoustic_cfl_safety * minimum_zspacing(cpu_grid) / c)
        @info "adiabatic balancer: host-decided Δt = $Δt s (T★ = $T★ K, c = $c m/s)"
        return Δt
    end
end

# ### Shim 11 (`AR_FTS_UNION_FIX`, default on): make `FieldTimeSeries` time interpolation
# ### type-stable, so the reverse sweep has something differentiable to work with
#
# This is the shim that makes `AR_AD=1` possible at all. Found by walking the `loc` table of the
# failed AD compile's module (job 4782) rather than by guessing — the chain is recorded below so it
# can be re-checked when Oceananigans changes.
#
# Oceananigans interpolates a `FieldTimeSeries` in time with (`OutputReaders/field_time_series_indexing.jl`,
# TWO sites — `interpolating_getindex` and the `FractionalIndices` method of `Fields.interpolate`):
#
#     ψ̃ = ψ₂ * ñ + ψ₁ * (1 - ñ)
#     return ifelse(n₁ == n₂, ψ₁, ψ̃)      # "don't interpolate if n₁ == n₂"
#
# `ψ₁, ψ₂` are the field's `Float32` samples, but `ñ` — the fractional time index — is built from
# `fts.times`, which are `Float64`. So `ψ̃ :: Float64` while `ψ₁ :: Float32`, and the two branches of
# that `ifelse` have DIFFERENT TYPES: the expression is a `Union{Float32, Float64}`.
#
# Julia stores such a union as a 64-bit payload plus a type tag, and that is exactly what the compiled
# module contains — one 64-bit slot holding either an f32 or an f64:
#
#     %1937 = stablehlo.compare NE, %1599, %1600, SIGNED : (tensor<i64>, tensor<i64>) -> tensor<i1>
#     …
#     %1965 = stablehlo.select %1937, <low half of the f64>, <bits of the f32>   : i32
#     %1966 = stablehlo.select %1937, <high half of the f64>, 0                  : i32
#     %1970 = stablehlo.shift_left %1969, 32
#     %1972 = stablehlo.add %1970, %1971
#     %1973 = stablehlo.bitcast_convert %1972 : i64 -> f64
#
# `%1937` is the type tag, and it is `n₁ != n₂` — a comparison of two scalar `Int64` time indices,
# uniform over the whole grid, which is why it is a `tensor<i1>` and not a per-cell mask.
#
# The FORWARD pass compiles this fine (it is just integer shuffling). The reverse pass cannot:
#
#     error: could not compute the adjoint for this operation
#       "stablehlo.bitcast_convert" / "stablehlo.shift_left" / "stablehlo.shift_right_logical"
#
# and no general adjoint is possible, because the bitcasts erase the floating-point structure Enzyme
# would differentiate through. This is a type instability that XLA happily compiles and AD cannot.
#
# One root cause, two consumers — the `loc` chains bottom out in the same tag `%1937`:
#
#     Davies relaxation   * (float.jl) → * (operators.jl) → Relaxation (Forcings/relaxation.jl)
#                         → x_momentum_tendency / potential_temperature_tendency (Breeze)
#                         → gpu_compute_*_tendency! → enzymexla.kernel_call
#
#     Open boundaries     / (float.jl) → / (promotion.jl) → left_gradient
#                         → _fill_west_halo! (BoundaryConditions/fill_halo_regions_value_gradient.jl)
#                         → gpu__fill_west_and_east_halo!
#
# The fix is to give the `ifelse` two branches of the SAME type. `oftype(ψ̃, ψ₁)` widens the
# exact-hit branch to match the interpolated one, which is value-preserving in the strictest sense:
# `Float32 → Float64` is exact, and the interpolating branch was already `Float64`, so no number this
# code produces changes. Only the union disappears.
#
# `AR_FTS_UNION_FIX=2` narrows instead of widening: `ñ` is converted to the sample's own type first,
# so `ψ̃` is `Float32` and the union closes from the other side. That ALSO deletes every `f64` op from
# these kernels, which is worth real time on a T4 (FP64 runs at 1/32 rate) — but it changes the
# interpolation weight's precision, so it is a numerics change rather than a pure representation
# change and is not the default. Against hourly ERA5 samples the difference is far below the data's
# own precision. Note the Float64 `relaxation_rate = 1/300` / `damping_rate = 1/5` further down still
# promote the product back to Float64; `1/300f0` and `1/5f0` would finish the job.
#
# `AR_FTS_UNION_FIX=0` restores upstream's definitions, which is how to confirm the blocker is still
# this and not something new.
#
# Upstream fix: either branch of this shim, applied at both sites.

## `AR_FT_FORCING=1` keeps the nest's forcing parameters at the grid's float type: the FTS time weight is
## narrowed (shim-11 mode 2 unless `AR_FTS_UNION_FIX` is set), and the Davies `relaxation_rate`, the lid
## sponge's `damping_rate` and the `UpperSponge` rate become `Float32`. With the defaults these are `Float64`
## and every forced tendency kernel (ρθ, ρu, ρv, ρqᵉ, ρw) and every open-boundary halo fill does its
## time interpolation and relaxation in f64 (perf/PROFILE_REPORT.md item 16; agent OPT-KERNEL).
ft_forcing = get(ENV, "AR_FT_FORCING", "0") == "1"
fts_union_fix = parse(Int, get(ENV, "AR_FTS_UNION_FIX", ft_forcing ? "2" : "1"))

if fts_union_fix != 0
    const OceanOutputReaders = Oceananigans.OutputReaders

    ## Mode 1 widens the exact-hit branch to the interpolated branch's type (exactly value-preserving);
    ## mode 2 narrows the weight to the sample's type, so both branches are the field's own eltype.
    ## Defined as a function so the two rewritten methods below share one policy.
    @eval OceanOutputReaders begin
        @inline _ar_close_union(::Val{1}, ψ₁, ψ̃) = (oftype(ψ̃, ψ₁), ψ̃)
        @inline _ar_close_union(::Val{2}, ψ₁, ψ̃) = (ψ₁, oftype(ψ₁, ψ̃))
    end
    @eval OceanOutputReaders const _AR_UNION_MODE = Val($(fts_union_fix))

    ## Both redefinitions are upstream's bodies verbatim except for the `oftype` on the exact-hit
    ## branch, so they stay easy to diff against a future Oceananigans.
    ## Upstream refactored `interpolating_getindex` into a thin wrapper over
    ## `time_interpolated_getindex` and moved the union-producing `ifelse` into the latter ("Read a
    ## FieldTimeSeries at a cell with a precomputed TimeInterpolator", #5886). That new function has
    ## TWO callers — the `Time` path and the precomputed-`TimeInterpolator` path — so patching IT
    ## covers both, where patching the old wrapper would now silently miss the second.
    if isdefined(OceanOutputReaders, :time_interpolated_getindex)
        @eval OceanOutputReaders @inline function time_interpolated_getindex(fts, i, j, k, ñ, n₁, n₂)
            @inbounds begin
                ψ₁ = getindex(fts, i, j, k, n₁)
                ψ₂ = getindex(fts, i, j, k, n₂)
            end
            ñ′ = _AR_UNION_MODE === Val(2) ? oftype(ψ₁, ñ) : ñ
            ψ̃ = ψ₂ * ñ′ + ψ₁ * (1 - ñ′)
            return ifelse(n₁ == n₂, _ar_close_union(_AR_UNION_MODE, ψ₁, ψ̃)...)
        end
    else
        ## Older Oceananigans: the arithmetic still lives in `interpolating_getindex` itself.
        @eval OceanOutputReaders @inline function interpolating_getindex(fts, i, j, k, time_index)
            ñ, n₁, n₂ = interpolating_time_indices(fts.time_indexing, fts.times, time_index.time)
            @inbounds begin
                ψ₁ = getindex(fts, i, j, k, n₁)
                ψ₂ = getindex(fts, i, j, k, n₂)
            end
            ñ′ = _AR_UNION_MODE === Val(2) ? oftype(ψ₁, ñ) : ñ
            ψ̃ = ψ₂ * ñ′ + ψ₁ * (1 - ñ′)
            return ifelse(n₁ == n₂, _ar_close_union(_AR_UNION_MODE, ψ₁, ψ̃)...)
        end
    end

    @eval OceanOutputReaders @inline function Fields.interpolate(fi::FractionalIndices,
                                                                time_indices::TimeInterpolator,
                                                                data::AbstractArray, backend, time_indexing)
        ñ  = time_indices.fractional_index
        n₁ = convert(Int, time_indices.first_index)
        n₂ = convert(Int, time_indices.second_index)
        Nt = convert(Int, time_indices.length)

        ix = interpolator(fi.i)
        iy = interpolator(fi.j)
        iz = interpolator(fi.k)

        m₁ = memory_index(backend, time_indexing, Nt, n₁)
        m₂ = memory_index(backend, time_indexing, Nt, n₂)

        ψ₁ = _interpolate(data, ix, iy, iz, m₁)
        ψ₂ = _interpolate(data, ix, iy, iz, m₂)
        ñ′ = _AR_UNION_MODE === Val(2) ? oftype(ψ₁, ñ) : ñ
        ψ̃ = ψ₂ * ñ′ + ψ₁ * (1 - ñ′)

        return ifelse(n₁ == n₂, _ar_close_union(_AR_UNION_MODE, ψ₁, ψ̃)...)
    end

    @info "shim 11: FieldTimeSeries time interpolation made type-stable — mode $(fts_union_fix) " *
          "($(fts_union_fix == 1 ? "widen exact-hit branch to Float64, value-preserving" : "narrow weight to the sample eltype")); no Float32/Float64 union"
end

# ### Shim 12: an RRTMGP ClimaComms context for `ReactantState`
#
# `RadiativeTransferModel(grid, …)` calls `rrtmgp_context(architecture(grid))`, and
# `BreezeRRTMGPExt` defines that for `CPU` and `GPU` only:
#
#     MethodError: no method matching rrtmgp_context(::ReactantState)
#
# So radiation fails at CONSTRUCTION, before any of the tracing that Breeze's `@trace`d
# `update_radiation!` fix addresses (job 4840). Two independent blockers, one after the other.
#
# The context tells RRTMGP which device to allocate its lookup tables and solver workspace on. `CPU()`
# is the right answer here, for a reason specific to this setup rather than as a fallback: the GPU
# context is `ClimaComms.context(ClimaComms.CUDADevice())`, which allocates `CuArray`s through CUDA.jl
# — but Reactant executes through its own PJRT plugin and `CUDA.functional()` is FALSE on these nodes
# (CUDA.jl's JLLs were precompiled without a driver; see the caveats up top). Reactant's arrays are
# not `CuArray`s either, so a CUDA context would allocate the wrong array type even where it worked.
#
# !!! warning "This may only move the failure"
#     The tables then live in HOST arrays while the traced solve wants traced ones, so the next
#     failure may be inside `_update_radiation!` rather than at construction. That is worth finding
#     out — it is three lines to try and the alternative is not running radiation at all — but do not
#     read a successful `RadiativeTransferModel(...)` as radiation working end to end.
let rrtmgp_ext = Base.get_extension(Breeze, :BreezeRRTMGPExt)
    if isnothing(rrtmgp_ext)
        @warn "BreezeRRTMGPExt is not loaded; AR_RADIATION=1 will fail"
    else
        ## INTERPOLATE the types rather than naming them by module path: `@eval` evaluates in
        ## `BreezeRRTMGPExt`, which does not bind `Oceananigans`, so a qualified path there is an
        ## `UndefVarError` (jobs 4841/4842). `$(...)` splices the type objects from THIS module, where
        ## they are in scope.
        RS = Oceananigans.Architectures.ReactantState
        OceanCPU = Oceananigans.Architectures.CPU
        @eval rrtmgp_ext rrtmgp_context(::$RS) = rrtmgp_context($OceanCPU())
        @info "shim 12: rrtmgp_context(::ReactantState) → the CPU ClimaComms context"
    end
end

# ## LAM grid
#
# Identical to `downscale.jl`: 60 m surface spacing, 490 m maximum, top at ~20 km, over the `case.jl`
# domain at `AR_CELLS_PER_DEGREE` cells per degree (default 9, i.e. ~12 km).
#
# `Nz` is an OUTPUT of the stretching, not an input, so `AR_ALIGN` cannot simply round it — it lowers
# the lid until the level count lands on a multiple. The search walks down from `AR_Z_EXTENT` in 25 m
# steps, keeping every other stretching parameter fixed, so the spacing profile is untouched and only
# the top few levels are given up: 19525 m → 19000 m takes 50 levels to 48. The lid stays far below
# the parent's 70 hPa top (~22.5 km), which is the constraint that actually matters.

vertical_discretization(extent) =
    ReferenceToStretchedDiscretization(; extent,
                                       bias = :left,
                                       bias_edge = 0,
                                       constant_spacing = 60,
                                       constant_spacing_extent = 60,
                                       maximum_spacing = 490,
                                       stretching = LinearStretching(0.15))

z_extent = parse(Float64, get(ENV, "AR_Z_EXTENT", "19525.0"))
z = vertical_discretization(z_extent)

if align > 1 && length(z) % align != 0
    aligned_extent = findfirst(e -> length(vertical_discretization(e)) % align == 0,
                               z_extent:-25.0:max(z_extent - 5000, 1000.0))

    if isnothing(aligned_extent)
        @warn "AR_ALIGN=$align: no lid within 5 km below $(z_extent) m gives a level count that is a \
               multiple of $align — leaving Nz = $(length(z)), so the vertical stays `DynamicCheck`."
    else
        e = (z_extent:-25.0:max(z_extent - 5000, 1000.0))[aligned_extent]
        @info @sprintf("AR_ALIGN=%d: lowering the lid %.0f → %.0f m to align the vertical — %d → %d levels",
                       align, z_extent, e, length(z), length(vertical_discretization(e)))
        z = vertical_discretization(e)
    end
end

Nz = length(z)

# ## Idealized orography (in place of ETOPO2022)
#
# A coastal range and a taller Cascade ridge, both fading away from mid-latitudes, plus an interior
# plateau east of ~115°W. The whole field is tapered to zero over an outer frame of physical width
# `AR_BLEND_LENGTH` — the same role the parent-orography blend plays in `downscale.jl`: at the open
# boundaries the child's ground must agree with the parent's, and this parent (like ERA5's
# pressure-level product read without surface geopotential) is flat.

terrain_blend_length = parse(Float64, get(ENV, "AR_BLEND_LENGTH", "60000"))
taper_degrees = terrain_blend_length / 111e3

λ₁, λ₂ = longitude
φ₁, φ₂ = latitude

@inline bump(x, x₀, w) = exp(-((x - x₀) / w)^2)

@inline function orography(λ, φ)
    midlatitude_band = bump(φ, 46.5, 9.0)
    coastal  =  900 * bump(λ, -123.9, 0.55) * midlatitude_band
    cascades = 2000 * bump(λ, -121.3, 0.90) * midlatitude_band
    interior = 1400 * (1 + tanh((λ + 115) / 3)) / 2 * bump(φ, 45.0, 14.0)
    return coastal + cascades + interior
end

# ## `AR_TERRAIN=etopo`: real orography
#
# The ridges above are straight north–south bumps: the Coast Range at -123.9°, the Cascades at
# -121.3°, no Olympics, no Willapa Hills, no Columbia Gorge. Fine for a configuration twin, wrong for
# anything that cares WHERE rain falls. `AR_TERRAIN=etopo` instead regrids ETOPO2022 onto the child's
# cell centres (land only, ocean → 0) and smooths it with `AR_TERRAIN_SMOOTHING` binomial passes
# (default 2, as in `downscale.jl`) — done once on the host, so the Reactant path takes it too. The
# same frame taper applies: the hand-rolled parent is flat, so the ground must reach 0 at the walls.
# The ETOPO file must already be in NumericalEarth's scratchspace (~480 MB, downloaded otherwise).
terrain_source = get(ENV, "AR_TERRAIN", "etopo")
terrain_source in ("analytic", "etopo") || error("AR_TERRAIN must be analytic or etopo, got $(terrain_source)")

if terrain_source == "etopo"
    etopo_grid = LatitudeLongitudeGrid(CPU(); longitude, latitude, size = (Nx, Ny), halo = (5, 5),
                                       topology = (Bounded, Bounded, Flat))
    etopo_field = regrid_topography(etopo_grid; dataset = ETOPO2022())
    smooth_topography!(etopo_field; passes = parse(Int, get(ENV, "AR_TERRAIN_SMOOTHING", "2")))
    const etopo_elevation = Array(interior(etopo_field, :, :, 1))
    ## Nearest cell centre: every caller (materialize_terrain!, the SST land mask) evaluates at
    ## centres of this same grid, so this is exact there.
    @inline function orography(λ, φ)
        i = clamp(round(Int, (λ - λ₁) / Δ + 0.5), 1, Nx)
        j = clamp(round(Int, (φ - φ₁) / Δ + 0.5), 1, Ny)
        return @inbounds etopo_elevation[i, j]
    end
    @info @sprintf("AR_TERRAIN=etopo: ETOPO2022 on the child grid, max %.0f m", maximum(etopo_elevation))
end

@inline function terrain_elevation(λ, φ)
    wall_distance = min(λ - λ₁, λ₂ - λ, φ - φ₁, φ₂ - φ)
    s = clamp(wall_distance / taper_degrees, 0, 1)
    frame_taper = s^2 * (3 - 2s)     # smoothstep: 0 at the wall, 1 inside the frame
    return frame_taper * orography(λ, φ)
end

## The terrain is materialized on a CPU twin and the finished grid is moved to Reactant: the
## slope kernels then run on the host, where they are cheap, once.
host_grid = LatitudeLongitudeGrid(CPU();
                                  longitude, latitude,
                                  z = TerrainFollowingVerticalDiscretization(z),
                                  size = (Nx, Ny, Nz),
                                  halo = (5, 5, 5),
                                  topology = (Bounded, Bounded, Bounded))

# AR_FLAT_TERRAIN=1: zero the orography (diagnostic). Isolates whether the ERA5-interior bottom-corner
# blow-up is driven by the terrain / frame-taper-to-zero mismatch (flat ⇒ stable) or something else.
flat_terrain = get(ENV, "AR_FLAT_TERRAIN", "0") == "1"
materialize_terrain!(host_grid, flat_terrain ? ((λ, φ) -> zero(λ)) : terrain_elevation)
flat_terrain && @info "AR_FLAT_TERRAIN=1: orography zeroed (diagnostic; not a physical downscale)"

# A native parent knows its own surface elevation, so the child's ground is the UNTAPERED orography
# blended toward the parent's over the frame — what `nested_atmosphere_model(…; terrain)` does — rather
# than tapered to zero as for the flat hand-rolled parent. Done here, on the host twin, before the grid
# moves to the device, so the eager CUDA and the Reactant paths get identical terrain. The parent's
# surface elevation comes from a two-date full-domain snapshot (the box the native parent reads).
## The native parents read ERA5 through `download(::MetadataSet)`, whose method lives in the
## CopernicusClimateDataStore extension (cached files make no requests; see the ERA5 block below).
NATIVE_PARENT && get(ENV, "AR_LOAD_CDS", "1") == "1" && @eval import CopernicusClimateDataStore

if NATIVE_PARENT && !flat_terrain
    let ext = Base.get_extension(NumericalEarth, :NumericalEarthBreezeExt),
        padding = parse(Float64, get(ENV, "AR_NATIVE_PADDING", "0.5")),
        snapshot = PrescribedAtmosphere(BoundingBox(host_grid; padding), start_date:Hour(1):(start_date + Hour(1)),
                                        ERA5HourlyPressureLevels(); architecture = CPU(), dir = era5_datadir),
        elevation = Field{Center, Center, Nothing}(host_grid),
        blend_width = ext.default_terrain_blend_width(host_grid, terrain_blend_length)

        set!(elevation, (λ, φ) -> orography(λ, φ))
        ## NumericalEarth #750 takes the parent's surface elevation; earlier versions the parent itself.
        surface = isdefined(NumericalEarth.Atmospheres, :BoundaryPrescribedAtmosphere) ?
                  NumericalEarth.surface_elevation(snapshot) : snapshot
        ## `orography` is ETOPO already smoothed by AR_TERRAIN_SMOOTHING; don't smooth it twice.
        smoothing = terrain_source == "etopo" ? 0 : parse(Int, get(ENV, "AR_TERRAIN_SMOOTHING", "2"))
        ext.materialize_nested_terrain!(host_grid, elevation, surface, blend_width, smoothing)
        @info @sprintf("native parent: child terrain blended toward the ERA5 surface over %d cells", blend_width)
    end
end

# `AR_TERRAIN_PATCH=<file.jld2>`: write the terrain into an existing snapshot file and exit.
#
# On a terrain-following grid `grid/z_center` is only a REFERENCE coordinate — the physical height of
# a cell is `rnode(k) + terrain_following_Δz_surface(i, j, k)` — so a snapshot file without the
# terrain cannot be mapped back to physical heights. This repairs a file written before the terrain
# extraction was fixed, and reuses the terrain built above rather than reimplementing it in a
# separate script, where the two definitions could silently drift apart.
#
# Costs a package load and a grid build (no GPU, no model), so it is seconds of work, not an hour.
if haskey(ENV, "AR_TERRAIN_PATCH")
    let JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2"),
        path = ENV["AR_TERRAIN_PATCH"]

        h = Array(parent(host_grid.z.formulation.h))
        Hx, Hy, _ = Oceananigans.Grids.halo_size(host_grid)
        Nx, Ny, _ = size(host_grid)

        JLD2.jldopen(path, "a+") do file
            haskey(file, "grid/terrain_height") ||
                (file["grid/terrain_height"] = h[Hx+1:Hx+Nx, Hy+1:Hy+Ny, 1])
            haskey(file, "grid/z_top") ||
                (file["grid/z_top"] = Float64(host_grid.z.formulation.z_top))
        end
        @info "AR_TERRAIN_PATCH: wrote grid/terrain_height ($(Nx)×$(Ny)) and grid/z_top into $path"
        exit(0)
    end
end

grid = on_architecture(arch, host_grid)

## Backs shim 3: the polar branch of `default_auxiliary_bc` is skipped inside the trace, so check on
## the host grid — where the latitudes are plain numbers — that no boundary actually sits on a pole.
let φfaces = φnodes(host_grid, Center(), Face(), Center())
    @assert !(first(φfaces) ≈ -90) && !(last(φfaces) ≈ 90) "\
        the child grid touches a pole, so the polar boundary conditions this script's \
        `default_auxiliary_bc` shim skips are actually needed — remove the shim before running."
end

## Construction is the slow part of a Reactant run — every eager kernel launch (halo fills, the
## exchanger's window fill, `set!`) is compiled as its own XLA executable — so each stage announces
## itself: a stall is far easier to place with these markers than with a native backtrace.
##
## The explicit `flush` is what makes them useful when stderr is a file rather than a terminal — as it
## is under `sbatch`. Julia buffers `stderr` itself, so without this every marker sits in the buffer
## until the process exits and the whole run looks like one silent block: exactly backwards for a
## script whose job is to show WHERE the time goes. `stdbuf -oL -eL` does not help, since Julia does
## not go through libc's FILE* buffering.
const script_start = time_ns()

function stage(message)
    @info string("[", @sprintf("%7.1f s", 1e-9 * (time_ns() - script_start)), "] ", message)
    flush(stderr)
    return nothing
end
## Report the alignment explicitly: whether the launches carry KA's `__validindex` guard is decided
## here, and it is decided per axis, so print the per-axis verdict rather than a single yes/no.
aligned_axes = align ≤ 1 ? "AR_ALIGN off" :
    join(("$name=$n" * (n % align == 0 ? "✓" : "✗")
          for (name, n) in (("Nx", Nx), ("Ny", Ny), ("Nz", Nz))), " ") *
    " (mod $align; ✓ ⇒ Center-located launches on that axis drop the DynamicCheck guard, " *
    "Face-located N+1 launches keep it either way)"

stage("child grid ready: $(summary(grid)) — $aligned_axes")

# ## Analytic atmospheric river (in place of the ERA5 parent)
#
# A moisture + low-level-jet filament tilted SW→NE, translating east at `corridor_speed`, on a
# hydrostatic background: an International Standard Atmosphere pressure profile (the same
# isothermal-scale-height map `standard_atmosphere_z_interfaces` uses to place ERA5's pressure
# levels, so level heights and level pressures are mutually consistent by construction), a
# 6.5 K km⁻¹ troposphere with a meridional gradient, and cloud/precipitation species peaking in
# the filament. Every field is a closed-form function of `(λ, φ, z, t)`.

const g_std = 9.80665             # m s⁻²
const Rᵈ_std = 287.0528           # J kg⁻¹ K⁻¹
const T_std = 288.15              # K, the ISA sea-level temperature behind the p ↔ z map
const p_std = 101325.0            # Pa

@inline isa_pressure(z) = p_std * exp(-g_std * z / (Rᵈ_std * T_std))

const z_tropopause = 11.5e3       # m
const lapse_rate = 6.5e-3         # K m⁻¹
const stratospheric_lapse = -1.5e-3

const corridor_λ₀ = -160.0        # the filament's southwestern anchor
const corridor_φ₀ = 32.0
const corridor_tilt = 0.42        # ° latitude per ° longitude
const corridor_width = 3.5        # ° latitude (≈ 390 km e-folding half-width)
const corridor_speed = 8.0        # m s⁻¹ eastward translation

## Filament weight ∈ (0, 1]: 1 on the axis, Gaussian across it, with the axis drifting east in time.
@inline function corridor_weight(λ, φ, t)
    eastward_drift = corridor_speed * t / (111e3 * cosd(φ))       # degrees longitude
    axis_offset = φ - (corridor_φ₀ + corridor_tilt * (λ - eastward_drift - corridor_λ₀))
    return exp(-(axis_offset / corridor_width)^2)
end

@inline sea_level_temperature(φ) = 300.0 - 0.55 * (φ - 25)        # 300 K at 25°N → 281 K at 60°N

@inline function air_temperature(λ, φ, z, t)
    T₀ = sea_level_temperature(φ) + 2.5 * corridor_weight(λ, φ, t)   # warm advection in the filament
    troposphere = T₀ - lapse_rate * min(z, z_tropopause)
    return troposphere - stratospheric_lapse * max(z - z_tropopause, zero(z))
end

const qᵛ_core = 0.019             # kg kg⁻¹ at the surface in the filament core
const qᵛ_background = 0.004
const vapor_scale_height = 2500.0 # m

@inline function vapor_specific_humidity(λ, φ, z, t)
    surface_value = qᵛ_background + (qᵛ_core - qᵛ_background) * corridor_weight(λ, φ, t)
    return surface_value * exp(-z / vapor_scale_height)
end

const U_background = 10.0         # m s⁻¹ westerly at the surface
const westerly_shear = 1.6e-3     # s⁻¹, capped at the tropopause
const U_jet = 30.0                # m s⁻¹ low-level jet core inside the filament
const z_jet = 1200.0
const jet_depth = 1800.0

@inline low_level_jet(λ, φ, z, t) =
    U_jet * corridor_weight(λ, φ, t) * exp(-((z - z_jet) / jet_depth)^2)

@inline eastward_velocity(λ, φ, z, t) =
    U_background + westerly_shear * min(z, z_tropopause) + low_level_jet(λ, φ, z, t)

## The filament's flow is southwesterly: ~30° of northward component in the jet, none in the mean.
@inline northward_velocity(λ, φ, z, t) = 0.6 * low_level_jet(λ, φ, z, t)

const qᶜˡ_core = 4.0e-4           # kg kg⁻¹ (0.4 g kg⁻¹ cloud liquid)
const z_cloud = 2500.0
const cloud_depth = 1800.0
const qᶜⁱ_core = 1.2e-4
const z_ice = 8000.0
const ice_depth = 3000.0

@inline cloud_liquid_specific_humidity(λ, φ, z, t) =
    qᶜˡ_core * corridor_weight(λ, φ, t) * exp(-((z - z_cloud) / cloud_depth)^2)

@inline cloud_ice_specific_humidity(λ, φ, z, t) =
    qᶜⁱ_core * corridor_weight(λ, φ, t) * exp(-((z - z_ice) / ice_depth)^2)

@inline rain_specific_humidity(λ, φ, z, t) = 0.25 * cloud_liquid_specific_humidity(λ, φ, z, t)
@inline snow_specific_humidity(λ, φ, z, t) = 0.50 * cloud_ice_specific_humidity(λ, φ, z, t)

@inline liquid_specific_humidity(λ, φ, z, t) =
    cloud_liquid_specific_humidity(λ, φ, z, t) + rain_specific_humidity(λ, φ, z, t)

@inline ice_specific_humidity(λ, φ, z, t) =
    cloud_ice_specific_humidity(λ, φ, z, t) + snow_specific_humidity(λ, φ, z, t)

# ## The parent `PrescribedAtmosphere`
#
# ERA5's geometry without ERA5's bytes: the native 0.25° horizontal spacing over the child's bounding
# box plus the dataset's default half-degree padding, and the pressure levels of
# `ERA5HourlyPressureLevels()` up to 70 hPa (~22.5 km, comfortably above the 19.5 km child lid),
# placed at their standard-atmosphere heights.
#
# The time axis carries exactly three hourly levels — the width of the exchanger's resident window —
# so the derived child prognostics are computed once at construction and the window never slides
# (see shim 2). That covers `2 h` of model time; the derived series is `Cyclical`, so a longer
# compiled run silently wraps back to the start of the filament's translation.

dataset = ERA5HourlyPressureLevels()

## The nest validates that the parent's x/y extents BRACKET the child's, in metres — and the lat-lon
## metric makes an equal-degree pad shrink with latitude, so the dataset's own half-degree padding
## (which the real nest gets away with because the ERA5 request snaps outward to native cell edges)
## leaves the child's corners outside. A full degree (four native cells) brackets it everywhere.
parent_padding = parse(Float64, get(ENV, "AR_PARENT_PADDING", "1"))
parent_region = BoundingBox(host_grid; padding = parent_padding)

parent_pressure_levels = filter(p -> p ≥ 7000, dataset.pressure_levels)   # ≥ 70 hPa
parent_z = NumericalEarth.DataWrangling.ERA5.standard_atmosphere_z_interfaces(parent_pressure_levels)

# `AR_PARENT_UNIFORM_Z=1` replaces the parent's stretched vertical with a UNIFORM one spanning the
# same extent with the same number of levels. This is a compiler fix, not a physics preference.
#
# Oceananigans picks the vertical interpolation index by dispatch (`Fields/interpolate.jl`):
#
#     fractional_z_index(z, locs, grid::ZRegGrid) = (z - z₀) / dz + 1        # arithmetic
#     fractional_z_index(z, locs, grid)           = fractional_index(z, zn, Nz)  # binary search
#
# The stretched branch runs `index_binary_search`, whose trip count depends on loaded data. That is
# the 269 × `cannot raise op to stablehlo … "scf.while"` blocking `@compile`: a `searchsortedfirst`
# over the parent's `memref<38xf32>` z-coordinates, once per `Interpolated` lateral boundary. A
# regular vertical takes the arithmetic branch and emits no loop at all.
#
# Legitimate HERE and not in `downscale.jl`: this parent is analytic — every field is a closed-form
# function of `(λ, φ, z, t)` — so it is exact on any set of levels. What is given up is that level
# heights no longer coincide with ERA5's pressure levels, which is only a statement about where the
# parent samples, not about the fields. `parent_pressure` is still set from `isa_pressure(z)`, so
# level heights and level pressures stay mutually consistent. A REAL ERA5 parent could not do this.
if get(ENV, "AR_PARENT_UNIFORM_Z", "0") == "1"
    @info @sprintf("AR_PARENT_UNIFORM_Z: parent vertical %.0f–%.0f m, %d levels, stretched → uniform \
                    (removes the searchsortedfirst binary search from the interpolated boundaries)",
                   first(parent_z), last(parent_z), length(parent_z) - 1)
    parent_z = (first(parent_z), last(parent_z))
end

Δparent = 1 / parse(Float64, get(ENV, "AR_PARENT_CELLS_PER_DEGREE", "4"))   # ERA5 native: 0.25°
parent_λ = parent_region.longitude
parent_φ = parent_region.latitude
parent_Nx = round(Int, (parent_λ[2] - parent_λ[1]) / Δparent)
parent_Ny = round(Int, (parent_φ[2] - parent_φ[1]) / Δparent)

parent_grid = LatitudeLongitudeGrid(arch;
                                    longitude = parent_λ,
                                    latitude = parent_φ,
                                    z = parent_z,
                                    size = (parent_Nx, parent_Ny, length(parent_pressure_levels)),
                                    halo = (5, 5, 5),
                                    topology = (Bounded, Bounded, Bounded))

# `AR_PARENT_HOURS` (default 2): hourly parent levels from `start_date`, so `AR_PARENT_HOURS + 1` time
# levels. The default three ARE the exchanger's resident window, which is what lets shim 2 freeze the
# window under Reactant. More levels are only meaningful under `AR_ARCH=cuda`, where the exchanger
# slides its window eagerly exactly as in `downscale.jl`; under Reactant the window cannot move, so
# a longer parent would still wrap after 2 h.
parent_hours = parse(Int, get(ENV, "AR_PARENT_HOURS", "2"))
parent_times = collect(0.0:1hour:(parent_hours * 1hour))

# ### Shim 2b: under Reactant, make the exchanger's resident window the WHOLE parent time axis
#
# Shim 2 freezes the exchanger window because a traced clock cannot decide when to slide it. With
# NumericalEarth's default 3-level window that froze the boundary forcing after 2 h. A window that
# holds every level never moves (`exchange_state!` pins `start = 1` when `window ≥ N`), and is filled
# once at construction (`force = true`, eager), so freezing it is then EXACT for any run within
# `AR_PARENT_HOURS`. The cost is memory: 8 derived fields × (AR_PARENT_HOURS + 1) levels on the parent
# grid — ~1 GB for 24 h over the 1°-padded landfall box at 0.25°.
if !VANILLA && parent_hours > 2
    @eval breeze_extension function child_prognostic_field_time_series(parent_atmosphere; time_indices_in_memory = 3)
        grid  = parent_atmosphere.temperature.grid
        times = parent_atmosphere.temperature.times
        window = length(times)
        build() = FieldTimeSeries{Center, Center, Center}(grid, times;
                                                          backend = PrognosticStateBackend(1, window),
                                                          time_indexing = Cyclical())
        return (ρᵈ = build(), ρu = build(), ρv = build(), ρθ = build(), ρqᵛᵉ = build(), θ = build(), u = build(), v = build())
    end
    @info "shim 2b: exchanger window = all $(length(parent_times)) parent levels ($(parent_hours) h of \
           forcing); runs longer than that see the forcing clamp at the last level"
end

u_parent = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
v_parent = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
T_parent = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
q_parent = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
qᶜˡ_parent = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
qʳ_parent  = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
qᶜⁱ_parent = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)
qˢ_parent  = FieldTimeSeries{Center, Center, Center}(parent_grid, parent_times)

set!(u_parent,   eastward_velocity)
set!(v_parent,   northward_velocity)
set!(T_parent,   air_temperature)
set!(q_parent,   vapor_specific_humidity)
set!(qᶜˡ_parent, cloud_liquid_specific_humidity)
set!(qʳ_parent,  rain_specific_humidity)
set!(qᶜⁱ_parent, cloud_ice_specific_humidity)
set!(qˢ_parent,  snow_specific_humidity)

## Pressure is the level coordinate — a static `Field`, exactly as the ERA5 parent carries it.
##
## This is a PLACEHOLDER: the isothermal-288 K map that also placed the levels. It is what
## `AR_PARENT_PRESSURE=isa` runs with, and it is hydrostatically inconsistent with any temperature
## field that is not 288.15 K everywhere — see the `AR_PARENT_PRESSURE` section below, which
## overwrites this field in place once the parent's temperature is known.
parent_pressure = CenterField(parent_grid)
set!(parent_pressure, (λ, φ, z) -> isa_pressure(z))

parent_atmosphere = PrescribedAtmosphere(parent_grid, parent_times;
                                         ## `source = dataset` is DELIBERATELY OMITTED (it defaults to
                                         ## `nothing`). `first_time_step!` compiles with it, but the
                                         ## `@trace`d loop in `step_for!` does not:
                                         ##
                                         ##   NoFieldMatchError: Cannot convert type ERA5HourlyPressureLevels{Nothing}
                                         ##     name=pressure_levels  Derived: Vector{TracedRNumber{Float64}}
                                         ##                           Existing: Vector{Float64}
                                         ##
                                         ## `Ops.while_loop` builds a tracer for everything the loop
                                         ## carries, and reaches this descriptor through the model.
                                         ## Converting it would need `pressure_levels::Vector{Float64}`
                                         ## to become a traced vector, but the struct is parameterized
                                         ## only on `z`, so no such type exists — hence "the type does
                                         ## not capture the fieldtypes that should be converted".
                                         ##
                                         ## Dropping it costs nothing: `PrescribedAtmosphere.source` is
                                         ## provenance metadata, never read while stepping (the only
                                         ## `.source` uses in the nest are `Interpolated.source`, the
                                         ## FieldTimeSeries). `dataset` is still used above to build the
                                         ## parent's pressure levels and grid geometry.
                                         velocities = (u = u_parent, v = v_parent),
                                         temperature = T_parent,
                                         specific_humidity = q_parent,
                                         microphysical_variables = (qᶜˡ = qᶜˡ_parent, qʳ = qʳ_parent,
                                                                    qᶜⁱ = qᶜⁱ_parent, qˢ = qˢ_parent),
                                         pressure = parent_pressure,
                                         precipitation_flux = nothing)

# ### `AR_PARENT=era5`: fill the parent with real ERA5 data, read on the host
#
# The analytic fields above are replaced by ERA5's actual bytes from `era5/`, while the parent's
# STRUCTURE — grid, static standard-atmosphere level heights, three-level window, plain
# `FieldTimeSeries` — is kept exactly as built above.
#
# The obvious alternative, handing `PrescribedAtmosphere(region, dates, dataset)` an
# `architecture = ReactantState()` so ERA5 builds the parent natively, does not work today. Its
# vertical coordinate is a `per_column_geopotential_discretization`: ERA5's true geopotential height
# per column, time-varying through a `TimeSeriesInterpolation` over a `FieldTimeSeries`. Converting
# THAT to Reactant blows up without bound — the same parent builds on `CPU()` in 33 s in a few
# hundred MB, and on `ReactantState()` it was still allocating when it was OOM-killed at 180 GB
# (job 4749, `Maximum resident set size: 191347856 kbytes`, signal 9). Two prerequisites were fixed
# getting that far and are worth keeping regardless — `per_column_geopotential_discretization`
# hardcoding `CPU()` for its geopotential fields, and `Downloads.download(::Metadata)` erroring even
# when every file is cached — but the blowup itself is upstream work.
#
# Reading on the host and pushing the numbers to the device sidesteps it entirely, and keeps the run
# on the parent structure that has compiled and stepped all along. Two approximations follow, both
# bounded and both stated rather than hidden:
#
#   * Pressure levels sit at their standard-atmosphere heights, not ERA5's true geopotential. The
#     pressure levels themselves ARE ERA5's, and this is the same mapping the analytic parent uses.
#   * The three-level window is hourly from `start_date`, so a run longer than 2 h of model time
#     wraps (the derived series is `Cyclical`), exactly as with the analytic parent.
#
# Regridding goes through `set!(cpu_dst, era5_src)` between two CPU fields, so Oceananigans' own
# interpolation handles any grid mismatch — rather than an index-by-index copy that would silently
# assume the two grids line up. Only then is the result pushed to the device, whole-parent.
## CPU twin of the parent grid built above. The ERA5 branch regrids onto it, and the hydrostatic
## pressure below integrates along its (plain-number) vertical coordinate in either parent mode.
cpu_parent_grid = LatitudeLongitudeGrid(CPU();
                                        longitude = parent_λ,
                                        latitude = parent_φ,
                                        z = parent_z,
                                        size = (parent_Nx, parent_Ny, length(parent_pressure_levels)),
                                        halo = (5, 5, 5),
                                        topology = (Bounded, Bounded, Bounded))

if get(ENV, "AR_PARENT", "analytic") == "era5"
    ## The read box DEFAULTS TO THE PARENT'S OWN PADDING. With the old 0.5° default the parent grid
    ## (padded 1°) extended half a degree past the ERA5 data on every side, and `set!` zero-filled
    ## that frame — the "56 of 2736 zeros are INTERIOR" line in every ERA5 load, and the source of
    ## the ρᵈ = 2.76 kg/m³ / θ = 126 K relaxation targets (real air interpolated against zeros).
    ## The 1°-padded landfall box is in the cache alongside the 0.5° one.
    era5_pad = parse(Float64, get(ENV, "AR_ERA5_PADDING", string(parent_padding)))
    ## `AR_ERA5_REGION="lon1,lon2,lat1,lat2"` reads a DIFFERENT (larger) cached box instead of the
    ## padded child box — the regrid below interpolates onto the parent grid either way. This is how
    ## a longer window is reached without a CDS download: the corridor box
    ## (-170.5,-109.5,24.5,60.5) is cached hourly for 72 h (Dec 7 12Z to Dec 10 12Z) where the landfall box has only 3 levels.
    era5_region = if haskey(ENV, "AR_ERA5_REGION")
        r = parse.(Float64, split(ENV["AR_ERA5_REGION"], ','))
        length(r) == 4 || error("AR_ERA5_REGION needs lon1,lon2,lat1,lat2")
        BoundingBox(longitude = (r[1], r[2]), latitude = (r[3], r[4]))
    else
        BoundingBox(longitude = longitude .+ (-era5_pad, era5_pad),
                    latitude  = latitude  .+ (-era5_pad, era5_pad))
    end
    era5_dates = start_date:Hour(1):(start_date + Hour(parent_hours))

    ## Metadata filenames encode the exact bounding box, so this padding must match a box that was
    ## actually downloaded or every read is a cache miss. The files must already be present in
    ## `era5_datadir`.
    ##
    ## The `glw/cleanup` NumericalEarth now routes `PrescribedAtmosphere(dir=…)` through
    ## `download(::MetadataSet)`, whose per-`Metadata` method lives in the `CopernicusClimateDataStore`
    ## extension — so without that package loaded the read dies with "No download method for
    ## Metadata{ERA5HourlyPressureLevels,…}" even when every file is on disk (job 1325). Loading it is
    ## SAFE here because the download path filters out files that already exist
    ## (`!isfile`, `download_era5cli_month`), so a COMPLETE cache makes zero CDS requests — the earlier
    ## "deliberately not loaded" stance held only while the read did its own cache check. `AR_LOAD_CDS=0`
    ## restores the old behavior for anyone who wants the read to hard-fail rather than risk a request.
    if get(ENV, "AR_LOAD_CDS", "1") == "1"
        @eval import CopernicusClimateDataStore
    end
    stage("reading ERA5 on the host: $(first(era5_dates)) … $(last(era5_dates)), $(summary(era5_region))")
    era5_atmosphere = PrescribedAtmosphere(era5_region, era5_dates, dataset;
                                           architecture = CPU(),
                                           dir = era5_datadir,
                                           time_indices_in_memory = nothing)

    ## `cpu_parent_grid` (defined above the branch) is the regridding destination.
    era5_sources = (u_parent   => era5_atmosphere.velocities.u,
                    v_parent   => era5_atmosphere.velocities.v,
                    T_parent   => era5_atmosphere.temperature,
                    q_parent   => era5_atmosphere.specific_humidity,
                    qᶜˡ_parent => era5_atmosphere.microphysical_variables.qᶜˡ,
                    qʳ_parent  => era5_atmosphere.microphysical_variables.qʳ,
                    qᶜⁱ_parent => era5_atmosphere.microphysical_variables.qᶜⁱ,
                    qˢ_parent  => era5_atmosphere.microphysical_variables.qˢ)

    ## Clamped (zero-gradient) extension of a field's interior into its halo, in place, on the host.
    ## Order matters: x first, then y, then z, so that corner and edge halo cells — which belong to
    ## two or three of these at once — are written from already-extended neighbours rather than from
    ## the zeros they start at.
    function extend_into_halo!(field)
        a = parent(field)
        Hx, Hy, Hz = Oceananigans.Grids.halo_size(field.grid)
        Nx, Ny, Nz = size(field.grid)
        for i in 1:Hx
            a[i, :, :]           .= @view a[Hx + 1, :, :]
            a[Hx + Nx + i, :, :] .= @view a[Hx + Nx, :, :]
        end
        for j in 1:Hy
            a[:, j, :]           .= @view a[:, Hy + 1, :]
            a[:, Hy + Ny + j, :] .= @view a[:, Hy + Ny, :]
        end
        for k in 1:Hz
            a[:, :, k]           .= @view a[:, :, Hz + 1]
            a[:, :, Hz + Nz + k] .= @view a[:, :, Hz + Nz]
        end
        return field
    end

    for (destination, era5_series) in era5_sources
        for n in 1:length(parent_times)
            scratch = CenterField(cpu_parent_grid)
            set!(scratch, era5_series[n])                 ## CPU→CPU, Oceananigans interpolates

            ## Fill the scratch HALOS before copying the whole array over. `set!(::Field, ::Field)`
            ## only writes the interior, so a fresh `CenterField`'s halos stay 0 — and `copyto!` below
            ## propagates those zeros to the device parent (the `T ∈ [0.0, …]` seen at every load). The
            ## analytic parent never hits this because `set!(field, ::Function)` evaluates in the halos
            ## too. Left unfilled, the child's lateral boundary + IC interpolation reads 0-valued parent
            ## cells at the domain EDGES — worst at the CORNERS, where two boundaries meet — which seeds
            ## a bottom-corner mass accumulation that the analytic IC tolerates (bounded) but the real
            ## ERA5 state amplifies into a blow-up (ρᵈ → 20+; all four corners, k=1). Zero-gradient
            ## (edge-extending) Bounded halos are what a properly-loaded parent carries.
            Oceananigans.BoundaryConditions.fill_halo_regions!(scratch)
            copyto!(parent(destination[n]), parent(scratch))   ## host→device, whole parent (halos incl.)
        end
    end

    ## Report what actually landed on the device, so "real data" is verified rather than assumed.
    let probe = Array(parent(T_parent[1])), finite = filter(isfinite, probe)
        stage(@sprintf("ERA5 parent loaded: %d×%d×%d, %d levels, T[t=1] ∈ [%.1f, %.1f] K (%d/%d finite)",
                       parent_Nx, parent_Ny, length(parent_pressure_levels), length(parent_times),
                       isempty(finite) ? NaN : minimum(finite), isempty(finite) ? NaN : maximum(finite),
                       length(finite), length(probe)))
    end

    ## WHERE are the zeros? A parent temperature of exactly 0 K is never data — the raw ERA5 file
    ## has none (min 201 K) — so every one was manufactured on the way in, and the bounds line above
    ## reports only that they exist. Which INDEX they occupy decides what is wrong:
    ##   * halo-only        → `copyto!` below carries unfilled halos, fix by filling them
    ##   * an interior FRAME → the parent grid is wider than the ERA5 data and `set!` silently
    ##                         zero-fills outside the source (AR_PARENT_PADDING vs AR_ERA5_PADDING)
    ##   * bottom levels     → below-ground fill in the source
    ## Cheap: one host array already resident, a few reductions, no device work.
    let probe = Array(parent(T_parent[1])),
        halos = Oceananigans.Grids.halo_size(cpu_parent_grid),
        Hx = halos[1], Hy = halos[2], Hz = halos[3],
        nz = count(iszero, probe)

        stage(@sprintf("parent T zeros: %d of %d cells (%.2f%%)", nz, length(probe),
                       100nz / length(probe)))
        if nz > 0
            idx = findall(iszero, probe)
            is = [I[1] for I in idx]; js = [I[2] for I in idx]; ks = [I[3] for I in idx]
            ## Indices are into the HALO-INCLUSIVE parent array, so interior i runs Hx+1 : Hx+Nx.
            interior_zeros = count(I -> Hx < I[1] <= Hx + parent_Nx &&
                                        Hy < I[2] <= Hy + parent_Ny &&
                                        Hz < I[3] <= Hz + length(parent_pressure_levels), idx)
            stage(@sprintf("  i ∈ [%d, %d] (interior is %d:%d), j ∈ [%d, %d] (interior %d:%d), \
                            k ∈ [%d, %d] (interior %d:%d)",
                           minimum(is), maximum(is), Hx + 1, Hx + parent_Nx,
                           minimum(js), maximum(js), Hy + 1, Hy + parent_Ny,
                           minimum(ks), maximum(ks), Hz + 1, Hz + length(parent_pressure_levels)))
            stage(@sprintf("  %d of %d zeros are INTERIOR (%.1f%%) — halo-only would be 0%%",
                           interior_zeros, nz, 100interior_zeros / nz))
        end
    end

    ## `AR_PARENT_PROBE_ONLY=1` stops here. The parent load is ~50 s and everything above is host
    ## work, so this answers "what is in the parent?" without paying for the nest, the coupling or
    ## any stepping.
    if get(ENV, "AR_PARENT_PROBE_ONLY", "0") == "1"
        stage("AR_PARENT_PROBE_ONLY=1 — stopping after the parent probe")
        exit(0)
    end
end

# ## `AR_PARENT_PRESSURE` (`column` for ERA5, else `hydrostatic`): a parent pressure the parent's own temperature can hold up
#
# The placeholder above pairs every parent level with the pressure of an ISOTHERMAL 288.15 K column
# at that height — the same map that placed the levels. The exchanger then forms the child's
# boundary targets as ρ = p / (Rᵐ T) with the REAL temperature at that height, and Breeze diagnoses
# the child's pressure back from (ρ, θ), so in the boundary zone the child's pressure IS p_iso(z).
# Its vertical gradient balances a 288 K density; the target density belongs to air 40–70 K colder.
# The net vertical force per unit mass is g (T / 288.15 − 1): about −0.3 m/s² near the surface and
# −2.3 m/s² through the upper troposphere. That is the ρw ≈ −12 to −20 m/s "in one step" kick every
# ERA5 run has shown, and — because the halos and Davies targets stay pinned to p_iso while the
# interior settles into balance with its own temperature — a standing pressure jump of tens of hPa
# across every lateral wall, radiating acoustic waves from t = 0. Same defect for the analytic
# parent (6.5 K/km lapse rate against an isothermal pressure), only milder.
#
# The fix integrates the pressure HYDROSTATICALLY on the parent's own level heights from the
# parent's own domain-mean virtual temperature, anchored at the domain-mean surface pressure. What
# remains is the per-column anomaly T′/T̄ (a few percent), which is the same residual the native
# `PressureLevelGrid` path carries, since its boundary interpolation also works on column-mean
# heights. Nothing here depends on WHAT the heights are, so `AR_PARENT_UNIFORM_Z=1` and the raise's
# arithmetic vertical index are unaffected.
#
# `AR_PARENT_PRESSURE=isa` keeps the isothermal placeholder, i.e. reproduces the old behaviour.
## Default `column` for the ERA5 parent (per-column balance; the domain-mean profile left every wall out of
## balance by ~T′/T̄ — a 6× larger step-1 frame kick, DT_SWEEP.md), `hydrostatic` for the analytic parent,
## which has no msl field to anchor columns on.
parent_pressure_mode = get(ENV, "AR_PARENT_PRESSURE",
                           get(ENV, "AR_PARENT", "analytic") == "era5" ? "column" : "hydrostatic")
if parent_pressure_mode == "hydrostatic"
    let constants64 = Breeze.ThermodynamicConstants(Float64),
        Rᵈ = Breeze.dry_air_gas_constant(constants64),
        Rᵛ = Breeze.vapor_gas_constant(constants64),
        Hz = Oceananigans.Grids.halo_size(cpu_parent_grid)[3],
        Nk = length(parent_pressure_levels)

        ## Whole (haloed) host copies of the t = 0 parent state; interior levels are Hz+1 : Hz+Nk.
        Tʰ   = Array(parent(T_parent[1]))
        qᵛʰ  = Array(parent(q_parent[1]))
        qˡʰ  = Array(parent(qᶜˡ_parent[1])) .+ Array(parent(qʳ_parent[1]))
        qⁱʰ  = Array(parent(qᶜⁱ_parent[1])) .+ Array(parent(qˢ_parent[1]))
        Hx, Hy, _ = Oceananigans.Grids.halo_size(cpu_parent_grid)
        ii = Hx+1:Hx+parent_Nx
        jj = Hy+1:Hy+parent_Ny

        ## Domain-mean "virtual" temperature per level, with the exchanger's own mixture gas
        ## constant: ρ = p / (Rᵐ T) ⇔ ρ = p / (Rᵈ Tᵛ) with Tᵛ = T Rᵐ / Rᵈ. Only finite, physical
        ## cells count, so a stray zero (unfilled corner, below-ground garbage) cannot bias the mean.
        T̄ᵛ = zeros(Nk)
        for k in 1:Nk
            kk = Hz + k
            acc = 0.0; n = 0
            for j in jj, i in ii
                T = Tʰ[i, j, kk]
                (isfinite(T) && T > 100) || continue
                Rᵐ = (1 - qᵛʰ[i, j, kk] - qˡʰ[i, j, kk] - qⁱʰ[i, j, kk]) * Rᵈ + qᵛʰ[i, j, kk] * Rᵛ
                acc += T * Rᵐ / Rᵈ; n += 1
            end
            T̄ᵛ[k] = n > 0 ? acc / n : (k > 1 ? T̄ᵛ[k-1] : 288.15)
        end

        ## z = 0 anchor: the dataset's domain-mean mean-sea-level pressure over the child at the start
        ## date (the same number `nested_atmosphere_model(grid, dataset)` uses for `base_pressure`);
        ## the analytic parent, and an ERA5 cache without that file, fall back to `p_std`.
        p_surface = p_std
        if get(ENV, "AR_PARENT", "analytic") == "era5"
            try
                p_surface = Float64(breeze_extension.mean_sea_level_pressure(dataset, host_grid, start_date, era5_datadir))
            catch err
                @warn "hydrostatic parent pressure: could not read the ERA5 mean sea-level pressure; \
                       anchoring at p_std = $(p_std) Pa instead" exception = (err, catch_backtrace())
            end
        end

        ## Center heights INCLUDING halos, so the halo levels get a hydrostatic extrapolation rather
        ## than a copied edge value. Integrate outward from z = 0 in both directions, using the
        ## layer-mean Tᵛ of the nearest interior levels.
        ## `znodes(...; with_halos = true)` is an offset-indexed view (1-Hz : Nk+Hz) over an offset
        ## array; `collect`, comprehensions over `eachindex`, and `Vector(...)` all keep those axes.
        ## Indexing over a plain integer range is what yields a 1-based vector.
        zc_halo = znodes(cpu_parent_grid, Center(); with_halos = true)
        zc_all = Float64[zc_halo[i] for i in firstindex(zc_halo):lastindex(zc_halo)]
        Ktot = length(zc_all)
        @assert Ktot == Nk + 2Hz
        Tᵛ_at(kk) = T̄ᵛ[clamp(kk - Hz, 1, Nk)]
        p_all = zeros(Ktot)
        k₀ = Hz + 1                                            # first interior center
        p_all[k₀] = p_surface * exp(-g_std * zc_all[k₀] / (Rᵈ * Tᵛ_at(k₀)))
        for kk in k₀+1:Ktot
            p_all[kk] = p_all[kk-1] * exp(-g_std * (zc_all[kk] - zc_all[kk-1]) /
                                          (Rᵈ * 0.5 * (Tᵛ_at(kk-1) + Tᵛ_at(kk))))
        end
        for kk in k₀-1:-1:1
            p_all[kk] = p_all[kk+1] * exp(+g_std * (zc_all[kk+1] - zc_all[kk]) /
                                          (Rᵈ * 0.5 * (Tᵛ_at(kk+1) + Tᵛ_at(kk))))
        end

        ## What the placeholder had, for the log: its relative hydrostatic imbalance is exactly
        ## Tᵛ/288.15 − 1 per level, and its pressure error is p_iso/p̄ − 1.
        p_iso = isa_pressure.(zc_all)
        worst_k = argmax(abs.(T̄ᵛ ./ 288.15 .- 1))
        stage(@sprintf("hydrostatic parent pressure: anchored at p_surface = %.0f Pa; T̄ᵛ ∈ [%.1f, %.1f] K; \
                        the isothermal placeholder was out of balance by up to %+.0f%% (level %d, %.0f m) \
                        and off in pressure by up to %+.0f%% at the top interior level",
                       p_surface, minimum(T̄ᵛ), maximum(T̄ᵛ),
                       100 * (T̄ᵛ[worst_k] / 288.15 - 1), worst_k, zc_all[Hz + worst_k],
                       100 * (p_iso[Hz + Nk] / p_all[Hz + Nk] - 1)))

        ## Level-constant field, whole-parent (halos included), pushed to the device in one shot.
        p_host = similar(Tʰ)
        for kk in 1:Ktot
            p_host[:, :, kk] .= eltype(p_host)(p_all[kk])
        end
        copyto!(parent(parent_pressure), p_host)
    end
elseif parent_pressure_mode == "column"
    ## `AR_PARENT_PRESSURE=column`: the same hydrostatic integration, but PER COLUMN — each parent
    ## column's own Tᵛ profile, anchored at that column's ERA5 mean-sea-level pressure at `start_date`
    ## (the parent is flat, so z = 0 is sea level). The domain-mean profile above is horizontally
    ## uniform while ERA5's temperature is not, so every boundary target ρ = p / (Rᵐ T) is out of
    ## hydrostatic balance by ~T′/T̄ and the walls carry a horizontal pressure gradient that is not
    ## ERA5's. Host-side and before any trace, so the Reactant path is unaffected. ERA5 only: the
    ## anchor is read from the cached single-level file `AR_MSL_FILE_REGION` (default the
    ## 0.25° −180…−110 × 20…62 box) by bilinear interpolation to the parent's cell centres.
    get(ENV, "AR_PARENT", "analytic") == "era5" || error("AR_PARENT_PRESSURE=column needs AR_PARENT=era5")
    let constants64 = Breeze.ThermodynamicConstants(Float64),
        Rᵈ = Breeze.dry_air_gas_constant(constants64),
        Rᵛ = Breeze.vapor_gas_constant(constants64),
        halo = Oceananigans.Grids.halo_size(cpu_parent_grid),
        Nk = length(parent_pressure_levels),
        NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")
        Hx, Hy, Hz = halo

        Tʰ  = Array(parent(T_parent[1]))
        qᵛʰ = Array(parent(q_parent[1]))
        qˡʰ = Array(parent(qᶜˡ_parent[1])) .+ Array(parent(qʳ_parent[1]))
        qⁱʰ = Array(parent(qᶜⁱ_parent[1])) .+ Array(parent(qˢ_parent[1]))
        Itot, Jtot, Ktot = size(Tʰ)
        @assert Ktot == Nk + 2Hz

        msl_box = get(ENV, "AR_MSL_FILE_REGION", "-180.0_-110.0_20.0_62.0")
        msl_path = joinpath(era5_datadir, "mean_sea_level_pressure_ERA5HourlySingleLevel_" *
                                          "$(Dates.format(start_date, "yyyy-mm-ddTHH"))_$(msl_box).nc")
        msl_λ, msl_φ, msl = NCDatasets.NCDataset(msl_path) do ds
            x = ds["msl"]
            Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:]),
            Float64.(coalesce.(ndims(x) == 3 ? x[:, :, 1] : x[:, :], NaN))
        end
        ## Bilinear on the (ascending-or-not) 0.25° lat-lon grid; points are clamped into the box.
        function msl_at(λ, φ)
            λs = msl_λ[1] < msl_λ[end] ? msl_λ : reverse(msl_λ)
            φs = msl_φ[1] < msl_φ[end] ? msl_φ : reverse(msl_φ)
            M = msl
            msl_λ[1] > msl_λ[end] && (M = reverse(M, dims = 1))
            msl_φ[1] > msl_φ[end] && (M = reverse(M, dims = 2))
            λ = clamp(λ, λs[1], λs[end]); φ = clamp(φ, φs[1], φs[end])
            i = clamp(searchsortedlast(λs, λ), 1, length(λs) - 1)
            j = clamp(searchsortedlast(φs, φ), 1, length(φs) - 1)
            a = (λ - λs[i]) / (λs[i+1] - λs[i]); b = (φ - φs[j]) / (φs[j+1] - φs[j])
            return (1 - a) * (1 - b) * M[i, j] + a * (1 - b) * M[i+1, j] +
                   (1 - a) * b * M[i, j+1] + a * b * M[i+1, j+1]
        end

        λc = λnodes(cpu_parent_grid, Center(), Center(), Center())
        φc = φnodes(cpu_parent_grid, Center(), Center(), Center())
        zc_halo = znodes(cpu_parent_grid, Center(); with_halos = true)
        zc_all = Float64[zc_halo[k] for k in firstindex(zc_halo):lastindex(zc_halo)]

        p_host = similar(Tʰ)
        Tᵛ = zeros(Ktot); p_col = zeros(Ktot)
        k₀ = Hz + 1
        anchors = Float64[]
        for J in 1:Jtot, I in 1:Itot
            i = clamp(I - Hx, 1, parent_Nx); j = clamp(J - Hy, 1, parent_Ny)
            p₀ = msl_at(λc[i], φc[j]); push!(anchors, p₀)
            ## Column Tᵛ with the exchanger's mixture gas constant; non-physical cells (unfilled
            ## corners, below-ground garbage) take the nearest physical value above them.
            for kk in 1:Ktot
                k = clamp(kk, Hz + 1, Hz + Nk)
                T = Tʰ[I, J, k]
                Rᵐ = (1 - qᵛʰ[I, J, k] - qˡʰ[I, J, k] - qⁱʰ[I, J, k]) * Rᵈ + qᵛʰ[I, J, k] * Rᵛ
                Tᵛ[kk] = (isfinite(T) && T > 100) ? T * Rᵐ / Rᵈ : NaN
            end
            for kk in Ktot-1:-1:1
                isfinite(Tᵛ[kk]) || (Tᵛ[kk] = Tᵛ[kk+1])
            end
            for kk in 2:Ktot
                isfinite(Tᵛ[kk]) || (Tᵛ[kk] = Tᵛ[kk-1])
            end
            p_col[k₀] = p₀ * exp(-g_std * zc_all[k₀] / (Rᵈ * Tᵛ[k₀]))
            for kk in k₀+1:Ktot
                p_col[kk] = p_col[kk-1] * exp(-g_std * (zc_all[kk] - zc_all[kk-1]) / (Rᵈ * (Tᵛ[kk-1] + Tᵛ[kk]) / 2))
            end
            for kk in k₀-1:-1:1
                p_col[kk] = p_col[kk+1] * exp(+g_std * (zc_all[kk+1] - zc_all[kk]) / (Rᵈ * (Tᵛ[kk+1] + Tᵛ[kk]) / 2))
            end
            @views p_host[I, J, :] .= p_col
        end
        stage(@sprintf("parent pressure: AR_PARENT_PRESSURE=column — per-column hydrostatic from each column's Tᵛ, \
                        anchored at ERA5 msl %s (anchor range %.0f–%.0f Pa); top-level p range %.0f–%.0f Pa",
                       Dates.format(start_date, "yyyy-mm-ddTHH"), extrema(anchors)...,
                       extrema(p_host[Hx+1:Hx+parent_Nx, Hy+1:Hy+parent_Ny, Hz+Nk])...))
        copyto!(parent(parent_pressure), p_host)
    end
else
    stage("parent pressure: AR_PARENT_PRESSURE=isa — keeping the isothermal-288 K placeholder (hydrostatically \
           inconsistent with the parent temperature; expect the acoustic kick from the walls)")
end

## `summary(::PrescribedAtmosphere)` reduces over the grid's node vectors with `extrema`, which is
## scalar indexing into a `ConcretePJRTArray` — `Scalar indexing is disallowed` on `ReactantState`.
## Every number it would report is already on the host here, so print those instead.
stage(@sprintf("parent ready: %d×%d×%d PrescribedAtmosphere over [%.2f, %.2f]°E × [%.2f, %.2f]°N, \
                %d–%d hPa, %d time levels",
               parent_Nx, parent_Ny, length(parent_pressure_levels),
               parent_λ[1], parent_λ[2], parent_φ[1], parent_φ[2],
               minimum(parent_pressure_levels) ÷ 100, maximum(parent_pressure_levels) ÷ 100,
               length(parent_times)))

# ## Build the nest
#
# Same physics choices as `downscale.jl`: fixed 1/300 s⁻¹ Davies relaxation, WENO(5) momentum,
# no bottom drag (the ocean coupling below supplies the surface fluxes). `terrain = nothing`
# because the grid handed in already carries its materialized terrain, and this parent has no
# surface elevation to blend toward.

relax_width = parse(Int, get(ENV, "AR_RELAX_WIDTH", "5"))
## `AR_RELAX_TIMESCALE` (seconds, default 300) sets the Davies relaxation rate 1/τ at the frame.
## `off` drops the interior relaxation forcing altogether (`relaxation_rate = nothing`) — not a physical
## configuration: it exists to measure what the in-kernel Davies forcing costs (perf/PROFILE_REPORT.md).
forcing_FT = ft_forcing ? eltype(grid) : Float64
relax_rate = get(ENV, "AR_RELAX_TIMESCALE", "300") == "off" ? nothing :
             forcing_FT(1 / parse(Float64, get(ENV, "AR_RELAX_TIMESCALE", "300")))
lid_damping_rate = forcing_FT(1 / 5)   # nested_atmosphere_model's default, at the forcing float type
aiva = get(ENV, "AR_AIVA", "0") == "1"

# ### The traced clock
#
# Built here, before the model, because every component has to share it. Two requirements:
#
#  1. Traced time and iteration, or a compiled step cannot advance the clock — a host-side
#     `Clock{Float64}` is mutated at TRACE time and then frozen at that value for every execution.
#  2. The same float type everywhere: `atmosphere_model` defaults to `Clock{eltype(grid)}` (plain
#     `Float32` here) while `Clock(grid::ReactantGrid)` gives traced-but-`Float64` time, and
#     `EarthSystemModel` refuses to adopt a clock whose time type differs from its components'.
#
# So: traced clocks at the grid's float type. Note the plural — the coupled model gets its OWN,
# not the nest's. `EarthSystemModels.matching_clock` compares clock TIME TYPES, not identity, so two
# separately-built clocks of the same type are accepted without coercion, and that is what is wanted:
# `time_step!(::EarthSystemModel, Δt)` steps each component and THEN ticks its own clock, so a coupled
# model handed the nest's clock object would tick it twice per step — model time running at 2Δt while
# the dynamics advanced by Δt.

FT = eltype(grid)

# Requirement 1 is Reactant-specific, and under `AR_ARCH=cuda` it inverts: with nothing traced,
# there is no compiled step to freeze the clock, and a `ConcreteRNumber` clock instead rides into
# every KA kernel as a kernel ARGUMENT — where GPUCompiler rejects it outright, since a
# `ConcretePJRTNumber` wraps an XLA buffer and a pointer-chasing struct is not a bitstype:
#
#     KernelError: passing non-bitstype argument … .time is of type ConcretePJRTNumber{Float32, 1}
#       .data is of type Tuple{Reactant.XLA.PJRT.AsyncBuffer} which is not isbits.
#
# (job 6671, in `fill_bottom_and_top_halo!` — the clock reaches the halo fills through the model's
# `fields` tuple). Requirement 2 is unchanged either way: same float type everywhere, or
# `EarthSystemModel` refuses to adopt the clock.
traced_clock() = VANILLA ?
    Clock(time = zero(FT),
          last_Δt = FT(Inf),
          last_stage_Δt = FT(Inf),
          iteration = 0,
          kernel_time_type = FT) :
    Clock(time = Reactant.ConcreteRNumber(zero(FT)),
          last_Δt = Reactant.ConcreteRNumber(FT(Inf)),
          last_stage_Δt = Reactant.ConcreteRNumber(FT(Inf)),
          iteration = Reactant.ConcreteRNumber(0),
          kernel_time_type = FT)

model_clock = traced_clock()

# `AR_MICROPHYSICS=nonequilibrium` swaps the nest's default 1-moment SATURATION-ADJUSTMENT mixed-phase
# scheme for the 1-moment NON-EQUILIBRIUM mixed-phase one (prognostic ρqᵛ, ρqᶜˡ, ρqᶜⁱ, ρqʳ, ρqˢⁿ). The
# default has no snow source at all on Breeze main: `microphysical_tendency(::MP1M, Val(:ρqˢⁿ))` falls
# through to zero (only the non-equilibrium variant defines ice → snow autoconversion, accretion,
# deposition and melting), so cloud ice sits in ρqᵉ forever and only warm rain reaches the ground.
# Breeze branch `ar/mixed-phase-positivity` (~/Breeze-micro; env ~/AtmosphericRivers-micro/env-micro) gives
# the default scheme the same snow pathway and donor-limits every 1M process rate, which also makes the
# non-equilibrium scheme stable at Δt = 10 s (it NaN'd within 20 min before): north-band 24 h precip
# 6.9 → 12.1 mm, polygon 9.7 → 11.8 mm (figures/micro/). Without that Breeze this knob changes nothing
# for snow under `equilibrium`.
microphysics = if get(ENV, "AR_MICROPHYSICS", "equilibrium") == "nonequilibrium"
    cm_extension = Base.get_extension(Breeze, :BreezeCloudMicrophysicsExt)
    ## Any non-`nothing` ice entry is a phase indicator, materialized from the scheme's own parameters.
    cm_extension.OneMomentCloudMicrophysics(FT; cloud_formation = Breeze.Microphysics.NonEquilibriumCloudFormation(nothing, :ice))
else
    breeze_extension.default_nested_microphysics()
end
stage("microphysics: $(summary(microphysics))")

# ## Turbulence closure (`AR_CLOSURE`, default `tke`)
#
# Without one the nest has no subgrid vertical mixing at all: the surface fluxes from the ocean
# coupling land in the lowest cell and stay there, and nothing mixes momentum, heat or moisture through
# the boundary layer. `tke` is Breeze's `TKEBasedTurbulenceClosure` — a CATKE-like vertical
# eddy diffusivity with prognostic ρe, vertically implicit diffusion and sinks — which adds the tracer
# ρe to the child. ρe needs no lateral or Davies target (zero-gradient walls) and starts at a small
# positive e₀ = AR_TKE_INITIAL (m² s⁻², default 1e-3; at zero the √e diffusivities never switch on).
# `build_closure` is the single place the mixing length and stability functions are chosen.
closure_kind = get(ENV, "AR_CLOSURE", "tke")
closure_kind in ("tke", "none") || error("AR_CLOSURE must be tke or none, got $(closure_kind)")

## `AR_TKE_FLAVOR` picks the closure's parameters:
##   `main`    (default) `TKEMixingLength` + `ConstantStabilityFunctions`, Breeze main's API;
##   `default` whatever this Breeze's constructor defaults to — on Breeze #975 that is
##             `GradientLimitedMixingLength` + `ConstantStabilityFunctions` + `MoistStaticStability`;
##   `catke`   Breeze #975's `catke_parameters()`: `GradientLimitedMixingLength(Cˢ = 1.131)` +
##             `RiDependentStabilityFunctions` (CATKE's calibrated values).
## #975 removes `TKEMixingLength`, so `main` only resolves on a Breeze without #975, and `catke` only
## on one with it; the names are looked up when `build_closure` runs, not when the script parses.
tke_flavor = get(ENV, "AR_TKE_FLAVOR", "main")
tke_flavor in ("main", "default", "catke") || error("AR_TKE_FLAVOR must be main, default or catke, got $(tke_flavor)")

function build_closure(FT)
    td = Oceananigans.TurbulenceClosures.VerticallyImplicitTimeDiscretization()
    tke_flavor == "default" && return TKEBasedTurbulenceClosure(td, FT)
    tke_flavor == "catke" && return TKEBasedTurbulenceClosure(td, FT; Breeze.catke_parameters()...)
    return TKEBasedTurbulenceClosure(td, FT; mixing_length = Breeze.TKEMixingLength(),
                                             stability_functions = Breeze.ConstantStabilityFunctions())
end

closure = closure_kind == "tke" ? build_closure(FT) : nothing

# ### Shim 15 (`AR_AD_SAFE_MICROPHYSICS`, default on under `AR_AD=1`): λ⁻¹ without 0/0 in reverse mode
#
# CloudMicrophysics' 1M `lambda_inverse` clamps q at 0 and takes `(ρ q r0^… / denom)^(1/(me+Δm+1))`,
# which Julia evaluates as `exp(p · log x)`. Wherever q ≤ 0 — every rain/snow-free cell, and every
# cell whose condensate went slightly negative — x = 0, the primal is fine (exp(−∞) = 0, then floored),
# but the reverse pass computes ∂log/∂x = adjoint / x = 0/0 = NaN, which no strong-zero rule catches
# (it is a division). Floor q and ρ at `ϵ_numerics` instead of 0: identical wherever q > ϵ (where the
# callers' `ifelse(q > ϵ, rate, 0)` gates make the result matter), finite derivatives everywhere.
if get(ENV, "AR_AD", "0") == "1" && get(ENV, "AR_AD_SAFE_MICROPHYSICS", "1") == "1"
    @eval CloudMicrophysics.Microphysics1M @inline function lambda_inverse(
            pdf::Union{CMP.ParticlePDFIceRain, CMP.ParticlePDFSnow}, mass::CMP.ParticleMass, q, ρ)
        FT = UT.promote_typeof(q, ρ)
        n0 = get_n0(pdf, q, ρ)
        (; r0, m0, me, Δm, χm, gamma_coeff) = mass
        qp = max(q, UT.ϵ_numerics(q))
        ρp = max(ρ, UT.ϵ_numerics(ρ))
        denom = χm * m0 * max(n0, UT.ϵ_numerics(n0)) * gamma_coeff
        λ_inv = (ρp * qp * r0^(me + Δm) / denom)^(1 / (me + Δm + 1))
        return max(r0 * FT(1e-5), λ_inv)
    end
    @info "shim 15: AD-safe CloudMicrophysics 1M lambda_inverse (q, ρ floored at ϵ_numerics)"
end

# ### Shim 16 (`AR_AD_SAFE_SECANT`, default on under `AR_AD=1`): a secant step with no 0/0 in reverse
#
# Saturation adjustment solves for T with Breeze's secant iteration, `Δx/Δr = (x₂ - x₁) / (r₂ - r₁)`,
# guarded in the primal by `ifelse(isfinite(Δx/Δr), Δx/Δr, 0)` — once a cell converges, r₂ == r₁ and
# x₂ == x₁, so the division is 0/0. The primal discards it; the reverse pass does not: the quotient
# rule computes `-adjoint · Δx / Δr²` = 0/0 = NaN for every converged saturated cell, and the gradient
# floods. That is why the adjoint goes all-NaN only after hours (more saturated, converged cells) with
# a perfectly finite primal (jobs 2381, 2433, 2552: finite at 9 h, all-NaN at 12 h). Divide by a safe
# denominator instead, selected BEFORE the division, so neither branch ever divides by zero.
if get(ENV, "AR_AD", "0") == "1" && get(ENV, "AR_AD_SAFE_SECANT", "1") == "1"
    @eval Breeze.Solvers begin
        @inline function safe_secant_slope(x₁, x₂, r₁, r₂)
            Δr = r₂ - r₁
            degenerate = (Δr == 0) | !isfinite(Δr)
            slope = (x₂ - x₁) / ifelse(degenerate, one(Δr), Δr)
            return ifelse(degenerate | !isfinite(slope), zero(slope), slope), !degenerate
        end
        @inline function secant_solve(residual, solver::SecantSolver, x₁, x₂, scale)
            r₁ = residual(x₁)
            r₂ = residual(x₂)
            iter = 0
            while abs(r₂) > max(solver.abstol, solver.reltol * abs(scale)) && iter < solver.maxiter
                ΔxΔr, valid_step = safe_secant_slope(x₁, x₂, r₁, r₂)
                x₁, r₁ = x₂, r₂
                x₂ -= r₂ * ΔxΔr
                r₂ = residual(x₂)
                r₂ = ifelse(valid_step, r₂, zero(r₂))
                iter += 1
            end
            return x₂
        end
        @inline function secant_solve(residual, solver::FixedIterations, x₁, x₂, scale)
            r₁ = residual(x₁)
            r₂ = residual(x₂)
            for _ in 1:solver.iterations
                ΔxΔr, _ = safe_secant_slope(x₁, x₂, r₁, r₂)
                x₁, r₁ = x₂, r₂
                x₂ -= r₂ * ΔxΔr
                r₂ = residual(x₂)
            end
            return x₂
        end
    end
    @info "shim 16: AD-safe secant step in saturation adjustment (no 0/0 once converged)"
end

# ### Shim 17 (`AR_AD_FROZEN_K`, default on under `AR_AD=1` with TKE): frozen-diffusivity adjoint
#
# With the TKE closure the adjoint does not just pick up a stray NaN — it EXPLODES: production config, 3 h
# window, median |∂J/∂ρqᵉ| = 7e10 and max 1e16 everywhere (job 2608), NaN by 6 h; without a closure the same
# loss gives O(1–30) at 6 h. The tangent-linear of nonlinear vertical diffusion, ∂z(K(e, N², ℓ) ∂z c),
# carries ∂z(K′ δe ∂z c), which is anti-diffusive wherever ∂K/∂e is large (K ∝ ℓ√e, and √e is floored
# at e_min = 1e-6, so ∂K/∂e ~ 1/(2√e_min) = 500 where the TKE is quiet) — the well-known reason
# operational 4D-Var adjoints use a simplified/"frozen-K" boundary-layer adjoint (Mahfouf 1999; Janisková
# et al. 1999). So: the primal is unchanged, but the closure fields (diffusivities, mixing length, N², the
# implicit TKE sink) are passed through `ignore_derivatives` after every computation. The gradient then
# omits sensitivity THROUGH the turbulence coefficients — mixing still acts on the perturbations, with the
# coefficients of the reference trajectory — which is the standard, documented approximation.
if get(ENV, "AR_AD", "0") == "1" && get(ENV, "AR_AD_FROZEN_K", "1") == "1" &&
   isdefined(Breeze.TurbulenceClosures, :FlavorOfTKEClosure)
    @eval function Oceananigans.TurbulenceClosures.compute_closure_fields!(closure_fields,
                closure::Breeze.TurbulenceClosures.FlavorOfTKEClosure,
                model::Breeze.AtmosphereModel{<:Any, <:Any, <:ReactantState}; parameters = :xyz)
        invoke(Oceananigans.TurbulenceClosures.compute_closure_fields!,
               Tuple{Any, Breeze.TurbulenceClosures.FlavorOfTKEClosure, Any},
               closure_fields, closure, model; parameters)
        for f in values(closure_fields)
            f isa Oceananigans.Fields.AbstractField || continue
            data = parent(f)
            data isa Reactant.TracedRArray && (data .= Reactant.Ops.ignore_derivatives(data))
        end
        return nothing
    end
    @info "shim 17: frozen-diffusivity adjoint (closure fields pass through ignore_derivatives)"
end

# ### Shim 14 (`AR_AD_SAFE_TKE`, default on under `AR_AD=1`): no infinite derivatives in the TKE closure
#
# Breeze's TKE closure evaluates `√N²⁺` and `√|e|` where both can be exactly 0, and hides the result
# behind an `ifelse` (ℓᴺ = Inf where N² ≤ 0; ω = 1/τ where e < 0). The primal is fine; the adjoint is
# not — reverse mode propagates a zero adjoint into the unselected branch and multiplies it by the
# infinite derivative of √ at 0, 0·∞ = NaN, which then floods every cell. (The TKE + column AD run 2410
# gave a finite 1 h gradient and an all-NaN 6 h one.) Floor both radicands at a value far below
# anything physical (N² ≥ 1e-12 s⁻², |e| ≥ 1e-10 m² s⁻²), which keeps every derivative finite and
# changes no selected branch's value measurably.
if closure_kind == "tke" && get(ENV, "AR_AD", "0") == "1" && get(ENV, "AR_AD_SAFE_TKE", "1") == "1" &&
   isdefined(Breeze.TurbulenceClosures, :stratification_mixing_lengthᶜᶜᶠ) &&
   isdefined(Breeze.TurbulenceClosures, :tke_sink_rate)
    @eval Breeze.TurbulenceClosures begin
        @inline function stratification_mixing_lengthᶜᶜᶠ(i, j, k, grid, closure, e, tracers, buoyancy)
            FT = eltype(grid)
            N²⁺ = clip(∂z_b(i, j, k, grid, buoyancy, tracers))
            ℓᴺ = closure.mixing_length.Cᴺ * ℑzᵃᵃᶠ(i, j, k, grid, turbulent_velocityᶜᶜᶜ, closure, e) /
                 sqrt(max(N²⁺, FT(1e-12)))
            return ifelse(N²⁺ == 0, FT(Inf), ℓᴺ)
        end
        @inline function stratification_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
            FT = eltype(grid)
            N²⁺ = clip(ℑbzᵃᵃᶜ(i, j, k, grid, ∂z_b, buoyancy, tracers))
            ℓᴺ = closure.mixing_length.Cᴺ * turbulent_velocityᶜᶜᶜ(i, j, k, grid, closure, e) /
                 sqrt(max(N²⁺, FT(1e-12)))
            return ifelse(N²⁺ == 0, FT(Inf), ℓᴺ)
        end
        @inline function tke_sink_rate(i, j, k, grid, closure, e, B, velocities, tracers, buoyancy)
            FT = eltype(grid)
            eᵐⁱⁿ = closure.minimum_tke
            eᵢ = @inbounds e[i, j, k]
            ℓ = mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, tracers, buoyancy)
            Sᴰ = dissipation_stability_functionᶜᶜᶜ(i, j, k, grid, closure, velocities, tracers, buoyancy)
            τ = closure.negative_tke_damping_time_scale
            ω = ifelse(eᵢ < 0, 1 / τ, Sᴰ * sqrt(max(abs(eᵢ), FT(1e-10))) / ℓ)
            B⁻ = min(0, B)
            ωᴮ = -B⁻ / max(eᵢ, eᵐⁱⁿ) * (eᵢ > eᵐⁱⁿ)
            return ω + ωᴮ
        end
    end
    @info "shim 14: AD-safe TKE closure (√ radicands floored at N² ≥ 1e-12, |e| ≥ 1e-10)"
end

## The same hazards in Breeze #975's closure (env-975 / env-micro: GradientLimitedMixingLength, N² stored
## in closure_fields), whose functions carry different names and signatures.
if closure_kind == "tke" && get(ENV, "AR_AD", "0") == "1" && get(ENV, "AR_AD_SAFE_TKE", "1") == "1" &&
   isdefined(Breeze.TurbulenceClosures, :buoyancy_penetration_depthᶜᶜᶠ)
    @eval Breeze.TurbulenceClosures begin
        @inline function buoyancy_penetration_depthᶜᶜᶠ(i, j, k, grid, closure, e, N²)
            FT = eltype(grid)
            N²⁺ = clip(@inbounds N²[i, j, k])
            ℓᵇ = ℑzᵃᵃᶠ(i, j, k, grid, turbulent_velocityᶜᶜᶜ, closure, e) / sqrt(max(N²⁺, FT(1e-12)))
            return ifelse(N²⁺ == 0, FT(Inf), ℓᵇ)
        end
        @inline function local_mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, N²)
            FT = eltype(grid)
            d = closure.mixing_length.Cˢ * height_above_bottomᶜᶜᶜ(i, j, k, grid)
            N²⁺ = clip(ℑbzᵃᵃᶜ(i, j, k, grid, face_valueᶜᶜᶠ, N²))
            ℓᵇ = turbulent_velocityᶜᶜᶜ(i, j, k, grid, closure, e) / sqrt(max(N²⁺, FT(1e-12)))
            ℓ = min(d, ifelse(N²⁺ == 0, FT(Inf), ℓᵇ))
            return ifelse(isnan(ℓ), d, ℓ)
        end
        @inline function tke_sink_rate(i, j, k, grid, closure, e, B, velocities, closure_fields)
            FT = eltype(grid)
            eᵐⁱⁿ = closure.minimum_tke
            eᵢ = @inbounds e[i, j, k]
            ℓ = mixing_lengthᶜᶜᶜ(i, j, k, grid, closure, e, closure_fields)
            Sᴰ = dissipation_stability_functionᶜᶜᶜ(i, j, k, grid, closure, velocities, closure_fields.N²)
            τ = closure.negative_tke_damping_time_scale
            ω = ifelse(eᵢ < 0, 1 / τ, Sᴰ * sqrt(max(abs(eᵢ), FT(1e-10))) / ℓ)
            B⁻ = min(0, B)
            ωᴮ = -B⁻ / max(eᵢ, eᵐⁱⁿ) * (eᵢ > eᵐⁱⁿ)
            return ω + ωᴮ
        end
    end
    @info "shim 14 (#975 closure): AD-safe buoyancy penetration depth, local mixing length, TKE sink"
end
initial_tke = parse(FT, get(ENV, "AR_TKE_INITIAL", "1e-3"))
stage("turbulence closure: $(isnothing(closure) ? "none" : summary(closure))")
explicit_scalar_advection = breeze_extension.default_nested_scalar_advection(microphysics)

if aiva
    implicit_vertical = AdaptiveVerticallyImplicitDiscretization(cfl = 0.5)
    momentum_advection = WENO(order = 5, time_discretization = implicit_vertical)
    scalar_names = keys(explicit_scalar_advection)
    scalar_advection = NamedTuple{scalar_names}(map(scalar_names) do name
        name === :ρθ ? WENO(order = 5, time_discretization = implicit_vertical) :
                       WENO(order = 5, bounds = (0, 1), time_discretization = implicit_vertical)
    end)
else
    momentum_advection = WENO(order = 5)
    scalar_advection = explicit_scalar_advection
end

## The TKE tracer ρe is not in NumericalEarth's `default_nested_scalar_advection`, and a tracer missing
## from a NamedTuple `tracer_advection` falls back to Oceananigans' default — second-order `Centered`,
## unbounded (`validate_tracer_advection(::NamedTuple, grid) = Centered(), tuple`), which let e go
## negative and overshoot. Give it the same bounds-preserving WENO(5) as the moisture, limited below
## at 0 on the specific TKE e = ρe/ρ. The upper bound only has to be finite (an `Inf` would put
## Inf/x terms into the limiter, and its derivative, for nothing): `AR_TKE_MAX`, m² s⁻², never binding.
if closure_kind == "tke"
    tke_max = parse(Float64, get(ENV, "AR_TKE_MAX", "1e4"))
    tke_time_discretization = aiva ? (; time_discretization = implicit_vertical) : (;)
    scalar_advection = merge(scalar_advection,
                             (ρe = WENO(order = 5, bounds = (zero(tke_max), tke_max); tke_time_discretization...),))
end
stage("scalar advection: " * join(("$(name) => $(summary(scheme))" for (name, scheme) in pairs(scalar_advection)), ", "))

# ### Shim 5: a host-decided acoustic substep count
#
# Δt has to be known here, not at the stepping section below, because the split-explicit dynamics
# needs it to size its acoustic substep loop.
#
# Breeze sizes that loop from the acoustic CFL:
# `Nτ = max(1, ceil(Int, Δt · √(γᵈ Rᵈ · 300) / (acoustic_cfl · Δx_min)))`, with
# `Δx_min = min(minimum_xspacing(grid), minimum_yspacing(grid))`. On a traced grid those spacings are
# `TracedRNumber`s, so `Nτ` is a traced `Int`, `1:Nτ` is a `TracedUnitRange`, and `for substep in 1:Nτ`
# fails with `TypeError: non-boolean (TracedRNumber{Bool}) used in boolean context` — the loop's trip
# count is not known at trace time.
#
# The count is a static property of the grid and Δt, both fixed for a compiled run, so it is decided
# here on the CPU twin — where the spacings are plain numbers — with Breeze's own formula, and handed
# back as a plain `Int` (`substeps`, which takes the `acoustic_substeps(N::Int, …) = N` branch and
# never consults the grid). Same move as the terrain and the polar boundary check: answer it on the
# host, hand the traced model a constant. `AR_ACOUSTIC_SUBSTEPS` overrides.
#
# Note this makes the substep loop UNROLL into the traced module — `Nτ` iterations of the acoustic
# kernels appear per RK3 stage — which is worth knowing when reading the emitted MLIR.

Δt = parse(FT, get(ENV, "AR_DT", "10"))

## ### Shim 13: AIVA's adaptive split step under a traced clock
##
## `AdaptiveVerticallyImplicitDiscretization` keeps its split time step in a host `Ref{FT}` and
## refreshes it every stage from the clock (`update_adaptive_timestep!`): `td.Δt[] = β_stage · Δt`.
## Under Reactant the clock's times are traced, so that store is `Float32(::TracedRNumber)` — a
## `MethodError` while tracing the first step (job 2314). At a FIXED Δt the value is known on the host:
## the stage index is a plain `Int` that the trace unrolls, so bake `stage_fraction(ts, stage) · Δt`
## in per stage. `AIVA_HOST_DT[]` is set to the Δt about to be compiled (spin-up vs AD sweep); a
## traced Δt schedule cannot use this and keeps the last value baked in.
const AIVA_HOST_DT = Ref{Float64}(Δt)
if !VANILLA
    @eval function Oceananigans.Advection.update_adaptive_timestep!(
            scheme::Oceananigans.Advection.AdaptiveImplicitVerticalAdvection,
            model::Breeze.AtmosphereModel{<:Any, <:Any, <:ReactantState})
        td = Oceananigans.TimeSteppers.time_discretization(scheme)
        td.Δt[] = Breeze.TimeSteppers.stage_fraction(model.timestepper, model.clock.stage) * AIVA_HOST_DT[]
        return nothing
    end
end

acoustic_cfl = parse(FT, get(ENV, "AR_ACOUSTIC_CFL", "0.5"))
thermodynamic_constants = Breeze.ThermodynamicConstants(FT)

host_substeps = Breeze.CompressibleEquations.compute_acoustic_substeps(host_grid, Δt,
                                                                      thermodynamic_constants,
                                                                      acoustic_cfl)
# `AR_ADAPTIVE=1` (eager CUDA only) floats Δt with an advective-CFL wizard — see the stepping section.
# The substep count must then follow Δt, so it is left to Breeze (`substeps = nothing`), which
# recomputes it from each stage's interval with the same formula. `AR_ACOUSTIC_SUBSTEPS` still wins.
adaptive_Δt = get(ENV, "AR_ADAPTIVE", "0") == "1"
adaptive_Δt && !VANILLA && error("AR_ADAPTIVE=1 requires AR_ARCH=cuda: a traced loop has a fixed Δt")
acoustic_substeps = haskey(ENV, "AR_ACOUSTIC_SUBSTEPS") ? parse(Int, ENV["AR_ACOUSTIC_SUBSTEPS"]) :
                    adaptive_Δt ? nothing : host_substeps

## Otherwise exactly `default_nested_dynamics(grid; …)`: an upper sponge over the lid, no divergence
## damping, and the script's `base_pressure`. Only `substeps` and `sponge` differ.
##
## `AR_SPONGE=0` drops the Rayleigh sponge. Breeze's `sponge_rhs`/`sponge_term_diag` are reached from
## `_build_vertical_rhs!` and the tridiagonal coefficients, and that kernel does not compile through
## Reactant on this grid — `InvalidIRError: unsupported call to jl_f_throw_methoderror` inside
## `sponge_rhs`, i.e. a dispatch GPUCompiler could not resolve statically, the same failure mode as
## the `AbstractOperation` caveat up top. The `::Nothing` methods are `zero(grid)` and pull neither
## `rnode` nor the ramp into the kernel, so turning the sponge off takes that path out of the trace.
## NOT physics-neutral: the lid loses its Rayleigh damping, so a compiled RUN would reflect vertically
## propagating waves off the top. Fine for inspecting what a step emits, wrong for a science run.
damping_depth = breeze_extension.default_lid_depth(host_grid)
sponge = get(ENV, "AR_SPONGE", "1") == "1" ?
    UpperSponge(damping_rate = lid_damping_rate, depth = damping_depth) : nothing

## `AR_DIVERGENCE_DAMPING=α` (> 0) turns on Breeze's Klemp–Skamarock–Ha acoustic divergence damping
## (`ThermalDivergenceDamping`, Breeze's own default at α = 0.1; explicit bound α ≤ 0.25) in place of
## the NumericalEarth nest default `NoDivergenceDamping()`, which leaves only the off-centred vertical
## solve to damp acoustic noise. A time-step-sweep knob: default 0 keeps the established behaviour.
divergence_damping_coefficient = parse(FT, get(ENV, "AR_DIVERGENCE_DAMPING", "0"))
## `AR_DIVERGENCE_DAMPING_VERTICAL=1` also folds the vertical part into the column tridiag
## (`damp_vertical = true`).
acoustic_damping = divergence_damping_coefficient > 0 ?
    Breeze.CompressibleEquations.ThermalDivergenceDamping(; coefficient = divergence_damping_coefficient,
                                                           damp_vertical = get(ENV, "AR_DIVERGENCE_DAMPING_VERTICAL", "0") == "1") :
    NoDivergenceDamping()

## `AR_FORWARD_WEIGHT=ω` sets the off-centring of the implicit vertical acoustic solve (Breeze default
## 0.65; ω ∈ [0.5, 1], larger damps vertical acoustic modes more).
acoustic_forward_weight = parse(FT, get(ENV, "AR_FORWARD_WEIGHT", "0.65"))

## `AR_OPEN_BOUNDARY_RELAXATION=α` sets Breeze's per-substep relaxation of the outermost open-boundary
## cell's ρ′, (ρθ)′ toward the prescribed wall value (Breeze default 0.5; must be in (0, 1], so ~0 is
## "off"). It is applied every acoustic substep, so its total kick grows with the substep count.
open_boundary_relaxation = parse(FT, get(ENV, "AR_OPEN_BOUNDARY_RELAXATION", "0.5"))

nested_time_discretization = SplitExplicitTimeDiscretization(FT;
                                                             substeps = acoustic_substeps,
                                                             acoustic_cfl,
                                                             sponge,
                                                             damping = acoustic_damping,
                                                             forward_weight = acoustic_forward_weight,
                                                             open_boundary_relaxation)

## Breeze 0.11 renamed the anchor `surface_pressure` → `base_pressure` (the reference pressure at
## z = 0; "surface pressure" now means the derived pressure at a column's ground). NumericalEarth
## followed suit (#698), so `nested_atmosphere_model` takes `base_pressure` too.
dynamics = CompressibleDynamics(nested_time_discretization; base_pressure = p_std)

## `@allowscalar` because regularizing the `Interpolated` lateral boundaries calls
## `validate_source_bracket`, whose `extrema(xnodes(grid))` / `extrema(ynodes(grid))` reduce over the
## grids' 1-D node vectors — `ConcretePJRTArray`s here, so the reduction iterates and trips the
## scalar-indexing guard. That is a host-side geometry check over a few hundred numbers, run once at
## construction, so paying a device round-trip per element is nothing; the point of the guard (do not
## silently iterate a large device array) is not in play. Scoped to this call so nothing else inherits
## the permission — and a scalar loop over an actual FIELD would show up as a stall, not a wrong answer.
# The native parents (`AR_PARENT_KIND=native|boundary`) are built by `build_native_nest` for any child
# grid: the device `grid` (GPU or ReactantState) and, under Reactant, the host twin `host_grid` too,
# whose nest initializes the child (`initialize_nested_child!` cannot run on a Reactant grid; see the
# CPU-twin IC below) and hands its state to the device. The terrain was already blended toward the
# parent's surface elevation on `host_grid` above, so the nest gets `terrain = nothing`.
#
# The parent is built here rather than by `nested_atmosphere_model(grid, dataset; …)`, whose parent
# type changed with NumericalEarth #750 (strips by default), so that `AR_PARENT_KIND` means the same
# thing on either NumericalEarth.
native_dates = start_date:Hour(1):(start_date + Hour(parent_hours))
native_padding = parse(Float64, get(ENV, "AR_NATIVE_PADDING",
                                    string(NumericalEarth.DataWrangling.default_horizontal_padding(dataset))))

function crop_boundary_strip_files(child_grid)
    ## Strip regions are new file names; cut them out of the cached padded child box
    ## (`AR_STRIP_SOURCE_PADDING`, default 0.5° — the box `AR_PARENT_KIND=native` reads) instead of
    ## queueing CDS requests. Same regions as `BoundaryPrescribedAtmosphere(grid, …)` builds.
    box = BoundingBox(child_grid)
    λw, λe = box.longitude
    φs, φn = box.latitude
    w = NumericalEarth.Atmospheres.relaxation_zone_width(child_grid, relax_width)
    p = native_padding
    λ = (λw - p, λe + p)
    φ = (φs - p, φn + p)
    regions = (BoundingBox(longitude = (λw - p, λw + w + p), latitude = φ),
               BoundingBox(longitude = (λe - w - p, λe + p), latitude = φ),
               BoundingBox(longitude = λ, latitude = (φs - p, φs + w + p)),
               BoundingBox(longitude = λ, latitude = (φn - w - p, φn + p)))
    source = BoundingBox(child_grid; padding = parse(Float64, get(ENV, "AR_STRIP_SOURCE_PADDING", "0.5")))
    names = (:temperature, :eastward_velocity, :northward_velocity, :specific_humidity,
             :specific_cloud_liquid_water_content, :specific_rain_water_content,
             :specific_cloud_ice_water_content, :specific_snow_water_content, :geopotential)
    sl = NumericalEarth.DataWrangling.matching_single_level_dataset(dataset)
    made = crop_era5_regions!(regions, source, dataset, names,
                              NumericalEarth.DataWrangling.expand_dates(dataset, :temperature, native_dates),
                              era5_datadir; single_level = ((sl, :geopotential, start_date),))
    stage("boundary strips: cropped $(made) ERA5 files from the cached $(source) box")
    return nothing
end

if PARENT_KIND === :boundary
    isdefined(NumericalEarth.Atmospheres, :BoundaryPrescribedAtmosphere) ||
        error("AR_PARENT_KIND=boundary needs a NumericalEarth with BoundaryPrescribedAtmosphere (#750)")
    include(joinpath(@__DIR__, "era5_crop.jl"))
    crop_boundary_strip_files(host_grid)
end

# Returns `(nest, ic_prognostic_kw)`: the kwargs `initialize_nested_child!` needs for this nest's IC
# (`prognostic` is a #750 keyword; a full parent's default is its own exchanger).
function build_native_nest(child_grid, clock, dynamics)
    arch = Oceananigans.Architectures.architecture(child_grid)
    full_parent(dates) = PrescribedAtmosphere(BoundingBox(child_grid; padding = native_padding), dates, dataset;
                                              architecture = arch, dir = era5_datadir)
    native, snapshot = if PARENT_KIND === :boundary
        strips = NumericalEarth.Atmospheres.BoundaryPrescribedAtmosphere(child_grid, native_dates, dataset;
                                                                         width = relax_width, padding = native_padding,
                                                                         dir = era5_datadir)
        strips, full_parent(native_dates[1:2])
    else
        full = full_parent(native_dates)
        full, full
    end

    kw = PARENT_KIND === :boundary ? (; parent_surface_elevation = NumericalEarth.surface_elevation(snapshot)) : (;)
    nest = Reactant.@allowscalar nested_atmosphere_model(native, child_grid;
                                                         terrain = nothing,
                                                         relaxation_rate = relax_rate,
                                                         relaxation_width = relax_width,
                                                         ## The lid damping knob, where this script defines one.
                                                         (@isdefined(lid_damping_rate) ? (; damping_rate = lid_damping_rate) : (;))...,
                                                         ## Passed explicitly so the anchor matches `dynamics`.
                                                         base_pressure = p_std,
                                                         clock,
                                                         dynamics,
                                                         microphysics,
                                                         closure,
                                                         momentum_advection,
                                                         scalar_advection,
                                                         kw...)

    ## The strips cannot supply an interior state: the IC comes from the full-domain snapshot through
    ## an exchanger that matches the nest's own.
    ic_kw = PARENT_KIND === :boundary ?
        (; prognostic = breeze_extension.state_exchanger(snapshot, first(nest.exchanger)).prognostic) : (;)
    return nest, ic_kw
end

nest = if NATIVE_PARENT
    stage("building the nest with NumericalEarth's own ERA5 parent (AR_PARENT_KIND=$(PARENT_KIND)) — \
           per-column geopotential levels, $(length(native_dates)) hourly dates, padding $(native_padding)°")
    native_nest, native_ic_kw = build_native_nest(grid, model_clock, dynamics)
    stage("$(PARENT_KIND) parent built: $(summary(native_nest.parent))")
    native_balancer = get(ENV, "AR_BALANCER", "0") == "1"
    if VANILLA
        breeze_extension.initialize_nested_child!(native_nest, dataset, start_date, era5_datadir;
                                                  balancer = native_balancer, native_ic_kw...)
    else
        ## Initialize a host twin of the same nest and copy its state to the device (as the hand-rolled
        ## CPU-twin IC below does, minus its parent rebuild: here the twin builds its own native parent).
        stage("native IC on a CPU twin (balancer $(native_balancer ? "on" : "off"))")
        twin, twin_ic_kw = build_native_nest(host_grid, Clock(time = zero(FT)),
                                             CompressibleDynamics(nested_time_discretization; base_pressure = p_std))
        breeze_extension.initialize_nested_child!(twin, dataset, start_date, era5_datadir;
                                                  balancer = native_balancer, twin_ic_kw...)
        twin_prognostics = prognostic_fields(twin.child)
        for (name, f) in pairs(prognostic_fields(native_nest.child))
            copyto!(parent(f), Array(parent(twin_prognostics[name])))
        end
        if !isnothing(native_nest.child.dynamics.reference_state)
            for fname in (:pressure, :density, :exner_function)
                copyto!(parent(getfield(native_nest.child.dynamics.reference_state, fname)),
                        Array(parent(getfield(twin.child.dynamics.reference_state, fname))))
            end
        end
        stage("native IC: copied the twin's initialized state and reference to the device")
    end
    native_nest
else
    Reactant.@allowscalar nested_atmosphere_model(parent_atmosphere, grid;
                                                     terrain = nothing,
                                                     relaxation_rate = relax_rate,
                                                     damping_rate = lid_damping_rate,
                                                     relaxation_width = relax_width,
                                                     base_pressure = p_std,
                                                     clock = model_clock,
                                                     dynamics,
                                                     microphysics,
                                                     closure,
                                                     momentum_advection,
                                                     scalar_advection)
end

child = nest.child

# `AR_TARGET_PROBE_ONLY=1`: dump the Davies/open-BC TARGET fields and stop.
#
# Both the lateral BCs and the interior relaxation drive the child toward `exchanger.prognostic` —
# density-weighted prognostics precomputed from the parent's raw state ON THE PARENT GRID
# (`breeze_nested_atmosphere.jl` lines 6-8), including `ρᵈ` itself, which is nudged alongside `ρθ`
# following WRF and MPAS. So the relaxation operator is SYMMETRIC in mass and heat, and a run that
# gains mass without gaining heat cannot be explained by the operator — only by targets that
# disagree with each other. This reads them directly, which no trajectory run can do: by the time a
# wrong target shows up in `ρᵈ`, it has already been advected, relaxed and mixed.
#
# Costs the nest build (~140 s under AR_ARCH=cuda) and nothing else — no coupling, no compile,
# no stepping.
if get(ENV, "AR_TARGET_PROBE_ONLY", "0") == "1"
    let prog = nest.exchanger.prognostic
        stage("Davies/BC target fields on the PARENT grid (exchanger.prognostic), time level 1:")
        for (nm, fts) in pairs(prog)
            a = Array(parent(fts[1]))
            fin = filter(isfinite, a)
            stage(@sprintf("  %-4s ∈ [%12.5g, %12.5g]  zeros=%7d  nonfinite=%7d  of %d",
                           nm, isempty(fin) ? NaN : minimum(fin), isempty(fin) ? NaN : maximum(fin),
                           count(iszero, a), length(a) - length(fin), length(a)))
        end
        ## The derived intensive quantity is what actually went wrong in the child (θ collapsed to
        ## 114 K while ρθ stayed flat), so form it on the target too: if θ_target is already broken
        ## on the parent grid, the child is faithfully chasing a broken target and the fault is in
        ## the precomputation, not in the relaxation or the boundary condition.
        ##
        ## NOTE the threshold is one-sided, and deliberately so. `ρθ` is density-weighted POTENTIAL
        ## temperature, which rises steeply with height: ~284 K at the surface and ~450-500 K at the
        ## parent's 70 hPa lid are both correct (the child's own initial state reads 438 K at the
        ## model top). So a HIGH θ is not evidence of anything. A low one is: atmospheric θ does not
        ## go below ~250 K anywhere, so θ < 250 K can only be contamination.
        if haskey(prog, :ρᵈ) && haskey(prog, :ρθ)
            ρ = Array(parent(prog.ρᵈ[1])); ρθ = Array(parent(prog.ρθ[1]))
            ok = findall(x -> isfinite(x) && x > 0, ρ)
            θ = [ρθ[I] / ρ[I] for I in ok]
            stage(@sprintf("  θ_target = ρθ/ρᵈ ∈ [%.2f, %.2f] K over %d cells with ρᵈ > 0",
                           minimum(θ), maximum(θ), length(θ)))
            for lim in (250, 200, 150)
                stage(@sprintf("  θ_target < %d K: %d cells (%.3f%%)  [high θ is physical, not checked]",
                               lim, count(<(lim), θ), 100count(<(lim), θ) / length(θ)))
            end
            bad = count(<(250), θ)

            ## WHERE the bad targets sit decides whether this is a physics error or an ugly halo the
            ## child never reads. `ρᵈ` is relaxed toward these values inside the 5-cell rind, so an
            ## INTERIOR bad target is forcing the child directly; a halo-only one is inert.
            badI = [I for (I, t) in zip(ok, θ) if t < 250]
            if !isempty(badI)
                halos = Oceananigans.Grids.halo_size(parent_grid)
                Hx, Hy, Hz = halos[1], halos[2], halos[3]
                Nlev = length(parent_pressure_levels)
                isint(I) = Hx < I[1] <= Hx + parent_Nx && Hy < I[2] <= Hy + parent_Ny &&
                           Hz < I[3] <= Hz + Nlev
                ni = count(isint, badI)
                stage(@sprintf("  θ_target < 250 K: i ∈ [%d, %d] (interior %d:%d), j ∈ [%d, %d] \
                                (interior %d:%d), k ∈ [%d, %d] (interior %d:%d)",
                               minimum(I[1] for I in badI), maximum(I[1] for I in badI), Hx + 1, Hx + parent_Nx,
                               minimum(I[2] for I in badI), maximum(I[2] for I in badI), Hy + 1, Hy + parent_Ny,
                               minimum(I[3] for I in badI), maximum(I[3] for I in badI), Hz + 1, Hz + Nlev))
                stage(@sprintf("  %d of %d cold θ_target cells are INTERIOR (%.1f%%)",
                               ni, length(badI), 100ni / length(badI)))
                if ni > 0
                    intI = filter(isint, badI)
                    stage(@sprintf("    interior bad cells: k ∈ [%d, %d] (of %d levels, interior k=%d is the SURFACE)",
                                   minimum(I[3] for I in intI) - Hz, maximum(I[3] for I in intI) - Hz,
                                   Nlev, 1))
                end
            end
        end
    end
    stage("AR_TARGET_PROBE_ONLY=1 — stopping after the target probe")
    exit(0)
end

stage("nest built (exchanger window filled, open BCs + Davies forcing in place); " *
      (isnothing(acoustic_substeps) ? "acoustic substeps recomputed from each Δt at CFL $(acoustic_cfl); " :
       "$(acoustic_substeps) acoustic substeps per step (host-decided at CFL $(acoustic_cfl)); ") *
      "upper sponge $(isnothing(sponge) ? "OFF" : "on")")

# ## Initial condition
#
# Written straight into the child's DENSITY-WEIGHTED PROGNOSTICS, one analytic function per field.
#
# The usual route — `initialize_nested_child!`, or `set!(model; ρ, θˡⁱ, qᵗ, u, v)` — goes through
# Oceananigans field algebra (`set!(model.moisture_density, ρ * qᵛᵉ)` and friends), and a Field-level
# broadcast whose grid is a `LatitudeLongitudeGrid` does not compile under Reactant: the KA kernel
# raises `InvalidIRError: unsupported call to jl_f_throw_methoderror`, eagerly and inside `@jit`
# alike (a `RectilinearGrid` is fine, which is why Breeze's own Reactant tests do not see this).
# Setting each prognostic from a function avoids field algebra altogether — `set_to_function!`
# evaluates on a CPU twin of the grid and copies the result over.
#
# The analytic state is mapped to prognostics with the SAME thermodynamic functions the exchanger's
# kernel uses (`air_density`, `liquid_ice_potential_temperature`) and the same density weighting
# (dry-weighted momentum and energy, total-weighted vapor), so the interior initial state and the
# parent-derived boundary values agree at the walls to interpolation error — the property the
# interpolated IC exists to guarantee. What is skipped is `reset_reference_state!`: the dynamics keeps
# the reference profile it was built with, anchored to `base_pressure` above.

constants = child.thermodynamic_constants
pˢᵗ = child.dynamics.standard_pressure
Rᵈ = Breeze.dry_air_gas_constant(constants)
Rᵛ = Breeze.vapor_gas_constant(constants)

## The moisture prognostic's NAME comes from the microphysics (`ρqᵉ` for the 1-moment mixed-phase
## scheme, `ρqᵛ` for others) — the same lookup `nested_atmosphere_model` uses to key its moisture
## boundary condition, so the IC and the boundary target land on the same field. Hardcoding `ρqᵛ`
## silently leaves the real moisture prognostic at zero.
moisture_name = Breeze.moisture_prognostic_name(microphysics)

## The exchanger hands the child precipitation-free air: under an equilibrium scheme (`ρqᵉ`) the
## moisture slot carries vapor + CLOUD condensate, otherwise vapor alone, and θˡⁱ gives up latent heat
## for exactly that condensate. Rain and snow still load the density (they are not dry gas).
const equilibrium_moisture = moisture_name === :ρqᵉ

@inline slot_cloud_liquid(λ, φ, z) = equilibrium_moisture ? cloud_liquid_specific_humidity(λ, φ, z, 0) : zero(z)
@inline slot_cloud_ice(λ, φ, z)    = equilibrium_moisture ? cloud_ice_specific_humidity(λ, φ, z, 0) : zero(z)

@inline function initial_density(λ, φ, z)
    T = air_temperature(λ, φ, z, 0)
    qᵛ = vapor_specific_humidity(λ, φ, z, 0)
    qˡ = liquid_specific_humidity(λ, φ, z, 0)
    qⁱ = ice_specific_humidity(λ, φ, z, 0)
    return breeze_extension.air_density(T, qᵛ, qˡ, qⁱ, isa_pressure(z), Rᵈ, Rᵛ)
end

@inline function initial_potential_temperature(λ, φ, z)
    T = air_temperature(λ, φ, z, 0)
    qᵛ = vapor_specific_humidity(λ, φ, z, 0)
    return breeze_extension.liquid_ice_potential_temperature(T, qᵛ, slot_cloud_liquid(λ, φ, z),
                                                             slot_cloud_ice(λ, φ, z), isa_pressure(z),
                                                             pˢᵗ, constants)
end

@inline initial_total_humidity(λ, φ, z) = vapor_specific_humidity(λ, φ, z, 0) +
                                          liquid_specific_humidity(λ, φ, z, 0) +
                                          ice_specific_humidity(λ, φ, z, 0)

## ρᵈ = ρ (1 − qᵗ) is the prognostic density; momentum and energy are dry-weighted, vapor total-weighted.
@inline initial_dry_density(λ, φ, z) = initial_density(λ, φ, z) * (1 - initial_total_humidity(λ, φ, z))

## Total-weighted moisture density, matching the exchanger's `ρqᵛᵉ = ρ qᵛᵉ` (which is what the lateral
## boundaries and the Davies relaxation drive this field toward).
moisture_density(λ, φ, z) = initial_density(λ, φ, z) *
    (vapor_specific_humidity(λ, φ, z, 0) + slot_cloud_liquid(λ, φ, z) + slot_cloud_ice(λ, φ, z))

analytic_prognostics = merge((ρᵈ = initial_dry_density,
                              ρθ = (λ, φ, z) -> initial_dry_density(λ, φ, z) *
                                                initial_potential_temperature(λ, φ, z),
                              ρu = (λ, φ, z) -> initial_dry_density(λ, φ, z) *
                                                eastward_velocity(λ, φ, z, 0),
                              ρv = (λ, φ, z) -> initial_dry_density(λ, φ, z) *
                                                northward_velocity(λ, φ, z, 0)),
                             NamedTuple{tuple(moisture_name)}(tuple(moisture_density)))

# ### `AR_IC=interpolated`: the real initial condition, instead of the analytic one
#
# `initialize_nested_child!` interpolates the exchanger's parent-derived prognostics onto the child
# interior — the SAME quantities, through the same `interpolate!`, that drive the lateral boundaries.
# That makes the interior IC and the prescribed boundary agree at the walls, so there is no standing
# density jump forcing spurious vertical velocity, and it is the path a real ERA5 run must take.
#
# It was previously unusable here: its field algebra went through `Field(ρᵈ + ρqᵛ)`, and `compute!`ing
# an `AbstractOperation` launches a KA kernel that does not compile under Reactant whenever the grid
# carries materialized coordinates. NumericalEarth now writes that algebra as a broadcast over
# `interior`, which stays inside Reactant's array operations — so this path is open.
#
# `dataset`, `date` and `dir` are unused by the function body (it reads the exchanger, not disk), so
# `nothing` is passed for all three.
#
# `AR_BALANCER=1` additionally runs the adiabatic (DFI) balancer. Off by default, following the
# function's own docstring: skipping it isolates whether the interpolated IC steps stably on its own.
ic_mode = Symbol(get(ENV, "AR_IC", "analytic"))

if NATIVE_PARENT
    ## Already done inside `nested_atmosphere_model(grid, dataset; …)`, from the real dataset at
    ## `first(dates)` rather than from `nothing` — calling it again here would redo the same
    ## interpolation against a parent it would have to rediscover.
    stage("child initialized: by nested_atmosphere_model(grid, dataset) itself \
           (balancer $(get(ENV, "AR_BALANCER", "0") == "1" ? "on" : "off"))")
elseif ic_mode === :interpolated
    # The interpolated ERA5 IC is initialized on a CPU TWIN of the nest and copied to the device. Two
    # steps of `initialize_nested_child!` cannot run on a Reactant grid, and BOTH matter for a stable
    # real-ERA5 start:
    #   * `set!(...; compute_reference_state=true)` → `reset_reference_state!` is shim-8-skipped on a
    #     Reactant grid (3 KA/array-mode blockers), leaving the ERA5 interior on the standard-288 K
    #     reference.
    #   * the DFI `balancer` (adiabatic init) that removes the coarse-interpolation imbalance takes an
    #     auto Δt from `minimum_zspacing(grid)` — a TRACED value on the device (shim 10) — fine on CPU.
    # Both run correctly on `host_grid`, which the device `grid` is `on_architecture`'d FROM, so the two
    # child grids are geometrically identical and a whole-array `copyto!` is exact. Without the balancer
    # the raw interpolated state blows up when stepped (ρᵈ → 20+, ρu → 400+ by ~iter 40; runs 1357/1386
    # — and the reference recompute ALONE did not fix it, the trajectory was ~identical, so the balancer
    # is the operative piece). So: build the twin, run the FULL balanced init on it, and copy its
    # balanced prognostic STATE + 3D reference onto the device child. The device's own
    # `initialize_nested_child!` is then unnecessary (it would re-pay ~48 min of eager compilation) and
    # is skipped. `AR_BALANCER=0` disables the DFI balance; `AR_IC_CPU_TWIN=0` reverts to on-device init.
    balancer = get(ENV, "AR_BALANCER", "1") == "1"

    if get(ENV, "AR_IC_CPU_TWIN", "1") == "1" && arch isa ReactantState
        stage("interpolated IC on a CPU twin (balancer $(balancer ? "on" : "off"), reference recomputed)")

        cpu_pgrid = LatitudeLongitudeGrid(CPU(); longitude = parent_λ, latitude = parent_φ, z = parent_z,
                                          size = (parent_Nx, parent_Ny, length(parent_pressure_levels)),
                                          halo = (5, 5, 5), topology = (Bounded, Bounded, Bounded))
        ## CPU FieldTimeSeries mirroring each device parent field, its ERA5 data copied host-side.
        cpu_fts(dev) = begin
            f = FieldTimeSeries{Center, Center, Center}(cpu_pgrid, parent_times)
            for n in 1:length(parent_times)
                copyto!(parent(f[n]), Array(parent(dev[n])))
            end
            f
        end
        ## The twin's parent pressure is the DEVICE parent's, whatever `AR_PARENT_PRESSURE` built
        ## (isa / hydrostatic / column) — it used to be the isothermal placeholder unconditionally, so the
        ## IC was balanced against a different pressure than the boundaries and relaxation then imposed.
        cpu_pressure = CenterField(cpu_pgrid)
        ## `AR_TWIN_ISA_PRESSURE=1` restores the old placeholder, to reproduce runs made before the fix.
        get(ENV, "AR_TWIN_ISA_PRESSURE", "0") == "1" ?
            set!(cpu_pressure, (λ, φ, z) -> isa_pressure(z)) :
            copyto!(parent(cpu_pressure), Array(parent(parent_pressure)))
        cpu_parent = PrescribedAtmosphere(cpu_pgrid, parent_times;
                                          velocities = (u = cpu_fts(u_parent), v = cpu_fts(v_parent)),
                                          temperature = cpu_fts(T_parent),
                                          specific_humidity = cpu_fts(q_parent),
                                          microphysical_variables = (qᶜˡ = cpu_fts(qᶜˡ_parent),
                                                                     qʳ = cpu_fts(qʳ_parent),
                                                                     qᶜⁱ = cpu_fts(qᶜⁱ_parent),
                                                                     qˢ = cpu_fts(qˢ_parent)),
                                          pressure = cpu_pressure,
                                          precipitation_flux = nothing)

        ## Same nest as the device one (identical kwargs), on the CPU twin grid + a plain clock.
        ## AR_BOTTOM_DRAG=<Cᴰ> adds a BulkDrag bottom stress (the bare nest otherwise has none, unlike
        ## downscale.jl which gets surface drag from its ocean coupling). Diagnostic for whether the
        ## ERA5-interior bottom-corner blow-up is undamped near-surface momentum. 0 disables.
        twin_drag = parse(Float64, get(ENV, "AR_BOTTOM_DRAG", "0"))
        cpu_nest = nested_atmosphere_model(cpu_parent, host_grid;
                                           terrain = nothing,
                                           relaxation_rate = relax_rate,
                                           damping_rate = lid_damping_rate,
                                           relaxation_width = relax_width,
                                           base_pressure = p_std,
                                           clock = Clock(time = zero(FT)),
                                           dynamics = CompressibleDynamics(nested_time_discretization;
                                                                           base_pressure = p_std),
                                           bottom_drag_coefficient = twin_drag > 0 ? twin_drag : nothing,
                                           drag_surface_temperature = twin_drag > 0 ?
                                               parse(FT, get(ENV, "AR_DRAG_TSFC", "285")) : nothing,
                                           microphysics,
                                           closure,
                                           momentum_advection,
                                           scalar_advection)
        breeze_extension.initialize_nested_child!(cpu_nest, nothing, nothing, nothing; balancer)

        ## ### `AR_TWIN_STEP_TEST=N`: step the CPU twin itself, to localize the ERA5-interior blow-up.
        ## The device run blows up identically with reference recompute and with the DFI balancer (ρw
        ## → −12 m/s in one step, ρᵈ → 20+; jobs 1357/1386/1387). Stepping the SAME balanced state on
        ## the CPU twin — plain Julia/KA, no XLA, no traced clock — separates a genuine model
        ## instability (blows up here too ⇒ Δt/substeps/vertical-interpolation) from a device/Reactant
        ## numerical difference (stable here ⇒ the compiled path differs). Reports ρw/ρᵈ then exits.
        let ntest = parse(Int, get(ENV, "AR_TWIN_STEP_TEST", "0"))
            if ntest > 0
                stage("CPU-twin step test: stepping the CPU nest $(ntest)× at Δt=$(Δt)s (no device compile)")
                first_time_step!(cpu_nest, Δt)
                for i in 0:ntest
                    i > 0 && time_step!(cpu_nest, Δt)
                    b = map(prognostic_fields(cpu_nest.child)) do f
                        x = interior(f); (minimum(x), maximum(x),
                                          sum(ifelse.(isfinite.(x), 0f0, 1f0)))
                    end
                    @info @sprintf("twin iter=%3d: %s", i,
                                   join(["$name∈[$(round(lo,sigdigits=4)),$(round(hi,sigdigits=4))]$(bad==0 ? "" : " <$(Int(bad)) NF>")"
                                         for (name, (lo, hi, bad)) in pairs(b)], ", "))
                end
                stage("CPU-twin step test done — exiting before the device compile")
                exit(0)
            end
        end

        ## Copy the balanced prognostic state, device ← CPU twin. `parent(f)` is the whole array, so
        ## halos come along too (the twin's `update_state!` already filled them consistently).
        cpu_prog = prognostic_fields(cpu_nest.child)
        for (name, f) in pairs(prognostic_fields(nest.child))
            copyto!(parent(f), Array(parent(cpu_prog[name])))
        end
        ## Copy the 3D reference (pressure/density/exner_function) too.
        if !isnothing(nest.child.dynamics.reference_state)
            dref = nest.child.dynamics.reference_state
            cref = cpu_nest.child.dynamics.reference_state
            for fname in (:pressure, :density, :exner_function)
                copyto!(parent(getfield(dref, fname)), Array(parent(getfield(cref, fname))))
            end
        end
        let r = cpu_nest.child.dynamics.reference_state
            stage(@sprintf("interpolated IC: copied balanced state + reference from CPU twin \
                            (ref p ∈ [%.0f, %.0f] Pa, ρ ∈ [%.4g, %.4g] kg/m³)",
                           minimum(interior(r.pressure)), maximum(interior(r.pressure)),
                           minimum(interior(r.density)), maximum(interior(r.density))))
        end
    else
        breeze_extension.initialize_nested_child!(nest, nothing, nothing, nothing; balancer)
        stage("child initialized: INTERPOLATED on-device (balancer $(balancer ? "on" : "off"))")
    end
else
    ## Any prognostic the analytic state does not name — ρw and the precipitating species — starts at
    ## rest/zero, zeroed on the raw array so no Field-level broadcast is involved.
    for (name, field) in pairs(prognostic_fields(child))
        if haskey(analytic_prognostics, name)
            set!(field, getproperty(analytic_prognostics, name))
        else
            fill!(parent(field), 0)
        end
    end

    ## Name the split explicitly: a prognostic silently zeroed because the analytic map does not know
    ## its name would be a quiet physics bug, not an error.
    analytic_names = filter(name -> haskey(analytic_prognostics, name), keys(prognostic_fields(child)))
    zeroed_names = filter(name -> !haskey(analytic_prognostics, name), keys(prognostic_fields(child)))
    stage("child initialized: analytic $(analytic_names), at rest $(zeroed_names)")

    ## Writing prognostic fields directly leaves the diagnostics (temperature, pressure, …) unset.
    ## The bare nest recomputes them on its first step, but the coupled model computes surface fluxes
    ## from them FIRST, so without this every cell is NaN after one step under AR_ARCH=cuda. Not run
    ## under Reactant, where an eager `update_state!` on the traced grid has not been tried.
    if VANILLA
        Oceananigans.TimeSteppers.update_state!(nest)
        stage("analytic IC: diagnostics computed (update_state!)")
    end
end

## Seed the TKE: every IC path above leaves ρe at zero (the parent carries no turbulence), and at
## e = 0 the closure's √e diffusivities and shear production stay zero forever.
if haskey(prognostic_fields(child), :ρe)
    ## Whole-parent host round trip: a broadcast over `interior` views of Reactant arrays scalar-indexes.
    copyto!(parent(prognostic_fields(child).ρe), initial_tke .* Array(parent(prognostic_fields(child).ρᵈ)))
    VANILLA && Oceananigans.TimeSteppers.update_state!(nest)
    stage("TKE seeded: ρe = $(initial_tke) m² s⁻² × ρᵈ")
end

# ## Prescribed ocean surface (in place of the ERA5 SST snapshot)
#
# An analytic SST — warm in the southwest, cool in the northeast — with land cells (elevation above
# a metre) carrying a colder "skin" temperature that follows the terrain, mirroring `downscale.jl`'s
# ERA5 skin-temperature fallback. Land still feels ocean-type (Charnock) roughness, as it does there.

ocean_grid = LatitudeLongitudeGrid(arch;
                                   longitude, latitude,
                                   size = (Nx, Ny),
                                   halo = (5, 5),
                                   topology = (Bounded, Bounded, Flat))

@inline open_ocean_temperature(λ, φ) = 293.15 - 0.42 * (φ - 25) + 0.03 * (λ + 140)

@inline function surface_temperature(λ, φ)
    h = terrain_elevation(λ, φ)
    ocean = open_ocean_temperature(λ, φ)
    return h > 1 ? ocean - 4 - 6.5e-3 * h : ocean
end

# `AR_SST=era5` replaces the analytic field with the cached ERA5 snapshot at `start_date` — `sst` over
# open water, `skt` (skin temperature) over land and sea ice, as `downscale.jl` does — sampled at the
# nearest 0.25° point to each child cell centre. Read from the corridor box cache (`AR_SST_REGION`).
if get(ENV, "AR_SST", "analytic") == "era5"
    const NCDatasets = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "NCDatasets")
    sst_box = get(ENV, "AR_SST_REGION", "-170.5_-109.5_24.5_60.5")
    era5_single(name, var) = NCDatasets.NCDataset(joinpath(era5_datadir,
            "$(name)_ERA5HourlySingleLevel_$(Dates.format(start_date, "yyyy-mm-ddTHH"))_$(sst_box).nc")) do ds
        x = ds[var]
        values = ndims(x) == 3 ? x[:, :, 1] : x[:, :]
        (Float64.(ds["longitude"][:]), Float64.(ds["latitude"][:]), Float64.(coalesce.(values, NaN)))
    end
    sst_λ, sst_φ, sst_values = era5_single("sea_surface_temperature", "sst")
    _, _, skt_values = era5_single("skin_temperature", "skt")
    λc = λnodes(host_grid, Center(), Center(), Center())
    φc = φnodes(host_grid, Center(), Center(), Center())
    const era5_surface_temperature = [begin
                                          i = argmin(abs.(sst_λ .- λc[ic])); j = argmin(abs.(sst_φ .- φc[jc]))
                                          isfinite(sst_values[i, j]) && terrain_elevation(λc[ic], φc[jc]) ≤ 1 ?
                                              sst_values[i, j] : skt_values[i, j]
                                      end for ic in 1:Nx, jc in 1:Ny]
    @inline function surface_temperature(λ, φ)
        i = clamp(round(Int, (λ - λ₁) / Δ + 0.5), 1, Nx)
        j = clamp(round(Int, (φ - φ₁) / Δ + 0.5), 1, Ny)
        return @inbounds era5_surface_temperature[i, j]
    end
    stage(@sprintf("AR_SST=era5: ERA5 sst/skt at %s, %.1f–%.1f K", start_date,
                   extrema(era5_surface_temperature)...))
end

ocean = PrescribedOcean(ocean_grid)
set!(ocean.sea_surface_temperature[1], surface_temperature)

# ## Radiation
#
# Off by default: `update_radiation!` decides whether to solve from `clock.iteration == 0 ||
# schedule(model)`, and both halves of that are traced values under Reactant. `AR_RADIATION=1`
# builds the same all-sky RRTMGP configuration as `downscale.jl` (with a constant albedo in place of
# the CGLS 1 km blue-sky albedo, which is a download) so the failure can be reproduced or a fix
# checked.

# The SCHEDULE has to be an `IterationInterval`, not `downscale.jl`'s `TimeInterval(1hour)`.
# `TimeInterval` cannot be traced, and not merely because of a branch (job 4845):
#
#     function (schedule::TimeInterval)(model)
#         t = model.clock.time
#         t★ = next_actuation_time(schedule)
#         if t ≥ t★                            # traced Bool → TypeError
#             if schedule.actuations < typemax(Int)
#                 schedule.actuations += 1     # MUTATES host-side state
#                 while … end                  # host loop on a traced comparison
#
# It keeps a mutable actuation counter and advances it as a side effect of being asked whether to
# fire, so no amount of `@trace if` in `update_radiation!` can help: the bookkeeping itself cannot
# happen inside a trace. `IterationInterval` is stateless and branch-free by construction —
#
#     (schedule::IterationInterval)(model) = (model.clock.iteration - schedule.offset) % schedule.interval == 0
#
# — pure arithmetic returning exactly the `TracedRNumber{Bool}` the traced branch wants. Oceananigans
# says as much itself: `prognostic_state(::IterationInterval) = nothing`, "IterationInterval has no
# state".
#
# `AR_RADIATION_EVERY` sets the interval, default 1 (every step). That is deliberate for AD: with a
# schedule that does NOT fire inside the differentiated window, radiation only shifts the base state
# and `∂J/∂c` carries no radiative sensitivity at all — the traced branch just selects the no-solve
# side at every step. Firing every step costs an RRTMGP solve per step and is the only way the
# gradient sees the radiation pathway.
radiation = if get(ENV, "AR_RADIATION", "0") == "1"
    radiation_every = parse(Int, get(ENV, "AR_RADIATION_EVERY", "1"))
    stage(VANILLA ? "radiation: all-sky RRTMGP on TimeInterval($(radiation_every) Δt) — once per interval" :
                    "radiation: all-sky RRTMGP on IterationInterval($(radiation_every)) — NOT TimeInterval, \
                     which mutates host state and cannot be traced")
    ## A bare nest must bind the surface temperature ITSELF. The RTM constructors accept
    ## `surface_temperature = nothing` so a coupled model can wire its interface SST in afterwards, and
    ## solving without one throws (`assert_bound_surface_temperature`, job 4846):
    ##
    ##     ArgumentError: This RadiativeTransferModel has no surface temperature … (coupled models
    ##     wire their interface surface temperature automatically)
    ##
    ## Nothing wires it here, so hand it the prescribed ocean's SST field — already built above on a
    ## grid with the child's horizontal extent, and already carrying the terrain lapse correction over
    ## land. `AR_RADIATION_SURFACE_T=<K>` substitutes a constant instead.
    rad_surface_T_env = get(ENV, "AR_RADIATION_SURFACE_T", "sst")
    rad_surface_T = rad_surface_T_env == "sst" ? ocean.sea_surface_temperature[1] :
                                                 parse(Float64, rad_surface_T_env)
    stage("radiation surface temperature: $(rad_surface_T_env == "sst" ?
          "the prescribed ocean SST field" : "constant $(rad_surface_T) K")")

    ## The SOLAR POSITION cannot be `ApparentSolarPosition` under Reactant. That type derives the true
    ## solar geometry from a wall-clock `DateTime` built out of the model clock:
    ##
    ##     compute_datetime(t::Number, epoch::AbstractDateTime) = epoch + Millisecond(round(Int, 1000t))
    ##
    ## and with a traced `t` the `round(Int, …)` is `Int64(::TracedRNumber{Int64})` — a `MethodError`
    ## (jobs 4847/4848). This is not a missing method: a `DateTime` has no traced representation, so
    ## there is nothing to add. Any solar position that consults the calendar is out.
    ##
    ## `FixedCosineZenith(cos θ_z)` holds one number and never touches the clock, so it traces.
    ##
    ## !!! note "Choosing cos θ_z, and what it costs"
    ##     The default 0.35 is roughly local NOON in December at 47°N (θ_z ≈ 69°), chosen so the
    ##     shortwave solver is actually exercised rather than short-circuited.
    ##
    ##     It does NOT match this case's start hour. At 2025-12-07T12:00 UTC the domain (148–112°W)
    ##     spans local solar times of about 02:00–04:30 — pre-dawn everywhere, i.e. cos θ_z ≈ 0 and
    ##     longwave only. Set `AR_SOLAR_COS_ZENITH=0` for that, at the price of never testing the
    ##     shortwave path. A fixed zenith also means no diurnal cycle at all, which is harmless over a
    ##     20 s AD window and wrong over a multi-hour run — `DiurnalSolarPosition` is the traceable
    ##     option there (analytic, no calendar), if that becomes the configuration of interest.
    ##
    ## None of that applies under `AR_ARCH=cuda`, where nothing is traced: there `AR_SOLAR=apparent` (the
    ## default on that path) uses Breeze's `ApparentSolarPosition` with `epoch = start_date`, i.e. the
    ## real sun for each column and model time — the diurnal cycle a multi-hour hindcast needs.
    ## `AR_SOLAR=fixed` keeps `FixedCosineZenith(AR_SOLAR_COS_ZENITH)` on either path.
    solar_mode = get(ENV, "AR_SOLAR", VANILLA ? "apparent" : "fixed")
    solar_mode == "apparent" && !VANILLA && error("AR_SOLAR=apparent consults the calendar and cannot be traced")
    cos_zenith = parse(Float64, get(ENV, "AR_SOLAR_COS_ZENITH", "0.35"))
    solar_position = solar_mode == "apparent" ? ApparentSolarPosition(epoch = start_date) :
                                                FixedCosineZenith(cos_zenith)
    solar_mode == "apparent" ?
        stage("radiation solar position: ApparentSolarPosition(epoch = $(start_date)) — real diurnal cycle") :
        stage(@sprintf("radiation solar position: FixedCosineZenith(%.3g) — no calendar, so traceable; \
                        %s", cos_zenith,
                       cos_zenith == 0 ? "longwave only (matches the case's pre-dawn start hour)" :
                                         "exercises the shortwave solver (NOT the case's start hour, which is pre-dawn)"))

    ## Eagerly, `IterationInterval` solves the radiation more than once per interval: `update_state!`
    ## runs after every Runge–Kutta stage and asks the schedule each time, and the clock's iteration
    ## only ticks at the end of the step, so `iteration % interval == 0` holds for the final update of
    ## step n-1 AND the first two stages of step n — three RRTMGP solves per interval (job 2266:
    ## ~0.5 s each on an A100, the run's largest single cost at Δt ≥ 30 s). `TimeInterval` counts its
    ## actuations and fires once; its host-side bookkeeping is exactly what cannot be traced, so the
    ## Reactant path keeps `IterationInterval`.
    radiation_schedule = VANILLA ? TimeInterval(radiation_every * Δt) : IterationInterval(radiation_every)

    RadiativeTransferModel(grid, AllSkyOptics(), child.thermodynamic_constants;
                           solar_position,
                           surface_albedo = 0.1,
                           surface_temperature = rad_surface_T,
                           schedule = radiation_schedule)
else
    nothing
end

# ## Coupled model
#
# `AtmosphereOceanModel(Simulation(nest), ocean)`, exactly as in `downscale.jl`. This SUCCEEDS on the
# current checkouts (job 6118) and is the configuration to run: it is the same atmosphere as the bare
# nest plus Monin–Obukhov surface fluxes over the prescribed ocean.
#
# The `try` is still here because "does this NumericalEarth couple a `NestedModel` under Reactant" is
# a property of the checkout, not of this script, and the point of the script is to reach the
# compiled step. Three answers of "no" are on record and the predicate below matches all three:
#
#   * `MethodError`. NumericalEarth's Breeze↔ESM interface (`thermodynamics_parameters`,
#     `surface_layer_height`, `interpolate_state!`, …) dispatches on `Breeze.AtmosphereModel` and
#     `Simulation{<:Breeze.AtmosphereModel}`; a `NestedModel` wrapping a Breeze child matches
#     neither. `pb/cleanup` forwards them; a checkout without the forwards does not.
#   * `InvalidIRError`. `ComponentExchanger` asks Breeze for `surface_precipitation_flux`, which for
#     the 1-moment scheme builds a `Field(::KernelFunctionOperation)`, and that constructor eagerly
#     `compute!`s it. Fixed by Oceananigans b2ea52a84, which recomputes an operation's eltype from
#     its ADAPTED operands instead of pinning the pre-adaptation type. Matched by type NAME because
#     `InvalidIRError` lives in GPUCompiler, not a direct dependency of this project.
#   * `ErrorException("Scalar indexing is disallowed")`. `PrescribedOcean`'s exchanger seeded its
#     state with `interior(T) .= interior(fts)[:, :, :, 1]`; `interior` is a view, and `getindex` on
#     a view falls back to Base's one-element-at-a-time Cartesian loop. Fixed in NumericalEarth's
#     `copy_prescribed_time_level!`, which slices `parent(fts)` so the backend's own `getindex`
#     handles it. This one fires FIRST — the ocean's exchanger is built before the atmosphere's — so
#     while it stood, the `InvalidIRError` above was never even reached.
#
# `minrepro_coupled.jl` is the write-up. `AR_COUPLED=0` skips the attempt entirely, and
# `AR_STOP_AFTER_COUPLING=1` (below) stops here, which is how to re-check coupling without paying
# for the compile.
#
# ### The Monin–Obukhov solver has to run a FIXED number of iterations
#
# `SimilarityTheoryFluxes` defaults to `ConvergenceStopCriteria(1e-8, 100)`, which stops the
# characteristic-scale fixed point when the drift in `(u★, θ★, q★)` falls below a tolerance. That is
# a DATA-DEPENDENT trip count, and it lowers to an `scf.while` whose condition reads the iterate:
#
#     error: cannot raise op to stablehlo
#     %149:6 = "scf.while"(…)                       ← julia_iterate_interface_fluxes_…
#       … %477 = arith.addf(%476, %475) : f32       ← |Δu★| + |Δθ★| + |Δq★|
#         %478 = arith.cmpf(%477, %21) …            ← < tolerance
#
# `raise-affine-to-stablehlo` cannot raise that (job 6125). `FixedIterations(n)` makes `iterating`
# just `iteration < n`, a counted loop the raise handles — and it is what a differentiable version
# needs anyway, since a convergence test is not something the reverse sweep can unroll either.
#
# `AR_FLUX_ITERATIONS` sets `n`, default 10. That is a physics knob, not a formality: the fixed point
# converges in a handful of iterations over ocean under near-neutral conditions and more slowly in
# strongly stable stratification, so a too-small `n` leaves the surface fluxes short of their
# converged value. Raise it if the surface fluxes look wrong; each iteration costs one pass through
# the similarity functions.
#
# Δt is fixed (no wizard inside the trace), at the clock's float type: keep `AR_DT` under the
# advective CFL of whatever resolution `AR_CELLS_PER_DEGREE` selects. It is set back at shim 5, which
# needs it to size the acoustic substep loop.

## No NumericalEarth branch defines `Base.eltype(::NestedModel)` (it lived only in a local checkout),
## so supply it here when only the `AbstractModel` fallback is present.
if !(Base.unwrap_unionall(which(eltype, Tuple{typeof(nest)}).sig).parameters[2] <: NestedModel)
    @eval Base.eltype(nest::NestedModel) = eltype(nest.child.grid)
end

atmosphere = Simulation(nest; Δt)

# `Simulation` stores `Δt` in a TYPED field, converted with `TT = eltype(model)`, and
# `time_step!(sim, Δt)` re-assigns that field on every call — so a `Simulation` whose `Δt` type is
# wider than the model's silently widens the step back on each step. `Base.eltype(::NestedModel)`
# (NumericalEarth) is what keeps this at the child's float type; without it the
# `eltype(::AbstractModel) = Float64` fallback applies, and the resulting `Float64` `Δt` reaches
# `tick_stage!` on a `TracedRNumber{Float32}` clock as a mixed-width `stablehlo.add` that fails MLIR
# verification. Assert rather than trust: the failure is 30 minutes of compiling away from here.
## Oceananigans 0.113's `Simulation(::ReactantModel)` stores `Δt = Float64(Δt)` unconditionally. Only
## the coupled path steps through `time_step!(sim, sim.Δt)`; the bare nest (and the AD path, which
## calls `time_step!(model, Δt)` with the script's own `Δt`) never reads it, so the mismatch only
## matters when coupling is requested.
typeof(atmosphere.Δt) === typeof(Δt) || get(ENV, "AR_COUPLED", "1") != "1" ||
@assert typeof(atmosphere.Δt) === typeof(Δt) "Simulation stored Δt as $(typeof(atmosphere.Δt)) but \
    the model steps at $(typeof(Δt)); eltype(nest) = $(eltype(nest)). A Float64 Δt against a Float32 \
    traced clock does not compile — check `Base.eltype(::NestedModel)` in NumericalEarth."
stage("simulation Δt: $(typeof(atmosphere.Δt)) (eltype(nest) = $(eltype(nest)))")

# ## Attaching radiation to the BARE nest
#
# `AR_RADIATION=1` built an RTM above, and for a long time it was only ever handed to
# `AtmosphereOceanModel` — which failed, so the run fell back to the bare nest and the RTM was
# silently DISCARDED. Every "radiation enabled" run from that era differentiated a model with no
# radiation in it. Coupling works now, so that is no longer the reason this block exists; it exists
# so `AR_COUPLED=0` and any future fallback still get a radiatively active atmosphere. Materializing
# here and then passing `radiation` to `AtmosphereOceanModel` as well is not a double application —
# both routes alias the same `rtm.flux_divergence`.
#
# Radiation does not actually need the coupled model. Breeze's `update_state!` calls
# `update_radiation!(model.radiation, model)` off the child's OWN field, and NumericalEarth's
# `atmosphere_model` seeds that field with a `CoupledRadiation()` skeleton whose `update_radiation!`
# is a no-op. Materializing it — `CoupledRadiation(rtm)`, which aliases `rtm.flux_divergence` — is
# what makes the child radiatively active, and NumericalEarth already has that method for precisely
# this shape (`materialize_earth_system_radiation!(::Simulation{<:NestedModel{<:Any,
# <:Breeze.AtmosphereModel}}, ::RadiativeTransferModel)`).
#
# So call it directly instead of hand-rolling the `@set`. Note `atmosphere_model` deliberately REFUSES
# a raw `Breeze.RadiativeTransferModel` ("Pass the RTM to the coupled-model constructor instead"), so
# threading it in at child-construction time is not an option — this materialize-after-the-fact step
# is the sanctioned route.
#
# It returns a NEW `Simulation` (the child's type changes with its `radiation` parameter), so `nest`
# has to be rebound too, or the fallback path would step the old radiation-free nest.
if !isnothing(radiation)
    atmosphere = NumericalEarth.EarthSystemModels.materialize_earth_system_radiation!(atmosphere, radiation)
    global nest = atmosphere.model
    stage("radiation materialized onto the bare nest's child (CoupledRadiation aliasing the RTM's \
           flux_divergence); it will be solved on the RTM's own schedule")
end

coupled_model = if get(ENV, "AR_COUPLED", "1") == "1"
    try
        flux_iterations = parse(Int, get(ENV, "AR_FLUX_ITERATIONS", "10"))
        stage("atmosphere-ocean fluxes: SimilarityTheoryFluxes with FixedIterations($(flux_iterations)) \
               — the default ConvergenceStopCriteria cannot be raised to StableHLO")
        AtmosphereOceanModel(atmosphere, ocean; radiation, clock = traced_clock(),
                             atmosphere_ocean_fluxes =
                                 NumericalEarth.SimilarityTheoryFluxes(FT; solver_stop_criteria =
                                     NumericalEarth.FixedIterations(flux_iterations)))
    catch err
        ## A THIRD failure mode appeared when Oceananigans was updated (job 5144): the exchanger's
        ## `PrescribedOcean` read now scalar-indexes a `ConcretePJRTArray`, which throws a plain
        ## `ErrorException` ("Scalar indexing is disallowed") rather than a `MethodError` or an
        ## `InvalidIRError` — so the fallback rethrew and killed a run that had already spent 55
        ## minutes on the ERA5 initial condition.
        ##
        ## The predicate is about the QUESTION being asked, not about one exception type: "can this
        ## NumericalEarth couple a NestedModel under Reactant". Every no answer it has ever given
        ## belongs here, and matching the scalar-indexing message by text is deliberate — the error
        ## is a bare `ErrorException` with nothing else to dispatch on.
        uncouplable = err isa MethodError ||
                      nameof(typeof(err)) === :InvalidIRError ||
                      (err isa ErrorException && occursin("Scalar indexing is disallowed", err.msg))
        uncouplable || rethrow()
        @warn """Could not couple the nested atmosphere to the prescribed ocean: either this
                 NumericalEarth lacks the `NestedModel` → child forwards the Breeze↔ESM interface
                 needs (`MethodError`), or it has them and the exchanger's eager
                 `surface_precipitation_flux` computation does not compile under Reactant
                 (`InvalidIRError`). Stepping the bare nest instead (no surface fluxes); set
                 AR_COUPLED=0 to skip this attempt.""" exception = (err, catch_backtrace())
        nothing
    end
end

model = something(coupled_model, nest)
stage(isnothing(coupled_model) ? "stepping the bare nest (uncoupled)" : "coupled model assembled")

# `AR_STOP_AFTER_COUPLING=1`: exit here, before the first compile.
#
# The coupling attempt above is the last thing in this script that is CHEAP — everything after it is
# the hours-long XLA compile. Working on the coupling itself means running the whole preamble (grid,
# parent, nest, initial condition) and then throwing the compile away, so make that an explicit
# option instead of a Ctrl-C. Exit status is 0 when the coupled model was built and 1 when it fell
# back, so a batch job's status alone answers "does coupling work yet".
if get(ENV, "AR_STOP_AFTER_COUPLING", "0") == "1"
    stage("AR_STOP_AFTER_COUPLING=1: stopping before the compile")
    exit(isnothing(coupled_model) ? 1 : 0)
end

# ## Compile and step
#
# One compilation of the first (Euler-ish) step, one of a `@trace`d chunk of `AR_CHUNK` steps. The
# chunk length is baked into the executable, so the run length is rounded down to a whole number of
# chunks. Between chunks we sync to the host to print min/max of every prognostic — the traced
# stand-in for `downscale.jl`'s progress callback, which a `ReactantSimulation` cannot carry.

# `track_numbers=false` is REQUIRED here, not a tuning choice.
#
# By default `@trace` promotes every plain Julia number in the loop-carried state to a
# `TracedRNumber`. The state reached through `model` includes Breeze's
# `SplitExplicitTimeDiscretization`, and that struct has
#
#     apply_first_substep_pressure_gradient :: Bool
#
# as a CONCRETE field with no type parameter to hold a traced value, so the promotion cannot be
# expressed and tracing dies before any MLIR is produced:
#
#     NoFieldMatchError: Cannot convert type SplitExplicitTimeDiscretization{Int64, Float32, …}
#       name=apply_first_substep_pressure_gradient  Derived: TracedRNumber{Bool}
#                                                   Existing: Bool   Best Attempt: Bool
#
# (Every other field of that struct reconciles — they are parameterized on `N`/`FT`.)
#
# `track_numbers=false` maps to `track_numbers = Union{}`, leaving plain numbers plain. That is also
# the semantically right answer: `substeps`, `acoustic_cfl` and the RK weights are loop-INVARIANT
# constants, and baking them in is better than carrying them. Genuinely varying state is unaffected —
# the clock is built from `ConcreteRNumber`s, so it is traced regardless of this setting.
#
# The alternative fixes are upstream: parameterize that field in Breeze, or have Reactant skip
# promotion for fields a struct cannot represent.
if VANILLA
    ## No `@trace`: with no tracing context there is nothing to trace INTO, and the loop is just a
    ## loop — `Nsteps` eager `time_step!`s, each launching its own kernels.
    function step_for!(model, Δt, Nsteps)
        for _ = 1:Nsteps
            time_step!(model, Δt)
            accumulate_precipitation!(Δt)
        end
        return nothing
    end
else
    function step_for!(model, Δt, Nsteps)
        @trace track_numbers = false for _ = 1:Nsteps
            time_step!(model, Δt)
        end
        return nothing
    end
end

steps = smoke ? 4 : parse(Int, get(ENV, "AR_STEPS", "100"))
chunk = smoke ? 2 : parse(Int, get(ENV, "AR_CHUNK", "10"))
chunks = max(1, steps ÷ chunk)

# ## One `CompileOptions` for every compile in this script
#
# Every `@compile`/`@code_hlo` below used to spell its options out inline (`sync = true raise = …
# raise_first = …`), which meant a new option had to be added in six places and could silently
# disagree between the forward run, the AD sweep, and the HLO dumps. They now all go through
# `ar_compile_options`, which returns a `Reactant.CompileOptions` — the single object Reactant's
# macros accept in place of the loose keywords (`compile_options = …`; note that when it is passed,
# EVERY other option keyword on the macro is ignored, so `sync` has to live inside the struct too —
# `Compiler.jl` reads it only as `compile_options.sync`).
#
# Two settings are turned on here for every compile:
#
#   * `speculate_partial_ifs = true` sets `speculate_partial_if=true` on both `canonicalize-loops`
#     invocations in the raise pipeline (`Reactant/src/compiler/Compiler.jl`). A loop body whose tail
#     sits under a partial `if` — exactly the shape a KernelAbstractions kernel's bounds guard emits
#     (`if I ≤ N …`) — blocks the affine raise until the `if` is speculated into the loop body. With
#     it on, more of those loops raise to StableHLO instead of surviving as opaque
#     `enzymexla.kernel_call`s, which both shortens the pass pipeline's work and gives the downstream
#     XLA optimizer real ops to fuse.
#
#   * `xla_debug_options` carries `--xla_backend_extra_options=xla.disable_while_loop_dce=true` into
#     XLA's `DebugOptionsProto` (`xla_backend_extra_options` is its `map<string, string>` escape
#     hatch, so the value is the STRING `"true"`). It disables XLA's dead-code elimination on
#     `while` loops — the traced step loop and, under AD, the checkpointed reverse sweep are both
#     `stablehlo.while`s, and the DCE pass is a compile-time cost that does not pay for itself here.
#     !!! warning "The KEY must be the LLVM `cl` option name, not the dotted form"
#         `xla_backend_extra_options` entries are handed to the backend's LLVM command-line parser,
#         and `"xla.disable_while_loop_dce"` is NOT a registered option there. XLA's parser answers an
#         unknown argument by printing one line and calling `exit(1)`:
#
#             xla: Unknown command line argument 'xla.disable_while_loop_dce=true'.  Try: 'xla --help'
#
#         That is fatal, silent (no Julia stacktrace), and lands ~1 h into a run, buried under
#         thousands of routine XLA warnings — it killed jobs 5171, 5395 and 5397 before being spotted.
#         The binary registers the UNDERSCORE spelling, `xla_disable_while_loop_dce`; `strings` on
#         libReactantExtra shows both, but only that one is a `cl::opt`.
#
#         `AR_XLA_WHILE_DCE=0` drops the option entirely, and `AR_XLA_WHILE_DCE_KEY` overrides the
#         spelling — because this is a compile-time optimisation with no effect on results, and no
#         tuning flag should be able to kill a multi-hour run with no way to switch it off.
const XLA_DEBUG_OPTIONS = if get(ENV, "AR_XLA_WHILE_DCE", "1") == "1"
    (; xla_backend_extra_options =
        Dict(get(ENV, "AR_XLA_WHILE_DCE_KEY", "xla_disable_while_loop_dce") => "true"))
else
    (;)
end

ar_compile_options(; raise, raise_first = false, optimize = true, xla_debug_options = XLA_DEBUG_OPTIONS, kwargs...) =
    Reactant.CompileOptions(; optimization_passes = optimize,
                            raise, raise_first,
                            sync = true,
                            speculate_partial_ifs = true,
                            xla_debug_options,
                            kwargs...)

## `@code_hlo` defaults `shardy_passes`/`strip` to `:none` itself, but those defaults are dropped the
## moment a `CompileOptions` is handed over, so the dump paths restate them.
ar_hlo_options(; kwargs...) =
    ar_compile_options(; optimize = false, shardy_passes = :none, strip = :none, kwargs...)

# ### `AR_HLO=1`: dump the unoptimized StableHLO and stop
#
# `@code_hlo optimize=false` traces the step into MLIR and hands back the module WITHOUT running any
# XLA pass pipeline or codegen — the two phases that make a full `@compile` of this model take hours
# on the CPU backend. Writing that module out gives a precise, inspectable record of what one step of
# the nest actually asks for (every kernel as a custom call, in order), so the cost can be attributed
# op by op rather than guessed at from a Julia-level profile.
#
# `raise` MUST be passed explicitly to match what `@compile` below does. Reactant's default is
# `raise = false` (`Reactant/src/compiler/Macros.jl`, `get_common_compile_options`), while the
# `@compile` calls further down set `raise = true` — so a `@code_hlo` that just inherits the default
# does not dump the module the compiled run is built from.
#
# BUT `raise = true` DOES NOT LIFT THE KERNELS HERE, because this call also passes `optimize = false`.
# Reactant gates the raise pipeline — `llvm-to-affine-access`, `delinearize-indexing`,
# `raise-affine-to-stablehlo`, `arith-raise`, … — behind
# `optimization_passes === :all || === :after_enzyme` (`Reactant/src/compiler/Compiler.jl`), and
# `optimize` is the option that selects that field. With `optimize = false` those passes never run,
# so every KernelAbstractions kernel stays an `enzymexla.kernel_call` wrapping inlined LLVM IR.
# Measured on this model: 792 `kernel_call`s, IDENTICAL with `raise = false` and `raise = true`.
# Seeing StableHLO kernel bodies would need `optimize = :all`/`:after_enzyme` too — the expensive
# pipeline this section exists to skip.
#
# `raise = true` is still the right setting, for a different reason. `Compiler.raising()` feeds
# `GPUCompiler.optimization_options`, which then returns `instcombine=false,
# aggressiveinstcombine=false, fastmath=false`, substituting `InstSimplifyPass` for `InstCombinePass`
# while each kernel is compiled. That keeps InstCombine's strength-reduced index arithmetic out of the
# kernel bodies: a `mul` by 2^60−3 paired with a `mul` by 3 that cancels exactly under a later
# `shl 4`, plus an `or disjoint` standing in for `add` — together obscuring what is really
# `16·blockIdx + (tid & 15)` compared against `Nx`. Measured here: that constant goes 55 → 0 and
# `disjoint` 56 → 0. Downstream rewriters want the affine form, so always dump with `raise = true`.
#
# Note the consequence for reading the dump: the per-op histogram is dominated by the `llvm.*` ops of
# the inlined kernel BODIES and by the `stablehlo.transpose`es Reactant emits to bridge Julia's
# column-major layout to XLA's, none of which the compiled executable would carry. Kernel LAUNCH
# counts are unaffected by any of this, so those are the numbers to trust here.

# ### `AR_HLO=optimized`: dump the StableHLO that XLA actually receives
#
# `AR_HLO=1` above is for reading what the step ASKS for; this mode is for handing the problem to
# someone who does not have Julia. It runs Reactant's FULL pass pipeline — the raise included, so no
# `enzymexla.kernel_call` survives and nothing Reactant-specific is left in the module — and writes
# the result out just before it would have gone to `ClientCompileWithProto`. What comes back is plain
# StableHLO: `hlo-opt`, `run_hlo_module` and friends can take it directly, with no Julia, no Reactant
# and no libReactantExtra in the loop.
#
# That matters here because the expensive phase is downstream of everything Julia does. The coupled
# `first_time_step!` has now spent 4 h 16 m (job 6287) and three separate 4 h+ attempts (job 6132) in
# XLA/ptxas without finishing, against 45 min for a bare nest on a THREE TIMES LARGER grid (job 5142,
# 108×54×50). Reproducing that from this script costs ~25 min of setup and a GPU node that keeps
# failing under long jobs; reproducing it from this file costs one command.
#
# The two modes differ only in `optimize`, which is what gates the raise (see the section above), but
# the cost is not symmetric: `optimize = false` is a trace, `optimize = true` is the whole pipeline —
# minutes versus tens of minutes. Neither runs XLA codegen, which is the part that takes hours.
#
# ### Capturing XLA's own view as well
#
# StableHLO is XLA's INPUT. To see what XLA then does with it — which pass is eating the hours — set
#
#     XLA_FLAGS="--xla_dump_to=<dir> --xla_dump_hlo_pass_re=.*"
#
# on an ordinary run (no `AR_HLO`). XLA writes `module_XXXX.*.before_optimizations.txt` as soon as
# compilation STARTS, so even a run killed at its walltime — which is how both coupled attempts have
# ended so far — leaves behind the HLO reproducer plus per-pass dumps. `before_optimizations.txt` is
# the other Julia-free entry point, and it is the one XLA's own bug reports want.

hlo_mode = get(ENV, "AR_HLO", "0")

if hlo_mode != "0"
    raise = true
    optimized = hlo_mode in ("optimized", "opt", "all")

    ## `optimize = true` selects `optimization_passes = true`, the full pipeline; `ar_hlo_options`
    ## hardcodes `optimize = false`, so the optimized mode goes through `ar_compile_options` and
    ## restates the `shardy_passes`/`strip` defaults `@code_hlo` would otherwise supply for itself.
    options = optimized ?
        ar_compile_options(raise = raise, optimize = true, shardy_passes = :none, strip = :none) :
        ar_hlo_options(raise = raise)

    default_path = optimized ? "stablehlo_ar_optimized.mlir" :
                   raise ? "unopt_ar_raised.mlir" : "unopt_ar.mlir"
    hlo_path = get(ENV, "AR_HLO_PATH", default_path)

    stage("tracing first_time_step! → $(optimized ? "post-pipeline (raised) StableHLO — the module \
           handed to XLA" : "unoptimized StableHLO") (raise = $raise)")

    trace_start = time_ns()
    hlo_module = @code_hlo compile_options = options first_time_step!(model, Δt)
    stage(@sprintf("%s in %.1f s", optimized ? "ran the pass pipeline" : "traced",
                   1e-9 * (time_ns() - trace_start)))

    write(hlo_path, repr(hlo_module))
    stage(@sprintf("wrote %s (%.1f MB) — stopping before the XLA compile", hlo_path,
                   filesize(hlo_path) / 1e6))

    ## The module is tens of MB of text and compresses ~10×; the point of this mode is to hand the
    ## file to someone else, so leave a copy that is small enough to attach to an issue.
    if get(ENV, "AR_HLO_GZIP", "1") == "1"
        run(pipeline(`gzip -9 -k -f $hlo_path`))
        stage(@sprintf("also wrote %s.gz (%.1f MB)", hlo_path, filesize(hlo_path * ".gz") / 1e6))
    end
    exit(0)
end

## Reach the Breeze child through whichever shape we ended up stepping — an `EarthSystemModel`
## reports `prognostic_fields === nothing`, so ask the child directly. Reductions over raw interiors,
## not online diagnostics: an `AbstractOperation` would not compile here (see the caveats up top).
breeze_child(nest::NestedModel) = nest.child
breeze_child(coupled) = coupled.atmosphere.model.child

# Surface precipitation accumulated every step (kg m⁻², i.e. mm of liquid water), from Breeze's
# `bottom_precipitation_flux` — the bottom-face flux of every sedimenting condensate, so rain and
# snow alike. CUDA path only: the snapshots carry the running total, and differencing two of them
# gives the accumulation over any window. Under Reactant the traced loop is left untouched.
if VANILLA
    const precipitation_flux = Breeze.bottom_precipitation_flux(breeze_child(model))
    const accumulated_precipitation = Field{Center, Center, Nothing}(breeze_child(model).grid)
    function accumulate_precipitation!(Δt)
        compute!(precipitation_flux)
        parent(accumulated_precipitation) .+= Δt .* parent(precipitation_flux)
        return nothing
    end
end

function prognostic_bounds(model)
    fields = prognostic_fields(breeze_child(model))
    ## The non-finite COUNT is the load-bearing number, not the bounds. `minimum`/`maximum` lower to
    ## a StableHLO `reduce` with `minimum`/`maximum` — and unlike Julia's `minimum`, those are not
    ## required to propagate a NaN operand, so a field can be riddled with NaN and still print a
    ## clean interval. Counting `!isfinite` directly (as a Float32 sum, avoiding a Bool reduction)
    ## makes "no NaNs after two steps" a measurement instead of an inference.
    return map(fields) do f
        x = interior(f)
        (minimum(x), maximum(x), sum(ifelse.(isfinite.(x), zero(eltype(x)), one(eltype(x)))))
    end
end

host_number(x) = x isa Reactant.ConcreteRNumber ? Reactant.to_number(x) : x

# ## Writing the run to disk
#
# `downscale.jl` gets output for free from Oceananigans' `JLD2Writer`, driven by a `Simulation`'s
# schedule. Neither is available here: `run!` is unsupported on `ReactantState`, so there is no
# simulation to hang writers off, and `JLD2Writer`'s outputs are typically `AbstractOperation`s
# (`sqrt(u^2 + v^2)`, `Integral(ρ * qᵛ * u)`) which `compute!` through KA kernels — the wall that
# shims 7-10 exist to route around.
#
# So write the snapshots directly. Deliberately NOT an imitation of Oceananigans' on-disk
# `FieldTimeSeries` layout: reproducing that by hand couples this file to Oceananigans' output
# internals, and a silently wrong reproduction would be worse than an obviously different format.
# What is written is self-describing — coordinates, locations, units and all — so it can be read
# with nothing but JLD2.
#
# Only PROGNOSTIC fields are stored, at their native staggered locations, with those locations
# recorded alongside. Deriving `u = ρu / ρᵈ` here would silently mix locations (ρu is at Face in x,
# ρᵈ at Center), so that interpolation is left to whoever reads the file and can choose it
# deliberately.
#
# `AR_OUTPUT=0` disables writing; `AR_OUTPUT_FILE` overrides the path.

# JLD2 is a dependency of Oceananigans, not a direct one of this project, so `using JLD2` would
# require editing Project.toml. It is certainly loaded by the time Oceananigans is, so take it from
# the loaded-module table (same approach as CUDACore in shim 9).
const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")

write_output = get(ENV, "AR_OUTPUT", "1") == "1"
output_closure_fields = get(ENV, "AR_OUTPUT_CLOSURE", "0") == "1"
output_path = get(ENV, "AR_OUTPUT_FILE",
                  "reactant_$(get(ENV, "AR_DOMAIN", "corridor"))_$(ic_mode)$(get(ENV, "AR_BALANCER", "0") == "1" ? "_balanced" : "").jld2")

# `interior(f)` is a view into `parent(f)`; `Array(parent(f))` is the whole-parent device→host
# transfer used throughout this file, and `parentindices` then selects the interior from the host
# copy. Going through `Array(interior(f))` instead would put a device-backed `SubArray` into Base's
# generic `copyto!`, which is exactly the `mightalias` → `pointer(::ConcretePJRTArray)` crash of
# shim 6.
host_interior(f) = view(Array(parent(f)), parentindices(interior(f))...)

location_name(f) = string(nameof.(Oceananigans.Fields.location(f)))

function write_grid_metadata(path)
    JLD2.jldopen(path, "w") do file
        file["grid/lambda_center"] = Array(λnodes(host_grid, Center(), Center(), Center()))
        file["grid/lambda_face"]   = Array(λnodes(host_grid, Face(), Center(), Center()))
        file["grid/phi_center"]    = Array(φnodes(host_grid, Center(), Center(), Center()))
        file["grid/phi_face"]      = Array(φnodes(host_grid, Center(), Face(), Center()))
        file["grid/z_center"]      = Array(znodes(host_grid, Center(), Center(), Center()))
        file["grid/z_face"]        = Array(znodes(host_grid, Center(), Center(), Face()))
        file["grid/size"]          = collect(size(host_grid))
        file["grid/halo"]          = collect(Oceananigans.Grids.halo_size(host_grid))

        ## The terrain is what makes z_center above only a REFERENCE coordinate: on a
        ## terrain-following grid the physical height of a cell varies with (i, j). `h` is
        ## `LinearDecay`'s terrain-height field, at (Center, Center).
        ## Guarded because it reaches into `LinearDecay`'s internals, which no other part of this
        ## script depends on: the prognostics and coordinates are the payload, and losing a
        ## multi-hour run to a renamed terrain field would be a poor trade. Everything else here
        ## is deliberately NOT guarded — it runs before the compiles, so a real problem surfaces
        ## in minutes rather than after the stepping.
        try
            ## `h` is a raw OffsetArray, NOT a Field — `interior` has no method for it — so trim the
            ## halos by hand from the halo/size pair.
            h  = Array(parent(host_grid.z.formulation.h))
            Hx, Hy, _ = Oceananigans.Grids.halo_size(host_grid)
            Nx, Ny, _ = size(host_grid)
            file["grid/terrain_height"] = h[Hx+1:Hx+Nx, Hy+1:Hy+Ny, 1]
            file["grid/z_top"] = Float64(host_grid.z.formulation.z_top)
        catch err
            @warn "could not record the terrain height; z_center is only a reference coordinate \
                   on this grid, so physical heights cannot be reconstructed from this file" err
        end

        file["meta/initial_condition"] = string(ic_mode)
        file["meta/dt_seconds"]        = Float64(Δt)
        file["meta/domain"]            = get(ENV, "AR_DOMAIN", "corridor")
        file["meta/sponge"]            = get(ENV, "AR_SPONGE", "1") == "1"
        file["meta/balancer"]          = get(ENV, "AR_BALANCER", "0") == "1"
        file["meta/reference_state_recomputed"] = get(ENV, "AR_REFERENCE_STATE", "0") == "1"
        file["meta/note"] = "Prognostic fields at their native staggered locations (see " *
                            "<name>/location). Interiors only, halos excluded. The parent is " *
                            (get(ENV, "AR_PARENT", "analytic") == "era5" ?
                             "ERA5 hourly pressure-level data read from disk." :
                             "the script's ANALYTIC atmospheric river, not ERA5 data.")
        file["meta/parent"]            = get(ENV, "AR_PARENT", "analytic")
        file["meta/parent_kind"]       = string(PARENT_KIND)
        file["meta/start_date"]        = string(start_date)
    end
    return nothing
end

## Physical heights and cell volumes of the terrain-following child, evaluated with the grid's own
## `znode`/`Vᶜᶜᶜ` on the host twin, so a reader never has to reimplement the terrain formulation.
function write_physical_heights(file)
    Nx, Ny, Nz = size(host_grid)
    c, f = Center(), Face()
    file["grid/z_physical_center"] = [Oceananigans.Grids.znode(i, j, k, host_grid, c, c, c) for i in 1:Nx, j in 1:Ny, k in 1:Nz]
    file["grid/z_physical_face"]   = [Oceananigans.Grids.znode(i, j, k, host_grid, c, c, f) for i in 1:Nx, j in 1:Ny, k in 1:Nz+1]
    file["grid/cell_volume"]       = [Oceananigans.Operators.Vᶜᶜᶜ(i, j, k, host_grid) for i in 1:Nx, j in 1:Ny, k in 1:Nz]
    return nothing
end

function write_snapshot(path, model, iteration, t)
    fields = prognostic_fields(breeze_child(model))
    JLD2.jldopen(path, "a+") do file
        file["timeseries/t/$iteration"] = Float64(t)
        for (name, f) in pairs(fields)
            file["timeseries/$name/$iteration"] = Array(host_interior(f))
            key = "location/$name"
            haskey(file, key) || (file[key] = location_name(f))
        end
        if VANILLA
            file["timeseries/precipitation_flux/$iteration"] = Array(host_interior(precipitation_flux))[:, :, 1]
            file["timeseries/accumulated_precipitation/$iteration"] =
                Array(host_interior(accumulated_precipitation))[:, :, 1]
        end
        ## `AR_OUTPUT_CLOSURE=1`: the closure's diagnosed diffusivities (and, on Breeze #975, the
        ## stored N² and mixing length), at (Center, Center, Face) — whatever `closure_fields` carries.
        if output_closure_fields
            cf = breeze_child(model).closure_fields
            for name in (:Kᵘ, :Kᶜ, :ℓ, :N²)
                hasproperty(cf, name) || continue
                file["timeseries/closure_$(name)/$iteration"] = Array(host_interior(getproperty(cf, name)))
            end
        end
        ## No separate iteration index: it would have to be deleted and rewritten on every
        ## snapshot, and a run killed mid-rewrite would leave the file inconsistent with its own
        ## contents. `keys(file["timeseries/t"])` already enumerates exactly the completed
        ## snapshots, so the file cannot disagree with itself.
    end
    return nothing
end

function report(model, wall_seconds)
    bounds = VANILLA ? prognostic_bounds(model) : @jit prognostic_bounds(model)
    iter = host_number(model.clock.iteration)
    t = host_number(model.clock.time)
    state = join([@sprintf("%s ∈ [%.4g, %.4g]%s", name, host_number(lo), host_number(hi),
                           host_number(bad) == 0 ? "" : @sprintf(" <%d NON-FINITE>", Int(host_number(bad))))
                  for (name, (lo, hi, bad)) in pairs(bounds)], ", ")
    nonfinite = sum(Int(host_number(b)) for (_, _, b) in bounds)
    @info @sprintf("iter=%4d, t=%s, Δt=%s, wall=%6.1fs, nonfinite=%d, %s",
                   iter, prettytime(t), prettytime(Δt), wall_seconds, nonfinite, state)
    return nonfinite
end

# ### `AR_SROA_INSTCOMBINE=1`: give the wrapper allocas a second SROA with InstCombine on
#
# `@compile` fails in the MLIR pass pipeline with
#
#     error: cannot raise op to stablehlo %N = "llvm.alloca"(%N) <{… elem_type = f32}> : (i32) -> !llvm.ptr
#
# `raise-affine-to-stablehlo` has no lowering for a stack allocation, and the kernel WRAPPERS Reactant
# generates are full of them: each captured Julia immutable (grid, `Interpolated` boundary condition
# with its parent `FieldTimeSeries`, the clock, the 24-field model NamedTuple) is materialized as a
# `dense<[…]>` byte blob stored into an `llvm.alloca` and loaded back at the struct type.
#
# Reactant already runs `sroa-wrappers` twice against exactly this, ahead of the raise passes — but
# both invocations are pinned `instcombine=false instsimplify=true`, and InstCombine is the pass that
# canonicalizes a type-punned whole-aggregate store/load into a form SROA can promote. So: prepend one
# more `sroa-wrappers` WITH InstCombine enabled, immediately before the raise pipeline. `raise` accepts
# a pass-pipeline string, which is what makes this reachable without patching Reactant.
#
# The string below is Reactant's own default raise pipeline (`Compiler.jl`, the `elseif raise` branch)
# with that one pass prepended; the interpolated options are pinned to their defaults. It has to be
# kept in step with upstream by hand — if a Reactant bump changes the default pipeline, this diverges
# silently, so it is opt-in and off by default.

const DEFAULT_RAISE_PASSES = "canonicalize,llvm-to-memref-access,canonicalize,convert-llvm-to-cf," *
    "canonicalize,enzyme-lift-cf-to-scf,canonicalize,func.func(canonicalize-loops),canonicalize-scf-for," *
    "canonicalize,libdevice-funcs-raise,canonicalize,affine-cfg,canonicalize," *
    "func.func(canonicalize-loops),canonicalize,llvm-to-affine-access,canonicalize,delinearize-indexing," *
    "canonicalize,simplify-affine-exprs,affine-cfg,canonicalize," *
    "func.func(affine-loop-invariant-code-motion),canonicalize,sort-memory,func.func(kernelcast)," *
    "raise-affine-to-stablehlo{strip_llvm_debuginfo=false prefer_while_raising=false dump_failed_lockstep=false}," *
    "canonicalize,arith-raise{stablehlo=true}"

# `AR_PREFER_WHILE=1` flips `raise-affine-to-stablehlo`'s own `prefer_while_raising` option on.
#
# The third blocker (after the dead allocas and the bounds-check traps) is 269 × `cannot raise op to
# stablehlo … "scf.while"`. Reading one in the post-pipeline module shows what it is: `lo = 0`,
# `hi = 27` over the parent's 28 vertical levels, midpoint by `sitofp`/`× 0.5`/`fptosi`, a
# `memref.load` from the parent's `memref<38xf32>` z-coordinates, and comparison-driven bound
# updates — a `searchsortedfirst` BINARY SEARCH for the vertical interpolation index of the
# `Interpolated` lateral boundary. Its trip count depends on loaded data, so it can never be affine;
# raising it needs a genuine `while`, which is what this option asks for.
prefer_while = get(ENV, "AR_PREFER_WHILE", "0") == "1"

raise_passes = replace(DEFAULT_RAISE_PASSES,
                       "prefer_while_raising=false" => "prefer_while_raising=$(prefer_while)")

# `AR_RAISE=0` turns the raise OFF entirely: KernelAbstractions kernels stay as
# `enzymexla.kernel_call`s and XLA executes them as custom calls around the CUDA kernels GPUCompiler
# emits, instead of being lifted to StableHLO. This is a CONTROL, not a production setting — it is
# how you ask "is a wrong answer the raise's fault?", because it runs the same model through a path
# where the raise never touches it. Two consequences worth knowing:
#   * The raise's failure modes cannot occur. No `llvm.alloca`, no `scf.while`, no traps to lift —
#     so `AR_PARENT_UNIFORM_Z=0` (the true stretched ERA5 vertical) is reachable this way, which it
#     is NOT with the raise on (job 6507: 225 `scf.while` + 123 `llvm.alloca`).
#   * XLA sees opaque custom calls instead of real ops, so it cannot fuse across kernels. Expect a
#     much cheaper compile and a slower step.
raise_option = if get(ENV, "AR_RAISE", "1") == "0"
    false
elseif get(ENV, "AR_SROA_INSTCOMBINE", "0") == "1"
    "sroa-wrappers{instcombine=true instsimplify=true attributor=true},canonicalize," * raise_passes
elseif prefer_while
    raise_passes
else
    true
end

stage(string("raise passes: ",
             raise_option === false ? "RAISE OFF (AR_RAISE=0) — kernels stay as enzymexla.kernel_call" :
             raise_option === true ? "Reactant default" : "custom",
             get(ENV, "AR_SROA_INSTCOMBINE", "0") == "1" ? " +leading-sroa-wrappers{instcombine=true}" : "",
             prefer_while ? " +prefer_while_raising=true" : "",
             get(ENV, "AR_PATCH_SROA_INSTCOMBINE", "0") == "1" ? " [Reactant's own sroa-wrappers patched to instcombine=true]" : ""))
stage("compile options: speculate_partial_ifs=true, " *
      (isempty(XLA_DEBUG_OPTIONS) ? "no xla_backend_extra_options" :
       join(("$k=$v" for (k, v) in XLA_DEBUG_OPTIONS.xla_backend_extra_options), ", ")))

# Report the state BEFORE anything is stepped. Cheap (one `@jit`ted reduction, no big compile) and it
# separates two very different failures: an initial condition that is already bad, versus a step that
# blows up. Without it, an all-`NaN` readout after stepping is ambiguous.
#
# `AR_REPORT_ONLY=1` stops here, which turns that question into an ~11 minute run instead of the
# ~90 minutes both compiles cost.
stage("initial state, before any step")
report(model, 0.0)

if write_output
    write_grid_metadata(output_path)
    JLD2.jldopen(write_physical_heights, output_path, "a+")
    write_snapshot(output_path, model, host_number(model.clock.iteration), host_number(model.clock.time))
    stage("writing snapshots to $(output_path)")
end

if get(ENV, "AR_REPORT_ONLY", "0") == "1"
    stage("AR_REPORT_ONLY=1 — stopping before the compiles")
    exit(0)
end

# ## `AR_AD=1`: reverse-mode gradients through the compiled run
#
# Everything above computes the model's trajectory. This computes its DERIVATIVE: given a scalar loss
# `J` evaluated on the state after `AR_AD_STEPS` steps, and a control field `c` written into the
# child's initial condition, it returns `∂J/∂c` at every one of the control's cells — the adjoint
# sensitivity of the downscale.
#
# Reverse mode is the whole point. The control here is a full 3D field (36×18×50 = 32 400 numbers at
# production size) and the loss is one number, so one reverse sweep yields the entire gradient, while
# forward mode would need one sweep per control cell. That asymmetry is why data assimilation and
# sensitivity studies are written adjoint-first, and it is exactly the regime Enzyme's reverse mode
# is for.
#
# ### Why `raise_first = true` is not optional here
#
# Reactant assembles ONE pass pipeline containing both the raise passes (which lift
# `enzymexla.kernel_call`s — inlined LLVM IR from KernelAbstractions kernels — into StableHLO) and the
# Enzyme passes (`enzyme-batch`, then the differentiation pass itself). `raise_first` decides their
# ORDER (`Reactant/src/compiler/Compiler.jl`): with the default `false` the raise list is appended
# AFTER `enzyme_pass`, so Enzyme is asked to differentiate kernels that are still opaque LLVM blobs;
# with `true` the raise list is spliced in BEFORE `enzyme-batch`, so by the time the differentiation
# pass runs, every kernel body is StableHLO that Enzyme-MLIR can transpose op by op.
#
# For a model that is *entirely* KA kernels — which is what Oceananigans and Breeze are — that is the
# difference between a gradient and a pipeline failure. Oceananigans' own Reactant+Enzyme tests
# (`test/test_reactant_hydrostatic_free_surface_models.jl`) pass `raise=true raise_first=true` for the
# same reason, and this block follows that test's structure deliberately: same `Duplicated(model,
# dmodel)` shape, same `set_strong_zero(ReverseWithPrimal)`, same `@trace mincut=true
# checkpointing=true` on the step loop.
#
# `mincut`/`checkpointing` are memory, not correctness. A reverse sweep needs the forward state at
# every step; storing all of it is `AR_AD_STEPS` × the full nest, which is why the step count here
# defaults to 2 rather than `AR_STEPS`. `checkpointing=true` sets `enzyme.enable_checkpointing` on the
# `while` op so Enzyme recomputes segments instead of taping them, and `mincut=true` lets it choose
# the cheaper cut (Reactant sets `enzyme.disable_mincut` when the flag is off, so this must be asked
# for explicitly).
#
# ### What is differentiated
#
#     AR_AD_CONTROL   the prognostic the control field is written into  (default `moisture`, ρqᵉ)
#     AR_AD_TARGET    the prognostic the loss reduces over              (default: same as the control)
#     AR_AD_STEPS     steps between the two                             (default 2)
#     AR_AD_FILE      where the gradient is written
#
# Names are ASCII aliases for Breeze's density-weighted prognostics (the raw `ρqᵉ` spellings work
# too). The loss is the mean square of the target's interior — chosen because it is guaranteed
# nonzero, so a zero gradient is a real finding rather than an artifact of a loss that was already
# zero. `AR_AD_TARGET=rain` is the physically interesting one (precipitation sensitivity to initial
# moisture), but ρqʳ is ~1e-6 after a couple of steps, so its mean square lands near Float32's floor
# and a zero gradient there says more about the arithmetic than about the atmosphere.
#
# The control is initialized to the CURRENT value of its prognostic, so the gradient is evaluated at
# the run's actual initial condition, not at some perturbation of it.
#
# ### The blocker that made this possible: `FieldTimeSeries` time interpolation (job 4782)
#
# The first AD run got all the way through — `make_zero` mirrored the whole nest in 96 s, the raise
# lifted every KA kernel — and died ~75 min in, inside the Enzyme pass:
#
#     error: could not compute the adjoint for this operation
#       "stablehlo.bitcast_convert" / "stablehlo.shift_left" / "stablehlo.shift_right_logical"
#
# Walking the `loc` table of the dumped module traced every one of those to a single
# `Union{Float32, Float64}` created by Oceananigans' `FieldTimeSeries` time interpolation, consumed
# both by the Davies `Relaxation` forcing and by the `Interpolated` open boundaries' halo fill.
# Shim 11 closes that union; the full diagnosis, the MLIR, and the two `loc` chains are documented
# there, and `minrepro_fts_union.jl` reproduces it in seconds without Reactant, Enzyme, or a GPU.
#
# So: run with shim 11 on (the default). `AR_FTS_UNION_FIX=0` puts the blocker back, which is how to
# check whether a later failure is this one again or something new.
#
# `first_time_step!` is compiled and run BEFORE the differentiated region, and `AR_AD_STEPS` counts
# the `time_step!`s after it. Without that opening step the primal goes NaN in one step (job 4785),
# which no adjoint can survive; differentiating THROUGH it would also make Enzyme transpose a body
# that costs ~2456 s to compile forward on its own. So the gradient is `∂J/∂(state at t = Δt)` — a
# sensitivity to a state the model produced, taken along the trajectory this script actually runs.

if get(ENV, "AR_AD", "0") == "1"
    ## Enzyme is a direct dependency of Reactant — certainly loaded — but not of this project, so
    ## `using Enzyme` would need a Project.toml edit. Same loaded-module lookup as JLD2 and CUDACore.
    const Enzyme = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "Enzyme")

    const AD_ALIASES = (density = :ρᵈ, u = :ρu, v = :ρv, w = :ρw, theta = :ρθ,
                        moisture = :ρqᵉ, rain = :ρqʳ, snow = :ρqˢⁿ)

    function ad_field_name(spec)
        key = Symbol(spec)
        haskey(AD_ALIASES, key) && return AD_ALIASES[key]
        available = prognostic_fields(breeze_child(model))
        haskey(available, key) && return key
        error("AR_AD: unknown field $(spec); use one of $(join(keys(AD_ALIASES), ", ")) " *
              "or a prognostic name ($(join(keys(available), ", ")))")
    end

    const AD_CONTROL = ad_field_name(get(ENV, "AR_AD_CONTROL", "moisture"))
    const AD_TARGET  = ad_field_name(get(ENV, "AR_AD_TARGET", get(ENV, "AR_AD_CONTROL", "moisture")))
    ## ### One compile, many window lengths
    ##
    ## `AR_AD_STEPS` takes a COMMA-SEPARATED list ("16,32,64"). The trip count is passed as a
    ## `ConcreteRNumber` argument rather than baked in as a Julia `Int`, so the traced loop keeps a
    ## dynamic bound and ONE compiled executable serves every window length — which is the only
    ## affordable way to measure how the sweep scales, given the compile costs ~1761 s.
    ##
    ## This forces the checkpointing choice below. Reactant refuses `checkpointing = true` once the
    ## bound is traced ("Attempted to perform automatic differentiation of a loop with non-statically
    ## known bounds"), because the `true` policy picks `isqrt(num_iters)` checkpoints and there is no
    ## `num_iters` to look at. `Binomial(budget)` is the revolve algorithm (Griewank & Walther 2000):
    ## a FIXED checkpoint budget with recomputation scheduled to minimise the extra work around it.
    ## So memory is bounded by the budget no matter how long the window gets, and the cost of a longer
    ## window shows up as recomputation instead of as tape.
    ## Commas, colons or spaces: `sbatch --export` splits on commas, so batch submissions use colons.
    ad_step_list = [parse(Int, x) for x in split(get(ENV, "AR_AD_STEPS", "2"), [',', ':', ' ']) if !isempty(strip(x))]
    smoke && (ad_step_list = [2])
    const AD_CHECKPOINT_BUDGET = parse(Int, get(ENV, "AR_AD_CHECKPOINTS", "4"))
    ## `AR_AD_RAISE_FIRST=0` re-tests whether the raise-before-Enzyme ordering is still required
    ## (REACTANT_AD_REPORT.md §4: it predates the union fix and may be a large share of the compile).
    const AD_RAISE_FIRST = get(ENV, "AR_AD_RAISE_FIRST", "1") == "1"

    ## Compiled against this ARGUMENT's type, not its value — so a fresh `ConcreteRNumber` with a
    ## different step count reuses the same executable.
    ##
    ## `AR_AD_TRACED_STEPS=0` passes a plain `Int` instead, which bakes the trip count into the
    ## executable (one compile per window, the pre-4802 behaviour) but gives the loop STATIC bounds.
    ## That distinction is the whole subject of the segfault in job 4802: traced bounds + Binomial
    ## revolve crashed the pass pipeline, and static bounds are the control case.
    ad_traced_steps = get(ENV, "AR_AD_TRACED_STEPS", "1") == "1"
    ad_steps = ad_traced_steps ? Reactant.ConcreteRNumber(first(ad_step_list)) : first(ad_step_list)

    ## The control lives at its prognostic's own location on the child's own grid, so writing
    ## it in is a plain traced broadcast (`broadcast_compatible`) — no interpolation, no KA kernel,
    ## nothing that would need shims 6/7 inside the differentiated region.
    ad_prognostic = prognostic_fields(breeze_child(model))[AD_CONTROL]
    like(f) = Field(Oceananigans.Fields.instantiated_location(f), f.grid;
                    indices = Oceananigans.Fields.indices(f))

    control  = like(ad_prognostic)
    dcontrol = like(ad_prognostic)

    ## ### `AR_AD_LOSS=precipitation`: accumulated surface precipitation over a region
    ##
    ## J = Σᵢⱼ wᵢⱼ Σₙ Δt Fᵢⱼ(tₙ) over the steps n > `AR_AD_ACCUM_START`, where F is Breeze's
    ## `bottom_precipitation_flux` (kg m⁻² s⁻¹, positive down: the bottom-face flux of every
    ## sedimenting condensate) evaluated after each `time_step!`. The weights w come from
    ## `precipitation_weights(λ, φ, h)` in `AR_AD_LOSS_FILE` (default `sensitivity/loss.jl`), called once
    ## on the host with the child's cell-centre longitudes, latitudes and terrain height; normalised
    ## weights make J a region-mean accumulation in mm.
    ##
    ## Everything the loss needs beyond the model rides in `aux`, passed `Duplicated` so that the
    ## accumulation buffer is a traced, mutable argument. A bonus of that: Enzyme's shadow of the
    ## weights comes back as ∂J/∂w = the accumulated precipitation itself.
    const AD_LOSS = get(ENV, "AR_AD_LOSS", "meansquare")
    const PRECIPITATION_LOSS = AD_LOSS in ("precip", "precipitation")
    const COASTAL_FLUX_LOSS = AD_LOSS == "coastal_flux"
    PRECIPITATION_LOSS || COASTAL_FLUX_LOSS || AD_LOSS == "meansquare" ||
        error("AR_AD_LOSS=$(AD_LOSS): use `meansquare`, `precipitation` or `coastal_flux`")

    ## ### `AR_AD_LOSS=coastal_flux`: eastward moisture flux through a meridional plane off the coast
    ##
    ## J = time-mean, segment-mean vertically integrated eastward moisture flux (kg m⁻¹ s⁻¹, an IVT-like
    ## number) through the u-face column nearest `AR_AD_PLANE_LON` (default −124.3°), over
    ## `AR_AD_PLANE_LAT` (default 44.5–47.0°N), surface to model top:
    ##
    ##     J = (1 / N_acc) Σₙ Σⱼₖ Wⱼₖ ρuᵢ₀ⱼₖ ½(ρqᵉ/ρᵈ|ᵢ₀₋₁ + ρqᵉ/ρᵈ|ᵢ₀),   Wⱼₖ = A^x_{i₀jk} / Σⱼ Δy_{i₀j}
    ##
    ## with A^x the terrain-following face area (Δy·Δz). ρu is dry-density-weighted (ρᵈu) in Breeze, so
    ## ρu·ρqᵉ/ρᵈ = u·ρqᵉ. Moisture is the PROGNOSTIC ρqᵉ — total non-precipitating water (vapour + cloud)
    ## under the saturation-adjustment scheme — so the loss itself never differentiates through saturation
    ## adjustment; the dynamics still does. Accumulated over steps n > AR_AD_ACCUM_START.
    function coastal_plane_aux()
        plane_λ = parse(Float64, get(ENV, "AR_AD_PLANE_LON", "-124.3"))
        φ₁ᵖ, φ₂ᵖ = parse.(Float64, split(get(ENV, "AR_AD_PLANE_LAT", "44.5:47.0"), [',', ':']))
        λf = Array(λnodes(host_grid, Face(), Center(), Center()))
        φc = Array(φnodes(host_grid, Center(), Center(), Center()))
        i₀ = argmin(abs.(λf .- plane_λ))
        2 ≤ i₀ ≤ length(λf) - 1 || error("coastal_flux plane at $(plane_λ)° is on the domain wall")
        band = findall(φ -> φ₁ᵖ ≤ φ ≤ φ₂ᵖ, φc)
        Nxh, Nyh, Nzh = size(host_grid)
        L = sum(Oceananigans.Operators.Δyᶠᶜᶜ(i₀, j, 1, host_grid) for j in band)
        W = zeros(FT, Nyh, Nzh)
        for j in band, k in 1:Nzh
            W[j, k] = Oceananigans.Operators.Axᶠᶜᶜ(i₀, j, k, host_grid) / L
        end
        stage(@sprintf("AD: coastal_flux plane at u-face i₀ = %d (λ = %.3f°), %d rows %.2f–%.2f°N, segment %.0f km",
                       i₀, λf[i₀], length(band), φc[first(band)], φc[last(band)], L / 1e3))
        ## Host-only description of the plane, for the output file; kept out of the traced argument.
        global COASTAL_PLANE_META = (λ = λf[i₀], i = i₀, φ_band = (φc[first(band)], φc[last(band)]),
                                     rows = band, segment_m = L)
        return (; plane_weights = Reactant.to_rarray(W),
                  plane_acc = Reactant.to_rarray(zeros(FT, Nyh, Nzh)),
                  start = Reactant.ConcreteRNumber(parse(Int, get(ENV, "AR_AD_ACCUM_START", "0"))),
                  plane_i = Val(i₀))
    end

    ad_aux = if COASTAL_FLUX_LOSS
        coastal_plane_aux()
    elseif PRECIPITATION_LOSS
        loss_file = get(ENV, "AR_AD_LOSS_FILE", joinpath(@__DIR__, "sensitivity", "loss.jl"))
        include(loss_file)
        λc = Array(λnodes(host_grid, Center(), Center(), Center()))
        φc = Array(φnodes(host_grid, Center(), Center(), Center()))
        Hx, Hy, _ = Oceananigans.Grids.halo_size(host_grid)
        Nxh, Nyh, _ = size(host_grid)
        hc = Array(parent(host_grid.z.formulation.h))[Hx+1:Hx+Nxh, Hy+1:Hy+Nyh, 1]
        ## Two accepted contracts: `precipitation_weights(λ, φ, h)` on cell centres, or
        ## sensitivity/region.jl's `region_weights(λ_faces, φ_faces) -> (w, area)`.
        w = if isdefined(@__MODULE__, :precipitation_weights)
            Base.invokelatest(precipitation_weights, Float64.(λc), Float64.(φc), Float64.(hc))
        else
            λf = Array(λnodes(host_grid, Face(), Center(), Center()))
            φf = Array(φnodes(host_grid, Center(), Face(), Center()))
            first(Base.invokelatest(region_weights, Float64.(λf), Float64.(φf)))
        end
        size(w) == (Nxh, Nyh) || error("precipitation_weights returned $(size(w)), expected $((Nxh, Nyh))")
        all(isfinite, w) || error("precipitation_weights returned non-finite weights")

        weights_field = Field{Center, Center, Nothing}(grid)
        host_weights = zeros(FT, size(parent(weights_field)))
        view(host_weights, parentindices(interior(weights_field))...) .= reshape(FT.(w), Nxh, Nyh, 1)
        copyto!(parent(weights_field), host_weights)

        stage(@sprintf("AD: precipitation loss from %s — %d columns weighted, Σw = %.4g",
                       loss_file, count(!iszero, w), sum(w)))
        base_aux = (; accumulated = Field{Center, Center, Nothing}(grid),
                      weights = weights_field,
                      start = Reactant.ConcreteRNumber(parse(Int, get(ENV, "AR_AD_ACCUM_START", "0"))))

        ## `AR_AD_DT_SCHEDULE=<file>`: replay a recorded adaptive-Δt schedule (one Δt in seconds per
        ## line, step n of the AD window uses line n) instead of the fixed `AR_DT`. The schedule rides
        ## in as a device array indexed by the traced step counter, so `time_step!` receives a TRACED
        ## Δt. The acoustic substep count is still host-decided from `AR_DT` (shim 5), so set `AR_DT`
        ## to the schedule's maximum. Windows longer than the schedule reuse its last entry.
        schedule_file = get(ENV, "AR_AD_DT_SCHEDULE", "")
        if isempty(schedule_file)
            base_aux
        else
            dts = [parse(FT, l) for l in eachline(schedule_file) if !isempty(strip(l))]
            maximum(dts) <= Δt || @warn "AR_AD_DT_SCHEDULE: max Δt $(maximum(dts)) s exceeds AR_DT = $(Δt) s, \
                                         which sized the acoustic substeps"
            stage(@sprintf("AD: replaying %d recorded Δt from %s (%.1f–%.1f s, mean %.1f s)",
                           length(dts), schedule_file, minimum(dts), maximum(dts), sum(dts) / length(dts)))
            merge(base_aux, (; dts = Reactant.to_rarray(dts)))
        end
    else
        nothing
    end

    ## ### The opening step runs OUTSIDE the differentiated region
    ##
    ## Without Breeze's Euler-ish `first_time_step!` the trajectory enters RK3 straight from the
    ## unbalanced initial condition and the PRIMAL goes NaN in one step — job 4785 returned J = NaN
    ## with all 32400 gradient cells non-finite, from an initial state that reported `nonfinite=0`.
    ##
    ## But it does not have to be DIFFERENTIATED; it only has to have HAPPENED. Compiling and running
    ## it here, ahead of the sweep, buys two things:
    ##
    ##   * the reverse compile covers only the `time_step!` loop. `first_time_step!` costs ~2456 s to
    ##     compile forward on its own, and putting it inside the differentiated region makes Enzyme
    ##     transpose all of it too;
    ##   * the control then perturbs a SETTLED state rather than the raw initial condition, which is
    ##     the better-posed question anyway — `∂J/∂(model state at t = Δt)` is a sensitivity to a
    ##     state the model itself produced, not to an analytic field it would have rejected.
    ##
    ## The ordering is what makes this correct: the control is seeded, and written into the model,
    ## AFTER the opening step. Were the control applied before it, the gradient would silently omit
    ## the path through `first_time_step!` and be wrong rather than merely different.
    ##
    ## `AR_AD_FIRST_STEP=0` skips it, which is how job 4785's NaN was diagnosed — keep it for triage,
    ## not for results.
    ## ### `AR_AD_SPINUP_STEPS`: settle the cold start at a small Δt before the long-Δt adjoint
    ##
    ## The interpolated ERA5 IC is unbalanced, and the opening step's ρw kick grows with Δt (−4.8,
    ## −20.7, −38 for 10/30/40 s at 12 km): long steps blow up at the FIRST step, not in the steady
    ## flow. So run `first_time_step!` and `AR_AD_SPINUP_STEPS` further steps at `AR_AD_SPINUP_DT`
    ## (default 10 s), compiled forward-only and NOT differentiated, then differentiate at `AR_DT`.
    ## The acoustic substep count stays the one shim 5 sized for `AR_DT`, i.e. MORE substeps than the
    ## short spin-up steps need, which only costs time. The control then perturbs the state at
    ## t = Δt_spin · (1 + AR_AD_SPINUP_STEPS), and the AD window must fit in what is left of
    ## AR_PARENT_HOURS after it.
    ad_spinup_steps = parse(Int, get(ENV, "AR_AD_SPINUP_STEPS", "0"))
    Δt_first = ad_spinup_steps > 0 ? parse(FT, get(ENV, "AR_AD_SPINUP_DT", "10")) : Δt

    if get(ENV, "AR_AD_FIRST_STEP", "1") == "1"
        AIVA_HOST_DT[] = Δt_first
        stage("AD: compiling first_time_step! at Δt = $(Δt_first) s (outside the differentiated region)")
        compile_start = time_ns()
        r_ad_first = @compile compile_options = ar_compile_options(raise = raise_option) first_time_step!(
            model, Δt_first)
        stage(@sprintf("AD: compiled first_time_step! in %.1f s", 1e-9 * (time_ns() - compile_start)))
        r_ad_first(model, Δt_first)
        stage("AD: ran first_time_step!; the differentiated segment starts from the state it left")
        report(model, 0.0)
    end

    if ad_spinup_steps > 0
        AIVA_HOST_DT[] = Δt_first
        stage("AD: compiling the spin-up loop ($(ad_spinup_steps) steps at Δt = $(Δt_first) s, forward only)")
        compile_start = time_ns()
        spinup_n = Reactant.ConcreteRNumber(ad_spinup_steps)
        r_spinup = @compile compile_options = ar_compile_options(raise = raise_option) step_for!(
            model, Δt_first, spinup_n)
        stage(@sprintf("AD: compiled the spin-up loop in %.1f s", 1e-9 * (time_ns() - compile_start)))
        spin_start = time_ns()
        r_spinup(model, Δt_first, spinup_n)
        stage(@sprintf("AD: spun up %d steps in %.1f s; t = %.0f s", ad_spinup_steps,
                       1e-9 * (time_ns() - spin_start), host_number(breeze_child(model).clock.time)))
        report(model, 0.0)
    end

    ## Seeded from the post-opening-step field, so evaluating the loss at `control` reproduces the
    ## trajectory exactly. Host round trip rather than a device-to-device broadcast: `Array(parent(·))`
    ## then a host→device `copyto!` is the direction Reactant specializes (shim 6's note).
    copyto!(parent(control), Array(parent(ad_prognostic)))

    ad_checkpointing() = AD_CHECKPOINT_BUDGET < 0 ? true :
                         AD_CHECKPOINT_BUDGET == 0 ? false :
                         Reactant.Binomial(AD_CHECKPOINT_BUDGET)

    scheduled_Δt(aux, n, Δt) = haskey(aux, :dts) ? aux.dts[min(n, length(aux.dts))] : Δt

    @inline function plane_flux(child, ::Val{i₀}) where i₀
        fields = prognostic_fields(child)
        ρu = view(interior(fields.ρu), i₀, :, :)
        q₋ = view(interior(fields[AD_CONTROL]), i₀ - 1, :, :) ./ view(interior(fields.ρᵈ), i₀ - 1, :, :)
        q₊ = view(interior(fields[AD_CONTROL]), i₀, :, :) ./ view(interior(fields.ρᵈ), i₀, :, :)
        return ρu .* (q₋ .+ q₊) ./ 2
    end

    function ad_loss(model, control, aux::NamedTuple{K}, Δt, nsteps) where K
        :plane_weights in K || return precipitation_loss(model, control, aux, Δt, nsteps)
        child = breeze_child(model)
        interior(prognostic_fields(child)[AD_CONTROL]) .= interior(control)
        acc = aux.plane_acc
        acc .= 0
        @trace mincut = true checkpointing = ad_checkpointing() track_numbers = false for n = 1:nsteps
            time_step!(model, Δt)
            acc .+= ifelse(n > aux.start, one(Δt), zero(Δt)) .* plane_flux(child, aux.plane_i)
        end
        return sum(aux.plane_weights .* acc) / (nsteps - aux.start)
    end

    function precipitation_loss(model, control, aux::NamedTuple, Δt, nsteps)
        child = breeze_child(model)
        interior(prognostic_fields(child)[AD_CONTROL]) .= interior(control)
        acc = interior(aux.accumulated)
        acc .= 0
        @trace mincut = true checkpointing = ad_checkpointing() track_numbers = false for n = 1:nsteps
            Δtₙ = scheduled_Δt(aux, n, Δt)
            time_step!(model, Δtₙ)
            flux = Breeze.AtmosphereModels.bottom_precipitation_flux(child)
            compute!(flux)
            acc .+= ifelse(n > aux.start, Δtₙ, zero(Δtₙ)) .* interior(flux)
        end
        return sum(interior(aux.weights) .* acc)
    end

    ad_loss(model, control, ::Nothing, Δt, nsteps) = ad_loss(model, control, Δt, nsteps)

    function ad_loss(model, control, Δt, nsteps)
        interior(prognostic_fields(breeze_child(model))[AD_CONTROL]) .= interior(control)
        ## `AR_AD_CHECKPOINTS`: >0 = `Binomial(n)` revolve, 0 = none, -1 = `true` (Reactant's automatic
        ## policy, `isqrt(num_iters)` checkpoints — STATIC bounds only). -1 matters because it is the
        ## ONE setting that has ever produced a gradient here (job 4790), and reducing the knob to
        ## Binomial-or-nothing made that configuration unreachable.
        @trace mincut = true checkpointing = (AD_CHECKPOINT_BUDGET < 0 ? true :
                                              AD_CHECKPOINT_BUDGET == 0 ? false :
                                              Reactant.Binomial(AD_CHECKPOINT_BUDGET)) track_numbers = false for _ = 1:nsteps
            time_step!(model, Δt)
        end
        x = interior(prognostic_fields(breeze_child(model))[AD_TARGET])
        return sum(x .^ 2) / length(x)
    end

    function ad_gradient!(model, dmodel, control, dcontrol, aux, daux, Δt, nsteps)
        ## Enzyme ACCUMULATES into the shadow, so a second call would return the sum of both sweeps.
        parent(dcontrol) .= 0
        _, loss_value = Enzyme.autodiff(
            ## `set_strong_zero` makes `0 * NaN` and `0 * Inf` return 0 rather than propagate, so a
            ## NaN sitting on a path with a zero adjoint cannot poison the whole gradient.
            Enzyme.set_strong_zero(Enzyme.ReverseWithPrimal),
            ad_loss, Enzyme.Active,
            Enzyme.Duplicated(model, dmodel),
            Enzyme.Duplicated(control, dcontrol),
            isnothing(aux) ? Enzyme.Const(aux) : Enzyme.Duplicated(aux, daux),
            Enzyme.Const(Δt),
            Enzyme.Const(nsteps))
        return dcontrol, loss_value
    end

    stage("AD: ∂/∂$(AD_CONTROL) of $(PRECIPITATION_LOSS ? "weighted accumulated precipitation" : "mean($(AD_TARGET)²)"); windows $(join(ad_step_list, ", ")) steps, " *
          "$(AD_CHECKPOINT_BUDGET < 0 ? "automatic (true)" : AD_CHECKPOINT_BUDGET == 0 ? "no" : "Binomial($(AD_CHECKPOINT_BUDGET))") " *
          "checkpointing, $(ad_traced_steps ? "traced" : "static") trip count")

    ## `make_zero` walks the whole nest — child, parent, grids, exchanger, microphysics — and
    ## allocates a zeroed shadow for every differentiable array in it, so this roughly DOUBLES the
    ## model's device footprint before a single tape entry exists. It is also the first thing that can
    ## fail on a struct Enzyme cannot mirror, so it gets its own stage line and its own error.
    shadow_start = time_ns()
    dmodel = Enzyme.make_zero(model)
    stage(@sprintf("AD: built the model shadow in %.1f s", 1e-9 * (time_ns() - shadow_start)))
    ad_daux = isnothing(ad_aux) ? nothing : Enzyme.make_zero(ad_aux)

    ## Calling the compiled thunk overflows the default 8 MB task stack (job 4784: the sweep
    ## COMPILED in 3805.8 s, then died in `Reactant.Compiler.Thunk`). `(::Thunk)(args...)` is a
    ## `@generated` function whose body flattens every argument into buffers; the AD thunk carries
    ## the model AND its `make_zero` shadow, so that body is about twice the forward path's — and the
    ## forward path already sits at 24 prognostic fields plus two grids' worth of coordinate arrays.
    ##
    ## Nothing is recursing without bound: it is depth, not a cycle, so a bigger stack is the whole
    ## fix. `Task(f, reserved_stack)` is the documented way to ask for one; the task is left sticky
    ## (the default) so it stays on this thread and nothing about device execution changes.
    function with_big_stack(f; reserved = 1 << 29)   # 512 MiB
        task = Task(f, reserved)
        schedule(task)
        return fetch(task)
    end

    ## ### State snapshot, so every window is the SAME experiment
    ##
    ## Each sweep steps the model forward, so without a reset window 32 would start where window 16
    ## finished and the three measurements would describe three different trajectories — the timings
    ## would still be comparable, but J and the gradients would not, and after 16+32+64 steps the run
    ## would likely be somewhere the physics no longer means anything.
    ##
    ## Snapshot on the host and restore before each sweep. The CLOCK goes with the prognostics: it
    ## drives the `FieldTimeSeries` time interpolation for the parent boundary/forcing data, so
    ## restoring the fields while leaving the clock advanced would silently change the boundary
    ## forcing between windows.
    child_state = breeze_child(model)
    ad_snapshot = Dict{Symbol,Array}(name => Array(parent(f))
                                     for (name, f) in pairs(prognostic_fields(child_state)))

    ## EVERY clock field, read off the struct rather than listed by hand: `Clock` carries
    ## `(time, last_Δt, last_stage_Δt, iteration, stage)`, and restoring only the obvious three would
    ## let the substepping state leak from one window into the next. `stage` is a plain `Int`; the
    ## rest are `ConcreteRNumber`s, so each is rebuilt from its host value.
    ##
    ## Both clocks: the PARENT's drives the `FieldTimeSeries` time interpolation for the boundary and
    ## Davies data, so leaving it advanced would change the forcing between windows.
    ad_clock_objs = Any[child_state.clock]
    try
        nest_parent = model isa NestedModel ? model.parent : model.atmosphere.model.parent
        hasproperty(nest_parent, :clock) && push!(ad_clock_objs, nest_parent.clock)
    catch err
        @warn "AD: could not reach the parent clock to snapshot it; windows may differ in their \
               boundary forcing time" err
    end

    ad_clock0 = [Dict{Symbol,Any}(f => (getfield(clk, f) isa Reactant.ConcreteRNumber ?
                                        host_number(getfield(clk, f)) : getfield(clk, f))
                                  for f in fieldnames(typeof(clk)))
                 for clk in ad_clock_objs]

    stage("AD: snapshotted $(length(ad_snapshot)) prognostics and $(length(ad_clock_objs)) clock(s) " *
          "for per-window reset")

    function restore_ad_state!()
        for (name, f) in pairs(prognostic_fields(breeze_child(model)))
            copyto!(parent(f), ad_snapshot[name])
        end
        for (clk, saved) in zip(ad_clock_objs, ad_clock0)
            for (fname, value) in saved
                setfield!(clk, fname, getfield(clk, fname) isa Reactant.ConcreteRNumber ?
                                      Reactant.ConcreteRNumber(value) : value)
            end
        end
        return nothing
    end

    ## ### `AR_AD_PRIMAL_ONLY=1`: is the LOSS finite, before asking anything of Enzyme?
    ##
    ## `ReverseWithPrimal` returns J alongside the gradient, so a NaN J means the forward pass inside
    ## `autodiff` produced NaN — an adjoint cannot rescue that, and no amount of staring at gradient
    ## statistics will say whether the model diverged or Enzyme's augmented forward (which recomputes
    ## segments under `checkpointing`) diverged from the plain one.
    ##
    ## This compiles `ad_loss` on its own — same control write, same `@trace`d loop, same reductions,
    ## no `autodiff` — and reports J. It is much cheaper than the reverse sweep (forward only), and it
    ## splits the question cleanly: NaN here means the trajectory itself is the problem (this path has
    ## no `first_time_step!`, so it enters RK3 straight from an unbalanced initial condition); finite
    ## here with NaN from the sweep means the augmented forward is.
    if get(ENV, "AR_AD_PRIMAL_ONLY", "0") == "1"
        AIVA_HOST_DT[] = Δt
        stage("AD: AR_AD_PRIMAL_ONLY=1 — compiling the LOSS only (no Enzyme)")
        compile_start = time_ns()
        r_ad_loss = @compile compile_options = ar_compile_options(
            raise = raise_option, raise_first = AD_RAISE_FIRST) ad_loss(model, control, ad_aux, Δt, ad_steps)
        stage(@sprintf("AD: compiled the loss in %.1f s", 1e-9 * (time_ns() - compile_start)))

        ## `AR_AD_FD_DIR=<gradient.jld2>` turns this into a FINITE-DIFFERENCE check of a gradient a
        ## previous run produced. The loss executable is already compiled, so a second evaluation is
        ## nearly free — evaluate J at the control and at `c + ε·v`, and compare
        ##
        ##     (J(c + εv) − J(c)) / ε   against   ⟨∂J/∂c, v⟩
        ##
        ## along `v = g/‖g‖`, the steepest-ascent direction. Directional rather than one-cell-at-a-time:
        ## it exercises all 32400 cells for the same GPU time, and it puts the signal where the
        ## gradient is largest instead of wherever a cell index happened to land. `⟨g, v⟩ = ‖g‖`, so
        ## the number to match is just the gradient's norm.
        ## `AR_AD_FD_EPS` takes a COMMA-SEPARATED list. One ε cannot distinguish "the gradient is
        ## right and ε is large enough for curvature to show" from "the gradient is wrong by that
        ## factor" — only the trend can. For an exact gradient the ratio approaches 1 LINEARLY in ε
        ## (the leading error is the ½ε·vᵀHv curvature term); a gradient wrong by a constant factor
        ## plateaus at that factor instead. The loss executable is already compiled, so each extra ε
        ## costs one evaluation, not one compile.
        fd_dir = get(ENV, "AR_AD_FD_DIR", "")
        fd_eps_list = [parse(Float64, x) for x in split(get(ENV, "AR_AD_FD_EPS", "1e-3"), [',', ':'])
                       if !isempty(strip(x))]

        ## The control's own bytes, saved BEFORE anything is evaluated. Reading the perturbation base
        ## back off `ad_prognostic` later would read the model's field AFTER `ad_loss` has stepped it —
        ## a different base point entirely, which is what made the first FD attempt (job 4797) report
        ## a ratio of 16.7 instead of ~1.
        control_host = Array(parent(control))

        ## Both evaluations must start from the SAME state. `ad_loss` steps the model, so without this
        ## the perturbed evaluation would begin one step further along and the difference would measure
        ## an extra step of evolution rather than the perturbation.
        restore_ad_state!()
        eval_start = time_ns()
        J_only = with_big_stack() do
            r_ad_loss(model, control, ad_aux, Δt, ad_steps)
        end

        if !isempty(fd_dir)
            g_prev = JLD2.jldopen(fd_dir, "r") do file; file["ad/gradient"]; end
            gnorm = sqrt(sum(abs2, Float64.(g_prev)))
            v = Float32.(g_prev ./ gnorm)

            stage(@sprintf("AD: FD check along g/‖g‖ — ⟨∇J, v⟩ = ‖g‖ = %.6g, J(c) = %.10g",
                           gnorm, host_number(J_only)))
            fd_rows = NamedTuple[]

            for fd_eps in fd_eps_list
                ## Perturb the SAVED control's interior on the host, then push the whole parent
                ## across — the same direction Reactant specializes (shim 6).
                ph = copy(control_host)
                view(ph, parentindices(interior(control))...) .+= Float32(fd_eps) .* v
                copyto!(parent(control), ph)

                restore_ad_state!()
                J_pert = with_big_stack() do
                    r_ad_loss(model, control, ad_aux, Δt, ad_steps)
                end

                fd = (host_number(J_pert) - host_number(J_only)) / fd_eps
                push!(fd_rows, (; fd_eps, J_pert = host_number(J_pert), fd, ratio = fd / gnorm))
                stage(@sprintf("AD:   ε = %.1e   J(c+εv) = %.10g   (ΔJ)/ε = %.6g   ratio = %.4f",
                               fd_eps, host_number(J_pert), fd, fd / gnorm))
            end

            ## Put the control back, so anything after this sees the unperturbed one.
            copyto!(parent(control), control_host)

            ## The VERDICT is in the trend, not in any single ratio. `ratio - 1` should fall roughly
            ## in proportion to ε; if it flattens out, the gradient is wrong by whatever it flattens
            ## to. Reported as the ratio of successive excesses so it can be read at a glance: ~ε-scaling
            ## means each row's excess shrinks by the same factor as ε does.
            if length(fd_rows) > 1
                stage("AD: FD convergence — for an exact gradient, (ratio − 1) ∝ ε")
                for i in eachindex(fd_rows)
                    r = fd_rows[i]
                    trend = if i == 1
                        ""
                    else
                        prev = fd_rows[i - 1]
                        @sprintf("   excess ×%.2f for ε ×%.2f",
                                 (r.ratio - 1) / (prev.ratio - 1), r.fd_eps / prev.fd_eps)
                    end
                    stage(@sprintf("AD:   ε = %.1e   ratio = %.4f   excess = %+.2f%%%s",
                                   r.fd_eps, r.ratio, 100 * (r.ratio - 1), trend))
                end
            end
        end
        stage(@sprintf("AD: primal-only J = %.6g after %d step(s), evaluated in %.1f s — %s",
                       host_number(J_only), host_number(ad_steps), 1e-9 * (time_ns() - eval_start),
                       isfinite(host_number(J_only)) ?
                           "FINITE, so a NaN from the reverse sweep is Enzyme's augmented forward, not the model" :
                           "NON-FINITE, so the trajectory itself diverges and the gradient was never going to mean anything"))
        exit(0)
    end


    ## ### `AR_AD_HLO=1`: dump the UNOPTIMIZED module and stop
    ##
    ## Job 4802 segfaulted (exit 139, core dumped, no Julia-level error) inside the pass pipeline
    ## while compiling this sweep with a traced trip count and `Binomial(4)` revolve checkpointing.
    ## A crash with no stack is only debuggable from the input, so dump the module the pipeline was
    ## handed.
    ##
    ## `optimize = false` runs NO passes — which is the point twice over: it is the artifact a bug
    ## report needs, and it is produced strictly BEFORE the pass that dies, so this succeeds even
    ## though the compile does not. What it shows is the `stablehlo.while` carrying Enzyme's
    ## checkpointing attributes (`enzyme.enable_checkpointing`, `enzyme.binomial_checkpointing`,
    ## `enzyme.checkpoint_period`) alongside the `enzyme.autodiff` op, with the kernels still
    ## `enzymexla.kernel_call`s — see the `AR_HLO` section above for why `optimize = false` means the
    ## raise never runs regardless of the `raise` setting.
    ##
    ## Pair it with `AR_AD_FIRST_STEP=0` (the traced IR of `ad_gradient!` does not depend on whether
    ## the opening step already ran) to skip the ~2675 s `first_time_step!` compile, and flip
    ## `AR_AD_TRACED_STEPS` to diff the crashing module against the static-bound one that compiled.
    if get(ENV, "AR_AD_HLO", "0") == "1"
        hlo_path = get(ENV, "AR_AD_HLO_PATH",
                       "unopt_ar_ad_$(ad_traced_steps ? "traced" : "static")_binomial$(AD_CHECKPOINT_BUDGET).mlir")
        stage("AD: tracing ad_gradient! → unoptimized StableHLO " *
              "($(ad_traced_steps ? "TRACED" : "static") trip count, Binomial($(AD_CHECKPOINT_BUDGET)))")
        trace_start = time_ns()
        ad_module = @code_hlo compile_options = ar_hlo_options(
            raise = raise_option, raise_first = AD_RAISE_FIRST) ad_gradient!(
            model, dmodel, control, dcontrol, ad_aux, ad_daux, Δt, ad_steps)
        stage(@sprintf("AD: traced in %.1f s", 1e-9 * (time_ns() - trace_start)))

        write(hlo_path, repr(ad_module))
        stage(@sprintf("AD: wrote %s (%.1f MB) — stopping before the pass pipeline that segfaults",
                       hlo_path, filesize(hlo_path) / 1e6))
        exit(0)
    end

    AIVA_HOST_DT[] = Δt
    stage("AD: compiling the reverse sweep (raise_first = $(AD_RAISE_FIRST)) — ONE compile for every window")
    compile_start = time_ns()
    ## `AR_AD_DETECT_NAN=1`: XLA checks every thunk of the REVERSE executable for NaN and logs the
    ## offending HLO instruction (warning mode). Only this compile — the same pass breaks the eager
    ## kernel compiles ("Module output slices must not contain tuple shapes", job 2611).
    ad_debug_options = get(ENV, "AR_AD_DETECT_NAN", "0") == "1" ?
        merge(XLA_DEBUG_OPTIONS, (; xla_gpu_detect_nan = Reactant.Proto.xla.var"DebugOptions.DetectionMode".DETECTION_MODE_WARNING)) :
        XLA_DEBUG_OPTIONS
    r_ad_gradient! = @compile compile_options = ar_compile_options(
        raise = raise_option, raise_first = AD_RAISE_FIRST, xla_debug_options = ad_debug_options) ad_gradient!(
        model, dmodel, control, dcontrol, ad_aux, ad_daux, Δt, ad_steps)
    ad_compile_seconds = 1e-9 * (time_ns() - compile_start)
    stage(@sprintf("AD: compiled the reverse sweep in %.1f s", ad_compile_seconds))

    ad_results = NamedTuple[]

    for n in ad_step_list
        ## Fresh shadow per window: Enzyme ACCUMULATES into it, so reusing one would return window
        ## 16's gradient added to window 32's. `local` is the point, not an accident — the global
        ## `dmodel` above exists only to give `@compile` an argument to specialize on, and must not
        ## be carried from one window into the next.
        local dmodel = Enzyme.make_zero(model)
        local ad_daux = isnothing(ad_aux) ? nothing : Enzyme.make_zero(ad_aux)
        restore_ad_state!()

        ## Same executable, new value — this is the point of tracing the trip count.
        nsteps_r = ad_traced_steps ? Reactant.ConcreteRNumber(n) : n

        sweep_start = time_ns()
        ∂J, J = with_big_stack() do
            r_ad_gradient!(model, dmodel, control, dcontrol, ad_aux, ad_daux, Δt, nsteps_r)
        end
        sweep_seconds = 1e-9 * (time_ns() - sweep_start)

        g = Array(host_interior(∂J))
        finite = filter(isfinite, g)
        push!(ad_results, (; n, sweep_seconds, J = host_number(J),
                           maxabs = isempty(finite) ? NaN : maximum(abs, finite),
                           nonfinite = length(g) - length(finite)))

        stage(@sprintf("AD: [%3d steps] J = %.6g, swept in %.1f s (%.2f s/step)",
                       n, host_number(J), sweep_seconds, sweep_seconds / n))
        stage(@sprintf("AD: [%3d steps] ∂J/∂%s — max|∂| = %.4g, ∈ [%.4g, %.4g], %d non-finite, %d exactly zero",
                       n, AD_CONTROL,
                       isempty(finite) ? NaN : maximum(abs, finite),
                       isempty(finite) ? NaN : minimum(finite),
                       isempty(finite) ? NaN : maximum(finite),
                       length(g) - length(finite), count(iszero, g)))

        ## Three verdicts, not two — see the note on why an all-NaN gradient must not be reported as
        ## "identically zero".
        if !isfinite(host_number(J))
            stage("AD: the LOSS is non-finite, so the gradient cannot mean anything — the failure is \
                   in the primal trajectory, not in the adjoint (AR_AD_PRIMAL_ONLY=1 separates them)")
        elseif length(finite) < length(g)
            stage(@sprintf("AD: %d of %d gradient cells are non-finite while the loss is finite — the \
                            adjoint is producing NaN somewhere the primal does not",
                           length(g) - length(finite), length(g)))
        elseif maximum(abs, finite) == 0
            stage("AD: the gradient is identically zero — the loss does not depend on the control \
                   through this trajectory (too few steps, or an inactive path)")
        end

        if write_output
            ad_default = PRECIPITATION_LOSS ?
                "reactant_$(get(ENV, "AR_DOMAIN", "corridor"))_sensitivity_precip_$(AD_CONTROL)_$(n)steps.jld2" :
                "reactant_$(get(ENV, "AR_DOMAIN", "corridor"))_gradient_$(AD_CONTROL)_$(AD_TARGET)_$(n)steps.jld2"
            ad_file = get(ENV, "AR_AD_FILE", "")
            ## A single AR_AD_FILE with several windows would be overwritten window by window, so
            ## suffix the step count whenever more than one window runs.
            ad_path = isempty(ad_file) ? ad_default :
                      length(ad_step_list) > 1 ? replace(ad_file, r"\.jld2$" => "_$(n)steps.jld2") : ad_file
            write_grid_metadata(ad_path)
            JLD2.jldopen(ad_path, "a+") do file
                file["ad/gradient"]        = g
                file["ad/control"]         = string(AD_CONTROL)
                file["ad/target"]          = string(AD_TARGET)
                file["ad/steps"]           = n
                file["ad/checkpointing"]   = "Binomial($(AD_CHECKPOINT_BUDGET))"
                file["ad/loss"]            = Float64(host_number(J))
                file["ad/location"]        = location_name(∂J)
                file["ad/control_initial"] = Array(host_interior(control))
                file["ad/sweep_seconds"]   = sweep_seconds
                file["ad/compile_seconds"] = ad_compile_seconds
                file["ad/loss_kind"]       = AD_LOSS
                file["ad/terrain_source"]  = get(ENV, "AR_TERRAIN", "etopo")
                file["ad/terrain_smoothing_passes"] = parse(Int, get(ENV, "AR_TERRAIN_SMOOTHING", "2"))
                file["ad/spinup_steps"]    = ad_spinup_steps
                file["ad/spinup_dt"]       = Float64(Δt_first)
                file["ad/control_time"]    = Float64(host_number(ad_clock0[1][:time]))
                file["ad/dt"]              = Float64(Δt)
                file["ad/control_value"]   = Array(host_interior(control))
                write_physical_heights(file)
                if COASTAL_FLUX_LOSS
                    m = COASTAL_PLANE_META
                    file["ad/plane_lambda"]   = m.λ
                    file["ad/plane_i"]        = m.i
                    file["ad/plane_phi_band"] = collect(m.φ_band)
                    file["ad/plane_rows"]     = collect(m.rows)
                    file["ad/plane_segment_m"] = m.segment_m
                    file["ad/plane_weights"]  = Array(ad_aux.plane_weights)
                    file["ad/accum_start"]    = host_number(ad_aux.start)
                    file["ad/loss_units"]     = "kg m^-1 s^-1: time-mean, segment-mean ∫ u ρqᵉ dz through the plane (ρqᵉ = vapour + cloud)"
                end
                if PRECIPITATION_LOSS
                    file["ad/weights"]              = Array(host_interior(ad_aux.weights))[:, :, 1]
                    file["ad/precip_accumulated"]   = Array(host_interior(ad_aux.accumulated))[:, :, 1]
                    file["ad/accum_start"]          = host_number(ad_aux.start)
                    file["ad/loss_units"]           = "kg m^-2 (mm), weighted by ad/weights"
                end
                file["ad/note"] = "∂J/∂control at every interior cell, where J = mean(interior(" *
                                  string(AD_TARGET) * ")²) after $(n) time_step!s. The opening " *
                                  "first_time_step! ran OUTSIDE the differentiated region, so this " *
                                  "is a sensitivity to the state at t = Δt. Reverse mode, Enzyme " *
                                  "via Reactant, raise_first=true, Binomial($(AD_CHECKPOINT_BUDGET))."
            end
            stage("AD: [$(n) steps] wrote $(ad_path) " *
                  "($(round(filesize(ad_path) / 2^20, digits=1)) MiB)")
        end
    end

    ## The measurement this run exists for: does the sweep cost scale with the window, and does the
    ## per-step cost fall (amortising fixed overhead) or rise (revolve recomputation)?
    if length(ad_results) > 1
        stage("AD: window scaling — one compile of $(round(ad_compile_seconds, digits=1)) s served all of them")
        for r in ad_results
            stage(@sprintf("AD:   %3d steps  %8.1f s  %6.2f s/step   J = %.6g  max|∂| = %.4g%s",
                           r.n, r.sweep_seconds, r.sweep_seconds / r.n, r.J, r.maxabs,
                           r.nonfinite == 0 ? "" : @sprintf("  <%d NON-FINITE>", r.nonfinite)))
        end
    end

    exit(0)
end

# `AR_SKIP_FIRST_STEP=1` skips BOTH the `first_time_step!` compile and its call, going straight to the
# `@trace`d loop. That compile costs ~48 min on a T4 at this size and is the one already known to
# succeed, so skipping it turns a ~58 min round trip into ~10 min when the question is only whether
# `step_for!` compiles. NOT equivalent physics: the model then enters the RK3 chunks straight from the
# initial condition, without the Euler-ish first step, so use it for compile triage, not for results.
skip_first = get(ENV, "AR_SKIP_FIRST_STEP", "0") == "1"

r_first_time_step! = if skip_first
    stage("SKIPPING first_time_step! compile (AR_SKIP_FIRST_STEP=1) — going straight to the traced loop")
    nothing
else
    if VANILLA
        stage("first_time_step! will run EAGERLY (AR_ARCH=cuda) — no XLA compile")
        first_time_step!
    else
        stage("compiling first_time_step! ($(Nx)×$(Ny)×$(Nz) child, " *
              "$(parent_Nx)×$(parent_Ny)×$(length(parent_pressure_levels)) parent)")
        compile_start = time_ns()
        f = @compile compile_options = ar_compile_options(raise = raise_option) first_time_step!(model, Δt)
        stage(@sprintf("compiled first_time_step! in %.1f s", 1e-9 * (time_ns() - compile_start)))
        f
    end
end

r_step_for! = if VANILLA
    stage("the $(chunk)-step loop will run EAGERLY (AR_ARCH=cuda) — no XLA compile")
    step_for!
else
    stage("compiling the $(chunk)-step traced loop ($(Nx)×$(Ny)×$(Nz) child, " *
          "$(parent_Nx)×$(parent_Ny)×$(length(parent_pressure_levels)) parent)")
    compile_start = time_ns()
    f = @compile compile_options = ar_compile_options(raise = raise_option) step_for!(
        model, Δt, chunk)
    stage(@sprintf("compiled a %d-step traced loop in %.1f s", chunk, 1e-9 * (time_ns() - compile_start)))
    f
end

worst_nonfinite = 0

# `AR_BOUNDARY_PROBE=<file.jld2>` (eager CUDA only): write the child's state WITH halos — prognostics,
# total density, diagnosed pressure, and every field of the reference state — before and after one
# `first_time_step!`, plus physical heights, then exit. The halos carry the open-boundary values, so
# the file shows the jump between the prescribed wall state and the first interior cells, and
# (after − before)/Δt is the step-1 tendency at the frame.
if haskey(ENV, "AR_BOUNDARY_PROBE")
    VANILLA || error("AR_BOUNDARY_PROBE requires AR_ARCH=cuda")
    probe_path = ENV["AR_BOUNDARY_PROBE"]
    probe_child = breeze_child(model)
    probe_fields() = merge(prognostic_fields(probe_child),
                           (; ρ = probe_child.dynamics.total_density, p = probe_child.dynamics.pressure))
    JLD2.jldopen(probe_path, "w") do file
        file["dt"] = Float64(Δt)
        file["halo"] = collect(Oceananigans.Grids.halo_size(host_grid))
        file["size"] = collect(size(host_grid))
        file["grid/lambda_center"] = Array(λnodes(host_grid, Center(), Center(), Center()))
        file["grid/phi_center"] = Array(φnodes(host_grid, Center(), Center(), Center()))
        write_physical_heights(file)
        for (name, f) in pairs(probe_fields())
            file["before/$name"] = Array(parent(f))
        end
        reference = probe_child.dynamics.reference_state
        for name in propertynames(reference)
            f = getproperty(reference, name)
            f isa Oceananigans.Fields.AbstractField && (file["reference/$name"] = Array(parent(f)))
        end
    end
    first_time_step!(model, Δt)
    JLD2.jldopen(probe_path, "a+") do file
        for (name, f) in pairs(probe_fields())
            file["after/$name"] = Array(parent(f))
        end
    end
    stage("AR_BOUNDARY_PROBE: wrote the before/after state with halos to $(probe_path)")
    exit(0)
end

snapshot!(model) = write_output &&
    write_snapshot(output_path, model, host_number(model.clock.iteration), host_number(model.clock.time))

# `AR_SPINUP_STEPS` steps at `AR_SPINUP_DT` (eager CUDA only), first step included, before the main
# loop. The interpolated initial condition is out of balance and its first steps launch a violent
# adjustment (ρw −38 after one 40 s step, job 2160); a short spin-up at a small step sheds it, so
# `AR_DT` then only has to be stable for the adjusted flow. The acoustic substep count stays sized
# for `AR_DT`, which only over-resolves the acoustics of the smaller spin-up step.
spinup_steps = parse(Int, get(ENV, "AR_SPINUP_STEPS", "0"))
Δt_spinup = parse(FT, get(ENV, "AR_SPINUP_DT", "10"))
spinup_steps > 0 && !VANILLA && error("AR_SPINUP_STEPS requires AR_ARCH=cuda")
Δt_first = spinup_steps > 0 ? Δt_spinup : Δt

if !isnothing(r_first_time_step!)
    step_start = time_ns()
    r_first_time_step!(model, Δt_first)
    VANILLA && accumulate_precipitation!(Δt_first)
    global worst_nonfinite = max(worst_nonfinite, report(model, 1e-9 * (time_ns() - step_start)))
    snapshot!(model)
end

if spinup_steps > 0
    step_start = time_ns()
    step_for!(model, Δt_spinup, spinup_steps)
    stage(@sprintf("spin-up: %d steps at Δt = %s done", spinup_steps, prettytime(Δt_spinup)))
    global worst_nonfinite = max(worst_nonfinite, report(model, 1e-9 * (time_ns() - step_start)))
    snapshot!(model)
end

# ### `AR_ADAPTIVE=1`: an advective-CFL wizard (eager CUDA only)
#
# What Oceananigans' `TimeStepWizard` does, written out because the stepped object here is the
# coupled model rather than a `Simulation`: before every step, Δt = min(AR_CFL · τ, 1.1 · Δt_prev),
# clamped to [AR_MIN_DT, AR_MAX_DT], where τ = `cell_advection_timescale(child)` — Breeze's
# direction-aware timescale (three-dimensional, with rain/snow fall speeds in the vertical term,
# unless every scheme is AIVA). The acoustic substep count follows Δt (`substeps = nothing` above).
# The run covers the same simulated time as the fixed-Δt run (AR_STEPS · AR_DT) and reports and
# snapshots every AR_CHUNK · AR_DT seconds; the last steps of each interval are evened out to land
# on its end. Every step's Δt goes to `timeseries_dt/*` in the output file and to a CSV beside it.
# Radiation is already on a TimeInterval on this path, so its cadence does not drift with Δt.
if adaptive_Δt
    wizard_cfl = parse(Float64, get(ENV, "AR_CFL", "0.7"))
    wizard_max_Δt = parse(Float64, get(ENV, "AR_MAX_DT", "Inf"))
    wizard_min_Δt = parse(Float64, get(ENV, "AR_MIN_DT", "1"))
    wizard_max_change = parse(Float64, get(ENV, "AR_MAX_CHANGE", "1.1"))
    stage(@sprintf("adaptive Δt: cfl %.2f, max change %.2f, Δt ∈ [%g, %g] s; substeps follow Δt",
                   wizard_cfl, wizard_max_change, wizard_min_Δt, wizard_max_Δt))

    child = breeze_child(model)
    advective_timescale() = Float64(Oceananigans.Advection.cell_advection_timescale(child))
    horizontal_timescale() = Float64(Oceananigans.Advection.cell_advection_timescale(child,
                                         Oceananigans.TurbulenceClosures.HorizontalFormulation()))
    substeps_for(Δt) = Breeze.CompressibleEquations.compute_acoustic_substeps(host_grid, FT(Δt),
                                                                           thermodynamic_constants,
                                                                           acoustic_cfl)
    function step_adaptively!(model, Δt_wizard)
        dt_log = (iteration = Int[], time = Float64[], dt = Float64[], advective_timescale = Float64[],
                  horizontal_timescale = Float64[], substeps = Int[])
        clock_time() = Float64(host_number(model.clock.time))
        t_run_end = clock_time() + steps * Float64(Δt)
        interval = chunk * Float64(Δt)

        while clock_time() < t_run_end - 0.05
            step_start = time_ns()
            t = clock_time()
            t_target = min(t_run_end, (floor(t / interval + 1e-6) + 1) * interval)
            n_before = length(dt_log.dt)
            while t < t_target - 0.05
                τ = advective_timescale()
                ## A non-finite timescale means the state already is: stop and keep the record.
                if !isfinite(τ)
                    stage(@sprintf("adaptive Δt: non-finite advective timescale at t = %.1f s after a %.2f s step",
                                   t, isempty(dt_log.dt) ? NaN : last(dt_log.dt)))
                    global worst_nonfinite = max(worst_nonfinite, 1)
                    break
                end
                Δt_wizard = clamp(min(wizard_cfl * τ, wizard_max_change * Δt_wizard), wizard_min_Δt, wizard_max_Δt)
                remaining = t_target - t
                Δt_step = remaining ≤ Δt_wizard ? remaining :
                          remaining < 2Δt_wizard ? remaining / 2 : Δt_wizard
                time_step!(model, FT(Δt_step))
                accumulate_precipitation!(FT(Δt_step))
                push!(dt_log.iteration, host_number(model.clock.iteration))
                push!(dt_log.time, clock_time())
                push!(dt_log.dt, Δt_step)
                push!(dt_log.advective_timescale, τ)
                push!(dt_log.horizontal_timescale, horizontal_timescale())
                push!(dt_log.substeps, substeps_for(Δt_step))
                t = clock_time()
            end
            global worst_nonfinite = max(worst_nonfinite, report(model, 1e-9 * (time_ns() - step_start)))
            recent = n_before+1:length(dt_log.dt)
            stage(@sprintf("adaptive Δt over the last %d steps: min %.2f s, mean %.2f s, max %.2f s; substeps %d–%d",
                           length(recent), minimum(dt_log.dt[recent]), sum(dt_log.dt[recent]) / length(recent),
                           maximum(dt_log.dt[recent]), minimum(dt_log.substeps[recent]),
                           maximum(dt_log.substeps[recent])))
            snapshot!(model)
            worst_nonfinite > 0 && break
        end
        return dt_log
    end

    dt_log = step_adaptively!(model, Float64(spinup_steps > 0 ? Δt_spinup : Δt))

    if write_output
        JLD2.jldopen(output_path, "a+") do file
            for (name, series) in pairs(dt_log)
                file["timeseries_dt/$name"] = series
            end
            file["meta/adaptive"] = (cfl = wizard_cfl, max_Δt = wizard_max_Δt, min_Δt = wizard_min_Δt,
                                     max_change = wizard_max_change)
        end
        csv_path = replace(output_path, r"\.jld2$" => "") * "_dt.csv"
        open(csv_path, "w") do io
            println(io, "iteration,time_s,dt_s,advective_timescale_s,horizontal_timescale_s,acoustic_substeps")
            for n in eachindex(dt_log.dt)
                println(io, join((dt_log.iteration[n], dt_log.time[n], dt_log.dt[n],
                                  dt_log.advective_timescale[n], dt_log.horizontal_timescale[n],
                                  dt_log.substeps[n]), ","))
            end
        end
        stage("wrote the Δt series ($(length(dt_log.dt)) steps) to $(csv_path)")
    end
    sorted = sort(dt_log.dt)
    stage(@sprintf("adaptive Δt over the run: %d steps, min %.2f s, median %.2f s, max %.2f s",
                   length(sorted), first(sorted), sorted[cld(length(sorted), 2)], last(sorted)))
end

for n in 1:(adaptive_Δt ? 0 : chunks)
    step_start = time_ns()
    r_step_for!(model, Δt, chunk)
    global worst_nonfinite = max(worst_nonfinite, report(model, 1e-9 * (time_ns() - step_start)))
    snapshot!(model)
    ## A NaN never heals: stop rather than step (and write) garbage for the rest of the run.
    worst_nonfinite > 0 && break
end

# One unambiguous verdict line, so the run answers "are there NaNs after stepping?" without anyone
# having to read every interval in the per-step reports above.
if worst_nonfinite == 0
    stage("FINITE: every prognostic stayed finite across all $(host_number(model.clock.iteration)) steps")
else
    stage("NON-FINITE: $(worst_nonfinite) bad values appeared while stepping — see the per-step reports")
end

if write_output
    nsnapshots = JLD2.jldopen(output_path, "r") do file
        length(keys(file["timeseries/t"]))
    end
    stage("wrote $(nsnapshots) snapshots to $(output_path) " *
          "($(round(filesize(output_path) / 2^20, digits=1)) MiB)")
end

# There are no output writers: a `ReactantSimulation` carries none, and this run's state is
# idealized anyway. To render something, run `downscale.jl` (which writes JLD2) and
# `analysis/render_run.jl`.
