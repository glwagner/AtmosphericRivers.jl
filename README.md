# AtmosphericRivers.jl

Downscaling the **December 2025 Pacific Northwest atmospheric-river family** with
[NumericalEarth.jl](https://github.com/NumericalEarth/NumericalEarth.jl):
ERA5 reanalysis drives a [Breeze.jl](https://github.com/NumericalEarth/Breeze.jl)
limited-area compressible atmosphere through open lateral boundaries, over a prescribed
ERA5 sea surface and ETOPO2022 terrain, with all-sky RRTMGP radiation.

## The event

Between December 3 and 20, 2025, five to six atmospheric rivers made landfall on the
Pacific Northwest coast. The core event (Dec 8–12) was an AR 4 on the Ralph et al. scale:
~96 hours of continuous AR conditions over Washington, peak IVT near 1000 kg m⁻¹ s⁻¹
offshore, >250 mm over the Olympics and Cascades with snow levels at 6,000–9,000 ft, and
record crests on the Skagit, Snohomish, and Cedar rivers; ~100,000 people were placed
under evacuation orders. A Gulf of Alaska low paired with a subtropical high anchored the
corridor; the moisture traced back ~11,000 km to the western Pacific.

- [CW3E event summary, 8–12 December 2025](https://cw3e.ucsd.edu/cw3e-event-summary-8-12-december-2025/)
- [UW state climatologist retrospective](https://climate.uw.edu/2026/01/13/december-8-11-2025-heavy-rainfall-and-flooding-historical-context-and-a-note-on-snow-drought/)
- [2025 Pacific Northwest floods (Wikipedia)](https://en.wikipedia.org/wiki/2025_Pacific_Northwest_floods)

## Contents

For **high-resolution satellite movies**, see the
[GOES-18 workflow](analysis/lifecycle/GOES.md): 10-minute, 2 km water-vapour imagery
of offshore development through landfall, plus a 5-minute, 500 m visible-light
close-up. All acquisition and rendering code is Julia. Resolutions are at nadir.
An optional, separate movie adds a clear **250 kg m⁻¹ s⁻¹ IVT boundary** and
very light shading from hourly ERA5. The satellite-only and earlier faint-outline
versions remain available.

For complementary moisture-transport diagnostics, the
[ERA5 and hindcast workflow](analysis/lifecycle/README.md) combines hourly 0.25°
ERA5 over the North Pacific with an optional existing 3 km, 30-minute hindcast.

| File | Purpose |
|---|---|
| `case.jl` | Shared configuration: dates, domain, resolution, data directory |
| `predownload.jl` | Fetch all ERA5 files up front (CDS queue is the bottleneck, not bytes) |
| `visualize_era5.jl` | Model-free ERA5 view of the event: IVT maps + animation, coastal AR-scale time series, landfall precipitation |
| `downscale.jl` | ERA5 → 12 km Breeze nest with prescribed-SST ocean coupling + RRTMGP |
| `slurm/*.batch` | Batch scripts (instantiate, predownload, visualize, downscale) |

## Workflow

```bash
cd ~/AtmosphericRivers.jl
sbatch slurm/instantiate.batch                       # resolve + precompile on an A100 node
sbatch slurm/predownload.batch                       # ~2 GB of ERA5, hours of CDS queue
sbatch slurm/visualize.batch                         # script 1: ERA5 event visualization
sbatch --export=ALL,AR_SMOKE=1 slurm/downscale.batch # 30-iteration GPU smoke test
sbatch slurm/downscale.batch                         # script 2: the 72 h hindcast
```

Requires CDS credentials (`~/.cdsapirc`, mirrored to `~/.config/era5cli/cds_key.txt`)
with the ERA5 single-level and pressure-level licences accepted.

NumericalEarth is sourced by path from `~/NumericalEarth.jl` (branch `glw/cleanup`, which
carries the Dec-2025 ERA5 date range and the `tcwv`/`viwve`/`viwvn` IVT variables).
Breeze comes from `main` (≥ 0.8, which has the RRTMGP coupled-model APIs).

## Configuration (v0: one A100-40GB)

- **Domain**: 170°W–110°W, 25°N–60°N — the moisture corridor from east of Hawaii to the
  coast, the Gulf of Alaska parent low, and every landfall from BC to Northern
  California, plus the Olympics, Cascades, and coastal ranges.
- **Resolution**: Δ = 1/9° ≈ 12 km, 540×315×50 ≈ 8.5M cells (Float32, ~10 GB on GPU).
- **Window**: 2025-12-07T12 + 72 h (override with `AR_HOURS`), covering the first
  landfall and the second pulse of the Dec 8–12 AR.

## Results (run `pnw72`, 2026-08-10)

The full 72 h hindcast (Dec 7 12Z → Dec 10 12Z) completed in 3.77 h of stepping on one
A100-40GB (47,600 iterations, ≈19× real time) with the production recipe:
`AR_RELAX_WIDTH=8 AR_BLEND_LENGTH=240000` and the streaming ERA5 parent. The interior
(> 25 cells from the frame) stays physical for all 72 hours; analysis masks that rind.
Peak interior IVT at landfall reaches 1592 kg m⁻¹ s⁻¹ where ERA5 has 1081 — the nest
sharpens the AR core the 0.25° reanalysis smooths. `analysis/compare_ivt.jl` makes the
matched-time comparison figure and `analysis/animate_ivt.jl` the side-by-side animation.

## Multi-GPU (2026-08-11)

`AR_RANKS=2` runs the nest on 2 A100s via `NCCLDistributed` (NCCL moves device halo
buffers over NVLink; host MPI bootstraps — the cluster's MPI is not CUDA-aware and
doesn't need to be). Validated end-to-end: `test_nccl_halo.jl`, a 30-iteration smoke,
and two full 6-simulated-hour runs.

- **Strong scaling 1→2 GPUs: 1.50× speedup (75% efficiency)** — 0.178 vs 0.267 s/iter
  on the 12 km corridor.
- Multi-rank runs hold the whole ERA5 parent resident (`AR_PARENT_MEMORY=all` default):
  streaming's concurrent NetCDF reads of one NFS file intermittently corrupt at window
  moves.
- Upstream fixes this campaign surfaced: Oceananigans
  [#5863](https://github.com/CliMA/Oceananigans.jl/pull/5863) (NCCL ext: `CUDA.wait` +
  device-buffer collectives), Breeze
  [#899](https://github.com/NumericalEarth/Breeze.jl/pull/899) (`rrtmgp_context` for
  distributed architectures), and NumericalEarth `glw/cleanup` (bathymetry reduction
  element-type match across ranks).
- Next rungs: 4-GPU scaling point, then the full corridor at 3 km (~136M cells,
  ~34M cells/GPU) once the single-GPU 3 km landfall run releases its A100.

## Scale-up ladder

1. **6 km** (Δ = 1/18°) on the same domain — no code changes, ~10M cells.
2. **Time-varying SST**: `PrescribedOcean` currently reads only the first time index —
   needs upstream temporal interpolation.
3. **Mixed land+ocean surface**: flux assembly currently assumes one surface type per
   cell (land would overwrite ocean); needs upstream tile-fraction assembly, then a
   `SlabLand` coast under the same child. Snow does not yet reach the land bucket.
4. **Wider domain** toward the full North Pacific (genesis-to-landfall crosses the
   dateline): needs the `time_indices_in_memory` passthrough in the high-level
   `nested_atmosphere_model` (the parent currently holds every date resident on GPU),
   and dateline-aware ERA5 requests.

## Known risks (v0)

- `AtmosphereOceanModel` around a `NestedModel` atmosphere is an untested path (the
  nested `AtmosphereLandModel` is proven; the component forwarding is shared).
- Land cells carry ERA5 skin temperature under ocean-type (Charnock) roughness.
- Near-surface θᵛ drifts cold over ocean in multi-day nests
  ([NumericalEarth#457](https://github.com/NumericalEarth/NumericalEarth.jl/issues/457)) —
  watch the surface θᵛ output.
