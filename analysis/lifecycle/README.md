# Development to landfall: December 2025

For **actual high-resolution GOES satellite imagery**, use the
[GOES-18 workflow](GOES.md): 10-minute water-vapour imagery and a 5-minute,
500 m visible-light close-up. This page documents the separate reanalysis and
simulation diagnostics.

This Julia-only visualization follows the **December 8–12, 2025 Pacific Northwest
atmospheric river**, starting on December 3 to show its offshore evolution. The
event date matches this repository's case. See the
[CW3E event summary](https://cw3e.ucsd.edu/cw3e-event-summary-8-12-december-2025/).

The main movie combines a North Pacific IVT map, column water vapour, pressure
contours, coastal IVT, and an optional synchronized 3 km hindcast inset. A second
movie shows the 3 km landfall at a larger scale. All download, processing,
validation, and rendering code is Julia; the CPU-only environment is independent
of this repository's cluster-specific simulation environment.

## Reproduce

Run from the repository root:

```sh
julia --project=analysis/lifecycle -e 'using Pkg; Pkg.instantiate()'
julia --project=analysis/lifecycle analysis/lifecycle/download_era5.jl
julia --project=analysis/lifecycle analysis/lifecycle/animate.jl
```

The public download needs no CDS account. It reads the four surface fields from
[ARCO-ERA5](https://github.com/google-research/arco-era5): native model-level
integrals of eastward and northward water-vapour flux, total column water vapour,
and mean sea-level pressure. It subsets the archive to **140°E–110°W, 15–65°N**,
crossing the dateline continuously, and saves one atomic, restartable NetCDF cache
per UTC day. The default December 3–12 window is 240 hourly samples, on the 0.25°
archive grid. These are reanalysis fields, not satellite images. ERA5's underlying
model resolution is approximately 31 km; the 0.25° output grid does not imply
independent information at a finer scale.

The archive uses one global spatial chunk per variable per hour. Downloads therefore
transfer more data than the final regional cache (about 220 MiB for the default case).
Eight concurrent downloads are used. Compression, dimension order, time units,
coverage, and finite values are checked explicitly; an unsupported archive encoding
fails instead of producing a plausible-looking map. Natural Earth coastlines are
downloaded and cached on first use.

### Add the existing 3 km run

Point `AR_LIFECYCLE_MODEL` to the completed `pnw3km72_ivt.jld2` output, for example:

```sh
AR_LIFECYCLE_MODEL=runs/pnw3km72/simulation/pnw3km72_ivt.jld2 \
    julia --project=analysis/lifecycle analysis/lifecycle/animate.jl
```

This is the existing **December 7 12:00–December 10 12:00 UTC** hindcast, with
**145 snapshots at 30-minute intervals**. The model grid is 1/36°, conventionally
called 3 km (about 3.1 km north–south and 2.1 km east–west at 48°N). The reader uses
the coordinates and halo widths stored in the file; it does not invent an evenly
spaced endpoint grid. The 32-cell relaxation boundary zone is masked. A missing or
nonfinite interior snapshot is an error. The large model file is not included in
Git and is not downloaded automatically.

This remains an **experimental hindcast**, subject to the simulation limitations
documented in the repository, including near-surface cold drift. It is presented
alongside reanalysis rather than as an observational reconstruction. The inset is
unavailable before/after the simulation; it never freezes its last frame to imply
continued model coverage.

## Reading the animation

- **Colour on the main and model maps:** IVT = `hypot(eastward_flux, northward_flux)`,
  in kg m⁻¹ s⁻¹, with a fixed 0–1600 scale throughout. Values above 1600 use the top
  colour. The separate blue map is column water vapour in kg m⁻².
- **Arrows:** direction of integrated moisture transport, shown where IVT ≥250.
  They are neither parcel trajectories nor surface-wind arrows; strength is encoded
  by map colour. Directions include the longitude cosine correction.
- **Grey contours:** sea-level pressure at 8 hPa intervals.
- **Timeline:** magnitude of IVT at the offshore Washington reference point
  48°N, 124.75°W (nearest model cell for the hindcast). The dashed 250 reference is
  not an AR category: the AR scale additionally depends on duration.
- **Time:** the movie advances in 30-minute steps. ERA5 holds its latest hourly
  sample, whose timestamp is printed separately. The model uses each real
  30-minute snapshot. No temporal interpolation or artificial particle motion is used.
- **Geometry:** equirectangular maps with an aspect ratio corrected at 40°N.
  Phase captions summarize the event timing, not a tracked identity for every
  moisture filament visible across the basin.

## Outputs and configuration

Outputs are written under `analysis/lifecycle/output/` by default:

| File | Content |
|---|---|
| `ar_lifecycle.mp4` | 3840×2160 (4K), 479 frames, approximately 60 seconds at 8 fps |
| `ar_landfall_3km.mp4` | 3200×2400, 145 frames, approximately 18 seconds at 8 fps; requires model file |
| `ar_development.png`, `ar_landfall.png`, `ar_second_pulse.png` | Key-frame previews |
| `ar_landfall_3km.png` | Large-format model preview |
| `provenance.toml` | Data-file SHA-256 hashes, dates, cadence, model mask, and render settings |

Both videos use H.264. Julia/CairoMakie supplies its FFmpeg dependency.

| Environment variable | Default / purpose |
|---|---|
| `AR_LIFECYCLE_DATA` | `analysis/lifecycle/data`; daily NetCDF cache |
| `AR_LIFECYCLE_OUTPUT` | `analysis/lifecycle/output`; movies and provenance |
| `AR_LIFECYCLE_MODEL` | Empty; optional completed `pnw3km72_ivt.jld2` |
| `AR_FIRST_DAY`, `AR_LAST_DAY` | `2025-12-03`, `2025-12-12`; UTC day bounds |
| `AR_FPS` | `8`; playback frame rate, independent of data cadence |
| `AR_PREVIEW` | `1` saves still previews without encoding the movies |

Changing day bounds does not change the event-specific captions or model epoch.
To apply this to another event, update those explicitly in the Julia source.

## Validation

```sh
julia --project=analysis/lifecycle analysis/lifecycle/runtests.jl
AR_LIFECYCLE_DATA=analysis/lifecycle/data \
AR_LIFECYCLE_MODEL=runs/pnw3km72/simulation/pnw3km72_ivt.jld2 \
    julia --project=analysis/lifecycle analysis/lifecycle/runtests.jl
julia --project=analysis/lifecycle analysis/lifecycle/verify_movies.jl
```

The small offline tests exercise transport magnitude, exact/held/out-of-range
timestamps, and coastline seam handling. With data supplied, the suite checks all
240 ERA5 timestamps, coordinates and field ranges, and every one of the 145 model
snapshots, including halo removal and the boundary mask. Inspect the key-frame
PNGs before encoding a long run with modified plotting settings.
`verify_movies.jl` checks the default event's video dimensions, codec, frame count,
cadence and duration, then decodes every frame to check for encoding errors.
