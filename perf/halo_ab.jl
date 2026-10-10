# A/B of fused halo filling (`AR_FUSED_HALOS`) in the production forward configuration.
#
#   AR_PROF_OUT=perf/data/<tag> AR_FUSED_HALOS=0|1 julia --project=<env> perf/halo_ab.jl
#
# 1. steps AR_AB_STEPS (default 60) after the script's own AR_STEPS and writes every prognostic and
#    closure field to <out>_state.jls — compare two runs with `perf/halo_ab.jl compare a.jls b.jls`;
# 2. kernel launches per step from a CUPTI trace of AR_AB_TRACE_STEPS (default 10) steps;
# 3. back-to-back wall time over AR_AB_TIME_STEPS (default 200) steps, host allocations and GC.

if length(ARGS) == 3 && ARGS[1] == "compare"
    using Serialization
    a = deserialize(ARGS[2]); b = deserialize(ARGS[3])
    nbad = 0
    for k in sort(collect(keys(a)))
        k == "meta" && continue
        x, y = a[k], b[k]
        same = isequal(x, y)
        d = same ? 0.0 : maximum(abs.(Float64.(x) .- Float64.(y)))
        same || (nbad += 1)
        println(rpad(k, 40), same ? "bitwise identical" : "DIFFERS: max |Δ| = $d (max |x| = $(maximum(abs, x)))")
    end
    println(nbad == 0 ? "ALL IDENTICAL" : "$nbad fields differ")
    exit(0)
end

include(joinpath(@__DIR__, "..", "reactant_downscale.jl"))

using CUDA
using Serialization
using Printf
using Profile
using Oceananigans.BoundaryConditions: fill_halo_regions!

out = get(ENV, "AR_PROF_OUT", "perf/data/halo_ab")
mkpath(dirname(out))
nab    = parse(Int, get(ENV, "AR_AB_STEPS", "60"))
ntrace = parse(Int, get(ENV, "AR_AB_TRACE_STEPS", "10"))
ntime  = parse(Int, get(ENV, "AR_AB_TIME_STEPS", "200"))
fused = isdefined(Oceananigans.Fields, :FUSED_HALO_FILLING) && Oceananigans.Fields.FUSED_HALO_FILLING[]
@info "halo A/B: FUSED_HALO_FILLING = $fused"

# ## 1. deterministic state after nab steps
step_for!(model, Δt, nab)
CUDA.synchronize()
child = breeze_child(model)
let file = Dict{String, Any}()
    file["meta"] = Dict("fused" => fused, "iteration" => Int(Oceananigans.iteration(model)))
    for (name, f) in pairs(prognostic_fields(child))
        file[string(name)] = Array(parent(f))
    end
    for (name, f) in pairs(child.velocities)
        file["velocity_" * string(name)] = Array(parent(f))
    end
    file["temperature"] = Array(parent(child.temperature))
    serialize(out * "_state.jls", file)
end
@info "state after $(Int(Oceananigans.iteration(model))) iterations → $(out)_state.jls"

# ## 2. launches per step
prof = CUDA.@profile begin
    step_for!(model, Δt, ntrace)
    CUDA.synchronize()
end
dev = prof.device
names = String.(dev.name)
nk = count(n -> !startswith(n, "[copy") && !startswith(n, "[set"), names)
nhalo = count(n -> occursin("halo", n), names)
@info @sprintf("HALO_AB launches: %.1f kernels/step, %.1f halo-fill kernels/step (%d steps)", nk / ntrace, nhalo / ntrace, ntrace)
let counts = Dict{String, Int}()
    for n in names
        occursin("halo", n) || continue
        key = replace(n, r"_\d+$" => "")
        key = first(split(key, '('))
        counts[key] = get(counts, key, 0) + 1
    end
    for (k, v) in sort(collect(counts), by = last, rev = true)[1:min(12, end)]
        @info @sprintf("   %-60s %7.1f /step", k, v / ntrace)
    end
end
halo_gpu_ms = sum(dev.stop[i] - dev.start[i] for i in eachindex(names) if occursin("halo", names[i]); init = 0.0) * 1e3 / ntrace
all_gpu_ms  = sum(dev.stop .- dev.start) * 1e3 / ntrace
@info @sprintf("HALO_AB GPU time: halo fills %.2f ms/step of %.2f ms/step", halo_gpu_ms, all_gpu_ms)

# ## 3. back-to-back timing
step_for!(model, Δt, 20)
CUDA.synchronize()
GC.gc()
stats = @timed begin
    step_for!(model, Δt, ntime)
    CUDA.synchronize()
end
tb = stats.time / ntime
@info @sprintf("HALO_AB back-to-back %d steps: %.2f ms/step, %.0f× real time; host %.2f MiB/step, GC %.1f%% of wall",
               ntime, 1e3tb, Float64(Δt) / tb, stats.bytes / 2^20 / ntime, 100 * stats.gctime / stats.time)

# Host enqueue time of one step with the GPU idle
CUDA.synchronize()
t0 = time_ns(); step_for!(model, Δt, 1); t1 = time_ns(); CUDA.synchronize()
@info @sprintf("HALO_AB host enqueue of one step: %.2f ms", 1e-6 * (t1 - t0))

# ## 4. Microbenchmark: host cost of one tuple fill of the prognostic fields (as update_state! does)
let child = breeze_child(model)
    pf = prognostic_fields(child)
    bca = Oceananigans.Models.boundary_condition_args(child)
    fill_halo_regions!(pf, bca...); CUDA.synchronize()
    a = @allocated fill_halo_regions!(pf, bca...)
    CUDA.synchronize()
    n = 200
    t0 = time_ns()
    for _ in 1:n
        fill_halo_regions!(pf, bca...)
    end
    t1 = time_ns(); CUDA.synchronize(); t2 = time_ns()
    @info @sprintf("HALO_AB microbenchmark fill_halo_regions!(prognostic_fields): %d fields, enqueue %.1f µs/call, with sync %.1f µs/call, %d bytes/call",
                   length(pf), 1e-3 * (t1 - t0) / n, 1e-3 * (t2 - t0) / n, a)
    if get(ENV, "AR_AB_HOSTPROF", "1") == "1"
        Profile.clear()
        @profile for _ in 1:2000
            fill_halo_regions!(pf, bca...)
        end
        CUDA.synchronize()
        io = IOBuffer()
        Profile.print(IOContext(io, :displaysize => (200, 220)); format = :flat, sortedby = :count, mincount = 40, noisefloor = 2)
        println(String(take!(io)))
    end
end
