# Short benchmark + state dump for kernel-level optimizations of the forward step (agent OPT-COLUMN).
#
# Builds the production model by `include`ing reactant_downscale.jl (run it with AR_STEPS = AR_CHUNK = 10,
# AR_OUTPUT = 0), then, away from the hourly events:
#
#   1. back-to-back wall time over AR_BENCH_STEPS steps, AR_BENCH_REPEATS times;
#   2. a CUPTI trace of AR_BENCH_PROF steps, summarized per kernel name (time per step, launches per step);
#   3. the prognostic and closure fields at a fixed iteration (AR_BENCH_DUMP_AT), written to AR_BENCH_OUT.jld2,
#      for a bitwise / roundoff comparison between two environments (perf/opt_column_compare.jl).
#
#   AR_BENCH_OUT=perf/data/optcol_<tag> julia --project=<env> perf/opt_column_bench.jl

include(joinpath(@__DIR__, "..", "reactant_downscale.jl"))

using CUDA
using JLD2
using Printf

out      = get(ENV, "AR_BENCH_OUT", "perf/data/optcol")
nsteps   = parse(Int, get(ENV, "AR_BENCH_STEPS", "30"))
nrepeat  = parse(Int, get(ENV, "AR_BENCH_REPEATS", "3"))
nprof    = parse(Int, get(ENV, "AR_BENCH_PROF", "6"))
dump_at  = parse(Int, get(ENV, "AR_BENCH_DUMP_AT", "700"))
mkpath(dirname(out))

child = breeze_child(model)
current_iteration() = Int(Oceananigans.iteration(model))

# Configurations: ENV toggles read at run time by the patched Breeze (ignored by an unpatched one).
configs = Dict(
    "on"         => ("BREEZE_BATCHED_IMPLICIT" => "1", "BREEZE_FUSED_TKE" => "1", "BREEZE_FUSED_LIMITERS" => "1"),
    "off"        => ("BREEZE_BATCHED_IMPLICIT" => "0", "BREEZE_FUSED_TKE" => "0", "BREEZE_FUSED_LIMITERS" => "0"),
    "nobatch"    => ("BREEZE_BATCHED_IMPLICIT" => "0", "BREEZE_FUSED_TKE" => "1", "BREEZE_FUSED_LIMITERS" => "1"),
    "notke"      => ("BREEZE_BATCHED_IMPLICIT" => "1", "BREEZE_FUSED_TKE" => "0", "BREEZE_FUSED_LIMITERS" => "1"),
    "nolim"      => ("BREEZE_BATCHED_IMPLICIT" => "1", "BREEZE_FUSED_TKE" => "1", "BREEZE_FUSED_LIMITERS" => "0"))
config_names = split(get(ENV, "AR_BENCH_CONFIGS", "on"), r"[,:]")

function kernel_summary(nprof, tag)
    prof = CUDA.@profile begin
        step_for!(model, Δt, nprof)
        CUDA.synchronize()
    end
    dev = prof.device
    totals = Dict{String, Float64}()
    counts = Dict{String, Int}()
    for i in eachindex(dev.id)
        name = string(dev.name[i])
        m = match(r"(gpu_[A-Za-z0-9_!]+)", name)
        key = m === nothing ? first(name, 60) : m.captures[1]
        totals[key] = get(totals, key, 0.0) + (dev.stop[i] - dev.start[i])
        counts[key] = get(counts, key, 0) + 1
    end
    gpu_total = sum(values(totals))
    @info @sprintf("BENCH [%s] CUPTI %d steps: GPU busy %.2f ms/step, %d launches/step", tag, nprof,
                   1e3 * gpu_total / nprof, round(Int, sum(values(counts)) / nprof))
    order = sort(collect(keys(totals)); by = k -> -totals[k])
    open(out * "_" * tag * "_kernels.tsv", "w") do io
        println(io, "kernel\tms_per_step\tlaunches_per_step")
        for k in order
            println(io, k, '\t', @sprintf("%.4f", 1e3 * totals[k] / nprof), '\t', counts[k] / nprof)
        end
    end
    for k in first(order, 30)
        @info @sprintf("BENCH [%s] %8.3f ms/step  %6.1f launches/step  %s", tag, 1e3 * totals[k] / nprof, counts[k] / nprof, k)
    end
end

# Warm-up: compile everything the timed window will run.
step_for!(model, Δt, 3)
CUDA.synchronize()

for name in config_names
    for (k, v) in configs[name]
        ENV[k] = v
    end
    step_for!(model, Δt, 2)   # compile this configuration's kernels
    CUDA.synchronize()
    times = Float64[]
    for r in 1:nrepeat
        t0 = time_ns()
        step_for!(model, Δt, nsteps)
        CUDA.synchronize()
        push!(times, 1e-6 * (time_ns() - t0) / nsteps)
    end
    @info @sprintf("BENCH [%s] back-to-back %d×%d steps: %s ms/step (min %.2f) at iteration %d", name, nrepeat, nsteps,
                   join([@sprintf("%.2f", t) for t in times], ", "), minimum(times), current_iteration())
    kernel_summary(nprof, name)
end
for (k, v) in configs["on"]
    ENV[k] = v
end

# Fixed-iteration state for correctness comparisons.
n = dump_at - current_iteration()
n > 0 && step_for!(model, Δt, n)
CUDA.synchronize()
jldopen(out * "_state.jld2", "w") do file
    file["iteration"] = current_iteration()
    for (name, f) in pairs(prognostic_fields(child))
        file["prognostic/$name"] = Array(interior(f))
    end
    cf = child.closure_fields
    if cf !== nothing
        for name in propertynames(cf)
            x = getproperty(cf, name)
            x isa Oceananigans.Fields.AbstractField || continue
            file["closure/$name"] = Array(interior(x))
        end
    end
end
@info "BENCH state at iteration $(current_iteration()) → $(out)_state.jld2"
