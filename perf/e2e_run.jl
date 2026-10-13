# End-to-end run(s) of the production script with the setup-phase sampler of perf/profile_window.jl.
#
# Runs `reactant_downscale.jl` once per configuration, each in a fresh module, in ONE Julia process, so
# the second and later configurations reuse everything the first one compiled (PROFILE_REPORT §9 #9).
# Configurations come from AR_MULTI_CONFIGS: `;`-separated, each an `&`-separated list of KEY=VALUE (not `,`: sbatch --export splits on commas)
# overrides applied to ENV on top of the batch environment. Unset = one run with the environment as is.
#
#   AR_E2E_OUT=perf/data/e2e_<tag> AR_MULTI_CONFIGS="AR_TAG=a;AR_TAG=b&AR_TKE_FLAVOR=catke" \
#       julia --project -t auto perf/e2e_run.jl
#
# Per configuration it writes <out>_c<i>_setup.tsv (same format as profile_window's, for
# perf/setup_phases.py) and prints one `E2E config <i>` line with its wall time and compile time.

const E2E_T0 = time_ns()
samples = Tuple{Float64, Float64, Float64, Float64}[]
sampling = Ref(true)
Base.cumulative_compile_timing(true)
sampler = Threads.@spawn begin
    while sampling[]
        push!(samples, (1e-9 * (time_ns() - E2E_T0), 1e-9 * Base.cumulative_compile_time_ns()[1],
                        1e-9 * Base.gc_num().total_time, Float64(Base.gc_total_bytes(Base.gc_num()))))
        sleep(1)
    end
end

out = get(ENV, "AR_E2E_OUT", "perf/data/e2e")
mkpath(dirname(out))
script = joinpath(@__DIR__, "..", "reactant_downscale.jl")
configs = split(get(ENV, "AR_MULTI_CONFIGS", ""), ';'; keepempty = false)
isempty(configs) && (configs = [""])

for (i, config) in enumerate(configs)
    for kv in split(config, '&'; keepempty = false)
        k, v = split(kv, '='; limit = 2)
        ENV[strip(k)] = strip(v)
    end
    println("E2E config $i start: ", isempty(config) ? "(batch environment)" : config)
    first_sample = length(samples) + 1
    start = time_ns()
    compile0 = 1e-9 * Base.cumulative_compile_time_ns()[1]
    run_module = Module(Symbol("ARRun", i))
    Base.include(run_module, script)
    wall = 1e-9 * (time_ns() - start)
    compile = 1e-9 * Base.cumulative_compile_time_ns()[1] - compile0
    println("E2E config $i done: wall ", round(wall, digits = 1), " s, compile ", round(compile, digits = 1), " s")
    open(out * "_c$(i)_setup.tsv", "w") do io
        println(io, "# config\t", config)
        println(io, "# stage_clock_offset_s\t", 1e-9 * (getfield(run_module, :script_start) - E2E_T0))
        println(io, "wall_s\tcompile_s\tgc_s\tallocated_bytes")
        for r in samples[first_sample:end]
            println(io, join(r, '\t'))
        end
    end
    GC.gc(true)
end

sampling[] = false
wait(sampler)
println("E2E total wall ", round(1e-9 * (time_ns() - E2E_T0), digits = 1), " s")
