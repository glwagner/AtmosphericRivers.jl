# Correctness of the multi-field vertically-implicit solve (agent OPT-COLUMN): solving several fields'
# tridiagonal systems in one launch, `implicit_step!(fields::Tuple, ...)`, must reproduce one
# `implicit_step!` per field bit for bit. CATKE gives each tracer and momentum its own, spatially
# varying diffusivity, and the TKE tracer its implicit linear coefficient.
#
#   julia --project=<env with the patched Oceananigans> perf/test_multi_tridiagonal.jl [gpu]

using Oceananigans
using Oceananigans.TurbulenceClosures: CATKEVerticalDiffusivity, implicit_diffusion_solver,
                                       VerticallyImplicitTimeDiscretization
using Oceananigans.TimeSteppers: implicit_step!, update_state!
using Random
using Test

arch = length(ARGS) > 0 && ARGS[1] == "gpu" ? (using CUDA; GPU()) : CPU()
@info "architecture: $arch"

# On the GPU, CATKE's own closure-field kernel trips an `llc` crash in this toolchain (unrelated to
# the solve), so there each field gets a distinct, spatially varying diffusivity from a
# VerticalScalarDiffusivity instead.
function check(arch, FT; catke = arch isa CPU)
    Random.seed!(1234)
    z = [-100 * (1 - (k / 16)^1.3) for k in 0:16]  # stretched
    grid = RectilinearGrid(arch, FT; size = (9, 7, 16), x = (0, 9e3), y = (0, 7e3), z,
                           topology = (Periodic, Bounded, Bounded))
    td = VerticallyImplicitTimeDiscretization()
    closure = catke ? CATKEVerticalDiffusivity() :
        VerticalScalarDiffusivity(td; ν = (x, y, z, t) -> 1e-2 * (1 + sin(x / 1e3)) * exp(z / 50),
                                  κ = (T = (x, y, z, t) -> 1e-3 * (2 + cos(y / 1e3)) * exp(z / 30),
                                       S = (x, y, z, t) -> 5e-3 * (1 + sin(x / 2e3)^2),
                                       c = (x, y, z, t) -> 2e-2 * exp(z / 80)))
    model = HydrostaticFreeSurfaceModel(grid; closure, tracers = (:T, :S, :c),
                                        buoyancy = SeawaterBuoyancy(), momentum_advection = nothing,
                                        tracer_advection = nothing)

    rnd(scale) = (x, y, z) -> scale * rand()
    set!(model; u = rnd(0.2), v = rnd(0.2), T = (x, y, z) -> 10 + 0.01z + 0.1rand(),
         S = (x, y, z) -> 35 + 0.1rand(), c = rnd(1))
    catke && set!(model; e = (x, y, z) -> 1e-4 + 1e-3rand())
    update_state!(model)

    Δt = FT(600)
    names = catke ? (:T, :S, :c, :e) : (:T, :S, :c)
    ids = ntuple(n -> Val(n), length(names))
    tracers = map(n -> model.tracers[n], names)
    reference = map(f -> deepcopy(f), (model.velocities.u, model.velocities.v, tracers...))
    batched   = map(f -> deepcopy(f), (model.velocities.u, model.velocities.v, tracers...))

    single_solver = implicit_diffusion_solver(VerticallyImplicitTimeDiscretization(), grid)
    multi_solver  = implicit_diffusion_solver(VerticallyImplicitTimeDiscretization(), grid; systems = 6)

    K = model.closure_fields
    flds = Oceananigans.fields(model)
    indices = (nothing, nothing, ids...)
    for (f, id) in zip(reference, indices)
        implicit_step!(f, single_solver, closure, K, id, model.clock, flds, Δt)
    end

    implicit_step!(batched, multi_solver, closure, K, indices, model.clock, flds, Δt,
                   ntuple(_ -> nothing, length(indices)), ntuple(_ -> nothing, length(indices)), ntuple(_ -> nothing, length(indices)))

    for (r, b, name) in zip(reference, batched, (:u, :v, names...))
        R = Array(interior(r)); B = Array(interior(b))
        @info "$FT $name: max |Δ| = $(maximum(abs, R .- B)), changed by the solve: $(maximum(abs, R .- Array(interior(name ∈ (:u, :v) ? model.velocities[name] : model.tracers[name]))))"
        @test R == B
    end

    # Too little scratch falls back to one solve per field, with the same result.
    fallback = map(f -> deepcopy(f), (model.velocities.u, model.velocities.v, tracers...))
    implicit_step!(fallback, single_solver, closure, K, indices, model.clock, flds, Δt,
                   ntuple(_ -> nothing, length(indices)), ntuple(_ -> nothing, length(indices)), ntuple(_ -> nothing, length(indices)))
    for (r, b) in zip(reference, fallback)
        @test Array(interior(r)) == Array(interior(b))
    end
end

@testset "multi-field implicit_step! on $arch" begin
    check(arch, Float64)
    check(arch, Float32)
end
