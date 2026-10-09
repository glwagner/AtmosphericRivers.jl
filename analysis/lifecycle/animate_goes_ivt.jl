# julia --project=analysis/lifecycle analysis/lifecycle/animate_goes_ivt.jl
# Always writes a separate *_ivt250 movie, preview, and provenance.
using NCDatasets
include("animate_goes.jl")
include("ivt_outline.jl")

if abspath(PROGRAM_FILE) == @__FILE__
    animate_goes(:water_vapor;overlay=make_ivt_overlay())
end
