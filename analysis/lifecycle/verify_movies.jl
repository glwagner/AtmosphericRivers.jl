# Verify the encoded products, including a complete decode of both streams.
using CairoMakie, JSON3, Test
const FFMPEG = CairoMakie.Makie.FFMPEG_jll

function verify_movie(path; width, height, frames, fps=8)
    result = JSON3.read(read(`$(FFMPEG.ffprobe()) -v error -select_streams v:0 -show_entries stream=codec_name,profile,width,height,pix_fmt,nb_frames,r_frame_rate,duration -of json $path`, String))
    stream = only(result.streams)
    @testset "$(basename(path))" begin
        @test stream.codec_name == "h264"
        @test stream.pix_fmt == "yuv420p"
        @test stream.width == width
        @test stream.height == height
        @test parse(Int,stream.nb_frames) == frames
        @test stream.r_frame_rate == "$fps/1"
        @test parse(Float64,stream.duration) ≈ frames/fps atol=0.001
        # -xerror makes any decoder error fail the process.
        @test success(`$(FFMPEG.ffmpeg()) -v error -xerror -i $path -f null -`)
    end
    println(basename(path), ": ", stream)
end

if abspath(PROGRAM_FILE) == @__FILE__
    directory = get(ENV,"AR_LIFECYCLE_OUTPUT",joinpath(@__DIR__,"output"))
    fps = parse(Int,get(ENV,"AR_FPS","8"))
    verify_movie(joinpath(directory,"ar_lifecycle.mp4");width=3840,height=2160,frames=479,fps)
    detailed = joinpath(directory,"ar_landfall_3km.mp4")
    isfile(detailed) && verify_movie(detailed;width=3200,height=2400,frames=145,fps)
end
