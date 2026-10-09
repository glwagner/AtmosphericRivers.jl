# Minimal reproducer for the `cannot raise op to stablehlo … llvm.alloca` failure that blocks
# `@compile` of `reactant_downscale.jl`.
#
# The full model costs ~11 min of construction plus ~45 min of pass pipeline per attempt. Everything
# needed to hit the bug is far smaller: ONE KernelAbstractions launch through Reactant, with
# `raise=true optimize=true` so `sroa-wrappers` and then `raise-affine-to-stablehlo` both run.
#
#   OMP_NUM_THREADS=1 julia --project minrepro_alloca.jl
#
# AR_MIN_CASE=plain|interpolated   which boundary condition the halo fill carries (default interpolated)
# AR_MIN_PASSES=<mlir pipeline>    override the raise pipeline, to test candidate fixes
# AR_MIN_SIZE=16,8,4               child grid size
#
# !!! warning "This reproduces a DIFFERENT raise failure than the full model's"
#     Measured, not assumed: every failing configuration here dies on
#     `cannot raise op to stablehlo … "scf.while"`, never on `llvm.alloca`. The full model dies on
#     `llvm.alloca` (147 of them) and reports no `scf.while` at all. So this file is a reproducer for
#     a SECOND raise blocker, not for the one that currently stops `reactant_downscale.jl`.
#     Check the failing OP, not just the failure, before drawing conclusions from it.
#
#     The alloca blocker needs no reproducer: the full model's post-pipeline module, kept at
#     `reactant_dumps/*/module_000_nxc9_post_all_pm.mlir` (see `TMPDIR` in
#     `slurm/reactant_compile.batch`), shows it directly.
#
# What this file DID establish, by bisection:
#   * default BCs + clock + 24 model fields  → RAISES CLEANLY
#   * `Interpolated` BC, no clock/fields     → RAISES CLEANLY
#   * `Interpolated` BC + clock + ONE field  → FAILS
#   so the trigger is the BC and the clock TOGETHER — i.e. the time-interpolation path — and it is
#   not a size threshold (one field fails exactly like 24).
#   * Float32 vs Float64 time axis makes no difference, so the mixed-precision
#     `Union{Float32,Float64}` stack slots visible in the IR are not what the raiser trips on.

using Oceananigans
using NumericalEarth
using Reactant
using CUDA                      # required for Reactant to raise KA kernels, on any backend
using Printf

using Oceananigans.Architectures: ReactantState
using Oceananigans.BoundaryConditions: fill_halo_regions!
using Oceananigans.TimeSteppers: Clock
using NumericalEarth.NestedModels: Interpolated

# AR_MIN_PATCH_SROA=1 flips Reactant's OWN `sroa-wrappers` invocations from `instcombine=false` to
# `instcombine=true`, in place, without `Pkg.develop` or a recompile: re-read `OptimizationPasses.jl`,
# string-replace the flag, parse it, and evaluate ONLY the `optimization_passes` method back into
# `Reactant.Compiler`. Everything else in that file (the `const … = Ref(…)` toggles) is left alone,
# since redefining those constants would error.
#
# This is the placement that matters. Prepending `sroa-wrappers{instcombine=true}` to the RAISE
# pipeline also removes the alloca errors, but fails afterwards with `unsupported GPU operation:
# gpu.block_id` — by then the module carries `gpu.*` ops that the pass cannot translate to LLVM.
# Reactant's own invocations sit earlier, in `opt_passes`, where the wrappers are still plain LLVM.
if get(ENV, "AR_MIN_PATCH_SROA", "0") == "1"
    let path = joinpath(pkgdir(Reactant), "src", "compiler", "OptimizationPasses.jl")
        src = read(path, String)
        patched = replace(src, "instcombine=false instsimplify=true" => "instcombine=true instsimplify=true")
        @assert patched != src "AR_MIN_PATCH_SROA: no `instcombine=false instsimplify=true` found in $path"

        found = false
        for ex in Meta.parseall(patched).args
            ex isa Expr || continue
            ex.head === :function || continue
            name = ex.args[1] isa Expr ? ex.args[1].args[1] : nothing
            if name === :optimization_passes || (name isa Expr && name.args[1] === :optimization_passes)
                Core.eval(Reactant.Compiler, ex)
                found = true
            end
        end
        @assert found "AR_MIN_PATCH_SROA: could not find `optimization_passes` to re-evaluate"
        @info "patched Reactant: sroa-wrappers now runs with instcombine=true"
    end
