# Reduce a reactant_downscale.jl snapshot file (raw density-weighted prognostics, ~2 GB at 9 cells
# per degree) to the 2-D slices needed to look at the boundary acoustic signal, so the result can be
# copied off the cluster and rendered anywhere with nothing but JLD2 and a plotting package.
#
# Per snapshot:
#   rho_sfc      ρᵈ at k = 1 (surface level)                     [Nx, Ny]
#   drho_sfc     ρᵈ(k=1) − ρᵈ(k=1, t=0)                            [Nx, Ny]
#   w_2km        w = ρw/ρᵈ, de-staggered to Center, at the 2 km level [Nx, Ny]
#   w_sec        w section along the row nearest 47.5°N            [Nx, Nz]
#   drho_sec     ρᵈ − ρᵈ(t=0) along that row                       [Nx, Nz]
#   speed_sfc    |U| at k = 1                                      [Nx, Ny]
#
# Usage: julia --project=. analysis/extract_acoustic_slices.jl in.jld2 out_slices.jld2

using JLD2
using Statistics

infile, outfile = ARGS[1], ARGS[2]

jldopen(infile, "r") do f
    λc = f["grid/lambda_center"]; φc = f["grid/phi_center"]; zc = f["grid/z_center"]
    iters = sort(parse.(Int, keys(f["timeseries/t"])))
    times = Float64[f["timeseries/t/$i"] for i in iters]
    snap(name, it) = f["timeseries/$name/$it"]

    k2km = argmin(abs.(zc .- 2000))
    jsec = argmin(abs.(φc .- 47.5))

    ## Layer thicknesses from the REFERENCE z faces (the grid is terrain-following, so this is the
    ## flat-ground thickness; over terrain the true Δz is compressed — same approximation as
    ## analysis/render_reactant_run.jl). IVT = |∫ ρqᵉ (u, v) dz|  [kg m⁻¹ s⁻¹].
    Δz = Float32.(diff(f["grid/z_face"]))
    function ivt(it, u, v)
        ρq = snap("ρqᵉ", it)
        e = zeros(Float32, size(ρq, 1), size(ρq, 2))
        n = zeros(Float32, size(ρq, 1), size(ρq, 2))
        @inbounds for k in axes(ρq, 3), j in axes(ρq, 2), i in axes(ρq, 1)
            e[i, j] += ρq[i, j, k] * u[i, j, k] * Δz[k]
            n[i, j] += ρq[i, j, k] * v[i, j, k] * Δz[k]
        end
        return sqrt.(e .^ 2 .+ n .^ 2)
    end

    ρ0 = snap("ρᵈ", iters[1])
    wc(it) = (a = snap("ρw", it); ρ = snap("ρᵈ", it);
              @views 0.5f0 .* (a[:, :, 1:end-1] .+ a[:, :, 2:end]) ./ ρ)
    uc(it) = (a = snap("ρu", it); ρ = snap("ρᵈ", it);
              @views 0.5f0 .* (a[1:end-1, :, :] .+ a[2:end, :, :]) ./ ρ)
    vc(it) = (a = snap("ρv", it); ρ = snap("ρᵈ", it);
              @views 0.5f0 .* (a[:, 1:end-1, :] .+ a[:, 2:end, :]) ./ ρ)

    jldopen(outfile, "w") do g
        g["lambda"] = λc; g["phi"] = φc; g["z"] = zc
        g["k2km"] = k2km; g["jsec"] = jsec; g["phi_sec"] = φc[jsec]
        g["iters"] = iters; g["times"] = times
        haskey(f, "grid/terrain_height") && (g["terrain_height"] = f["grid/terrain_height"])
        for (n, it) in enumerate(iters)
            ρ = snap("ρᵈ", it)
            w = wc(it)
            u = uc(it); v = vc(it)
            g["frames/$n/rho_sfc"]   = ρ[:, :, 1]
            g["frames/$n/drho_sfc"]  = ρ[:, :, 1] .- ρ0[:, :, 1]
            g["frames/$n/w_2km"]     = w[:, :, k2km]
            g["frames/$n/w_sec"]     = w[:, jsec, :]
            g["frames/$n/drho_sec"]  = ρ[:, jsec, :] .- ρ0[:, jsec, :]
            g["frames/$n/speed_sfc"] = sqrt.(u[:, :, 1] .^ 2 .+ v[:, :, 1] .^ 2)
            g["frames/$n/ivt"]       = ivt(it, u, v)
            println("frame $n / $(length(iters))  t = $(round(times[n] / 60, digits = 1)) min  ",
                    "max|w₂ₖₘ| = $(round(maximum(abs, w[:, :, k2km]), digits = 2)) m/s  ",
                    "max|Δρ_sfc| = $(round(maximum(abs, ρ[:, :, 1] .- ρ0[:, :, 1]), sigdigits = 3))")
        end
    end
end
println("EXTRACT_OK $outfile $(round(filesize(outfile) / 2^20, digits = 1)) MiB")
