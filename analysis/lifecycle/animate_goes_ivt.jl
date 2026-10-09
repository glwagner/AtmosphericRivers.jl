# julia --project=analysis/lifecycle analysis/lifecycle/animate_goes_ivt.jl
# Writes *_ivt250_shaded. AR_IVT_STYLE=outline reproduces the earlier *_ivt250 version.
using NCDatasets
include("animate_goes.jl")
include("ivt_outline.jl")

if abspath(PROGRAM_FILE) == @__FILE__
    animate_goes(:water_vapor;overlay=make_ivt_overlay())
end