end

Reactant.set_default_backend(get(ENV, "AR_BACKEND", "cpu"))
Oceananigans.defaults.FloatType = Float32

sz = Tuple(parse.(Int, split(get(ENV, "AR_MIN_SIZE", "16,8,4"), ',')))
case = Symbol(get(ENV, "AR_MIN_CASE", "interpolated"))

arch = ReactantState()

## Child grid, and a parent that BRACKETS it horizontally (`validate_source_bracket` insists).
grid = LatitudeLongitudeGrid(arch; longitude = (-10, 10), latitude = (-5, 5), z = (0, 1000),
                             size = sz, halo = (3, 3, 3), topology = (Bounded, Bounded, Bounded))

boundary_conditions = if case === :plain
    NamedTuple()
else
    parent_grid = LatitudeLongitudeGrid(arch; longitude = (-12, 12), latitude = (-7, 7), z = (0, 1000),
                                        size = (12, 7, 4), halo = (3, 3, 3),
                                        topology = (Bounded, Bounded, Bounded))

    ## AR_MIN_TIMES: how many time levels the boundary source carries. With ONE level there is
    ## nothing to interpolate between, which isolates the time-interpolation path itself.
    ntimes = parse(Int, get(ENV, "AR_MIN_TIMES", "3"))
    ## AR_MIN_TIMETYPE: element type of the boundary source's time axis. The clock is Float32; a
    ## Float64 time axis makes the time-interpolation arithmetic mixed-precision, and Julia lowers the
    ## resulting `Union{Float32,Float64}` intermediate through STACK SLOTS — an f32 alloca, an f64
    ## alloca and an i8 type tag — which is what survives into the raise pass.
    TT = get(ENV, "AR_MIN_TIMETYPE", "f64") == "f32" ? Float32 : Float64
    times = collect(range(TT(0), TT(7200), length = max(ntimes, 1)))
    fts = FieldTimeSeries{Center, Center, Center}(parent_grid, times)
    bc = ValueBoundaryCondition(Interpolated(fts))
    (; west = bc, east = bc, south = bc, north = bc)
end

## `@allowscalar` for the same reason the real script needs it: regularizing an `Interpolated`
## boundary calls `validate_source_bracket`, which reduces over the grids' node vectors.
c = Reactant.@allowscalar CenterField(grid;
        boundary_conditions = FieldBoundaryConditions(grid, (Center(), Center(), Center());
                                                      boundary_conditions...))

# The real model calls `fill_halo_regions!(field, clock, model_fields)`: the `Interpolated` boundary
# interpolates its source in TIME, so `getbc` needs the clock, and Oceananigans threads the model's
# prognostic fields through as well. Those two trailing arguments are the 464- and 424-byte
# `dense<[…]>` blobs in the failing wrappers, so a reproduction has to pass them.
const NFIELDS = parse(Int, get(ENV, "AR_MIN_NFIELDS", "24"))

## AR_MIN_ARGS decouples "which BC" from "does the launch also carry clock + model fields", so the
## two can be bisected independently.
pass_extra_args = get(ENV, "AR_MIN_ARGS", case === :plain ? "0" : "1") == "1"

extra_args = if !pass_extra_args
    ()
else
    clock = Clock(time = Reactant.ConcreteRNumber(zero(Float32)),
                  last_Δt = Reactant.ConcreteRNumber(Float32(Inf)),
                  last_stage_Δt = Reactant.ConcreteRNumber(Float32(Inf)),
                  iteration = Reactant.ConcreteRNumber(0),
                  kernel_time_type = Float32)

    names = ntuple(i -> Symbol(:f, i), NFIELDS)
    model_fields = NamedTuple{names}(ntuple(_ -> CenterField(grid), NFIELDS))
    (clock, model_fields)
end

fill_halos!(c, args...) = (fill_halo_regions!(c, args...); nothing)

@info "reproducer" case NFIELDS summary(grid)

