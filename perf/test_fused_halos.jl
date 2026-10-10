# Bitwise check of fused tuple halo filling (Oceananigans `Fields.FUSED_HALO_FILLING`) against the
# per-field path, on CPU and (if available) GPU, for a mix of boundary conditions including a
# field-reading discrete BC (a barrier) and Face-located normal-flow fields.
#
#   julia --project=<env with the opt/halo-fusion Oceananigans> perf/test_fused_halos.jl

using Oceananigans
using Oceananigans.BoundaryConditions: fill_halo_regions!
using Oceananigans.Fields: FUSED_HALO_FILLING
using Oceananigans.Architectures: on_architecture
using Oceananigans.BoundaryConditions: regularize_field_boundary_conditions
using Random
using Test

archs = Any[CPU()]
try
    @eval using CUDA
    CUDA.functional() && push!(archs, GPU())
catch
end

@inline reads_u(i, j, grid, clock, fields) = @inbounds fields.u[i, j, 0] + fields.u[i+1, j, 0]

function build(arch)
    grid = LatitudeLongitudeGrid(arch; size=(20, 13, 7), halo=(3, 3, 3), longitude=(0, 20), latitude=(10, 23), z=(0, 1000))
    Nx, Ny, Nz = size(grid)
    west_values = on_architecture(arch, rand(Ny, Nz))
    c_bcs = FieldBoundaryConditions(west=ValueBoundaryCondition(west_values), east=GradientBoundaryCondition(0.1),
                                    south=FluxBoundaryCondition(nothing), north=ValueBoundaryCondition(2),
                                    bottom=FluxBoundaryCondition(1), top=ValueBoundaryCondition(0))
    u_bcs = FieldBoundaryConditions(west=NormalFlowBoundaryCondition(1.0), east=NormalFlowBoundaryCondition(2.0),
                                    bottom=FluxBoundaryCondition(0.5))
    v_bcs = FieldBoundaryConditions(south=NormalFlowBoundaryCondition(0.3), north=NormalFlowBoundaryCondition(-0.3))
    w_bcs = FieldBoundaryConditions(bottom=NormalFlowBoundaryCondition(reads_u; discrete_form=true))
    reg(bcs, loc) = regularize_field_boundary_conditions(bcs, grid, loc)
    ccc = (Center(), Center(), Center())
    c = CenterField(grid; boundary_conditions=reg(c_bcs, ccc))
    d = CenterField(grid)
    u = XFaceField(grid; boundary_conditions=reg(u_bcs, (Face(), Center(), Center())))
    v = YFaceField(grid; boundary_conditions=reg(v_bcs, (Center(), Face(), Center())))
    w = ZFaceField(grid; boundary_conditions=reg(w_bcs, (Center(), Center(), Face())))
    e = CenterField(grid; boundary_conditions=reg(c_bcs, ccc))
    ud = XFaceField(grid); vd = YFaceField(grid); wd = ZFaceField(grid)
    return grid, (; c, d, u, v, w, e, ud, vd, wd)
end

function randomize!(fields, seed)
    rng = Xoshiro(seed)
    for f in fields
        a = rand(rng, size(parent(f))...)
        copyto!(parent(f), a)
    end
end

snapshot(fields) = map(f -> Array(parent(f)), fields)

for arch in archs
    @testset "fused halo filling on $arch" begin
        grid, fields = build(arch)
        clock = Clock(time=0.0)
        for (label, tup) in (("all", fields), ("no barrier", (fields.c, fields.d, fields.u, fields.v, fields.e)),
                             ("barrier first", (fields.w, fields.c, fields.u)), ("nested", ((fields.c, fields.d), (; u=fields.u, v=fields.v))),
                             ("mixed locations, default BCs", (fields.ud, fields.vd, fields.wd, fields.d)))
            for kw in ((;), (; fill_normal_flow_bcs=false))
                randomize!(fields, 42)
                FUSED_HALO_FILLING[] = false
                fill_halo_regions!(tup, clock, fields; kw...)
                reference = snapshot(fields)

                randomize!(fields, 42)
                FUSED_HALO_FILLING[] = true
                fill_halo_regions!(tup, clock, fields; kw...)
                fused = snapshot(fields)

                @test all(map(==, reference, fused))
                census = []
                Oceananigans.BoundaryConditions.HALO_CENSUS[] = census
                fill_halo_regions!(tup, clock, fields; kw...)
                Oceananigans.BoundaryConditions.HALO_CENSUS[] = nothing
                @info "$arch $label $kw: per-field fills left when fused = $(length(census))"
                @info "$arch $label $kw: identical = $(all(map(==, reference, fused)))"
            end
        end
    end
end
