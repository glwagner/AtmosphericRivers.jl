# Reverse-mode AD through a nested atmosphere model under Reactant/Enzyme

**Status report and hand-off notes.** Everything below concerns `reactant_downscale.jl`, a
Reactant/XLA-compiled twin of a nested Breeze atmosphere (ERA5-forced parent → limited-area
child), and the reverse-mode adjoint built through it with Enzyme.

The point of this document is the **workarounds**. The adjoint works, but it works only because a
dozen separate blockers were routed around, most of them in library code rather than in this
script. Anyone rebuilding this on new hardware needs that list more than they need the results.

---

## 1. What was built

A gradient of a scalar loss with respect to a prognostic field, taken through `N` compiled time
steps of the nested model:

```julia
function ad_loss(model, control, Δt, nsteps)
    interior(prognostic_fields(breeze_child(model))[AD_CONTROL]) .= interior(control)
    @trace mincut=true checkpointing=... track_numbers=false for _ = 1:nsteps
        time_step!(model, Δt)
    end
    x = interior(prognostic_fields(breeze_child(model))[AD_TARGET])
    return sum(x .^ 2) / length(x)
end
```

Differentiated with

```julia
Enzyme.autodiff(set_strong_zero(ReverseWithPrimal), ad_loss, Active,
                Duplicated(model, dmodel), Duplicated(control, dcontrol),
                Const(Δt), Const(nsteps))
```

compiled with `@compile compile_options = ar_compile_options(raise = ..., raise_first = true)`.

Default configuration: `J = mean(ρqᵉ²)` after `N` steps, control and target both `ρqᵉ`, so the
gradient answers *how does end-of-window moisture respond to initial moisture*. Control and target
are independently selectable.

Enabled by `AR_AD=1`. The whole AD path is one block in the script; with `AR_AD=0` nothing below
is touched.

---

## 2. What works

- **The adjoint is correct**, validated by finite differences at 1° resolution: directional FD
  along `v = g/‖g‖` gave a ratio of 1.12, and the ε-sweep showed `(ratio − 1)` shrinking linearly
  in ε, which is the signature of an exact gradient (a gradient wrong by a constant factor
  plateaus at that factor instead). Agreement ≲1%.
- **At 21 km with a real ERA5 initial condition**, windows of 8, 32 and 128 steps at Δt = 10 s all
  produce finite, non-zero gradients with no NaN cells.
- **One compile serves every window.** The trip count is passed as a `ConcreteRNumber`, producing a
  dynamic-bound `stablehlo.while`, so a sweep over several window lengths pays one compile.
- **Binomial (revolve) checkpointing works at budget 4** after a crash fix landed in
  `libReactantExtra`.
- **Radiation traces and differentiates** after the fixes in §3.

The FD validation has **not** been repeated at 21 km. It was done at 1°, before several of the
shims below existed. Nothing suggests the gradient is wrong at higher resolution, but nothing has
confirmed it either.

---

## 3. Workarounds

### 3.1 Library-level shims (applied at load time by the script)

These are monkey-patches over Oceananigans / Breeze / NumericalEarth / Reactant. Each one is a
real upstream defect or gap. They are numbered as in the script.

