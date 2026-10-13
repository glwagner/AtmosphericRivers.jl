# Short per-kernel audit of the eager-CUDA forward step (agent OPT-KERNEL).
#
# Builds the production model through `reactant_downscale.jl` (short AR_STEPS), optionally under
# perf/kernel_tuning.jl's launch bounds, then, between hourly events:
#   1. back-to-back wall time over AR_AUDIT_WALL steps                         → log
#   2. CUPTI trace over AR_AUDIT_PROF steps, aggregated per kernel             → <out>_kernels.tsv
#      (ms/step, launches/step, registers, local memory = spills, block)
#   3. the prognostic state after a fixed iteration count                      → <out>_state.jld2
#      (compare two runs with perf/kernel_compare_state.jl)
#   4. AR_AUDIT_DUMP=1: PTX/SASS of every kernel one step compiles             → <out>_code/
#      (needs a GPUCompiler disk cache that is OFF, or nothing recompiles)
#
#   AR_AUDIT_OUT=perf/data/<tag> julia --project=<env> perf/kernel_audit.jl   (production AR_* env)

using CUDA
include(joinpath(@__DIR__, "kernel_tuning.jl"))
include(joinpath(@__DIR__, "..", "reactant_downscale.jl"))

using Printf
const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")

out    = get(ENV, "AR_AUDIT_OUT", "perf/data/audit")
nwall  = parse(Int, get(ENV, "AR_AUDIT_WALL", "100"))
nprof  = parse(Int, get(ENV, "AR_AUDIT_PROF", "30"))
nstate = parse(Int, get(ENV, "AR_AUDIT_STATE_ITERATION", "150"))
mkpath(dirname(out))
current_iteration() = Int(Oceananigans.iteration(model))
child = breeze_child(model)

function save_state(path)
    CUDA.synchronize()
    JLD2.jldopen(path, "w") do file
        file["iteration"] = current_iteration()
        for (name, f) in pairs(prognostic_fields(child))
            file["state/$name"] = Array(interior(f))
        end
    end
end

# `AR_AUDIT_EARLY_STATE=n`: also save the state at iteration n (before differences between builds have had time
# to grow chaotically), for roundoff-level comparisons.
nearly = parse(Int, get(ENV, "AR_AUDIT_EARLY_STATE", "0"))
if nearly > 0
    nearly > current_iteration() && step_for!(model, Δt, nearly - current_iteration())
    save_state(out * "_state_early.jld2")
    @info "AUDIT early state at iteration $(current_iteration()) → $(out)_state_early.jld2"
end

# Warm every code path once (the script ran AR_STEPS already).
step_for!(model, Δt, 3)
CUDA.synchronize()

# 1. Back-to-back wall time.
Nc = prod(size(grid))

# 2. CUPTI per-kernel aggregate.
function audit_kernels(tag)
    prof = CUDA.@profile begin
        step_for!(model, Δt, nprof)
        CUDA.synchronize()
    end
    dev = prof.device
    agg = Dict{String, Vector{Any}}()   # name → [total s, launches, regs, local mem, block]
    for i in eachindex(dev.id)
        name = string(dev.name[i])
        r = dev.registers[i]
        r === missing && continue                     # memcpy / memset
        a = get!(() -> Any[0.0, 0, r, dev.local_mem[i], dev.block[i]], agg, name)
        a[1] += dev.stop[i] - dev.start[i]; a[2] += 1
    end
    rows = sort(collect(agg); by = p -> -p[2][1])
    gpu_total = sum(p -> p[2][1], rows)
    ## Host side: the window's span on the host, minus the time spent blocked in synchronizing API calls
    ## (≈ the time the host needs to enqueue the work when it is not waiting on the GPU).
    host = prof.host
    span = maximum(host.stop) - minimum(host.start)
    blocked = sum((host.stop[i] - host.start[i]) for i in eachindex(host.id)
                  if occursin(r"ynchronize|MemcpyDtoH|cuMemcpy[^A]|StreamQuery|EventQuery", string(host.name[i])); init = 0.0)
    nlaunch = count(i -> occursin("Launch", string(host.name[i])), eachindex(host.id))
    @info @sprintf("AUDIT host: window span %.2f ms/step, blocked in sync %.2f ms/step ⇒ host busy %.2f ms/step; %.0f launches/step",
                   1e3span / nprof, 1e3blocked / nprof, 1e3(span - blocked) / nprof, nlaunch / nprof)
    open(tag * "_kernels.tsv", "w") do io
        println(io, "kernel\tms_per_step\tlaunches_per_step\tus_per_launch\tregisters\tlocal_mem\tblock")
        for (name, a) in rows
            @printf(io, "%s\t%.4f\t%.2f\t%.1f\t%d\t%s\t%s\n", replace(name, '\t' => ' '), 1e3a[1] / nprof, a[2] / nprof,
                    1e6a[1] / a[2], a[3], string(a[4]),
                    nameof(typeof(a[5])) === :CuDim3 ? "$(a[5].x)x$(a[5].y)x$(a[5].z)" : string(a[5]))
        end
    end
    @info @sprintf("AUDIT CUPTI %d steps: kernel GPU time %.2f ms/step over %d distinct kernels → %s_kernels.tsv",
                   nprof, 1e3gpu_total / nprof, length(rows), tag)
    for (name, a) in first(rows, 25)
        @info @sprintf("  %8.3f ms/step  %6.1f launches  %4d regs  local %s  %s", 1e3a[1] / nprof, a[2] / nprof, a[3],
                       string(a[4]), first(name, 110))
    end
    return 1e3gpu_total / nprof
