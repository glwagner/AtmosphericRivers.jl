# Profile the eager-CUDA forward step of reactant_downscale.jl.
#
# Builds the model by `include`ing the production script with a short run (AR_STEPS = AR_CHUNK), then,
# with `model`, `Δt` and `step_for!` left in `Main`, times and profiles more steps:
#
#   1. synchronized wall time per step over AR_PROF_STEPS steps (radiation interval included if it fits)
#   2. host allocations and GC time per step
#   3. CUDA.@profile (integrated) kernel/API summary over AR_PROF_TRACE_STEPS steps
#   4. under nsys (`AR_PROF_NSYS=1`), a cudaProfilerStart/Stop range around the same steps
#
#   AR_ARCH=cuda AR_STEPS=10 AR_CHUNK=10 AR_OUTPUT=0 julia --project perf/profile_forward.jl

include(joinpath(@__DIR__, "..", "reactant_downscale.jl"))

using CUDA
using Printf
using Profile

nprof  = parse(Int, get(ENV, "AR_PROF_STEPS", "90"))
ntrace = parse(Int, get(ENV, "AR_PROF_TRACE_STEPS", "10"))

CUDA.synchronize()

# Time a single step at a time to expose outliers (radiation steps, parent-window shifts).
per_step = Float64[]
for n in 1:nprof
    t0 = time_ns()
    step_for!(model, Δt, 1)
    CUDA.synchronize()
    push!(per_step, 1e-9 * (time_ns() - t0))
end
sorted = sort(per_step)
@info @sprintf("PERF per-step wall (synchronized each step, %d steps): median %.2f ms, min %.2f ms, max %.2f ms, mean %.2f ms",
               nprof, 1e3 * sorted[(nprof + 1) ÷ 2], 1e3 * sorted[1], 1e3 * sorted[end], 1e3 * sum(per_step) / nprof)
slow = findall(>(2 * sorted[(nprof + 1) ÷ 2]), per_step)
@info "PERF slow steps (> 2× median): " * join([@sprintf("#%d %.1f ms", i, 1e3 * per_step[i]) for i in slow], ", ")

# Unsynchronized back-to-back steps: the production loop's cost.
t0 = time_ns()
step_for!(model, Δt, nprof)
CUDA.synchronize()
tb = 1e-9 * (time_ns() - t0) / nprof
Nc = prod(size(grid))
@info @sprintf("PERF back-to-back: %.2f ms/step over %d steps ⇒ %.1f M cell-steps/s (%d cells), %.1f× real time at Δt = %s",
               1e3 * tb, nprof, Nc / tb / 1e6, Nc, Float64(Δt) / tb, Δt)

# Host-side allocation and GC per step.
stats = @timed begin
    step_for!(model, Δt, nprof)
    CUDA.synchronize()
end
@info @sprintf("PERF host: %.2f MiB allocated per step, GC %.1f%% of wall, %.2f ms/step",
               stats.bytes / 2^20 / nprof, 100 * stats.gctime / stats.time, 1e3 * stats.time / nprof)

# Host-only cost: how long does Julia take to *enqueue* a step when the GPU is idle?
CUDA.synchronize()
t0 = time_ns()
step_for!(model, Δt, 1)
t_enqueue = 1e-9 * (time_ns() - t0)
CUDA.synchronize()
@info @sprintf("PERF enqueue-only time of one step (no sync): %.2f ms", 1e3 * t_enqueue)

if get(ENV, "AR_PROF_HOST", "0") == "1"


    ## Where does the host spend the enqueue time? Sampled CPU profile of back-to-back steps.
    step_for!(model, Δt, 2); CUDA.synchronize()
    Profile.clear()
    Profile.init(n = 10^7, delay = 0.0005)
    @profile begin
        step_for!(model, Δt, ntrace)
        CUDA.synchronize()
    end
    println("==== PERF host CPU profile (flat, by inclusive count) ====")
    Profile.print(IOContext(stdout, :displaysize => (10_000, 400)); format = :flat, sortedby = :count,
                  mincount = 20, C = false)
    println("==== PERF host CPU profile (tree) ====")
    Profile.print(IOContext(stdout, :displaysize => (10_000, 400)); format = :tree, maxdepth = 40,
                  mincount = 40, C = false, noisefloor = 2)

    ## Who allocates? Group sampled allocations by type and by the innermost frame in package code.
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate = 0.05 step_for!(model, Δt, 2)
    CUDA.synchronize()
    allocs = Profile.Allocs.fetch().allocs
    bysite = Dict{String, Tuple{Int, Int}}()
    for a in allocs
        frame = "?"
        for sf in a.stacktrace
            f = string(sf.file)
            if occursin(r"Oceananigans|Breeze|NumericalEarth|KernelAbstractions|CUDA|GPUArrays|reactant_downscale", f) &&
               !occursin("Profile", f)
                frame = string(sf.func, " @ ", basename(f), ":", sf.line)
                break
            end
        end
        key = string(a.type, "  ←  ", frame)
        n, b = get(bysite, key, (0, 0))
        bysite[key] = (n + 1, b + a.size)
    end
    total = sum(last, values(bysite); init = 0)
    println(@sprintf("==== PERF sampled allocations (rate 0.05, 2 steps): %d samples, %.2f MiB sampled ⇒ ≈ %.2f MiB/step ====",
                     length(allocs), total / 2^20, total / 2^20 / 0.05 / 2))
    for (k, (n, b)) in first(sort(collect(bysite); by = x -> -x[2][2]), 40)
        println(@sprintf("%9.1f KiB %6d  %s", b / 2^10, n, k))
    end
end

if get(ENV, "AR_PROF_SPIKE", get(ENV, "AR_PROF_HOST", "0")) == "1"
    ## The slow steps: the radiation step (iteration % AR_RADIATION_EVERY == 0) and the step that
    ## crosses a parent time level. Advance to just before the next radiation step, then profile 2.
    every = parse(Int, get(ENV, "AR_RADIATION_EVERY", "1"))
    it = Int(Oceananigans.iteration(model))
    nadvance = mod(-it - 1, every)
    nadvance > 0 && step_for!(model, Δt, nadvance)
    CUDA.synchronize()
    for label in ("step before the radiation step", "radiation step", "step after (parent window shift?)")
        local t0 = time_ns()
        local p = CUDA.@profile begin
            step_for!(model, Δt, 1)
            CUDA.synchronize()
        end
        println(@sprintf("==== PERF spike profile: %s, iteration %d → %d, %.1f ms ====", label,
                         Int(Oceananigans.iteration(model)) - 1, Int(Oceananigans.iteration(model)),
                         1e-6 * (time_ns() - t0)))
        show(IOContext(stdout, :limit => false, :displaysize => (60, 300)), p)
        println()
    end
end

if get(ENV, "AR_PROF_NSYS", "0") == "1"
    CUDA.@profile external = true begin
        step_for!(model, Δt, ntrace)
        CUDA.synchronize()
    end
else
    prof = CUDA.@profile begin
        step_for!(model, Δt, ntrace)
        CUDA.synchronize()
    end
    show(IOContext(stdout, :limit => false, :displaysize => (10_000, 400)), prof)
    println()
end

@info "PERF done"

# A profile of a NaN-filled model is not a profile of the model: say whether the state is still finite.
let
    bad = sum(f -> count(!isfinite, interior(f)), values(prognostic_fields(breeze_child(model))))
    @info "PERF state after profiling: iteration $(Oceananigans.iteration(model)), " *
          (bad == 0 ? "all prognostics finite" : "$(bad) NON-FINITE prognostic values — timings are not representative")
end