| # | Blocker | Workaround |
|---|---|---|
| 1 | `on_architecture` for a `LatitudeLongitudeGrid` walks grid fields through the Reactant extension's private `_to_reactant`, which knows about arrays and the *static* vertical only — a terrain-following coordinate does not survive the trip | Extend `_to_reactant` to move Breeze's terrain-following vertical coordinate onto Reactant |
| 2 | The state exchanger slides a 3-level resident window over the parent's time axis and decides when to move it by comparing clock-derived indices — traced values, so the comparison is not a host boolean | Size the parent to exactly the resident window and remove the data-dependent branch |
| 3 | `default_auxiliary_bc` asks whether a boundary sits on a pole (`φnode(...) ≈ ±90`) while building boundary conditions. Static property of the grid, but the query happens inside the traced step | Decide the polar branch on the host, outside the trace |
| 4 | `time_step!(::NestedModel, Δt)` advances the parent only `if Δt_parent > 0` — a traced comparison. At fixed Δt the clocks advance in lockstep and the guard always holds | Specialised `time_step!` for a Reactant `NestedModel` with the guard removed |
| 5 | Breeze's split-explicit dynamics sizes its acoustic substep loop from the acoustic CFL, so `Nτ` is a traced `Int`, `1:Nτ` is a `TracedUnitRange`, and `for substep in 1:Nτ` throws `TypeError: non-boolean (TracedRNumber{Bool})` | Decide the substep count on the host and pass a plain `Int`, taking the `acoustic_substeps(N::Int, …) = N` branch that never consults the grid |
| 6 | `set!(dst, src)` between two Reactant fields at *different* locations falls back to Oceananigans' CPU interpolation in `set_to_field!`, because `interpolate!`'s KA kernel does not trace | Patch `set_to_field!`; resolve the predicate name at load time (`copyable_fields`, renamed from `broadcast_compatible`) so the shim survives either Oceananigans version |
| 7 | `set!(field, ::AbstractOperation)` carrying a real interpolation (`ℑxᶠᵃᵃ`) cannot be flattened into a `parent` broadcast | Materialise the operation on the host |
| 8 | `set!(model; compute_reference_state=true)` → `reset_reference_state!` is unreachable under Reactant on a terrain-following model — three independent blockers | Skip it on a Reactant grid, keeping the constructor's standard-288 K `AutoReference` |
| 9 | `enzymexla.math.fmuladd` has no lowering in the eager kernel path. Oceananigans writes every advection stencil with `@muladd`, so all centered/upwind/WENO reconstructions hit it | Override `Base.muladd` in the loaded-module table |
| 10 | The adiabatic balancer's automatic Δt needs `minimum_zspacing(grid)`, which cannot be evaluated on a traced terrain grid | Supply Δt explicitly; balancer off |
| 11 | **The one that mattered for AD.** See §3.2 | |
| 12 | `rrtmgp_context(::ReactantState)` is undefined, blocking radiation | Define it to return the CPU `ClimaComms` context. Must interpolate *types*, not module paths — `BreezeRRTMGPExt` does not bind `Oceananigans` |

### 3.2 The non-differentiable arithmetic (shim 11)

The first serious adjoint failure was Enzyme refusing to transpose `bitcast_convert`, `shift_left`
and `shift_right_logical` — bitwise ops that have no derivative and should never appear in a
physics kernel.

Tracing the MLIR debug locations back to source found the cause in `FieldTimeSeries` **time
interpolation**. `fts.times` is `Float64` while the field data is `Float32`, so the interpolated
value came out `Float64` while the exact-hit branch stayed `Float32`. The resulting
`Union{Float32,Float64}` made Julia emit a runtime type check, which lowers to bit manipulation —
and that is what Enzyme could not differentiate.

The fix closes the union by widening the exact-hit branch to `Float64`, which is value-preserving
(verified bit-identical). `AR_FTS_UNION_FIX=1` is the default; `=0` restores the blocker, `=2`
narrows the other way instead. The patch targets `time_interpolated_getindex` with a fallback to
`interpolating_getindex` for older Oceananigans.

**This is an upstream Enzyme-differentiability bug in ordinary Oceananigans code, not a
Reactant quirk.** Any attempt to differentiate a model with a `FieldTimeSeries` forcing will hit
it. It deserves a fix in Oceananigans rather than a load-time patch in every script that wants a
gradient.

There is a related shim on `find_time_index`: for a `StepRangeLen` the index is pure arithmetic,
so the binary search (`searchsortedfirst`) can be replaced by a closed form. Verified against Base
over 213 sample times including exact hits and out-of-range values.

### 3.3 AD-specific workarounds

