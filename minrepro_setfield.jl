# # Two `set!` bugs in Oceananigans' Reactant extension
#
# Both are hit by any code that initializes a Reactant model from fields at a DIFFERENT staggered
# location than the destination — e.g. Breeze's `set_velocity!`, which does
#
#     set!(u, value)          # value is Center-located, u is Face-located
#     set!(ρu, ρ * u)         # ρ is Center-located, ρu is Face-located
#
# Neither needs a nested model, ERA5 data, or `@compile`: both fire during eager construction.
#
# Run:
#     AR_BACKEND=cpu julia --project -t auto minrepro_setfield.jl     # rung A only
#     AR_BACKEND=gpu julia --project -t auto minrepro_setfield.jl     # rungs A and B
#
# `AR_FIX=1` installs the two shims (as in `reactant_downscale.jl`) so the same script shows the fix.
#
# ## Rung A — `conversion to pointer not defined for ConcretePJRTArray`
#
# `set!(u::Field, v::Field)` → `set_to_field!`. Locations differ, so the extension takes its CPU
# interpolation fallback (`interpolate!`'s KA kernel does not trace), which stages the source on the
# host with `copyto!(interior(cpu_v), interior(v))`. That is a SubArray←SubArray copy whose source is
# device-backed, so Base's `copyto!` calls `unalias`/`mightalias`, reaching
#
#     _parentsmatch(A::DenseArray, B::DenseArray) = elsize(A) == elsize(B) && pointer(A) == pointer(B) && …
#
# and `ConcretePJRTArray <: DenseArray`, so it asks a PJRT buffer for a host pointer.
#
# NOTE this reproduces on the CPU backend too — the buffer is host-resident there, but `pointer` is
# still not defined for it. Only the DIRECTION is broken: the mirror-image write in
# `set_to_function!` (`copyto!(interior(u), interior(cpu_u))`, host source, device destination) is
# what every `set!(field, func)` already does, so Reactant specializes writes INTO a device SubArray
# but leaves reads OUT of one to Base's generic path.
#
# Fix: transfer the whole parent (`Array(parent(v))`) instead of a SubArray view — no aliasing check,
# no element loop, and it carries the halos along, which is strictly more than `interpolate!` had.
#
# ## Rung B — `InvalidIRError` broadcasting an `AbstractOperation` (GPU only)
#
# `set!(u::Field, v)` falls back to `u .= v`. For an `AbstractOperation` that launches
# `gpu__broadcast_kernel!` over a `BinaryOperation` whose grid has been retyped to
# `CuTracedRNumber{Float32}` — the usual "KA kernel + materialized grid coordinates" wall.
#
# Fix: `on_architecture` is defined for every operation node (binary, unary, multiary,
# kernel-function, derivative, conditional) and for `Field`, so the whole tree — operands,
# interpolation operators and grid — can be rebuilt on the CPU and evaluated by Oceananigans' own
# code. That keeps `ℑxᶠᵃᵃ` exactly as upstream defines it instead of hand-rolling the stencil.

using Reactant
using Oceananigans
using Oceananigans.Architectures: ReactantState, on_architecture, CPU
using Oceananigans.Fields: interior, interpolate!
using Printf

Oceananigans.defaults.FloatType = Float32

backend = get(ENV, "AR_BACKEND", "cpu")
if backend == "gpu"
    Reactant.set_default_backend("gpu")
end
apply_fix = get(ENV, "AR_FIX", "0") == "1"

const ReactantFieldsExt = Base.get_extension(Oceananigans, :OceananigansReactantExt).Fields

if apply_fix
    ## Shim 6: whole-parent device→host transfer, replacing the SubArray copy. This is the ONLY
    ## changed line; the interpolate! and the write-back are upstream's.
    @eval ReactantFieldsExt function set_to_field!(u::ReactantField, v::ReactantField)
        if broadcast_compatible(u, v)
            interior(u) .= interior(v)
        else
            cpu_grid_u = on_architecture(CPU(), u.grid)
            cpu_grid_v = on_architecture(CPU(), v.grid)
            cpu_u = Field(Oceananigans.Fields.instantiated_location(u), cpu_grid_u;
                          indices=Oceananigans.Fields.indices(u))
            cpu_v = Field(Oceananigans.Fields.instantiated_location(v), cpu_grid_v;
                          indices=Oceananigans.Fields.indices(v))
            copyto!(parent(cpu_v), Array(parent(v)))
            ## The generic `set_to_field!` fills v's halos before interpolating (they are read by the
            ## boundary-adjacent stencils); the Reactant extension skipped that, interpolating from
            ## halos left at zero. Fill them on the CPU twin — same result as upstream for
            ## non-distributed boundary conditions, and no device kernel.
            Oceananigans.BoundaryConditions.fill_halo_regions!(cpu_v)
            interpolate!(cpu_u, cpu_v)
            copyto!(interior(u), interior(cpu_u))
        end
        return u
    end

    ## Shim 7: evaluate an operation-valued `set!` on a CPU twin of the whole tree.
    @eval ReactantFieldsExt function Oceananigans.Fields.set!(u::ReactantField,
                                                             v::Oceananigans.AbstractOperations.AbstractOperation)
        cpu_grid = on_architecture(CPU(), u.grid)
        cpu_u = Field(Oceananigans.Fields.instantiated_location(u), cpu_grid;
                      indices=Oceananigans.Fields.indices(u))
        cpu_v = on_architecture(CPU(), v)
        cpu_u .= cpu_v
        copyto!(interior(u), interior(cpu_u))
        return u
    end
