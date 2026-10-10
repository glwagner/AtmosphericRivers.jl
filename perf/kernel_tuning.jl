# Per-kernel launch bounds for the eager CUDA path (profiling experiments; agent OPT-KERNEL).
#
# KernelAbstractions' CUDA back end compiles every kernel with `@cuda launch=false always_inline maxthreads`,
# and Oceananigans launches 3-D kernels with a static (16, 16) workgroup, so ptxas only knows "≤ 256 threads
# per block" and is free to use up to 255 registers per thread. The WENO tendency kernels take 159–229 of
# them and run at 12% occupancy (perf/PROFILE_REPORT.md §2–3). This file re-defines the back end's launch
# method so selected kernels are compiled with `blocks_per_sm` (→ PTX `.minnctapersm`, the launch-bounds
# register cap: 65536 / (256 · n) registers) or an explicit `maxregs`.
#
#   AR_KERNEL_BLOCKS_PER_SM="regex=n,regex=n,…"   e.g. "tendency=2" caps every *tendency* kernel at 128 regs
#   AR_KERNEL_MAXREGS="regex=n,…"                 e.g. "compute_x_momentum_tendency=96"
#
# Rules match `string(nameof(kernel.f))` (e.g. `gpu_compute_scalar_tendency!`); the first matching rule wins.
# Include it BEFORE the first kernel compiles (before the production script).

using CUDA
using Oceananigans
const KA = Base.loaded_modules[Base.PkgId(Base.UUID("63c18a36-062a-441e-b654-da1e3ab1ce7c"), "KernelAbstractions")]

const CUDACoreModule = Base.loaded_modules[Base.PkgId(Base.UUID("bd0ed864-bdfe-4181-a5ed-ce625a5fdea2"), "CUDACore")]
const CUDAKernels = CUDACoreModule.CUDAKernels

parse_kernel_rules(s) = [Regex(first(split(r, '='))) => parse(Int, last(split(r, '=')))
                         for r in split(s, ',') if !isempty(strip(r))]

# `AR_KERNEL_TUNING=1` without explicit rules applies these, measured on A100-SXM4-80GB (agent OPT-KERNEL,
# jobs 2553/2561: 44.2 → 41.4 ms/step, state bitwise identical). Register caps never change results.
const DEFAULT_KERNEL_BLOCKS_PER_SM = "x_momentum_tendency=2,default_microphysical_tendencies=4," *
    "potential_temperature_tendency=4,z_momentum_tendency=3,y_momentum_tendency=3,compute_scalar_tendency=3,interface_state=3"

# With Oceananigans #6211 (static-size device arrays for Field data) registers already drop (ρu 159 → 128, scalars
# → 64), so ρu needs no cap and the acoustic `build_vertical_rhs` gains one instead (H100 job 2576: GPU 26.1 → 21.8
# ms/step together with #6211, bitwise identical). Chosen automatically when the CUDA extension defines the array.
const DEFAULT_KERNEL_BLOCKS_PER_SM_6211 = "default_microphysical_tendencies=4,potential_temperature_tendency=4," *
    "build_vertical_rhs=4,y_momentum_tendency=3,z_momentum_tendency=4,add_sedimentation_tendency=4"

function default_kernel_rules()
    ext = Base.get_extension(Oceananigans, :OceananigansCUDAExt)
    return !isnothing(ext) && isdefined(ext, :StaticSizeDeviceArray) ? DEFAULT_KERNEL_BLOCKS_PER_SM_6211 :
                                                                       DEFAULT_KERNEL_BLOCKS_PER_SM
end

const KERNEL_BLOCKS_PER_SM = parse_kernel_rules(get(ENV, "AR_KERNEL_BLOCKS_PER_SM",
                                                    get(ENV, "AR_KERNEL_TUNING", "0") == "1" ? default_kernel_rules() : ""))
const KERNEL_MAXREGS       = parse_kernel_rules(get(ENV, "AR_KERNEL_MAXREGS", ""))
const KERNEL_TUNED         = Dict{String, Any}()

