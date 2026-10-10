# Profile windows of the eager-CUDA forward run that contain the hourly events.
#
# Builds the model by `include`ing the production script with a short run (AR_STEPS = AR_CHUNK), then
# walks the clock through consecutive hours. Each window is AR_PROF_WINDOW steps (default 200) centred
# on an hour boundary, so it contains one radiation solve (TimeInterval) and one parent-window
# (hourly ERA5) update:
#
#   hour 1  per-step synchronized wall times                         → <out>_steps.tsv
#   hour 2  back-to-back wall time, host allocations and GC          → log
#   hour 3  CUPTI trace (CUDA.@profile): every API call and kernel,  → <out>_device.tsv.gz, <out>_host.tsv.gz
#           with grid/block/registers/shared/local memory
#   hour 4  nsys capture range (only under `AR_PROF_NSYS=1`)
#   then    host CPU profile and sampled allocations over AR_PROF_HOST_STEPS steps between events
#
#   AR_PROF_OUT=perf/data/<tag> julia --project perf/profile_window.jl   (with the production AR_* env)

# Setup-phase attribution: a sampler on another thread records (wall, cumulative compile time, GC time,
# allocated bytes) every second while the production script builds the model, so each `stage` interval
# of the log can be split into compilation vs. work. Load time before this line comes from the batch
# script's timestamps.
const SETUP_T0 = time_ns()
const SETUP_UNIX = time()
setup_samples = Tuple{Float64, Float64, Float64, Float64}[]
setup_sampling = Ref(true)
Base.cumulative_compile_timing(true)
setup_sampler = Threads.@spawn begin
    while setup_sampling[]
        push!(setup_samples, (1e-9 * (time_ns() - SETUP_T0), 1e-9 * Base.cumulative_compile_time_ns()[1],
                              1e-9 * Base.gc_num().total_time, Float64(Base.gc_total_bytes(Base.gc_num()))))
        sleep(1)
    end
end

include(joinpath(@__DIR__, "..", "reactant_downscale.jl"))

setup_sampling[] = false

using CUDA
using Printf
using Profile

out      = get(ENV, "AR_PROF_OUT", "perf/data/profile")
nwindow  = parse(Int, get(ENV, "AR_PROF_WINDOW", "200"))
nhost    = parse(Int, get(ENV, "AR_PROF_HOST_STEPS", "30"))
mkpath(dirname(out))

steps_per_hour = round(Int, 3600 / Float64(Δt))
current_iteration() = Int(Oceananigans.iteration(model))

"Step until the iteration is `half` steps before the next hour boundary at or after `hour`."
function advance_to_window!(hour)
    target = hour * steps_per_hour - nwindow ÷ 2
    n = target - current_iteration()
    n < 0 && error("already past iteration $target (at $(current_iteration()))")
    n > 0 && step_for!(model, Δt, n)
    CUDA.synchronize()
    return target
end

first_hour = cld(current_iteration() + nwindow ÷ 2, steps_per_hour)

wait(setup_sampler)
open(out * "_setup.tsv", "w") do io
    ## the script's `stage` clock starts at `script_start`; record its offset from this driver's t0
    println(io, "# driver_t0_unix\t", SETUP_UNIX)
    println(io, "# stage_clock_offset_s\t", 1e-9 * (script_start - SETUP_T0))
    println(io, "wall_s\tcompile_s\tgc_s\tallocated_bytes")
    for r in setup_samples
        println(io, join(r, '\t'))
    end
end