# `optimize = true` is what makes this a reproduction rather than a trace: it selects
# `optimization_passes === :all`, which runs `opt_passes` (containing TWO
# `sroa-wrappers{instcombine=false instsimplify=true attributor=true}` invocations) and only then the
# raise pipeline. `optimize = false` skips both and always "succeeds" by never trying to raise.
# Reactant's own default raise pipeline (`Compiler.jl`, the `elseif raise` branch), with the
# interpolated options pinned to their defaults. Needed verbatim so a candidate fix can be tested as
# "default pipeline PLUS one pass" rather than as a replacement.
const DEFAULT_RAISE_PASSES = "canonicalize,llvm-to-memref-access,canonicalize,convert-llvm-to-cf," *
    "canonicalize,enzyme-lift-cf-to-scf,canonicalize,func.func(canonicalize-loops),canonicalize-scf-for," *
    "canonicalize,libdevice-funcs-raise,canonicalize,affine-cfg,canonicalize," *
    "func.func(canonicalize-loops),canonicalize,llvm-to-affine-access,canonicalize,delinearize-indexing," *
    "canonicalize,simplify-affine-exprs,affine-cfg,canonicalize," *
    "func.func(affine-loop-invariant-code-motion),canonicalize,sort-memory,func.func(kernelcast)," *
    "raise-affine-to-stablehlo{strip_llvm_debuginfo=false prefer_while_raising=false dump_failed_lockstep=false}," *
    "canonicalize,arith-raise{stablehlo=true}"

# AR_MIN_FIX selects a candidate fix to prepend to the raise pipeline:
#   sroa_instcombine — one more `sroa-wrappers`, this time WITH InstCombine, which is the pass that
#                      canonicalizes a type-punned whole-aggregate store/load into promotable form.
#                      Reactant's own two invocations are pinned `instcombine=false`.
#   mem2reg          — MLIR's own promotion, for comparison.
#   sroa             — MLIR's own SROA, for comparison.
const FIX_PASSES = Dict(
    "sroa_instcombine" => "sroa-wrappers{instcombine=true instsimplify=true attributor=true},canonicalize,",
    "mem2reg" => "func.func(mem2reg),canonicalize,",
    "sroa" => "func.func(sroa),canonicalize,",
)

raise_option = if haskey(ENV, "AR_MIN_PASSES")
    ENV["AR_MIN_PASSES"]
elseif haskey(ENV, "AR_MIN_FIX")
    fix = ENV["AR_MIN_FIX"]
    haskey(FIX_PASSES, fix) || error("unknown AR_MIN_FIX=$fix; have $(collect(keys(FIX_PASSES)))")
    @info "candidate fix" fix
    FIX_PASSES[fix] * DEFAULT_RAISE_PASSES
else
    true
end

start = time_ns()
try
    ## AR_MIN_OPTIMIZE=0 dumps the PRE-raise module instead of running the pipeline, so the alloca
    ## and whatever call consumes it can be read directly in a small module.
    mod = if get(ENV, "AR_MIN_OPTIMIZE", "1") == "1"
        @code_hlo optimize = true raise = raise_option fill_halos!(c, extra_args...)
    else
        @code_hlo optimize = false raise = true fill_halos!(c, extra_args...)
    end
    text = repr(mod)
    elapsed = 1e-9 * (time_ns() - start)
    write("minrepro_raised.mlir", text)

    lines = split(text, '\n')
    @info @sprintf("RAISED OK in %.1f s — %d lines, %d llvm.alloca, %d kernel_call left; wrote minrepro_raised.mlir",
                   elapsed, length(lines),
                   count(l -> occursin("llvm.alloca", l), lines),
                   count(l -> occursin("enzymexla.kernel_call", l), lines))
catch err
    elapsed = 1e-9 * (time_ns() - start)
    msg = sprint(showerror, err)
    ## `s` flag: the offending op is printed on the line AFTER "cannot raise op to stablehlo".
    n_raise = count(!isnothing, eachmatch(r"cannot raise op to stablehlo"s, msg))
    n_alloca = count(!isnothing, eachmatch(r"llvm\.alloca"s, msg))
    ops = unique([m.match for m in eachmatch(r"\"llvm\.[a-z_.]+\""s, msg)])
    @info @sprintf("FAILED in %.1f s — %d 'cannot raise' errors, %d mention llvm.alloca; unraisable ops: %s",
                   elapsed, n_raise, n_alloca, join(ops, ", "))
    println(first(msg, 1200))
end