- **`first_time_step!` must run, and must run outside the differentiated region.** Without it the
  primal loss is NaN. Compiling it separately and executing it before the sweep means the
  differentiated segment starts from the state it leaves — and halves the sweep compile.
- **Big stack.** Reactant's `Compiler.Thunk` overflows the default stack during tracing. Every
  compiled call is wrapped in `Task(f, 1 << 29)`.
- **Fresh shadow per window.** Enzyme *accumulates* into the shadow, so a shadow reused across
  windows returns window 2's gradient added to window 1's. Declared `local` inside the loop; the
  global exists only to give `@compile` something to specialise on.
- **Full state snapshot and restore between windows**, covering every `Clock` field generically
  plus the parent clock. Without it each window starts where the previous one ended.
- **The FD check must reset state too**, and must perturb a base point saved *before* anything
  runs. Reading the base point back off the model after it has been stepped, and letting the two
  evaluations start from different states, produced a bogus FD ratio of 16.7 on the first attempt.
- **Coupled model disabled** (`AR_COUPLED=0`). Attaching the coupled ocean/atmosphere path fails
  under Reactant with either a `MethodError`, a GPUCompiler `InvalidIRError`, or a scalar-indexing
  `ErrorException`; the script's fallback predicate matches all three. `InvalidIRError` must be
  matched by type *name*, since GPUCompiler is not a direct dependency.
- **Reporting.** Non-finite loss, non-finite gradient, and identically-zero gradient are three
  distinct verdicts. Collapsing them hid an all-NaN gradient as "identically zero" once.

### 3.4 XLA flags

Two flags are load-bearing.

- **`--xla_disable_hlo_passes=multi_output_fusion`** — without it, the compiled model **hangs on
  H100** and never returns. Diagnosed by running with `TF_CPP_VMODULE=custom_kernel_thunk=3` and
  `--xla_gpu_enable_command_buffer=` (empty, disabling command buffers): the process wedged on a
  single `loop_dynamic_update_slice_fusion` launch, host stack `ThunkExecutor → CustomKernelThunk →
  CudaStream::LaunchKernel → cuLaunchKernelEx`. Disabling multi-output fusion clears it entirely.
  The same code runs fine on T4 without the flag, so this is **H100/Hopper-specific**. Worth
  reporting upstream; it is not fixed, only avoided.
- **`xla_disable_while_loop_dce=true`**, passed via `xla_backend_extra_options` (a
  `map<string,string>` in `DebugOptionsProto`). Note the key uses **underscores**; a dotted spelling
  is rejected with `xla: Unknown command line argument`, and the process exits 1 with no other
  message.

### 3.5 Checkpointing

`@trace` accepts `checkpointing = true` (automatic, static bounds only), `Reactant.Periodic(n)`, or
`Reactant.Binomial(budget)` (revolve). Budget is a compile-time constant.

`Binomial` originally segfaulted; fixed in `libReactantExtra` and confirmed working at budget 4.
**Budget 8 is implicated in an open failure — see §5.**

Revolve's recompute factor `r` is set by `binom(budget + r, budget) ≥ nsteps`. At 128 steps budget 4
gives `r ≈ 6`; at 2160 steps the same budget gives `r ≈ 13`, so the per-step cost roughly doubles.
Raising the budget buys the factor back. Checkpoint *memory* is negligible at these grid sizes — a
state is ~15 MB, so budget 8 is ~120 MB against a 59 GiB arena — so memory is not the reason to
keep the budget small.

---

## 4. Performance

The dominant cost is **fixed, not per-step**. Measured at 21 km (108×54×50 child), H100:

| phase | time | nature |
|---|---|---|
| model setup + ERA5 + initialisation | ~3600 s | host |
| `first_time_step!` compile | ~2400 s | host CPU |
| Enzyme shadow (`make_zero`) | ~90 s | host, per window |
| reverse sweep compile | ~1800 s | host CPU |
| **first-call warmup** | **~2400 s** | XLA, at execution time |
| marginal gradient work | **~0.1 s/step** | GPU |

