using Test, NCDatasets, Dates, SHA
include("animate_goes.jl")
using .GOESData

const P = Dict{String,Any}("semi_major_axis"=>6378137.0,"semi_minor_axis"=>6356752.31414,
    "perspective_point_height"=>35786023.0,"longitude_of_projection_origin"=>-137.0,
    "sweep_angle_axis"=>"x","grid_mapping_name"=>"geostationary")

# Independent inverse from NOAA's ABI navigation equations.
function inverse_scan(x,y,p)
    re,rp = p["semi_major_axis"],p["semi_minor_axis"]
    H = p["perspective_point_height"] + re
    a = sin(x)^2 + cos(x)^2*(cos(y)^2+(re/rp)^2*sin(y)^2)
    b,c = -2H*cos(x)*cos(y),H^2-re^2
    r = (-b-sqrt(b^2-4a*c))/(2a)
    sx,sy,sz = r*cos(x)*cos(y),-r*sin(x),r*cos(x)*sin(y)
    lat = atand((re/rp)^2*sz/hypot(H-sx,sy))
    lon = p["longitude_of_projection_origin"] - rad2deg(atan(sy,H-sx))
    lon,lat
end

@testset "Satellite pixels retain orientation and fixed enhancement" begin
    pixels = display_pixels((values=Float32[195 NaN;280 230],),:water_vapor)
    @test pixels[1,1] == RGBf(GOES_BACKGROUND)
    @test pixels[1,2] == first(WV_LOOKUP)
    @test pixels[2,2] == last(WV_LOOKUP)
    for t in 195f0:0.1f0:280f0
        k = clamp(round(Int,(t-195)*4095/85)+1,1,4096)
        @test abs(195+(k-1)*85/4095-t) <= 0.011
    end
    pixels = display_pixels((values=Float32[0 0.6;0.15 NaN],),:visible)
    @test pixels[1,1] == RGBf(1,1,1)
    @test pixels[1,2] == RGBf(0,0,0)
    @test pixels[2,1] == RGBf(GOES_BACKGROUND)
    @test pixels[2,2] == RGBf(0.5,0.5,0.5)
end

@testset "ABI geometry and timestamps" begin
    @test scan_position(-137,0,P) == (0.0,0.0)
    @test all(isnan,scan_position(43,0,P))
    for lon in (-175.,-150.,-122.33,-105.), lat in (20.,40.,47.61,60.)
        x,y = scan_position(lon,lat,P)
        λ,φ = inverse_scan(x,y,P)
        @test λ ≈ lon atol=1e-8
        @test φ ≈ lat atol=1e-8
    end
    key = "OR_ABI-L2-CMIPF-M6C09_G18_s20253420000224_e20253420009539_c20253420010000.nc"
    @test GOESData.key_time(key) == DateTime(2025,12,8,0,0,22,400)
    @test_throws ErrorException GOESData.key_time("invalid.nc")
    @test movie_config(:water_vapor).cadence == 10
    @test movie_config(:visible).cadence == 5
    @test_throws ErrorException movie_config(:other)
end

@testset "Packed satellite data survive cropping and QC" begin
    mktempdir() do dir
        raw,cache = joinpath(dir,"raw.nc"),joinpath(dir,"crop.nc")
        x = Float32.(-0.1:0.025:0.1)
        y = Float32.(0.15:-0.01:0.05)
        packed = reshape(Int16.(1:length(x)*length(y)),length(x),length(y))
        q = zeros(Int8,size(packed))
        q[5,5]=1; q[5,6]=2; q[5,7]=3; q[5,8]=4
        q[6,5]=-1; packed[6,6]=-1
        attrs = Dict("units"=>"K","scale_factor"=>0.25f0,"add_offset"=>200f0,
                     "_FillValue"=>Int16(-1),"_Unsigned"=>"true")
        NCDataset(raw,"c") do ds
            defDim(ds,"x",length(x)); defDim(ds,"y",length(y)); defDim(ds,"band",1)
            defVar(ds,"x",Float32,("x",))[:] = x
            defVar(ds,"y",Float32,("y",))[:] = y
            defVar(ds,"CMI",Int16,("x","y");attrib=attrs).var[:,:] = packed
            defVar(ds,"DQF",Int8,("x","y"))[:,:] = q
            defVar(ds,"band_id",Int32,("band",))[:] = [9]
            defVar(ds,"goes_imager_projection",Int32,();attrib=P)[] = 0
            ds.attrib["platform_ID"]="G18"
            ds.attrib["time_coverage_start"]="2025-12-08T00:00:22.4Z"
            ds.attrib["time_coverage_end"]="2025-12-08T00:09:53.9Z"
            ds.attrib["spatial_resolution"]="2km at nadir"
        end
        config = merge(movie_config(:water_vapor),(bounds=(-0.08,0.08,0.06,0.14),))
        GOESData.crop_scan(raw,cache,config,"test.nc")
        scan = read_scan(cache)
        ix = findall(v -> -0.08 <= v <= 0.08,x)
        iy = findall(v -> 0.06 <= v <= 0.14,y)
        @test scan.x == x[ix]
        @test scan.y == y[iy]
        @test scan.hash == bytes2hex(open(sha256,raw))
        @test scan.projection == P
        NCDataset(cache) do ds
            @test ds["CMI"].var[:,:] == packed[ix,iy]
            @test ds["DQF"][:,:] == q[ix,iy]
        end
        for (i,a) in enumerate(ix), (j,b) in enumerate(iy)
            if q[a,b] in (0,1) && packed[a,b] >= 0
                @test scan.values[i,j] == 200 + 0.25packed[a,b]
            else
                @test isnan(scan.values[i,j])
            end
        end
    end
end
