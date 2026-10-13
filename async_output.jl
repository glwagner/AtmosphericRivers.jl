# # `AR_ASYNC_OUTPUT=1`: snapshots written off the critical path (eager CUDA only)
#
# `write_snapshot` holds the stepping loop for the whole snapshot: a device→host copy of every field
# through `Array(parent(f))` (pageable memory, ~0.6 GB/s) and then the JLD2 append, ≈ 0.68 s per
# 138 MB snapshot, ≈ 35–45 s of a 24 h run (perf/PROFILE_REPORT.md §8). Here the stepping loop only
# pays for a whole-`parent` copy into page-locked host buffers allocated once (≈ 10 ms per snapshot);
# extracting the interiors and appending to the JLD2 file happen on a background task while the GPU
# keeps stepping.
#
# The file is the same: the background task writes the same keys, in the same order, with the same
# values (`view(buffer, parentindices(interior(f))...)` is exactly what `host_interior` selects from
# its own host copy). Two buffer sets alternate, so at most two snapshots are in flight; staging into a
# set first waits for the write that last used it (backpressure). Each write also waits for its
# predecessor, so appends to the file never overlap and stay in snapshot order. `flush_snapshots!()`
# waits for everything and must run before anything else opens the output file; an exception in a
# write is rethrown there.

struct SnapshotEntry
    key   :: String     # "timeseries/<key>/<iteration>"
    field :: Any        # the device Field
    flat  :: Bool       # 2-D field written as [:, :, 1]
    loc   :: Union{Nothing, String}  # "location/<name>" value for prognostics, written once
end

function snapshot_entries(model)
    entries = SnapshotEntry[]
    for (name, f) in pairs(prognostic_fields(breeze_child(model)))
        push!(entries, SnapshotEntry(string(name), f, false, location_name(f)))
    end
    push!(entries, SnapshotEntry("precipitation_flux", precipitation_flux, true, nothing))
    push!(entries, SnapshotEntry("accumulated_precipitation", accumulated_precipitation, true, nothing))
    if output_closure_fields
        cf = breeze_child(model).closure_fields
        for name in (:Kᵘ, :Kᶜ, :ℓ, :N²)
            hasproperty(cf, name) || continue
            push!(entries, SnapshotEntry("closure_$(name)", getproperty(cf, name), false, nothing))
        end
    end
    return entries
end

mutable struct AsyncSnapshotWriter
    path    :: String
    entries :: Vector{SnapshotEntry}
    buffers :: Vector{Vector{Array}}   # two sets, one page-locked host array per entry
    tasks   :: Vector{Union{Nothing, Task}}
    last    :: Union{Nothing, Task}
    count   :: Int
    staged_seconds :: Float64
end

function pinned_like(device_array)
    buffer = Array{eltype(device_array)}(undef, size(device_array))
    try
        CUDA.pin(buffer)
    catch err
        @warn "AR_ASYNC_OUTPUT: could not page-lock a snapshot buffer; copies fall back to pageable memory" err maxlog=1
    end
    return buffer
end

function AsyncSnapshotWriter(path, model)
    entries = snapshot_entries(model)
    buffers = [Array[pinned_like(parent(e.field)) for e in entries] for _ in 1:2]
    return AsyncSnapshotWriter(path, entries, buffers, Union{Nothing, Task}[nothing, nothing], nothing, 0, 0.0)
end

function write_staged!(file, writer, set, iteration, t)
    file["timeseries/t/$iteration"] = Float64(t)
    for (e, buffer) in zip(writer.entries, writer.buffers[set])
        interior_view = view(buffer, parentindices(interior(e.field))...)
        data = e.flat ? Array(interior_view)[:, :, 1] : Array(interior_view)
        file["timeseries/$(e.key)/$iteration"] = data
        if !isnothing(e.loc)
            key = "location/$(e.key)"
            haskey(file, key) || (file[key] = e.loc)
        end
    end
    return nothing
end

function async_snapshot!(writer::AsyncSnapshotWriter, iteration, t)
    start = time_ns()
    set = writer.count % 2 + 1
    ## Backpressure: the write that last read this buffer set must be done before it is overwritten.
    isnothing(writer.tasks[set]) || wait(writer.tasks[set])
    for (e, buffer) in zip(writer.entries, writer.buffers[set])
        copyto!(buffer, parent(e.field))   # on the stepping stream, so it sees the finished step
    end
    previous = writer.last
    task = Threads.@spawn begin
        isnothing(previous) || wait(previous)
        JLD2.jldopen(f -> write_staged!(f, writer, set, iteration, t), writer.path, "a+")
    end
    writer.tasks[set] = task
    writer.last = task
    writer.count += 1
    writer.staged_seconds += 1e-9 * (time_ns() - start)
    return nothing
end

function flush_snapshots!(writer::AsyncSnapshotWriter)
    isnothing(writer.last) || wait(writer.last)
    foreach(t -> isnothing(t) || wait(t), writer.tasks)
    return nothing
end

flush_snapshots!(::Nothing) = nothing
