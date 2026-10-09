# Fetch every ERA5 file the visualization and downscaling scripts need — run on a cheap
# CPU node (slurm/predownload.batch) so the GPU jobs never wait on the CDS request queue.
#
# Building the parent `ERA5PrescribedAtmosphere` here triggers the same bundled
# pressure-level + surface-geopotential downloads `nested_atmosphere_model` performs on
# the GPU run, with identical cache filenames (region = child domain padded by the
# dataset's 1/2° default).

using NumericalEarth
using NumericalEarth.DataWrangling.ERA5
using NumericalEarth.DataWrangling: default_horizontal_padding
using CopernicusClimateDataStore
using Oceananigans
using Downloads: download
using Dates: DateTime, Hour

include("case.jl")

pressure_levels = ERA5HourlyPressureLevels()
single_levels = ERA5HourlySingleLevel()

padding = default_horizontal_padding(pressure_levels)
child_region = BoundingBox(; longitude, latitude)
parent_region = BoundingBox(longitude = longitude .+ (-padding, padding),
                            latitude  = latitude  .+ (-padding, padding))

@info "Parent state: pressure levels + surface geopotential over $(summary(parent_region))..."
ERA5PrescribedAtmosphere(parent_region, dates; dataset = pressure_levels,
                         dir = era5_datadir, time_indices_in_memory = 3)

# The nest anchors its hydrostatic reference (`base_pressure`) to the mean sea-level pressure
# over the unpadded child box; the ocean surface reads SST + skin temperature over the parent box.
@info "Single-level surface snapshots at $start_date..."
Field(Metadatum(:mean_sea_level_pressure; dataset = single_levels, date = start_date,
                region = child_region, dir = era5_datadir))
for name in (:sea_surface_temperature, :skin_temperature)
    Field(Metadatum(name; dataset = single_levels, date = start_date,
                    region = parent_region, dir = era5_datadir))
end

@info "Wide-view IVT + sea-level pressure, $(first(viz_dates)) – $(last(viz_dates))..."
download(MetadataSet(:vertically_integrated_eastward_water_vapor_flux,
                     :vertically_integrated_northward_water_vapor_flux,
                     :mean_sea_level_pressure;
                     dataset = single_levels, dates = viz_dates,
                     region = wide_region, dir = era5_datadir))

@info "Hourly landfall precipitation, $(first(precip_dates)) – $(last(precip_dates))..."
download(Metadata(:total_precipitation; dataset = single_levels, dates = precip_dates,
                  region = precip_region, dir = era5_datadir))

@info "Predownload complete: $(length(readdir(era5_datadir))) files in $era5_datadir"
