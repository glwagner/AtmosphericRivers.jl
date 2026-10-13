# Read an `AR_BOUNDARY_PROBE` file (reactant_downscale.jl) and explain the step-1 kick at the frame.
#
#     julia --project=sensitivity analysis/boundary_probe.jl dtsweep/probe30_hydro.jld2 ...
#
# 1. Step-1 tendencies (after − before)/Δt of ρ, ρθ, ρw: where is the worst frame cell?
# 2. The wall-normal profile through that cell — halo (the prescribed wall state) and the first
#    interior cells — of ρ, θ = ρθ/ρᵈ and p: is there a jump between the halo and the nest?
# 3. Hydrostatic residual of the initial state, a = −(1/ρ) ∂p/∂z − g at w-faces, frame vs interior:
#    an unbalanced column accelerates vertically at a, i.e. an impulse ∝ Δt in one step.

using JLD2, Printf, Statistics

const g = 9.80665
const FRAME = 3

function probe(path)
    f = jldopen(path)
    Δt = f["dt"]; Hx, Hy, Hz = f["halo"]; Nx, Ny, Nz = f["size"]
    zc = f["grid/z_physical_center"]
    λ, φ = f["grid/lambda_center"], f["grid/phi_center"]
    B(name) = f["before/$name"]; A(name) = f["after/$name"]
    I(a) = a[Hx+1:Hx+Nx, Hy+1:Hy+Ny, :]                     # interior in x, y; all z incl. halos
    ρᵈ, ρθ, p, ρ = B("ρᵈ"), B("ρθ"), B("p"), B("ρ")
    @printf("=== %s (Δt = %g s)\n", basename(path), Δt)
    println("reference-state fields: ", haskey(f, "reference") ? keys(f["reference"]) : "none")

    edge = [min(i - 1, Nx - i, j - 1, Ny - j) for i in 1:Nx, j in 1:Ny]

    # 1. step-1 tendencies
    Gw = I((A("ρw") .- B("ρw")) ./ Δt)[:, :, Hz+2:Hz+Nz]      # interior w-faces 2:Nz
    Gρ = I((A("ρᵈ") .- ρᵈ) ./ Δt)[:, :, Hz+1:Hz+Nz]
    Gθ = I((A("ρθ") .- ρθ) ./ Δt)[:, :, Hz+1:Hz+Nz]
    for (name, G) in (("ρw", Gw), ("ρᵈ", Gρ), ("ρθ", Gθ))
        frame = [edge[i, j] < FRAME for i in 1:Nx, j in 1:Ny, k in 1:size(G, 3)]
        @printf("  step-1 max|∂t %-3s|  frame %.3e   interior %.3e\n", name,
                maximum(abs, G[frame]), maximum(abs, G[.!frame]))
    end
    frame3 = [edge[i, j] < FRAME for i in 1:Nx, j in 1:Ny, k in 1:size(Gw, 3)]
    Gmask = abs.(Gw) .* frame3
    i₀, j₀, kw = Tuple(argmax(Gmask)); k₀ = kw + 1
    @printf("  worst frame cell for ∂t ρw: (i, j, k_face) = (%d, %d, %d), λ = %.2f, φ = %.2f, z ≈ %.0f m, ∂t ρw = %.3g\n",
            i₀, j₀, k₀, λ[i₀], φ[j₀], zc[i₀, j₀, min(k₀, Nz)], Gw[i₀, j₀, kw])

    # 2. wall-normal profile through the worst cell (nearest wall)
    dists = (west = i₀ - 1, east = Nx - i₀, south = j₀ - 1, north = Ny - j₀)
    wall = argmin(dists)
    k = Hz + min(k₀, Nz)
    idx(n) = wall === :west  ? (Hx + 1 + n, Hy + j₀) :     # n = -1 is the first halo cell
             wall === :east  ? (Hx + Nx - n, Hy + j₀) :
             wall === :south ? (Hx + i₀, Hy + 1 + n) : (Hx + i₀, Hy + Ny - n)
    println("  wall-normal profile at level k = $(min(k₀, Nz)) toward the $(wall) wall (n = -1 is the halo):")
    for n in -2:4
        a, b = idx(n)
        @printf("    n = %2d   ρᵈ = %.5f   θ = %8.3f K   p = %9.2f Pa\n", n, ρᵈ[a, b, k], ρθ[a, b, k] / ρᵈ[a, b, k], p[a, b, k])
    end

    # 3. hydrostatic residual of the initial state at interior w-faces k = 2:Nz
    acc = zeros(Nx, Ny, Nz - 1)
    for kk in 2:Nz, j in 1:Ny, i in 1:Nx
        a, b = Hx + i, Hy + j
        Δz = zc[i, j, kk] - zc[i, j, kk-1]
        ρf = (ρ[a, b, Hz+kk] + ρ[a, b, Hz+kk-1]) / 2
        acc[i, j, kk-1] = -(p[a, b, Hz+kk] - p[a, b, Hz+kk-1]) / Δz / ρf - g
    end
    for r in (0, 1, 2, 5, 10)
        m = [edge[i, j] == r for i in 1:Nx, j in 1:Ny, k in 1:Nz-1]
        @printf("  hydrostatic residual |a| (m/s²) at edge-dist %2d: max %.4f  rms %.4f\n", r, maximum(abs, acc[m]), sqrt(mean(acc[m] .^ 2)))
    end
    m = [edge[i, j] > 10 for i in 1:Nx, j in 1:Ny, k in 1:Nz-1]
    @printf("  hydrostatic residual |a| (m/s²) interior (>10):  max %.4f  rms %.4f\n", maximum(abs, acc[m]), sqrt(mean(acc[m] .^ 2)))
    @printf("  residual at the worst cell's face: %.4f m/s²\n", acc[i₀, j₀, kw])

    # Horizontal pressure jump across the boundary face vs the next interior face, per wall
    for (wname, cut) in ((:west, (Hx, Hx + 1, Hx + 2)), (:east, (Hx + Nx + 1, Hx + Nx, Hx + Nx - 1)))
        J = Hy+1:Hy+Ny; K = Hz+1:Hz+Nz
        jump = p[cut[1], J, K] .- p[cut[2], J, K]; next = p[cut[2], J, K] .- p[cut[3], J, K]
        @printf("  %-5s |Δp| halo→cell1 max %.1f rms %.1f Pa   cell1→cell2 max %.1f rms %.1f Pa\n", wname,
                maximum(abs, jump), sqrt(mean(jump .^ 2)), maximum(abs, next), sqrt(mean(next .^ 2)))
    end
    for (wname, cut) in ((:south, (Hy, Hy + 1, Hy + 2)), (:north, (Hy + Ny + 1, Hy + Ny, Hy + Ny - 1)))
        Ii = Hx+1:Hx+Nx; K = Hz+1:Hz+Nz
        jump = p[Ii, cut[1], K] .- p[Ii, cut[2], K]; next = p[Ii, cut[2], K] .- p[Ii, cut[3], K]
        @printf("  %-5s |Δp| halo→cell1 max %.1f rms %.1f Pa   cell1→cell2 max %.1f rms %.1f Pa\n", wname,
                maximum(abs, jump), sqrt(mean(jump .^ 2)), maximum(abs, next), sqrt(mean(next .^ 2)))
    end
    close(f)
end

foreach(probe, ARGS)