end

steps_per_hour = round(Int, 3600 / Float64(Δt))

"Step past the next hour boundary (radiation + parent update) if a window of `n` steps would contain it."
function avoid_hour_boundary!(n)
    it = current_iteration()
    next = cld(it + 1, steps_per_hour) * steps_per_hour
    if it + n + 1 >= next
        step_for!(model, Δt, next - it + 2)
        CUDA.synchronize()
    end
end

function audit_wall(label)
    avoid_hour_boundary!(nwall + nprof)
    stats = @timed begin
        step_for!(model, Δt, nwall)
        CUDA.synchronize()
    end
    tb = stats.time / nwall
    @info @sprintf("AUDIT [%s] back-to-back %d steps: %.2f ms/step ⇒ %.1f M cell-steps/s, %.0f× real time; host %.2f MiB/step, GC %.1f%%",
                   label, nwall, 1e3tb, Nc / tb / 1e6, Float64(Δt) / tb, stats.bytes / 2^20 / nwall, 100 * stats.gctime / stats.time)
    return 1e3tb
end

audit_wall("base")
audit_kernels(out)

# 3. State at a fixed iteration, for correctness comparisons between builds.
n = nstate - current_iteration()
n > 0 && step_for!(model, Δt, n)
CUDA.synchronize()
JLD2.jldopen(out * "_state.jld2", "w") do file
    file["iteration"] = current_iteration()
    for (name, f) in pairs(prognostic_fields(child))
        file["state/$name"] = Array(interior(f))
    end
end
bad = sum(f -> count(!isfinite, interior(f)), values(prognostic_fields(child)))
@info "AUDIT state at iteration $(current_iteration()) → $(out)_state.jld2; non-finite values: $bad"

# 4. Device code of one step, compiled afresh.
if get(ENV, "AR_AUDIT_DUMP", "0") == "1"
    for cache in values(CUDACoreModule._compiler_caches)
        empty!(cache)
    end
    isdefined(CUDACoreModule, :_kernel_instances) && empty!(CUDACoreModule._kernel_instances)
    dir = out * "_code"
    mkpath(dir)
    CUDA.@device_code dir = dir begin
        step_for!(model, Δt, 1)
        CUDA.synchronize()
    end
    @info "AUDIT device code of one step → $dir ($(length(readdir(dir))) files)"
end

# 5. In-process sweep of launch-bound rules: AR_AUDIT_SWEEP="blocks_per_sm rules|maxregs rules;…", e.g.
#    "tendency=2|;tendency=3|;|x_momentum=128". Each entry recompiles every kernel under its rules.
sweep = get(ENV, "AR_AUDIT_SWEEP", "")
if !isempty(sweep)
    for (n, entry) in enumerate(split(sweep, ';'))
        bps, mr = String.(split(entry * "|", '|'))[1:2]
        set_kernel_rules!(bps, mr)
        step_for!(model, Δt, 3)                  # recompile + warm
        CUDA.synchronize()
        @info "AUDIT sweep $n: blocks_per_sm \"$bps\", maxregs \"$mr\""
        audit_wall("sweep $n: $entry")
        audit_kernels(out * "_sweep$n")
    end
    bad = sum(f -> count(!isfinite, interior(f)), values(prognostic_fields(child)))
    @info "AUDIT sweep done at iteration $(current_iteration()); non-finite values: $bad"
end
