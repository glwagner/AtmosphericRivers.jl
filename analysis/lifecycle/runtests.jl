using Test, Dates, NCDatasets, JLD2
include("data.jl")
using .LifecycleData

@testset "Transport magnitude and honest time alignment" begin
    @test ivt_magnitude([3.0,-3.0,0.0], [4.0,-4.0,0.0]) == [5.0,5.0,0.0]
    times = [DateTime(2025,12,8)+Hour(h) for h in 0:2]
    @test available_index(times,times[1]-Minute(1)) === nothing
    @test available_index(times,times[1]+Minute(30)) == 1
    @test available_index(times,times[2]) == 2
    @test available_index(times,times[end]+Minute(1)) === nothing
    @test available_index(DateTime[],times[1]) === nothing
end

@testset "Dateline continuity and prime-meridian seam" begin
    x,y = split_longitudes([(179,45),(-179,46),(-170,47)])
    @test x == [179,181,190]
    @test y == [45,46,47]
    x,y = split_longitudes([(-1,45),(1,46)])
    @test isequal(x,[359,NaN,1])
    @test isequal(y,[45,NaN,46])
end

data_dir = get(ENV,"AR_LIFECYCLE_DATA","")
if !isempty(data_dir)
    @testset "Actual ERA5 input validation" begin
        s = ERA5Series(data_dir)
        @test length(s.dates) == 240
        @test size(s.east) == (441,201,240)
        @test extrema(s.longitude) == (140,250)
        @test extrema(s.latitude) == (15,65)
        @test all(diff(s.longitude) .== 0.25)
        @test all(diff(s.latitude) .== 0.25)
        @test all(0 .<= s.iwv .< 100)
        @test all(85000 .< s.pressure .< 110000)
        f = era5_frame(s,133)
        @test f.ivt[10,10] ≈ hypot(s.east[10,10,133],s.north[10,10,133])
        @test 850 < f.pressure[10,10] < 1100
    end
end

model_path = get(ENV,"AR_LIFECYCLE_MODEL","")
if !isempty(model_path)
    @testset "Actual model coordinates, halo removal, and full time coverage" begin
        s = ModelSeries(model_path)
        try
            @test length(s.dates) == 145
            @test last(s.dates)-first(s.dates) == Hour(72)
            @test length(s.longitude) == 1296 && length(s.latitude) == 648
            @test first(s.longitude) ≈ 212 + 1/72 atol=2e-5
            @test first(s.latitude) ≈ 38 + 1/72 atol=2e-5
            for n in eachindex(s.dates)
                field = model_frame(s,n)
                @test size(field) == (1296,648)
                @test all(isnan,field[1:32,:])
                @test all(isfinite,field[33:end-32,33:end-32])
            end
            @test available_index(s.dates,last(s.dates)+Minute(30)) === nothing
        finally
            close(s)
        end
    end
end