# Metadata the analysis needs (perf/analyze_profile.py): sizes, step, substeps, field order.
open(out * "_meta.txt", "w") do io
    child = breeze_child(model)
    println(io, "gpu\t", CUDA.name(CUDA.device()))
    println(io, "size\t", join(size(grid), "x"))
    println(io, "halo\t", join(Oceananigans.Grids.halo_size(grid), "x"))
    println(io, "dt\t", Float64(Δt))
    println(io, "acoustic_substeps\t", acoustic_substeps)
    println(io, "window\t", nwindow)
    println(io, "steps_per_hour\t", steps_per_hour)
    println(io, "first_hour\t", first_hour)
    println(io, "prognostic\t", join(string.(keys(prognostic_fields(child))), ","))
    println(io, "closure\t", get(ENV, "AR_CLOSURE", "tke"), "/", get(ENV, "AR_TKE_FLAVOR", "main"))
    println(io, "project\t", Base.active_project())
end

# ## Hour 1: per-step synchronized timings
w0 = advance_to_window!(first_hour)
open(out * "_steps.tsv", "w") do io
    println(io, "iteration\twall_ms")
    for _ in 1:nwindow
        it = current_iteration()
        t0 = time_ns()
        step_for!(model, Δt, 1)
        CUDA.synchronize()
        println(io, it, '\t', 1e-6 * (time_ns() - t0))
    end
end
let t = parse.(Float64, last.(split.(readlines(out * "_steps.tsv")[2:end], '\t')))
    s = sort(t)
    @info @sprintf("PERF synchronized steps %d–%d: median %.2f ms, mean %.2f ms, max %.1f ms; steps > 2× median: %s",
                   w0, w0 + nwindow, s[(end + 1) ÷ 2], sum(t) / length(t), s[end],
                   join([@sprintf("%d (%.0f ms)", w0 + i - 1, t[i]) for i in findall(>(2s[(end + 1) ÷ 2]), t)], ", "))
end

# ## Hour 2: back-to-back, allocations, GC
w0 = advance_to_window!(first_hour + 1)
stats = @timed begin
    step_for!(model, Δt, nwindow)
    CUDA.synchronize()
end
Nc = prod(size(grid))
tb = stats.time / nwindow
@info @sprintf("PERF back-to-back steps %d–%d (incl. one radiation + one parent update): %.2f ms/step ⇒ %.1f M cell-steps/s, %.0f× real time; host %.2f MiB/step, GC %.1f%% of wall",
               w0, w0 + nwindow, 1e3tb, Nc / tb / 1e6, Float64(Δt) / tb, stats.bytes / 2^20 / nwindow, 100 * stats.gctime / stats.time)

# ## Hour 3: CUPTI trace dumped to TSV (skipped under nsys, which owns CUPTI)
if get(ENV, "AR_PROF_CUPTI", "1") == "1"
w0 = advance_to_window!(first_hour + 2)
prof = CUDA.@profile begin
    step_for!(model, Δt, nwindow)
    CUDA.synchronize()
end

function write_trace(path, table, columns)
    open(pipeline(`gzip -c`, stdout = path), "w") do io
        println(io, join(string.(columns), '\t'))
        for i in eachindex(table.id)
            row = map(columns) do c
                v = getproperty(table, c)[i]
                v === missing ? "" :
                nameof(typeof(v)) === :CuDim3 ? "$(v.x)x$(v.y)x$(v.z)" :
                v isa NamedTuple ? join(values(v), "/") :
                v isa AbstractFloat ? @sprintf("%.9f", v) : replace(string(v), '\t' => ' ')
            end
            println(io, join(row, '\t'))
        end
    end
end
write_trace(out * "_device.tsv.gz", prof.device,
            (:id, :start, :stop, :name, :stream, :grid, :block, :registers, :shared_mem, :local_mem, :size))
write_trace(out * "_host.tsv.gz", prof.host, (:id, :start, :stop, :name, :tid))
@info "PERF CUPTI trace of steps $(w0)–$(w0 + nwindow): $(length(prof.device.id)) device records, " *
      "$(length(prof.host.id)) host records → $(out)_{device,host}.tsv.gz"
show(IOContext(stdout, :limit => true, :displaysize => (60, 250)), prof)
println()
end

