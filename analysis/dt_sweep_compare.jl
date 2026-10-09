# Compare the members of the time-step sweep (slurm/dt_sweep.batch) against the smallest-Δt member.
#
#     julia --project=sensitivity analysis/dt_sweep_compare.jl 9 2   # 12 km, ETOPO with 2 smoothing passes
#     julia --project=sensitivity analysis/dt_sweep_compare.jl 9 8   # 12 km, 8 passes
#     julia --project=sensitivity analysis/dt_sweep_compare.jl 3 2   # 21 km
#     julia --project=sensitivity analysis/dt_sweep_compare.jl 9 2 1 # 12 km, after a 1 h spin-up at 10 s
#
# Per member, from its log: completion, finiteness, acoustic substeps, wall seconds per step.
# From its JLD2: max|w| and a grid-scale-noise index of w over time; the regional 6 h and 24 h
# accumulated precipitation over the sensitivity target (sensitivity/region.jl); and RMS
# differences from the reference member in IWV and accumulated precipitation away from the frame.

using JLD2, Printf, Statistics
include(joinpath(@__DIR__, "..", "sensitivity", "region.jl"))

const CPD = parse(Int, get(ARGS, 1, "9"))
const SMOOTHING = get(ARGS, 2, "2")                       # AR_TERRAIN_SMOOTHING of the etopo members; "analytic" for the ridge
const TERRAIN = SMOOTHING == "analytic" ? "analytic" : "etopo, $(SMOOTHING) smoothing passes"
const SPINUP = get(ARGS, 3, "")                          # "1" for the members run after a 1 h spin-up (AR_SPINUP_HOURS)
const TAG = (SMOOTHING == "analytic" ? "" : "_etopo_s$(SMOOTHING)") * (isempty(SPINUP) ? "" : "_spin$(SPINUP)h")
const JOBTAG = (SMOOTHING == "analytic" ? "" : "e$(SMOOTHING)") * (isempty(SPINUP) ? "" : "s$(SPINUP)")  # job names ar-dt<cpd><JOBTAG>-<Δt>
const DIR = get(ENV, "AR_DTSWEEP_DIR", joinpath(@__DIR__, "..", "dtsweep"))
const LOGDIR = joinpath(@__DIR__, "..", "slurm")
const RIND = 20              # cells from the lateral frame excluded from field comparisons

files = filter(f -> occursin(Regex("^landfall_$(CPD)cpd_dt(\\d+)_24h$(TAG)\\.jld2\$"), f), readdir(DIR))
dts = sort([parse(Int, match(r"_dt(\d+)_", f)[1]) for f in files])
path(dt) = joinpath(DIR, "landfall_$(CPD)cpd_dt$(dt)_24h$(TAG).jld2")

function log_summary(dt)
    logs = filter(f -> startswith(f, "ar-dt$(CPD)$(JOBTAG)-$(dt)-") && endswith(f, ".log"), readdir(LOGDIR))
    isempty(logs) && return (; substeps = missing, s_per_step = missing, verdict = "no log", gpu = "")
    text = read(joinpath(LOGDIR, last(sort(logs))), String)
    m = match(r"(\d+) acoustic substeps per step", text)
    substeps = isnothing(m) ? missing : parse(Int, m[1])
    walls = [parse(Float64, x[1]) for x in eachmatch(r"iter=\s*\d+, t=[^,]+, Δt=[^,]+, wall=\s*([\d.]+)s", text)]
    per_hour = 3600 ÷ dt
    s_per_step = length(walls) > 3 ? median(walls[3:end]) / per_hour : missing
    verdict = occursin("FINITE: every prognostic", text) ? "finite" :
              occursin("NON-FINITE", text) ? "NON-FINITE" :
              occursin(r"done \(exit 0\)", text) ? "exit 0" :
              occursin(r"done \(exit \d+\)", text) ? "FAILED" : "running"
    gpu = something(match(r"\n(NVIDIA [^,\n]+)", text), (; captures = [""])).captures[1]
    return (; substeps, s_per_step, verdict, gpu)
end

