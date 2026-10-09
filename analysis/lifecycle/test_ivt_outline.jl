using Test
include("animate_goes_ivt.jl")

@testset "ERA5 time alignment and vector interpolation" begin
    times = collect(DateTime(2025,12,6):Hour(1):DateTime(2025,12,6,2))
    @test ivt_bracket(times,first(times)) == (1,2,0.0)
    @test ivt_bracket(times,times[2]) == (2,3,0.0)
    @test ivt_bracket(times,last(times)) == (2,3,1.0)
    @test ivt_bracket(times,times[1]+Minute(30)+Second(30)) == (1,2,0.5083333333333333)
    @test_throws ErrorException ivt_bracket(times,first(times)-Second(1))
    @test_throws ErrorException ivt_bracket(times,last(times)+Second(1))
    @test_throws ErrorException ivt_bracket(times[[1,3]],times[2])
    series = (dates=times,east=reshape(Float32[300,-300,300],1,1,3),north=zeros(Float32,1,1,3))
    # Interpolating magnitudes or contour positions would wrongly retain 300.
    @test only(interpolated_ivt(series,times[1]+Minute(30)).ivt) == 0
    @test only(interpolated_ivt(series,times[1]).ivt) == 300
    @test only(interpolated_ivt(series,last(times)).ivt) == 300
    series = (dates=times,east=fill(300f0,1,1,3),north=reshape(Float32[-400,400,400],1,1,3))
    @test only(interpolated_ivt(series,times[1]).ivt) == 500
    @test only(interpolated_ivt(series,times[1]+Minute(30)).ivt) == 300
end

@testset "High-side shading, holes, and satellite limb" begin
    projection = Dict("semi_major_axis"=>6378137.0,"semi_minor_axis"=>6356752.31414,
        "perspective_point_height"=>35786023.0,"longitude_of_projection_origin"=>-137.0)
    for (lon,lat) in [(-170.,30.),(-150.,60.),(-122.33,47.61)]
        x,y = scan_position(lon,lat,projection)
        λ,φ = ivt_geographic_position(x,y,projection)
        @test λ ≈ lon atol=1e-8
        @test φ ≈ lat atol=1e-8
    end
    @test all(isnan,ivt_geographic_position(0.15,0.15,projection))
    lon,lat = [200.,201.,202.],[30.,31.,32.]
    @test isnothing(ivt_bilinear_location(lon,lat,199.,31.))
    @test isnothing(ivt_bilinear_location(lon,lat,201.,33.))
    cells = [ivt_bilinear_location(lon,lat,λ,φ) for (λ,φ) in [(200.,30.),(201.,31.),(200.5,31.)]]
    lookup = (pixels=Int32[1,2,3],indices=Int32[c.index for c in cells],
              u=Float32[c.u for c in cells],v=Float32[c.v for c in cells],nx=3)
    field = fill(400.,3,3); field[2,2] = 100
    transparent,tint = RGBAf(0,0,0,0),RGBAf(colorant"#f2ce78",0.10)
    pixels = fill(transparent,3,1)
    shade_ivt!(pixels,lookup,field,250,tint)
    @test pixels[1] == tint
    @test pixels[2] == transparent # Low-IVT hole inside a surrounding high region.
    @test pixels[3] == tint # Exactly on the threshold is included.
    shade_ivt!(pixels,lookup,fill(100.,3,3),250,tint)
    @test all(==(transparent),pixels) # No stale shading after the boundary moves.
end

@testset "Threshold geometry and disconnected features" begin
    x,y = collect(-4.0:0.025:4.0),collect(-2.0:0.025:2.0)
    field = [500max(exp(-((λ-2)^2+φ^2)/0.5),exp(-((λ+2)^2+φ^2)/0.5)) for λ in x, φ in y]
    project(λ,φ) = (λ+10,2φ)
    points = projected_ivt_outline(x,y,field,250,project)
    @test count(p->all(isnan,p),points) == 2
    finite = filter(p->all(isfinite,p),points)
    @test !isempty(finite)
    radius = sqrt(log(2)/2)
    for p in finite
        λ,φ = p[1]-10,p[2]/2
        @test min(hypot(λ-2,φ),hypot(λ+2,φ)) ≈ radius atol=0.002
    end
    @test isempty(projected_ivt_outline(x,y,fill(100.0,size(field)),250,project))
    @test isempty(projected_ivt_outline(x,y,fill(500.0,size(field)),250,project))
    # A crossing that reaches the data boundary stays open, with no fake closure.
    ramp = [250+λ for λ in x,φ in y]
    line = filter(p->all(isfinite,p),projected_ivt_outline(x,y,ramp,250,(λ,φ)->(λ,φ)))
    @test all(p->abs(p[1])<1e-6,line)
    @test abs(first(line)[2]-last(line)[2]) ≈ 4
    @test_throws ErrorException projected_ivt_outline(x,y,fill(NaN,size(field)),250,project)
end
