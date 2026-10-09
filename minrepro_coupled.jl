# # Coupling a nested atmosphere to an ocean fails under Reactant: `Field(Integral(...))`
#
# `AtmosphereOceanModel(Simulation(nest), ocean)` cannot be built on `ReactantState`. On a
# NumericalEarth WITHOUT the `NestedModel` → child forwards it dies early with a `MethodError`
# (`thermodynamics_parameters`); on one that HAS them (`glw/cleanup`) it gets as far as the
# `ComponentExchanger`, which asks Breeze for `surface_precipitation_flux`:
#
#     function AtmosphereModels.surface_precipitation_flux(model, ::IP)
#         P = model.microphysical_fields.precipitation_rate
#         return Field(Integral(P, dims=3))          # <-- eagerly `compute!`s
#     end
#
# and that is where it stops:
#
#     InvalidIRError: compiling MethodInstance for Oceananigans.AbstractOperations.gpu__compute!(
#         ::KernelAbstractions.CompilerMetadata{Oceananigans.Utils.OffsetStaticSize{(1:36, 1:18, 1:1)}…
#     Reason: unsupported call to an unknown function (call to jl_f_throw_methoderror)
#
# The `(1:36, 1:18, 1:1)` launch range is the giveaway: `Nx × Ny × 1`, the shape of a `dims = 3`
# reduction over the child's columns. Nothing about coupling, precipitation, or nesting is required
# to reproduce it — only a reduction `Field` on a `LatitudeLongitudeGrid` under Reactant.
#
# `Field(::Reduction)` computes at CONSTRUCTION, so the failure happens during model assembly rather
# than at a `compute!` the caller can see and defer. That is why `reactant_downscale.jl` can only
# catch it and fall back to stepping the bare nest (no Monin–Obukhov surface fluxes).
#
# Run (the GPU backend is where this bites; the CPU backend is included so the difference is visible):
#     AR_BACKEND=gpu julia --project -t auto minrepro_coupled.jl
#     AR_BACKEND=cpu julia --project -t auto minrepro_coupled.jl
#
# ## What varies
#
# Three rungs isolate the trigger. The grid TYPE is the discriminating variable — the same reduction
# on a `RectilinearGrid` compiles, which is why Oceananigans' and Breeze's own Reactant tests (all on
# rectilinear grids) never hit this. A `LatitudeLongitudeGrid` carries materialized coordinate and
# metric arrays, and tracing retypes its `FT` to `CuTracedRNumber{Float32}`; the KA kernel then
# contains a call the GPU compiler cannot resolve and lowers to `jl_f_throw_methoderror`.

using Reactant
## Required even though nothing here calls CUDA.jl directly: Reactant's KA raising path lives in its
## CUDA extension, on ANY backend.
using CUDA
using Oceananigans
using Oceananigans.Architectures: ReactantState, CPU, on_architecture
using Oceananigans.AbstractOperations: Integral
using Breeze: materialize_terrain!
using Breeze.TerrainFollowingDiscretization: TerrainFollowingVerticalDiscretization, LinearDecay

## Shim 1 from `reactant_downscale.jl`, verbatim: `on_architecture(ReactantState(), grid)` walks a
## `LatitudeLongitudeGrid`'s fields through this private `_to_reactant`, which upstream knows about
## arrays and the STATIC vertical only — so a terrain-following vertical cannot be moved to Reactant
## without it. Needed here because rung D's whole point is that the vertical is terrain-following.
const ReactantArchitecturesExt = Base.get_extension(Oceananigans, :OceananigansReactantExt).Architectures

ReactantArchitecturesExt._to_reactant(f::LinearDecay) =
    LinearDecay(f.z_top,
                ReactantArchitecturesExt._to_reactant(f.h),
                ReactantArchitecturesExt._to_reactant(f.∂x_h),
                ReactantArchitecturesExt._to_reactant(f.∂y_h))

ReactantArchitecturesExt._to_reactant(z::TerrainFollowingVerticalDiscretization) =
    TerrainFollowingVerticalDiscretization(ReactantArchitecturesExt._to_reactant(z.cᵃᵃᶠ),
                                           ReactantArchitecturesExt._to_reactant(z.cᵃᵃᶜ),
                                           ReactantArchitecturesExt._to_reactant(z.Δᵃᵃᶠ),
                                           ReactantArchitecturesExt._to_reactant(z.Δᵃᵃᶜ),
                                           ReactantArchitecturesExt._to_reactant(z.formulation))

Oceananigans.defaults.FloatType = Float32

backend = get(ENV, "AR_BACKEND", "gpu")
backend == "gpu" && Reactant.set_default_backend("gpu")
@info "backend = $backend"

const N = (8, 6, 4)

function attempt(name, f)
    try
        value = f()
        @info "$name: OK"
        return value
    catch err
        msg = sprint(showerror, err)
        ## `InvalidIRError` lives in GPUCompiler, which is not a direct dependency here, so it is
        ## identified by type NAME rather than by `isa` (same approach as reactant_downscale.jl).
        @warn "$name: FAILED [$(nameof(typeof(err)))]\n$(first(msg, 600))"
        return nothing
    end
end

# ### Rung A — the failing case: a reduction Field on a LatitudeLongitudeGrid, on ReactantState
llg = LatitudeLongitudeGrid(ReactantState(), Float32;
                            size = N, longitude = (-140, -120), latitude = (40, 52),
                            z = (0, 8000), topology = (Bounded, Bounded, Bounded))
c_llg = CenterField(llg)
copyto!(parent(c_llg), fill(2.0f0, size(parent(c_llg))))

