using CairoMakie, JSON3, TOML, Dates, Test
include("goes_data.jl")
using .GOESData

const FFMPEG = CairoMakie.Makie.FFMPEG_jll
output = get(ENV,"AR_GOES_OUTPUT",joinpath(@__DIR__,"output"))

for mode in (:water_vapor,:visible)
    config = movie_config(mode)
    movie = joinpath(output,config.stem * ".mp4")
    manifest = TOML.parsefile(joinpath(output,config.stem * "_provenance.toml"))
    probe = JSON3.read(read(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -count_frames -show_entries stream=width,height,nb_read_frames,r_frame_rate,duration -of json $movie`,String)).streams[1]
    @testset "$mode encoded movie" begin
        @test probe.width == 3840
        @test probe.height == 2160
        @test parse(Int,probe.nb_read_frames) == manifest["frames"]
        @test probe.r_frame_rate == "$(manifest["fps"])/1"
        @test parse(Float64,probe.duration) ≈ manifest["frames"]/manifest["fps"] atol=0.01
        @test manifest["actual_scans"] == length(manifest["scans"])
        @test manifest["actual_scans"] + length(manifest["missing_scan_slots"]) == manifest["frames"]
        @test !manifest["temporal_interpolation"]
        expected = collect(config.start:Minute(config.cadence):config.stop-Minute(config.cadence))
        actual = floor.([DateTime(replace(s["scan_start"],"Z"=>"")) for s in manifest["scans"]],Minute(config.cadence))
        @test sort(vcat(actual,DateTime.(manifest["missing_scan_slots"]))) == expected
        @test length(unique(actual)) == length(actual)
        @test all(s -> startswith(s["url"],GOESData.BUCKET * config.product),manifest["scans"])
        @test all(s -> occursin(r"^[a-f0-9]{64}$",s["original_sha256"]),manifest["scans"])
        @test success(pipeline(`$(FFMPEG.ffmpeg()) -v error -xerror -threads 4 -i $movie -f null -`;stdout=devnull))
    end
end
