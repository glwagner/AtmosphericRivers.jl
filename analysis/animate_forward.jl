# MP4 animations of `reactant_downscale.jl AR_ARCH=cuda` forward runs, one frame per output snapshot.
#
# Usage (CPU only; no GPU needed — e.g. `sbatch -p cpu slurm/analysis.batch analysis/animate_forward.jl …`):
#
#   julia --project=.. analysis/animate_forward.jl out.mp4 label=run.jld2
#       Single run, three panels per frame: IVT magnitude + vectors with IWV contours (whole nest), precipitation
#       rate, and precipitation accumulated since t = 0 (zoomed on the Pacific Northwest).
#
#   julia --project=.. analysis/animate_forward.jl out.mp4 label1=run1.jld2 label2=run2.jld2 …
#       Several runs side by side (2 columns for 4 runs), precipitation rate only; each title carries the run's
#       running target-polygon accumulation. Runs must share the output cadence (frames follow the first run).
#
# Environment knobs:
#   AR_ANIM_FPS=12                 frame rate
#   AR_ANIM_MODE=panels|rate       force the layout (default: panels for one run, rate for several)
#   AR_ANIM_ZOOM=-131,-115,40,54   precipitation panel limits (λmin, λmax, φmin, φmax)
#   AR_ANIM_STRIDE=1               use every n-th snapshot
#   AR_ANIM_PREVIEW=out.png        also save the last frame as a still
#
# Style comes from analysis/precip_colors.jl (discrete NWS-like palette, transparent below 0.5 mm or 0.1 mm h⁻¹,
# heavy coast + state lines, white-haloed target polygon from sensitivity/region.jl). Reuse it for other runs
# (e.g. figures/sixkm/): the script reads only grid/*, meta/start_date and timeseries/{t, ρu, ρv, ρᵈ, ρqᵛ or ρqᵉ,
# precipitation_flux, accumulated_precipitation}, and takes the domain from the file.

using Oceananigans           # loads JLD2
using NumericalEarth         # with NaturalEarth + GeoInterface → natural_earth_lines
using CairoMakie
using NaturalEarth, GeoInterface
using Dates
using Printf

const JLD2 = first(m for (pkg, m) in Base.loaded_modules if pkg.name == "JLD2")
include(joinpath(@__DIR__, "precip_colors.jl"))
include(joinpath(@__DIR__, "..", "sensitivity", "region.jl"))   # TARGET_POLYGON, point_in_polygon

out_path = ARGS[1]
specs = [split(a, "=", limit = 2) for a in ARGS[2:end]]
fps = parse(Int, get(ENV, "AR_ANIM_FPS", "12"))
mode = get(ENV, "AR_ANIM_MODE", length(specs) == 1 ? "panels" : "rate")
zoom = parse.(Float64, split(get(ENV, "AR_ANIM_ZOOM", "-131,-115,40,54"), ','))
stride = parse(Int, get(ENV, "AR_ANIM_STRIDE", "1"))
zλ, zφ = (zoom[1], zoom[2]), (zoom[3], zoom[4])

struct Run
    label::String
    file::Any
    its::Vector{Int}
    t::Vector{Float64}
    λ::Vector{Float64}
    φ::Vector{Float64}
    Δz::Array{Float64, 3}
    moisture::String
    flux_sign::Float64
    start::DateTime
    weights::Matrix{Float64}
end

