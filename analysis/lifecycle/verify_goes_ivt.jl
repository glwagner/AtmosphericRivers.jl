using CairoMakie, JSON3, TOML, Dates, Test
const FFMPEG = CairoMakie.Makie.FFMPEG_jll
output = get(ENV,"AR_GOES_OUTPUT",joinpath(@__DIR__,"output"))
style = get(ENV,"AR_IVT_STYLE","shaded")
style in ("shaded","outline") || error("Unknown IVT style")
stem = "goes18_water_vapor_ivt250" * (style == "shaded" ? "_shaded" : "")
movie = joinpath(output,stem * ".mp4")
manifest = TOML.parsefile(joinpath(output,stem * "_provenance.toml"))
original = TOML.parsefile(joinpath(output,"goes18_water_vapor_provenance.toml"))
probe = JSON3.read(read(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -count_frames -show_entries stream=codec_name,pix_fmt,width,height,nb_read_frames,r_frame_rate,duration -of json $movie`,String)).streams[1]

@testset "Separate IVT-overlay movie" begin
    @test probe.width == 3840
    @test probe.height == 2160
    @test probe.codec_name == "h264"
    @test probe.pix_fmt == "yuv420p"
    @test parse(Int,probe.nb_read_frames) == manifest["frames"] == 864
    @test probe.r_frame_rate == "12/1"
    @test parse(Float64,probe.duration) ≈ 72 atol=0.01
    for key in ("scans","frames","fps","actual_scans","missing_scan_slots","scan_bounds_radians","source_pixel_dimensions","display")
        @test manifest[key] == original[key]
    end
    @test manifest["temporal_interpolation"]
    @test manifest["ivt_temporal_interpolation"]
    @test !manifest["satellite_temporal_interpolation"]
    ivt = manifest["ivt_overlay"]
    @test ivt["threshold_kg_m-1_s-1"] == 250
    @test ivt["grid_degrees"] == 0.25
    @test ivt["cadence_minutes"] == 60
    @test ivt["style"]["fill"] == (style == "shaded")
    if style == "shaded"
        @test ivt["style"]["fill_opacity"] == 0.10
        @test ivt["style"]["line_width_figure_pixels"] == 2.5
    end
    @test ivt["latitude_bounds_degrees_north"] == [15,65]
    @test ivt["longitude_bounds_degrees_east"] == [140,250]
    @test length(ivt["files"]) == 7
    @test all(f->occursin(r"^[a-f0-9]{64}$",f["sha256"]),ivt["files"])
    @test DateTime(ivt["first_analysis"]) <= DateTime(replace(first(manifest["scans"])["scan_start"],"Z"=>""))
    @test DateTime(ivt["last_analysis"]) >= DateTime(replace(last(manifest["scans"])["scan_start"],"Z"=>""))
    @test success(pipeline(`$(FFMPEG.ffmpeg()) -v error -xerror -threads 4 -i $movie -f null -`;stdout=devnull))
end
