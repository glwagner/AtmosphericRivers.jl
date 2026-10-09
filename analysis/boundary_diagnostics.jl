# Where does a run go unstable: at the lateral frame or in the interior?
#
#     julia --project=sensitivity analysis/boundary_diagnostics.jl dtsweep/diag30_rw15.jld2 ...
#
# For each snapshot: max |ρw| and the max vertical advective Courant number Cz = |w| Δt / Δz in the
# outermost FRAME cells (within `FRAME` cells of a lateral wall) versus the interior. Δz is the
# physical spacing between the centres adjacent to each w-face on the LinearDecay terrain-following
# grid (∂z/∂r = 1 − h/z_top). One line per snapshot, then a one-line verdict per file.

using JLD2, Printf

const FRAME = parse(Int, get(ENV, "AR_FRAME_CELLS", "3"))

function diagnose(path)
    jldopen(path) do f
        Δt = f["meta/dt_seconds"]; h = f["grid/terrain_height"]; ztop = f["grid/z_top"]
        rc = f["grid/z_center"]; Nx, Ny, Nz = f["grid/size"]
        s = 1 .- h ./ ztop
        edge = [min(i - 1, Nx - i, j - 1, Ny - j) < FRAME for i in 1:Nx, j in 1:Ny]
        iterations = sort(parse.(Int, keys(f["timeseries/t"])))
        @printf("=== %s (Δt = %g s; frame = outermost %d cells)\n", basename(path), Δt, FRAME)
        last_t = 0.0; worst = (0.0, 0.0, 0.0, 0.0)
        for n in iterations
            t = f["timeseries/t/$n"]
            ρ = f["timeseries/ρᵈ/$n"]; ρw = f["timeseries/ρw/$n"]
            if !all(isfinite, ρw)
                @printf("  t = %8.0f s  NON-FINITE\n", t)
                break
            end
            ρw_frame = ρw_int = Cz_frame = Cz_int = 0.0
            for k in 2:Nz, j in 1:Ny, i in 1:Nx
                a = abs(ρw[i, j, k])
                Cz = a / ((ρ[i, j, k-1] + ρ[i, j, k]) / 2) * Δt / ((rc[k] - rc[k-1]) * s[i, j])
                if edge[i, j]
                    ρw_frame = max(ρw_frame, a); Cz_frame = max(Cz_frame, Cz)
                else
                    ρw_int = max(ρw_int, a); Cz_int = max(Cz_int, Cz)
                end
            end
            @printf("  t = %8.0f s  max|ρw| frame %8.3f  interior %7.3f   max Cz frame %7.3f  interior %6.3f\n",
                    t, ρw_frame, ρw_int, Cz_frame, Cz_int)
            last_t = t
            worst = max.(worst, (ρw_frame, ρw_int, Cz_frame, Cz_int))
        end
        @printf("  VERDICT %s: last finite t = %.2f h; worst max|ρw| frame %.2f / interior %.2f; worst Cz frame %.2f / interior %.2f\n",
                basename(path), last_t / 3600, worst...)
    end
end

foreach(diagnose, ARGS)
