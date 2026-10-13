# Case configuration shared by the predownload, visualization, and downscaling scripts.
#
# The December 2025 Pacific Northwest atmospheric-river family: an AR 4 (locally
# forecast AR 5) made landfall over Washington and Oregon early on December 8, a second
# pulse arrived late December 9, and AR conditions persisted ~96 hours — record crests
# on the Skagit, Snohomish, and Cedar rivers and >250 mm over the Olympics and Cascades.

using Dates: DateTime, Hour

# Simulation window: the first landfall plus the second pulse of the Dec 8–12 AR.
# Override the duration with AR_HOURS (e.g. AR_HOURS=96 to reach the event's full tail).
start_date = DateTime(get(ENV, "AR_START", "2025-12-07T12:00:00"))
event_hours = parse(Int, get(ENV, "AR_HOURS", "72"))
stop_date = start_date + Hour(event_hours)
dates = (start_date, stop_date)

# Child domain presets: `corridor` (default) spans the moisture corridor from east of
# Hawaii to the coast, the Gulf of Alaska parent low, and every landfall from BC to
# Northern California; `landfall` is the compact box for single-GPU convection-permitting
# runs — the AR's final approach plus the Pacific Northwest terrain. Both stay east of
# the dateline so one ERA5 subregion request covers the parent.
domain_presets = (corridor = ((-170, -110), (25, 60)),
                  landfall = ((-148, -112), (38, 56)))
longitude, latitude = domain_presets[Symbol(get(ENV, "AR_DOMAIN", "corridor"))]

# `AR_DOMAIN_BOX="λ₁:λ₂:φ₁:φ₂"` (or commas) overrides the preset with an arbitrary box (degrees), e.g. a reduced
# nest around the coastal-flux plane so a 6 km reverse sweep fits on one 80 GB GPU.
if haskey(ENV, "AR_DOMAIN_BOX")
    let b = parse.(Float64, split(ENV["AR_DOMAIN_BOX"], [',', ':']))  # colons survive sbatch --export
        global longitude, latitude = (b[1], b[2]), (b[3], b[4])
    end
end

# The northern corridor edge cuts through the steep BC-coast terrain that seeds the
# frame cold-point instability at (-129.7, 59.8); AR_LAT_NORTH trims it out (the AR
# landfalls all sit south of 56).
latitude = (latitude[1], parse(Float64, get(ENV, "AR_LAT_NORTH", string(latitude[2]))))

# ~12 km grid spacing by default (2.25× refinement over ERA5's native 0.25°);
# AR_CELLS_PER_DEGREE=36 gives the ~3 km convection-permitting configuration.
Δ = 1 / parse(Float64, get(ENV, "AR_CELLS_PER_DEGREE", "9"))
Nx = round(Int, (longitude[2] - longitude[1]) / Δ)
Ny = round(Int, (latitude[2] - latitude[1]) / Δ)

era5_datadir = joinpath(@__DIR__, "era5")

# Wide North Pacific view for the ERA5 visualization (single-level IVT + MSLP),
# kept east of the dateline so one ERA5 subregion request covers it.
wide_region = BoundingBox(longitude = (-180, -110), latitude = (20, 62))
viz_dates = DateTime(2025, 12, 6):Hour(3):DateTime(2025, 12, 20)

# Landfall precipitation box over the Dec 8–12 core; hourly, since ERA5's
# total_precipitation is accumulated over each hour.
precip_region = BoundingBox(longitude = (-130, -115), latitude = (40, 52))
precip_dates = DateTime(2025, 12, 7):Hour(1):DateTime(2025, 12, 12)