function open_run(label, path)
    f = JLD2.jldopen(path, "r")
    its = sort(parse.(Int, keys(f["timeseries/t"])))
    t = [Float64(f["timeseries/t/$n"]) for n in its]
    λ = Float64.(f["grid/lambda_center"]); φ = Float64.(f["grid/phi_center"])
    if haskey(f, "grid/z_physical_face")
        zf = Float64.(f["grid/z_physical_face"]); Δz = diff(zf; dims = 3)
    else
        rf = Float64.(f["grid/z_face"]); h = Float64.(f["grid/terrain_height"]); z_top = f["grid/z_top"]
        Δz = [(rf[k+1] - rf[k]) * (1 - h[i, j] / z_top) for i in eachindex(λ), j in eachindex(φ), k in 1:length(rf)-1]
    end
    moisture = haskey(f, "timeseries/ρqᵛ") ? "ρqᵛ" : "ρqᵉ"
    start = DateTime(haskey(f, "meta/start_date") ? f["meta/start_date"] : "2025-12-07T12:00:00")
    # precipitation_flux sign convention: positive = falling out. Decide from the last snapshot.
    F = Float64.(f["timeseries/precipitation_flux/$(last(its))"])
    flux_sign = abs(minimum(F)) > abs(maximum(F)) ? -1.0 : 1.0
    mask = [point_in_polygon(a, b, TARGET_POLYGON) for a in λ, b in φ]
    w = mask .* cosd.(φ')
    w ./= sum(w)
    @info @sprintf("%s: %d snapshots, %.1f–%.1f h, moisture %s, flux sign %+g, grid %d×%d", label, length(its),
                   first(t) / 3600, last(t) / 3600, moisture, flux_sign, length(λ), length(φ))
    return Run(label, f, its, t, λ, φ, Δz, moisture, flux_sign, start, w)
end

runs = [open_run(String(l), String(p)) for (l, p) in specs]
r1 = first(runs)
frames = 1:stride:length(r1.its)

center_x(a, N) = size(a, 1) == N + 1 ? (a[1:end-1, :, :] .+ a[2:end, :, :]) ./ 2 : a
center_y(a, N) = size(a, 2) == N + 1 ? (a[:, 1:end-1, :] .+ a[:, 2:end, :]) ./ 2 : a
read3(r, name, n) = Float64.(r.file["timeseries/$name/$n"])

function column_fields(r, n)
    ρq = read3(r, r.moisture, n); ρd = read3(r, "ρᵈ", n)
    u = center_x(read3(r, "ρu", n), length(r.λ)) ./ ρd
    v = center_y(read3(r, "ρv", n), length(r.φ)) ./ ρd
    qΔz = ρq .* r.Δz
    iwv = dropdims(sum(qΔz; dims = 3); dims = 3)
    ivtu = dropdims(sum(qΔz .* u; dims = 3); dims = 3)
    ivtv = dropdims(sum(qΔz .* v; dims = 3); dims = 3)
    return iwv, ivtu, ivtv
end
rate(r, n) = 3600 .* r.flux_sign .* Float64.(r.file["timeseries/precipitation_flux/$n"])   # mm h⁻¹
accum(r, n) = Float64.(r.file["timeseries/accumulated_precipitation/$n"]) .-
              Float64.(r.file["timeseries/accumulated_precipitation/$(first(r.its))"])
nearest_index(r, k) = argmin(abs.(r.t .- r1.t[k]))

stamp(r, k) = (d = r.start + Millisecond(round(Int, 1000r.t[k]));
               Dates.format(d, "yyyy-mm-dd HH:MM") * @sprintf(" UTC  (+%.1f h)", r.t[k] / 3600))

poly_λ = [first.(TARGET_POLYGON); first(TARGET_POLYGON)[1]]
poly_φ = [last.(TARGET_POLYGON); first(TARGET_POLYGON)[2]]
geo_line_data()

if mode == "panels"
    r = r1
    k0 = first(frames)
    iwv0, ivtu0, ivtv0 = column_fields(r, r.its[k0])
    IVT = Observable(hypot.(ivtu0, ivtv0)); IWV = Observable(iwv0)
    s = max(1, round(Int, length(r.λ) / 27))                       # ~27 arrows across the nest
    ai, aj = 1+s÷2:s:length(r.λ), 1+s÷2:s:length(r.φ)
    pts = vec([Point2f(r.λ[i], r.φ[j]) for i in ai, j in aj])
    vecs(u, v) = vec([Vec2f(u[i, j], v[i, j]) for i in ai, j in aj])
    V = Observable(vecs(ivtu0, ivtv0))
    R = Observable(rate(r, r.its[k0])); A = Observable(accum(r, r.its[k0]))
    title = Observable(""); Jtext = Observable("")

    λlim = (first(r.λ), last(r.λ)); φlim = (first(r.φ), last(r.φ))
    fig = Figure(size = (2000, 640), fontsize = 15)
    Label(fig[0, 1:6], title; fontsize = 20, font = :bold)
    ax1 = Axis(fig[1, 1]; title = "IVT (kg m⁻¹ s⁻¹), vectors; IWV contours 20/30/40 kg m⁻²",
               limits = (λlim, φlim), aspect = DataAspect())
    hm = heatmap!(ax1, r.λ, r.φ, IVT; colormap = :YlGnBu, colorrange = (0, 1000), highclip = :black)
    contour!(ax1, r.λ, r.φ, IWV; levels = [20, 30, 40], color = :darkorange, linewidth = 1.3)
    geo_lines!(ax1; coast_width = 1.1, state_width = 0.6)
    outline!(ax1, poly_λ, poly_φ; linewidth = 1.4)
    arrows2d!(ax1, pts, V; lengthscale = 1.6 * s / 9 / 1000, color = (:black, 0.75), shaftwidth = 1.4,
              tipwidth = 6, tiplength = 6)
    Colorbar(fig[1, 2], hm; label = "IVT (kg m⁻¹ s⁻¹)")

    ax2 = Axis(fig[1, 3]; title = "precipitation rate (mm h⁻¹)", limits = (zλ, zφ), aspect = DataAspect())
    precip_heatmap!(ax2, r.λ, r.φ, R; levels = RATE_LEVELS)
    geo_lines!(ax2); outline!(ax2, poly_λ, poly_φ)
    precip_colorbar!(fig[1, 4]; levels = RATE_LEVELS, label = "mm h⁻¹")

    ax3 = Axis(fig[1, 5]; title = Jtext, limits = (zλ, zφ), aspect = DataAspect())
    precip_heatmap!(ax3, r.λ, r.φ, A)
    geo_lines!(ax3); outline!(ax3, poly_λ, poly_φ)
    precip_colorbar!(fig[1, 6]; label = "mm since start")
    colsize!(fig.layout, 1, Auto(2.0))

    record(fig, out_path, frames; framerate = fps) do k
        n = r.its[k]
        iwv, ivtu, ivtv = column_fields(r, n)
        IVT[] = hypot.(ivtu, ivtv); IWV[] = iwv; V[] = vecs(ivtu, ivtv)
        R[] = rate(r, n); A[] = accum(r, n)
        Jtext[] = @sprintf("accumulated precipitation (target polygon %.1f mm)", sum(r.weights .* A[]))
        title[] = "$(r.label) — $(stamp(r, k))"
    end
else
    nr = length(runs)
    ncol = nr == 4 ? 2 : min(nr, 3)
    nrow = cld(nr, ncol)
    fig = Figure(size = (620ncol + 160, 600nrow + 80), fontsize = 15)
    title = Observable("")
    Label(fig[0, 1:ncol], title; fontsize = 20, font = :bold)
    Rs = [Observable(rate(r, r.its[nearest_index(r, first(frames))])) for r in runs]
    Ts = [Observable(r.label) for r in runs]
    for (m, r) in enumerate(runs)
        ax = Axis(fig[cld(m, ncol), mod1(m, ncol)]; title = Ts[m], limits = (zλ, zφ), aspect = DataAspect())
        precip_heatmap!(ax, r.λ, r.φ, Rs[m]; levels = RATE_LEVELS)
        geo_lines!(ax); outline!(ax, poly_λ, poly_φ)
    end
    precip_colorbar!(fig[1:nrow, ncol + 1]; levels = RATE_LEVELS, label = "precipitation rate (mm h⁻¹)")
    record(fig, out_path, frames; framerate = fps) do k
        for (m, r) in enumerate(runs)
            n = r.its[nearest_index(r, k)]
            Rs[m][] = rate(r, n)
            Ts[m][] = @sprintf("%s — polygon %.1f mm so far", r.label, sum(r.weights .* accum(r, n)))
        end
        title[] = "Precipitation rate — $(stamp(r1, k))"
    end
end
haskey(ENV, "AR_ANIM_PREVIEW") && save(ENV["AR_ANIM_PREVIEW"], fig)
foreach(r -> close(r.file), runs)
@info "wrote $out_path ($(round(filesize(out_path) / 2^20; digits = 1)) MB, $(length(frames)) frames at $fps fps)"
