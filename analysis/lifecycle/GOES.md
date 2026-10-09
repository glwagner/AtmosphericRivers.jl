# GOES-18 imagery of the December 2025 atmospheric river

These movies use **observed NOAA GOES-18 ABI satellite imagery**. The continuous
water-vapour movie follows the North Pacific from December 6 through 11, 2025,
before and during the December 8–12 Pacific Northwest atmospheric river. A second
movie shows the fine daylight cloud structure at landfall on December 8.

| Movie | Input product | Sampling | Coverage |
|---|---|---|---|
| `goes18_water_vapor.mp4` | ABI band 9, 6.9 µm, full disk | 2 km at nadir; 10-minute scans | Dec 6 00:00–Dec 11 23:50 UTC scan slots |
| `goes18_visible_landfall.mp4` | ABI band 2, 0.64 µm, Pacific CONUS sector | 500 m at nadir; 5-minute scans | Dec 8 18:00–23:55 UTC scan slots |

The displayed timestamps are the **actual scan start times**, which have a small
offset from these nominal slots. A scan takes time to acquire; it is not an
instantaneous photograph. The native pixel footprint increases away from nadir,
particularly at Pacific Northwest latitudes. The video is 3840×2160; that is an
output format, not a claim of greater instrument resolution.

## Run in Julia

From the repository root:

```sh
julia --project=analysis/lifecycle -e 'using Pkg; Pkg.instantiate()'
julia --project=analysis/lifecycle analysis/lifecycle/download_goes.jl
julia --project=analysis/lifecycle analysis/lifecycle/animate_goes.jl
```

An optional argument, `water_vapor` or `visible`, selects one movie. All data
acquisition, cropping, quality control, mapping, rendering, and verification code
is Julia. CairoMakie supplies FFmpeg for H.264 encoding. No cloud account, NOAA
login, Python installation, ERA5 data, or model output is needed.

The public source is the [NOAA GOES-18 S3 archive](https://noaa-goes18.s3.amazonaws.com/),
using `ABI-L2-CMIPF` and `ABI-L2-CMIPC`. The downloader lists each hour, checks
for duplicate/unexpected scans, downloads six files at a time, and crops the
original packed samples to the region of interest. It preserves the calibration,
quality flags, projection, scan times, original URL, and SHA-256 in regional
NetCDF files. Downloads and caches use atomic renames and can be resumed.
The temporary full-sector files are removed after the regional cache is saved.
Expect roughly 20 GB of network transfer for both sequences and several GB of
regional cache; the exact size is determined by NOAA's compression.

Configuration:

- `AR_GOES_DATA`: cache folder; defaults to `analysis/lifecycle/goes_data/`.
- `AR_GOES_OUTPUT`: movie folder; defaults to `analysis/lifecycle/output/`.
- `AR_GOES_PREVIEW=1`: render only a PNG from the available cache.
- `AR_GOES_PREVIEW_INDEX`: choose a cached frame for that preview (default 1).

Movies run at 12 frames/s for water vapour (72 seconds) and 5 frames/s for visible
imagery (14.4 seconds). Every nominal scan slot gets one frame. There is **no
temporal interpolation, optical-flow morphing, or repeated image filling**.
The archive was missing the December 9 15:00 UTC full-disk scan when checked;
that slot displays an explicit data-gap card. The source manifest distinguishes
an archive gap from an interrupted local download: incomplete local input fails.

Each movie has a PNG preview and a `*_provenance.toml` containing all original
scan URLs and hashes, actual scan start/end times, missing slots, bounds, input
dimensions, output dimensions, and display settings. The water-vapour movie also
exports `goes18_water_vapor_landfall.png` at the December 8 18:00 slot.

## Interpreting the images

Band 9 is a thermal infrared **brightness-temperature image**, sensitive to cloud
tops and water vapour in the middle troposphere; its vertical sensitivity varies
with the atmosphere and viewing angle. It works through the day and night. The
fixed 195–280 K enhancement renders cold features blue/white and warmer features
grey/orange. This makes cloud bands, dry intrusions, and evolving circulation
visible, but **does not measure total-column moisture, low-level moisture
transport, or IVT**. The cloud band need not coincide with the AR's IVT maximum.
The phase captions describe the event timing, not an objectively tracked AR edge
or a measured intensification rate.

Band 2 shows reflected sunlight. Its grayscale uses the same square-root
enhancement, `sqrt(clamp(reflectance / 0.6, 0, 1))`, in every frame. There is no per-frame
contrast normalization or solar-zenith correction; changing illumination near
sunset is real. NOAA quality flags 0 (good) and 1 (conditionally usable) are kept;
other flags and fill values are masked. Coastlines are projected onto the native
ABI fixed grid using the product's ellipsoid, satellite height, longitude, and
sweep-x geometry. They mark the surface; elevated cloud tops can have parallax.

For quantitative moisture transport, the separate
[ERA5 and hindcast animations](README.md) are useful companion diagnostics.

## Verification and sources

```sh
julia --project=analysis/lifecycle analysis/lifecycle/test_goes.jl
julia --project=analysis/lifecycle analysis/lifecycle/verify_goes.jl
```

The first checks projection geometry, scan timestamps, quality masking, and
retention of the original packed/calibrated samples. The second checks both
videos and provenance, including full FFmpeg decoding, frame count, dimensions,
duration, cadence, and the explicit archive gap.

- [NOAA ABI Cloud and Moisture Imagery algorithm and navigation equations](https://www.star.nesdis.noaa.gov/goesr/documents/ATBDs/Enterprise/ATBD_Enterprise_Cloud_and_Moisture_Imagery_Product_v4_2021-01-13.pdf)
- [NOAA ABI band descriptions](https://www.goes-r.gov/education/ABI-bands-quick-info.html)
- [CW3E December 8–12, 2025 event summary](https://cw3e.ucsd.edu/cw3e-event-summary-8-12-december-2025/)

Imagery credit: NOAA GOES-18 / NESDIS. Coastlines: Natural Earth. Processing and
animation: Julia / AtmosphericRivers.jl. Generated data and movies stay outside Git.