function load(dt)
    jldopen(path(dt)) do f
        iters = sort(parse.(Int, keys(f["timeseries/t"])))
        t = [f["timeseries/t/$i"] for i in iters]
        λf, φf = f["grid/lambda_face"], f["grid/phi_face"]
        h, ztop, rf = f["grid/terrain_height"], f["grid/z_top"], f["grid/z_face"]
        Δr = diff(rf)
        stretch = 1 .- h ./ ztop                                  # LinearDecay: ∂z/∂r
        Nx, Ny, Nz = f["grid/size"]
        kmid = Nz ÷ 2
        maxw = Float64[]; noise = Float64[]; iwv = Matrix{Float64}[]; acc = Matrix{Float64}[]; flux = Matrix{Float64}[]
        for i in iters
            ρ = f["timeseries/ρᵈ/$i"]; ρw = f["timeseries/ρw/$i"]
            ρface = similar(ρw); ρface[:, :, 2:Nz] .= (ρ[:, :, 1:Nz-1] .+ ρ[:, :, 2:Nz]) ./ 2
            ρface[:, :, 1] .= ρ[:, :, 1]; ρface[:, :, Nz+1] .= ρ[:, :, Nz]
            w = ρw ./ ρface
            wi = w[RIND+1:Nx-RIND, RIND+1:Ny-RIND, 2:Nz]
            push!(maxw, all(isfinite, wi) ? maximum(abs, wi) : NaN)
            wm = w[RIND:Nx-RIND+1, RIND:Ny-RIND+1, kmid]
            lap = wm[1:end-2, 2:end-1] .+ wm[3:end, 2:end-1] .+ wm[2:end-1, 1:end-2] .+ wm[2:end-1, 3:end] .- 4wm[2:end-1, 2:end-1]
            push!(noise, sqrt(mean(lap .^ 2)) / (8 * sqrt(mean(wm[2:end-1, 2:end-1] .^ 2))))
            q = f["timeseries/ρqᵉ/$i"]
            push!(iwv, dropdims(sum(q .* reshape(Δr, 1, 1, :), dims = 3), dims = 3) .* stretch)
            push!(acc, f["timeseries/accumulated_precipitation/$i"])
            push!(flux, f["timeseries/precipitation_flux/$i"])
        end
        (; dt, t, λf, φf, maxw, noise, iwv, acc, flux)
    end
end

"Accumulated precipitation at exactly `T`, from the nearest snapshot corrected with its flux."
function acc_at(r, T)
    n = argmin(abs.(r.t .- T))
    return r.acc[n] .- r.flux[n] .* (r.t[n] - T), n
end

interior(a) = a[RIND+1:end-RIND, RIND+1:end-RIND]
rms(a) = sqrt(mean(a .^ 2))

runs = Dict{Int, Any}()
for dt in dts
    try
        runs[dt] = load(dt)
    catch err
        @warn "could not read Δt = $dt" err
    end
end
isempty(runs) && error("no readable members in $DIR for $CPD cpd")
ref = runs[minimum(keys(runs))]
w, _ = region_weights(ref.λf, ref.φf)

regional(r, T) = (a = first(acc_at(r, T)); r.t[end] ≥ T - r.dt ? sum(w .* a) : NaN)

println("# Δt sweep, $(CPD) cpd, $(TERRAIN)$(isempty(SPINUP) ? "" : ", $(SPINUP) h spin-up") — reference Δt = $(ref.dt) s; field diffs exclude a $(RIND)-cell rind")
println("| Δt (s) | verdict | hours | substeps | wall s/step | sim/wall | max|w| 6h / 24h / peak (m/s) | noise idx (24h) | region P 6h (mm) | region P 24h (mm) | P24 vs ref | RMS ΔIWV 24h (kg/m²) | RMS ΔP24 (mm) |")
println("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for dt in dts
    L = log_summary(dt)
    if !haskey(runs, dt)
        println("| $dt | $(L.verdict) | – | $(L.substeps) | – | – | – | – | – | – | – | – | – |")
        continue
    end
    r = runs[dt]
    hours = r.t[end] / 3600
    wat(T) = r.maxw[argmin(abs.(r.t .- T))]
    P6, P24 = regional(r, 6 * 3600), regional(r, 24 * 3600)
    P24ref = regional(ref, 24 * 3600)
    n24 = argmin(abs.(r.t .- 24 * 3600)); nr = argmin(abs.(ref.t .- 24 * 3600))
    diwv = hours ≥ 23.9 ? rms(interior(r.iwv[n24] .- ref.iwv[nr])) : NaN
    dP = hours ≥ 23.9 ? rms(interior(first(acc_at(r, 24 * 3600)) .- first(acc_at(ref, 24 * 3600)))) : NaN
    sps = L.s_per_step
    @printf("| %d | %s | %.1f | %s | %s | %s | %.2f / %.2f / %.2f | %.3f | %.2f | %.2f | %+.1f%% | %.3f | %.2f |\n",
            dt, L.verdict, hours, string(L.substeps), ismissing(sps) ? "–" : @sprintf("%.4f", sps),
            ismissing(sps) ? "–" : @sprintf("%.0f", dt / sps),
            wat(6 * 3600), wat(24 * 3600), maximum(filter(isfinite, r.maxw); init = 0.0), r.noise[end],
            P6, P24, 100 * (P24 / P24ref - 1), diwv, dP)
end
println("\nReference spread: std of interior IWV at 24 h = ", @sprintf("%.2f", std(interior(ref.iwv[end]))),
        " kg/m²; interior-mean 24 h precip = ", @sprintf("%.2f", mean(interior(ref.acc[end]))), " mm")
