# Longest stable time step for the 12 km nest (eager CUDA, ERA5 parent, ETOPO terrain)

**Result: Δt = 10 s is the longest verified-stable step. 12 s runs 2 h; 15 s and longer blow up within minutes.** The limit
is not advective CFL, terrain, physics, or the cold start. It is an instability of the **outermost
open-boundary row** in Breeze's split-explicit acoustic substepper (cf. Breeze issue #825). No knob
available in this repository moves the edge past ~12 s.

Configuration: `reactant_downscale.jl`, `AR_ARCH=cuda`, landfall box 148–112°W × 38–56°N, 9 cells per degree
(324×162×50, Δx_min ≈ 6.9 km), hydrostatic ERA5 parent, `AR_IC=interpolated`, coupled ocean, hourly
RRTMGP, upper sponge, 5-cell Davies zone at 1/300 s⁻¹, `NoDivergenceDamping`, Breeze `main` @ 0e3d153.
Driver: `slurm/dt_sweep.batch`. Analysis: `analysis/dt_sweep_compare.jl`, `analysis/boundary_diagnostics.jl`,
`analysis/boundary_probe.jl`.

## Stability

| Δt (s) | acoustic substeps | result |
|---|---|---|
| 10 | 2 | stable 24 h (ETOPO smoothing 2 and 8) |
| 12 | 2 | stable 2 h |
| 15, 20, 24, 30, 36, 40, 45, 60 | 2–7 | NaN within 7–20 steps (≤ 1 h) |
| 21 km grid: 20, 30, 60, 120 | 1–6 | NaN within the first minutes |

Throughput at 10 s: 26 ms/step on an H100 (≈ 390× real time; 24 h in 3.7 min of stepping) and 43 ms/step
on an A100-40GB (≈ 230×).

## Variants that do not move the edge

All were run at Δt = 20–60 s, and all still went NaN within ≤ 16 steps:

- **Acoustics:** acoustic substeps ×2 and ×4 (worse: the step-1 kick grows 38 → 59 → 81 kg m⁻² s⁻¹);
  `ThermalDivergenceDamping` α = 0.1, with and without `damp_vertical`; off-centring ω = 0.8 and 1.0 (slows the
  blowup only); open-boundary relaxation α = 0.5, 0.05 and 10⁻⁶.
- **Advection:** adaptive implicit vertical advection on every prognostic (`AR_AIVA=1`; the Breeze #897/#913/#914
  fixes are present via #964).
- **Boundary zone:** Davies width 5, 10, 15 and 25 cells; width 15 at a 100 s timescale.
- **Parent pressure:** isothermal, domain-mean hydrostatic, per-column hydrostatic (`AR_PARENT_PRESSURE=column`),
  and the native per-column-geopotential parent (`AR_NATIVE_PARENT=1`).
- **Physics:** sponge off; radiation off; uncoupled.
- **Initialization:** DFI balancer; a 1 h spin-up at 10 s before switching.
- **Terrain:** smoothing 2 vs 8 passes, and idealized terrain.

## Mechanism

At Δt = 20 s, with a snapshot every 3 steps, the growth sits entirely in the outermost interior row of every wall:
- **Step 1:** max|ρw| is 6.7 in the frame and 4.1 in the interior.
- **Step 4:** the entire perimeter row, open ocean included, carries a wall-uniform ρw ≈ −95 near 7 km. The interior
  beyond 3 cells stays at |ρw| ≤ 1.8 and vertical Courant number ≤ 0.3.
- **Step 7:** NaN.

That is a growth factor of about ×15 per step. In the stable 10 s run the largest vertical Courant numbers (≈ 0.2) also sit in the first two frame cells.

What the probe and the variants rule out:
- **No static imbalance at the wall.** The t = 0 halo probe shows the prescribed wall ρ and θ match the first
  interior cell to ~0.02%.
- **The parent pressure only sets the size of the first kick.** A consistent per-column parent pressure cuts the
  step-1 frame tendency 6× (∂t ρw 0.69 → 0.11), yet the run still diverges.
- **It is dynamic, not a CFL or imbalance problem.** The open-boundary row is dynamically unstable once Δt·c/Δx
  exceeds ≈ 1. Inside the substep loop the wall-normal momentum perturbation is held at zero and ρ′, (ρθ)′ have
  zero-gradient halos, so the boundary cell's wall flux is frozen at its stage-entry value while its neighbour
  responds acoustically.

The candidate upstream fix is Breeze PR #839 (an MPAS-style specified zone, updated each substep). It is open,
conflicts with current `main`, and was not tested here.

## Side findings

- The Reactant CPU-twin IC path builds its parent pressure from `isa_pressure`, whatever
  `AR_PARENT_PRESSURE` says.
- The interpolated IC is constant in ρ, θ and p over the lowest ~3 child levels (below ERA5's lowest level).
- `slurm/dt_sweep.batch` used to hard-code `AR_PARENT_PRESSURE` and `AR_SPONGE`; both are now overridable.

## Knobs added for the sweep

All defaults are unchanged:
- `AR_SPINUP_STEPS` / `AR_SPINUP_DT`
- `AR_DIVERGENCE_DAMPING`, `AR_DIVERGENCE_DAMPING_VERTICAL`
- `AR_FORWARD_WEIGHT`
- `AR_OPEN_BOUNDARY_RELAXATION`
- `AR_RELAX_TIMESCALE`
- `AR_PARENT_PRESSURE=column`
- `AR_BOUNDARY_PROBE`
