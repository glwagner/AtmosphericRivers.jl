# julia --project=analysis/lifecycle analysis/lifecycle/download_goes.jl [water_vapor|visible]
include("goes_data.jl")
using .GOESData
for mode in (isempty(ARGS) ? [:water_vapor,:visible] : Symbol.(ARGS))
    download_goes(mode)
end