"Replace the rules in place and drop every compiled kernel, so the next launches recompile under them."
function set_kernel_rules!(blocks_per_sm::AbstractString, maxregs::AbstractString)
    empty!(KERNEL_BLOCKS_PER_SM); append!(KERNEL_BLOCKS_PER_SM, parse_kernel_rules(blocks_per_sm))
    empty!(KERNEL_MAXREGS);       append!(KERNEL_MAXREGS, parse_kernel_rules(maxregs))
    empty!(KERNEL_TUNED)
    foreach(empty!, values(CUDACoreModule._compiler_caches))
    isdefined(CUDACoreModule, :_kernel_instances) && empty!(CUDACoreModule._kernel_instances)
    return nothing
end

function kernel_rule(rules, name)
    for (re, n) in rules
        occursin(re, name) && return n
    end
    return nothing
end

function tuned_launch_kwargs(f)
    name = string(nameof(f))
    return get!(KERNEL_TUNED, name) do
        bps = kernel_rule(KERNEL_BLOCKS_PER_SM, name)
        mr  = kernel_rule(KERNEL_MAXREGS, name)
        kw = (; (isnothing(bps) ? () : (:blocks_per_sm => bps,))..., (isnothing(mr) ? () : (:maxregs => mr,))...)
        isempty(kw) || @info "kernel tuning: $name ← $kw"
        kw
    end
end

if !isempty(KERNEL_BLOCKS_PER_SM) || !isempty(KERNEL_MAXREGS) || get(ENV, "AR_AUDIT_SWEEP", "") != ""
    @eval CUDAKernels function (obj::KA.Kernel{CUDABackend})(args...; ndrange=nothing, workgroupsize=nothing)
        backend = KA.backend(obj)
        ndrange, workgroupsize, iterspace, dynamic = KA.launch_config(obj, ndrange, workgroupsize)
        ctx = KA.mkcontext(obj, ndrange, iterspace)
        maxthreads = KA.workgroupsize(obj) <: KA.StaticSize ? prod(KA.get(KA.workgroupsize(obj))) : nothing
        tuning = Main.tuned_launch_kwargs(obj.f)
        kernel = CUDACore.@cuda(launch=false, always_inline=backend.always_inline, maxthreads=maxthreads,
                                blocks_per_sm=get(tuning, :blocks_per_sm, nothing),
                                maxregs=get(tuning, :maxregs, nothing), obj.f(ctx, args...))
        if KA.workgroupsize(obj) <: KA.DynamicSize && workgroupsize === nothing
            config = CUDACore.launch_configuration(kernel.fun; max_threads=prod(ndrange))
            if backend.prefer_blocks
                threads = min(prod(ndrange), config.threads)
                cu_blocks = max(cld(prod(ndrange), threads), config.blocks)
                threads = cld(prod(ndrange), cu_blocks)
            else
                threads = config.threads
            end
            workgroupsize = threads_to_workgroupsize(threads, ndrange)
            iterspace, dynamic = KA.partition(obj, ndrange, workgroupsize)
            ctx = KA.mkcontext(obj, ndrange, iterspace)
        end
        blocks = length(KA.blocks(iterspace))
        threads = length(KA.workitems(iterspace))
        blocks == 0 && return nothing
        kernel(ctx, args...; threads, blocks)
        return nothing
    end
    @info "kernel tuning active: blocks_per_sm $(KERNEL_BLOCKS_PER_SM), maxregs $(KERNEL_MAXREGS)"
end

# `AR_KERNEL_WORKGROUP="32x8"`: replace Oceananigans' (16, 16) workgroup for 3-D launches. A warp then spans
# 32 consecutive x-cells (one 128-byte line of Float32) instead of 16 × 2 rows.
let wg = get(ENV, "AR_KERNEL_WORKGROUP", "")
    if !isempty(wg)
        wx, wy = parse.(Int, split(wg, 'x'))
        @eval Oceananigans.Utils function heuristic_workgroup(Wx::Int, Wy::Int, Wz=nothing, Wt=nothing)
            Wx == 1 && Wy == 1 && return (1, 1)
            Wx == 1 && return (1, min(256, Wy))
            Wy == 1 && return (min(256, Wx), 1)
            return ($wx, $wy)
        end
        @info "kernel tuning: 3-D workgroup ($wx, $wy)"
    end
end