end

# A `LatitudeLongitudeGrid` is the point: it carries materialized coordinate arrays, which is what
# makes tracing retype the grid's `FT` and break the KA kernels. A uniform `RectilinearGrid` would
# not reproduce rung B.
grid = LatitudeLongitudeGrid(ReactantState(), Float32;
                             size = (16, 12, 8),
                             longitude = (-140, -120),
                             latitude = (40, 52),
                             z = (0, 8000),
                             halo = (3, 3, 3),
                             topology = (Bounded, Bounded, Bounded))

@info "grid: $(summary(grid))  [backend=$backend, fix=$(apply_fix ? "on" : "off")]"

function attempt(name, f)
    try
        f()
        @info "$name: OK"
        return true
    catch err
        msg = sprint(showerror, err)
        @warn "$name: FAILED\n$(first(msg, 400))"
        return false
    end
end

# ### Rung A: Center → Face `set!`, the copy direction that is not specialized
ρ = CenterField(grid)
u_center = CenterField(grid)

## Deliberately NON-uniform in x: with a constant ρ every averaging stencil gives the same answer, so
## a uniform field would let a wrong `ℑxᶠᵃᵃ` pass the value check below.
ramp(P) = Float32[1 + i / 10 + j / 100 + k / 1000 for i in 1:P[1], j in 1:P[2], k in 1:P[3]]
ρ_host = ramp(size(parent(ρ)))
u_host = ramp(size(parent(u_center)))
copyto!(parent(ρ), ρ_host)
copyto!(parent(u_center), u_host)

u_face = XFaceField(grid)
a_ok = attempt("rung A  set!(XFaceField, CenterField)", () -> set!(u_face, u_center))

# ### Rung B: an operation with a real interpolation in it
ρu = XFaceField(grid)
b_ok = attempt("rung B  set!(XFaceField, ρ * u_face)", () -> set!(ρu, ρ * u_face))

# Check the ANSWER, not just that it ran. The reference is vanilla Oceananigans on a CPU grid with
# the same data and the same expression — no Reactant anywhere in it — so this tests that the shims
# reproduce upstream's `ℑxᶠᵃᵃ` rather than merely producing some number.
if a_ok && b_ok
    cpu_grid = LatitudeLongitudeGrid(CPU(), Float32;
                                     size = (16, 12, 8),
                                     longitude = (-140, -120),
                                     latitude = (40, 52),
                                     z = (0, 8000),
                                     halo = (3, 3, 3),
                                     topology = (Bounded, Bounded, Bounded))
    cpu_ρ = CenterField(cpu_grid)
    cpu_uc = CenterField(cpu_grid)
    copyto!(parent(cpu_ρ), ρ_host)
    copyto!(parent(cpu_uc), u_host)

    cpu_uf = XFaceField(cpu_grid)
    set!(cpu_uf, cpu_uc)          ## rung A's reference
    cpu_ρu = XFaceField(cpu_grid)
    set!(cpu_ρu, cpu_ρ * cpu_uf)  ## rung B's reference

    for (label, device_field, reference) in (("rung A  u_face", u_face, cpu_uf),
                                             ("rung B  ρu    ", ρu, cpu_ρu))
        got = Array(parent(device_field))[parentindices(interior(device_field))...]
        want = Array(interior(reference))
        δ = maximum(abs.(got .- want))
        @info @sprintf("%s vs CPU Oceananigans: max|Δ| = %.3g over %d cells — %s",
                       label, δ, length(want), δ <= 1f-6 * maximum(abs.(want)) ? "MATCH" : "MISMATCH")
    end
end

@info "summary: rung A $(a_ok ? "ok" : "failed"), rung B $(b_ok ? "ok" : "failed")"