# ## Hour 4: nsys capture range
if get(ENV, "AR_PROF_NSYS", "0") == "1"
    w0 = advance_to_window!(first_hour + 3)
    CUDA.@profile external = true begin
        step_for!(model, Δt, nwindow)
        CUDA.synchronize()
    end
    @info "PERF nsys capture range: steps $(w0)–$(w0 + nwindow)"
end

# ## Host CPU profile and allocations, between events
if get(ENV, "AR_PROF_HOSTPROF", "1") == "1"
step_for!(model, Δt, 5)
CUDA.synchronize()
Profile.clear()
Profile.init(n = 10^7, delay = 0.0002)
@profile begin
    step_for!(model, Δt, nhost)
    CUDA.synchronize()
end
open(out * "_hostprofile.txt", "w") do io
    ctx = IOContext(io, :displaysize => (100_000, 1000))
    println(io, "==== flat, by inclusive count ($nhost steps) ====")
    Profile.print(ctx; format = :flat, sortedby = :count, C = false)
    println(io, "==== tree ====")
    Profile.print(ctx; format = :tree, C = false, noisefloor = 1, mincount = 10)
end

Profile.Allocs.clear()
Profile.Allocs.@profile sample_rate = 0.1 step_for!(model, Δt, 3)
CUDA.synchronize()
open(out * "_allocs.tsv", "w") do io
    println(io, "bytes\ttype\tframes")
    for a in Profile.Allocs.fetch().allocs
        frames = [string(sf.func, "@", basename(string(sf.file)), ":", sf.line) for sf in a.stacktrace
                  if occursin(r"Oceananigans|Breeze|NumericalEarth|KernelAbstractions|CUDA|GPUArrays|reactant_downscale|Base",
                              string(sf.file))]
        println(io, a.size, '\t', replace(string(a.type), '\t' => ' ')[1:min(end, 200)], '\t',
                join(first(frames, 12), " < "))
    end
end
@info "PERF host profile → $(out)_hostprofile.txt, sampled allocations (rate 0.1, 3 steps) → $(out)_allocs.tsv"
end

# ## Output cost: what one snapshot costs on the critical path, split into device→host copies and
# the JLD2 append (the part an asynchronous writer could overlap with stepping).
let path = tempname(dirname(abspath(out))) * ".jld2", nsnap = parse(Int, get(ENV, "AR_PROF_SNAPSHOTS", "6"))
    child = breeze_child(model)
    copy_times = Float64[]; write_times = Float64[]; full_times = Float64[]
    for n in 1:nsnap
        CUDA.synchronize()
        t0 = time_ns()
        arrays = map(f -> Array(host_interior(f)), prognostic_fields(child))
        t1 = time_ns()
        JLD2.jldopen(path * ".split", "a+") do file
            for (name, a) in pairs(arrays)
                file["timeseries/$name/$n"] = a
            end
        end
        t2 = time_ns()
        write_snapshot(path, model, n, Float64(n))
        t3 = time_ns()
        push!(copy_times, 1e-9 * (t1 - t0)); push!(write_times, 1e-9 * (t2 - t1)); push!(full_times, 1e-9 * (t3 - t2))
    end
    bytes = filesize(path) / nsnap
    @info @sprintf("PERF output: write_snapshot %.2f s/snapshot (%.0f MB) — prognostic device→host copy %.3f s, JLD2 append %.3f s (medians of %d)",
                   sort(full_times)[(end + 1) ÷ 2], bytes / 1e6, sort(copy_times)[(end + 1) ÷ 2],
                   sort(write_times)[(end + 1) ÷ 2], nsnap)
    rm(path; force = true); rm(path * ".split"; force = true)
end

let
    bad = sum(f -> count(!isfinite, interior(f)), values(prognostic_fields(breeze_child(model))))
    @info "PERF state after profiling: iteration $(current_iteration()), " *
          (bad == 0 ? "all prognostics finite" : "$(bad) NON-FINITE prognostic values — timings are not representative")
end
