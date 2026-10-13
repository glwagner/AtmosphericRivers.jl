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

| File | Purpose |
|---|---|
| `case.jl` | Shared configuration: dates, domain, resolution, data directory |
| `predownload.jl` | Fetch all ERA5 files up front (CDS queue is the bottleneck, not bytes) |
| `visualize_era5.jl` | Model-free ERA5 view of the event: IVT maps + animation, coastal AR-scale time series, landfall precipitation |
| `downscale.jl` | ERA5 → 12 km Breeze nest with prescribed-SST ocean coupling + RRTMGP |
| `reactant_downscale.jl` | The landfall nest with a hand-rolled ERA5 parent, runnable eagerly on CUDA (`AR_ARCH=cuda`) or compiled with Reactant, plus the Enzyme adjoint (`AR_AD=1`) |
| `analysis/render_precipitation.jl` | 24 h accumulated precipitation of a `reactant_downscale.jl` CUDA run against ERA5 |
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

Breeze is tracked from `main` and NumericalEarth from a git branch, both via `[sources]`
in `Project.toml`. Breeze `main` carries the unified sedimentation transport and the
moist-state fixes. NumericalEarth points at `glw/bottom-precipitation-flux`
(NumericalEarth#753: `main` plus two fixes for coupling a Breeze atmosphere to a
`PrescribedOcean` on Breeze `main`); switch it to `rev = "main"` once #753 merges. The
Manifest pins the exact commits, and `Pkg.update()` moves both forward. Resolve with
Julia 1.12 (the Manifest's `julia_version`).

## 12 km landfall nest on one H100 (`reactant_downscale.jl`, 2026-10-09)

```bash
sbatch slurm/instantiate_prod.batch    # fill ~/.julia-prod once (gpuprod = H100 80GB)
sbatch --export=ALL,AR_SKIP_SETUP=1,AR_PARENT_HOURS=25,AR_RUN_HOURS=24,AR_CHUNK=360,AR_RUN_BAL=0 \
       slurm/cuda_hydro_long.batch     # 24 h from 2025-12-07T12, eager CUDA, Δt = 10 s
julia --project=. analysis/render_precipitation.jl reactant_landfall_era5_9cpd_cuda_hydro_24h_dt10_etopo_nobal.jld2
```

The 324×162×50 child (9 cells per degree, landfall box) with the hydrostatic ERA5 parent,
prescribed-ocean coupling, hourly RRTMGP and ETOPO2022 terrain (`AR_TERRAIN=etopo`, the
default; 2 smoothing passes) runs 24 h at Δt = 10 s in ~4 min of stepping on an H100:
26 ms per step, ~380× real time, 1.0×10⁸ cell-steps per second. Snapshots carry the
running surface precipitation total (`accumulated_precipitation`, mm). Over SW Washington
and NW Oregon west of the Cascades the first 24 h total is 12.6 mm against ERA5's 12.3 mm.
Δt = 30 and 40 s blow up from the first-step initialization kick; `AR_SPINUP_STEPS` /
`AR_SPINUP_DT` start the run at a smaller step.

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