**Roughly 6600 s of compile and warmup to buy ~0.1 s per differentiated step.** A 128-step window
costs 17 s of actual work; a 720-step window costs ~65 s. Window length is essentially free, and
the fixed cost sets the iteration speed of any experiment on the adjoint.

Two observations worth carrying forward:

- The ~2400 s **warmup is not compile** — compile finished and was timed separately. It is paid on
  the reverse executable's first execution, and the forward-only executable does not pay it
  (compiles in ~2400 s, runs in ~260 s). Most likely XLA autotuning, possibly command-buffer
  instantiation. **Never measured, and both have flags** (`--xla_gpu_autotune_level=0`, and a
  persistent autotune cache to amortise it across jobs). This is the single largest available win.
- **The compiles are host-CPU-bound, not GPU-bound.** A T4 node compiled `first_time_step!` in
  2176 s versus the H100's 2396 s, on identical 8-core hosts. Compile time will not improve with a
  better GPU; it improves with faster cores.
- `raise_first = true` has never been re-tested since it was added at the very start, before the
  union fix and the fusion workaround. If it is now redundant it is likely a large share of the
  1800 s.
- The XLA BFC allocator pre-reserves ~75% of the card (59.38 GiB on an 80 GB H100) regardless of
  problem size. This is not a measure of what the model needs and should not be read as one.

---

## 5. Open problems

### 5.1 NaN gradient on a long window (unresolved)

At **720 steps with `Binomial(8)`**, the loss came back perfectly healthy (`J = 8.84e-06`, in line
with the trend from shorter windows, forward diagnostics showing zero non-finite cells) while
**every one of the 291,600 gradient cells was NaN**. The adjoint produces NaN somewhere the primal
does not.

Two variables changed at once relative to the last known-good run (128 steps, budget 4), and they
have **not yet been separated**:

1. **Window length 128 → 720.** Adjoints of atmospheric dynamics amplify backward in time, and
   this is Float32 (overflow ~3.4e38). Going from ~1e-7 gradients to overflow over 592 extra steps
   needs a growth factor of only ~1.2/step — entirely plausible for moist/acoustic dynamics at
   Δt = 10 s with one acoustic substep.
2. **Checkpoint budget 4 → 8.** Under checkpointing the forward states are *recomputed from
   checkpoints during the reverse sweep*, so a faulty restore corrupts the adjoint while leaving
   the already-computed loss untouched. That is exactly the observed signature, and budget 8 has
   never run successfully — only budget 4 has, and the Binomial crash fix is recent.

**The experiment that separates them** is a single job sweeping windows 128, 256, 512, 720 at
budget 4 — one compile serves all four, so the extra windows cost seconds. All finite ⇒ budget 8
is a Reactant/Enzyme checkpointing bug. NaN appearing partway up ⇒ adjoint instability, and the
threshold is itself a number worth having. **This has not yet been run to completion** — see §5.4.

### 5.2 The parent forcing window is 2 hours

`parent_times = collect(0.0:1hour:2hours)` — three hourly ERA5 levels. Beyond 2 h of model time
`find_time_index` clamps and the lateral boundary forcing silently **freezes** at the last level.
It does not crash; it quietly stops being a nested downscale. 720 steps at Δt = 10 s is exactly
2 h, i.e. the largest defensible window as configured.

Hourly ERA5 covering a full day is already on disk, so widening this is cheap and is the real gate
on window length — not GPU time.

### 5.3 The coupled model does not trace

`AR_COUPLED=1` fails under Reactant (§3.3). Nothing downstream of surface fluxes is differentiable
until that is fixed. A reproducer file exists but **does not reproduce the original
`InvalidIRError`** — it reaches scalar indexing and a separate `MethodError` instead, so it is not
yet a faithful minimal case.

### 5.4 Hardware