a = attempt("rung A  Field(Integral(c, dims=3)) on LatitudeLongitudeGrid + ReactantState",
            () -> Field(Integral(c_llg, dims = 3)))

# ### Rung B — same reduction, RectilinearGrid: the grid type is the variable
rg = RectilinearGrid(ReactantState(), Float32;
                     size = N, x = (0, 1), y = (0, 1), z = (0, 1),
                     topology = (Bounded, Bounded, Bounded))
c_rg = CenterField(rg)
copyto!(parent(c_rg), fill(2.0f0, size(parent(c_rg))))

b = attempt("rung B  Field(Integral(c, dims=3)) on RectilinearGrid + ReactantState",
            () -> Field(Integral(c_rg, dims = 3)))

# ### Rung C — the same LatitudeLongitudeGrid reduction on the CPU architecture (no Reactant)
cpu_llg = LatitudeLongitudeGrid(CPU(), Float32;
                                size = N, longitude = (-140, -120), latitude = (40, 52),
                                z = (0, 8000), topology = (Bounded, Bounded, Bounded))
c_cpu = CenterField(cpu_llg)
set!(c_cpu, 2)

c = attempt("rung C  Field(Integral(c, dims=3)) on LatitudeLongitudeGrid + CPU (no Reactant)",
            () -> Field(Integral(c_cpu, dims = 3)))

# Check the ANSWER where it computed: the column integral of a constant 2 over an 8000 m column is
# 16000, so a rung that "succeeds" with the wrong number is not a success.
if c !== nothing
    @info "rung C value: $(Array(interior(c))[1, 1, 1]) (expected 2 × 8000 = 16000)"
end
if b !== nothing
    @info "rung B value: $(Array(interior(b))[1, 1, 1]) (expected 2 × 1 = 2)"
end

# ### Rung D — the grid the real model actually uses: TERRAIN-FOLLOWING
#
# Rungs A-C establish that a plain `LatitudeLongitudeGrid` reduction is fine, so the trigger is
# something the real child grid has and rung A's does not. The candidate is the vertical: Breeze's
# `TerrainFollowingVerticalDiscretization` makes `Δz` depend on `(i, j)` through `LinearDecay`'s
# terrain arrays, so a `dims = 3` reduction has to index those arrays inside the kernel — with the
# grid's `FT` retyped to `CuTracedRNumber{Float32}` by tracing.
#
# The terrain is materialized on a CPU twin and the finished grid moved across, exactly as
# `reactant_downscale.jl` does (the slope kernels then run once, on the host).
z_faces = collect(range(0, 8000, length = N[3] + 1))
tf_host = LatitudeLongitudeGrid(CPU(), Float32;
                                size = N, longitude = (-140, -120), latitude = (40, 52),
                                z = TerrainFollowingVerticalDiscretization(z_faces),
                                halo = (5, 5, 5), topology = (Bounded, Bounded, Bounded))

## A bump, so the terrain is not trivially flat (flat terrain could let the compiler fold away the
## very indexing under suspicion).
materialize_terrain!(tf_host, (λ, φ) -> 400 * exp(-((λ + 130)^2 + (φ - 46)^2) / 8))

d = attempt("rung D  Field(Integral(c, dims=3)) on TERRAIN-FOLLOWING LLG + ReactantState",
            () -> begin
                tf = on_architecture(ReactantState(), tf_host)
                c_tf = CenterField(tf)
                copyto!(parent(c_tf), fill(2.0f0, size(parent(c_tf))))
                Field(Integral(c_tf, dims = 3))
            end)

# ## STATUS: this file does NOT yet reproduce the coupling error
#
# Measured on a GPU (jobs 4809, 4812):
#
#   rung A  plain LLG + Reactant        OK          <- so a bare reduction Field is NOT the trigger
#   rung B  Rectilinear + Reactant      ErrorException "Scalar indexing is disallowed"
#   rung C  plain LLG + CPU             OK (16000, correct)
#   rung D  terrain-following + Reactant MethodError: +(::Int64, ::TracedRArray{Float32, 2})
#
# The target is `InvalidIRError: … gpu__compute! … jl_f_throw_methoderror`, and NONE of these rungs
# produce it. Rungs B and D each hit a genuine, separate Reactant defect — B a scalar-indexing read
# during construction, D the same `+(::Int64, ::TracedRArray)` class that shim 10 in
# `reactant_downscale.jl` works around — so they are worth keeping, but they are not the coupling
# blocker and must not be reported as such.
#
# What is still untested, in the order I would try it: the real reduction is over
# `model.microphysical_fields.precipitation_rate` inside an assembled `AtmosphereModel`, reached
# through the `ComponentExchanger` during `AtmosphereOceanModel` construction — so the trigger may be
# the FIELD (a Breeze microphysics field, not a bare `CenterField`) or the surrounding model
# assembly, rather than the grid. Until one of those reproduces it, the only reliable reproducer of
# the actual coupling error is `AR_COUPLED=1` in `reactant_downscale.jl` itself.

@info "summary: rung A (plain LLG+Reactant) $(a === nothing ? "failed" : "ok"), " *
      "rung B (Rectilinear+Reactant) $(b === nothing ? "failed" : "ok"), " *
      "rung C (LLG+CPU) $(c === nothing ? "failed" : "ok"), " *
      "rung D (terrain-following+Reactant) $(d === nothing ? "failed" : "ok")"
@warn "NONE of these rungs produce the target `InvalidIRError` — see the STATUS note above; this \
       file isolates adjacent defects, not the coupling blocker yet"