The bisection in §5.1 has been blocked by cluster capacity, not by code. On the smaller nodes the
job is **killed by the host OOM killer at the moment the reverse sweep begins executing** — after
paying both compiles — because the batch script caps memory at 28 GB on 31 GB nodes. The larger
nodes, where the identical phase runs fine under the same cap, have been down for maintenance.

**On the new cluster, size the host memory generously.** The failure mode is a bare SIGKILL with no
Julia traceback, two and a half hours into a job, and it is easy to misread as a model problem.

---

## 6. Environment

| package | version | source |
|---|---|---|
| Reactant | 0.2.284 | local checkout, branch `traced-dates-periods-and-adapt` |
| Reactant_jll | 0.0.407 | **overridden** — see below |
| Enzyme | 0.13.199 | registry |
| Oceananigans | 0.110.19 | local checkout, branch `fix/reactant-terrain-following-coordinate` |
| Breeze | 0.8.0 | local checkout, branch `traced-datetime-solar-position` |
| NumericalEarth | 0.6.1 | local checkout |
| RRTMGP | 0.21.9 | registry |

`libReactantExtra` is overridden in `LocalPreferences.toml` to a custom build carrying the Binomial
checkpointing fix:

```toml
[Reactant_jll]
libReactantExtra_path = ".../reactant_jll_artifact/lib/libReactantExtra.so"
```

**This override is essential and easy to lose.** `LocalPreferences.toml` was deleted once during
this work and had to be restored.

**A second, related trap:** the batch script runs `Pkg.instantiate(); Pkg.precompile()` on every
job. That once pulled Oceananigans back to a registry version, silently dropping the local
checkout and breaking a shim with `UndefVarError: broadcast_compatible`. On the new cluster, either
pin the dev checkouts or skip the instantiate step once the environment is known good.

### Key environment variables

| variable | meaning |
|---|---|
| `AR_AD=1` | enable the AD block |
| `AR_AD_STEPS` | comma-separated window lengths, e.g. `128,256,512,720` |
| `AR_AD_CHECKPOINTS` | `>0` = `Binomial(n)`, `0` = none, `-1` = automatic |
| `AR_AD_TRACED_STEPS` | `1` = traced trip count (one compile for all windows), `0` = static bounds |
| `AR_AD_PRIMAL_ONLY` | compile and run the loss only, no Enzyme |
| `AR_AD_FD_DIR` / `AR_AD_FD_EPS` | finite-difference check against a saved gradient; ε takes a list |
| `AR_AD_HLO` | dump unoptimised IR and stop before the pass pipeline |
| `AR_FTS_UNION_FIX` | `1` = the shim-11 fix (default), `0` = restore the blocker |
| `AR_COUPLED` | `0` skips the coupled-model attempt |
| `AR_CELLS_PER_DEGREE` | resolution; `3` ≈ 21 km |
| `AR_DT` | fixed Δt — no wizard inside the trace, so keep it under the advective CFL |
| `AR_RADIATION`, `AR_SOLAR_COS_ZENITH`, `AR_RADIATION_EVERY` | radiation controls |

---

## 7. Recommendations

1. **Run the window/budget bisection first.** It is the one open correctness question, and it is a
   single job. Everything else about the adjoint is provisional until it is answered.
2. **Size host memory generously**, and expect the OOM to arrive as an unexplained SIGKILL after
   the compiles.
3. **Attack the ~2400 s first-call warmup.** Test `--xla_gpu_autotune_level=0` and a persistent
   autotune cache. It is ~40% of every AD job's wall clock and has never been measured.
4. **Re-test `raise_first = true`.** It predates several fixes and may no longer be needed.
5. **Fix shim 11 upstream in Oceananigans.** The `FieldTimeSeries` type instability blocks
   differentiation for anyone, not just this script.
6. **Report the H100 multi-output-fusion hang upstream.** It is currently only avoided.
7. **Widen the ERA5 parent window** before running anything longer than 2 h of model time, or the
   boundary forcing freezes without warning.
8. **Repeat the FD validation at production resolution.** It has only ever passed at 1°.
