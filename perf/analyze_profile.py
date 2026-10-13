#!/usr/bin/env python3
"""Analyze CUPTI traces written by perf/profile_window.jl.

    python3 perf/analyze_profile.py perf/data/<tag> [<tag> ...]   → perf/data/<tag>_summary.json + stdout tables

Per trace: per-kernel table (time, launches, registers, block, occupancy, estimated bandwidth),
component breakdown, launch counts by category, GPU idle/gaps, host enqueue statistics.
"""
import gzip, json, math, re, sys, collections

PEAK_BW = {"H100": 3.35e12, "A100": 2.04e12}  # bytes/s, HBM3 SXM / HBM2e 80GB SXM

# Component of a kernel, by its function name (the argument types are NOT searched: every tendency
# kernel's signature mentions the closure, the microphysics and the boundary conditions).
CATEGORIES = [
    ("radiation (RRTMGP, amortized)", r"^rte_|rrtmgp|permutedims|radiation_flux_divergence|apparent_zenith"),
    ("halo fills",                    r"fill_.*halo"),
    ("closure: N², mixing length, K, TKE sources", r"tke_static_stability|mixing_length|tke_closure_fields|add_tke_tendencies|tke_implicit_linear|stability_function|diffusivit"),
    ("acoustic substeps",             r"vertical_rhs|explicit_horizontal_step|post_solve_recovery|build_predictors|linearization|initialize_stage_perturbations|zero_stage_workspaces|finalize_time_averaged|recover_full_state|terrain_vertical_momentum_perturbation|terrain_density_tendency|contravariant_velocity|terrain_slow_vertical"),
    ("closure: implicit vertical diffusion solves", r"^solve_batched_tridiagonal"),
    ("advection/tendency: momentum",  r"^compute_[xyz]_momentum_tendency"),
    ("advection/tendency: ρθ",        r"^compute_potential_temperature_tendency"),
    ("advection/tendency: moisture scalars", r"^compute_scalar_tendency"),
    ("bounds-preserving limiter",     r"bounds_preserving"),
    ("microphysics + sedimentation",  r"microphysic|sedimentation"),
    ("thermodynamics/diagnostics",    r"auxiliary_thermodynamic|temperature_and_pressure|^compute_velocities|total_density"),
    ("surface fluxes/coupling",       r"interface_state|net_atmosphere_fluxes|interpolate_breeze_state|^compute_z_bcs"),
    ("nesting: open-boundary relaxation, parent window", r"relax_open_boundary|child_prognostics"),
    ("RK update, broadcasts, copies, precip accumulation", r"rk3_substep|broadcast|getindex|copy|^compute$|set"),
]

def category(name):
    s = short(name)
    for cat, pat in CATEGORIES:
        if re.search(pat, s):
            return cat
    return "other"

# Nominal bytes per cell (Float32, each array read or written once) for the big 3D kernels — the
# minimum traffic, from the arguments each kernel reads; used for an achieved-bandwidth estimate.
BYTES_PER_CELL = {
    "compute_x_momentum_tendency": 4 * 14, "compute_y_momentum_tendency": 4 * 14,
    "compute_z_momentum_tendency": 4 * 11, "compute_potential_temperature_tendency": 4 * 13,
    "compute_scalar_tendency": 4 * 8, "default_microphysical_tendencies_kernel": 4 * 12,
    "compute_auxiliary_thermodynamic_variables": 4 * 12, "compute_bounds_preserving_limiter": 4 * 4,
    "add_sedimentation_tendency": 4 * 8, "build_vertical_rhs": 4 * 14, "explicit_horizontal_step": 4 * 10,
    "solve_batched_tridiagonal_system_kernel": 4 * 7, "post_solve_recovery": 4 * 8, "build_predictors": 4 * 8,
    "compute_tke_static_stability": 4 * 8, "compute_mixing_length": 4 * 6, "add_tke_tendencies": 4 * 8,
    "assemble_terrain_slow_vertical_momentum_tendency": 4 * 8, "compute_temperature_and_pressure": 4 * 8,
}

def nominal_bytes(key):
    return BYTES_PER_CELL.get(key.split(" ")[0])

def short(name):
    s = re.sub(r"\(.*", "", name)
    return s.replace("gpu_", "").strip("_")

def occupancy(regs, threads, gpu):
    # H100 and A100: 64K registers/SM, 2048 threads/SM, 32 blocks/SM; registers allocated per warp in 256s
    if not regs or not threads:
        return None
    warps = math.ceil(threads / 32)
    regs_per_warp = math.ceil(regs * 32 / 256) * 256
    by_regs = 65536 // (regs_per_warp * warps) if regs_per_warp * warps else 32
    by_threads = 2048 // threads
    blocks = max(0, min(by_regs, by_threads, 32))
    return blocks * warps / 64

def dims(s):
    if not s:
        return (0, 0, 0)
    return tuple(int(x) for x in s.split("x"))

def load(prefix):
    meta = {}
    try:
        for line in open(prefix + "_meta.txt"):
            k, v = line.rstrip("\n").split("\t", 1)
            meta[k] = v
    except FileNotFoundError:
        pass
    dev = []
    with gzip.open(prefix + "_device.tsv.gz", "rt") as f:
        cols = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(cols, line.rstrip("\n").split("\t")))
            r["start"] = float(r["start"]); r["stop"] = float(r["stop"])
            dev.append(r)
    host = []
    with gzip.open(prefix + "_host.tsv.gz", "rt") as f:
        cols = f.readline().rstrip("\n").split("\t")
        for line in f:
            r = dict(zip(cols, line.rstrip("\n").split("\t")))
            r["start"] = float(r["start"]); r["stop"] = float(r["stop"])
            host.append(r)
    return meta, dev, host

def analyze(prefix, nsteps=None, bytes_per_cell=None):
    meta, dev, host = load(prefix)
    gpu = "H100" if "H100" in meta.get("gpu", prefix) else "A100"
    nsteps = nsteps or int(meta.get("window", 200))
    size = tuple(int(x) for x in meta.get("size", "324x162x50").split("x"))
    ncells = size[0] * size[1] * size[2]
    dev.sort(key=lambda r: r["start"])
    t0 = min(r["start"] for r in dev); t1 = max(r["stop"] for r in dev)
    span = t1 - t0
    kernels = [r for r in dev if r.get("grid")]
    busy = 0.0; last = t0; gaps = []
    for r in dev:
        s, e = r["start"], r["stop"]
        if s > last:
            gaps.append(s - last)
        busy += max(0.0, e - max(s, last)); last = max(last, e)

    # scalar tendency kernels: label by field using launch order within each stage
    scalar_fields = []
    if "prognostic" in meta:
        names = meta["prognostic"].split(",")
        scalar_fields = [n for n in names if n not in ("ρᵈ", "ρu", "ρv", "ρw", "ρθ", "ρe_total")]
    sc = [r for r in kernels if "compute_scalar_tendency" in r["name"]]
    nper = round(len(sc) / (3 * nsteps)) if sc else 0
    for i, r in enumerate(sc):
        k = i % nper if nper else 0
        r["field"] = scalar_fields[k] if k < len(scalar_fields) else f"scalar#{k}"

    per = collections.OrderedDict()
    for r in kernels:
        key = short(r["name"]) + (f" [{r['field']}]" if "field" in r else "")
        cat = category(r["name"])
        # distinguish different specializations of the same kernel by register count + block
        key = f"{key} (r{r['registers']}, {r['block']})"
        a = per.setdefault(key, dict(time=0.0, n=0, regs=int(r["registers"] or 0), block=r["block"],
                                     grid=r["grid"], cat=cat, local=r["local_mem"],
                                     cells=0))
        a["time"] += r["stop"] - r["start"]; a["n"] += 1
        g, b = dims(r["grid"]), dims(r["block"])
        a["cells"] += g[0] * g[1] * g[2] * b[0] * b[1] * b[2]
    passes = sum(a["n"] for k, a in per.items() if k.startswith("build_vertical_rhs")) / nsteps
    for k, a in per.items():
        if k.startswith("solve_batched_tridiagonal") and abs(a["n"] / nsteps - passes) < 0.01:
            a["cat"] = "acoustic substeps"
        b = dims(a["block"])
        a["occupancy"] = occupancy(a["regs"], b[0] * b[1] * b[2], gpu)
        a["ms_per_step"] = 1e3 * a["time"] / nsteps
        a["launches_per_step"] = a["n"] / nsteps
        a["us_per_launch"] = 1e6 * a["time"] / a["n"]
        a["threads_per_launch"] = a["cells"] / a["n"]
        if True:
            bpc = nominal_bytes(k)
            if bpc:
                if a["threads_per_launch"] < 0.5 * ncells:   # one thread per column (tridiagonal solves)
                    a["threads_per_launch"] *= size[2]
                a["bytes_per_cell"] = bpc
                a["GBps"] = a["threads_per_launch"] * bpc / (a["time"] / a["n"]) / 1e9
                a["pct_peak_bw"] = 100 * a["GBps"] * 1e9 / PEAK_BW[gpu]

    cats = collections.defaultdict(lambda: [0.0, 0])
    for a in per.values():
        cats[a["cat"]][0] += a["time"]; cats[a["cat"]][1] += a["n"]
    mem = [r for r in dev if not r.get("grid")]
    memtime = sum(r["stop"] - r["start"] for r in mem)
    if mem:
        cats["broadcast / reductions / copies"][0] += memtime
        cats["broadcast / reductions / copies"][1] += len(mem)

    launches = [r for r in host if "Launch" in r["name"]]
    api = collections.defaultdict(lambda: [0.0, 0])
    for r in host:
        api[r["name"]][0] += r["stop"] - r["start"]; api[r["name"]][1] += 1
    hstart = min(r["start"] for r in host); hstop = max(r["stop"] for r in host)
    # queue depth: how far ahead of the GPU the host is when each kernel launches
    devstart = {r["id"]: r["start"] for r in kernels}
    lead = sorted(devstart[r["id"]] - r["stop"] for r in launches if r["id"] in devstart)
    sync = [r for r in host if "Synchronize" in r["name"]]

    out = dict(prefix=prefix, gpu=meta.get("gpu", gpu), size=size, ncells=ncells, nsteps=nsteps,
               steps_per_hour=int(meta.get("steps_per_hour", 360)),
               dt=float(meta.get("dt", 10)), substeps=meta.get("acoustic_substeps"), substep_passes=passes,
               span_ms_per_step=1e3 * span / nsteps, gpu_busy_ms_per_step=1e3 * busy / nsteps,
               busy_fraction=busy / span, kernel_launches_per_step=len(kernels) / nsteps,
               memops_per_step=len(mem) / nsteps,
               gap_count_per_step=sum(1 for g in gaps if g > 5e-6) / nsteps,
               gap_ms_per_step=1e3 * sum(gaps) / nsteps,
               big_gap_ms_total=1e3 * sum(g for g in gaps if g > 5e-3),
               host_api_ms_per_step={k: 1e3 * v[0] / nsteps for k, v in api.items()},
               host_api_calls_per_step={k: v[1] / nsteps for k, v in api.items()},
               host_span_ms_per_step=1e3 * (hstop - hstart) / nsteps,
               launch_lead_ms_median=1e3 * lead[len(lead) // 2] if lead else None,
               launch_lead_ms_p10=1e3 * lead[len(lead) // 10] if lead else None,
               sync_calls_per_step=len(sync) / nsteps,
               categories={k: dict(ms_per_step=1e3 * v[0] / nsteps, launches_per_step=v[1] / nsteps)
                           for k, v in sorted(cats.items(), key=lambda kv: -kv[1][0])},
               kernels=sorted(({"kernel": k, **{kk: vv for kk, vv in a.items() if kk not in ("time",)}}
                               for k, a in per.items()), key=lambda x: -x["ms_per_step"]))
    return out

def report(out, top=25):
    print(f"\n### {out['prefix']}  ({out['gpu']}, {out['size']}, Δt={out['dt']}, substeps={out['substeps']})")
    print(f"window {out['span_ms_per_step']:.2f} ms/step, GPU busy {out['gpu_busy_ms_per_step']:.2f} ms/step "
          f"({100*out['busy_fraction']:.0f}%), {out['kernel_launches_per_step']:.0f} kernels/step, "
          f"idle gaps {out['gap_ms_per_step']:.2f} ms/step")
    print("component                                   ms/step   launches/step")
    for k, v in out["categories"].items():
        print(f"  {k:40s} {v['ms_per_step']:8.2f} {v['launches_per_step']:10.1f}")
    api = out["host_api_ms_per_step"]; calls = out["host_api_calls_per_step"]
    for k in sorted(api, key=lambda k: -api[k])[:5]:
        print(f"  host API {k:28s} {api[k]:7.2f} ms/step {calls[k]:7.1f} calls/step")
    print(f"  host span {out['host_span_ms_per_step']:.2f} ms/step; launch lead (device start − API return) "
          f"median {out['launch_lead_ms_median']:.2f} ms, p10 {out['launch_lead_ms_p10']:.2f} ms; "
          f"syncs/step {out['sync_calls_per_step']:.2f}")
    print(f"top {top} kernels: ms/step  launches/step  µs/launch  regs  block  occupancy")
    for a in out["kernels"][:top]:
        occ = f"{100*a['occupancy']:.0f}%" if a.get("occupancy") is not None else "-"
        bw = f"  {a['GBps']:.0f} GB/s ({a['pct_peak_bw']:.0f}%)" if "GBps" in a else ""
        print(f"  {a['kernel'][:70]:70s} {a['ms_per_step']:7.3f} {a['launches_per_step']:7.1f} "
              f"{a['us_per_launch']:9.1f} {a['regs']:5d} {a['block']:>9s} {occ:>5s}{bw}")


# Eight groups for the stacked-bar figure (perf/plot_profile.jl); GPU idle is drawn separately.
FIGURE_GROUPS = [
    ("WENO advection + tendencies", ("advection/tendency: momentum", "advection/tendency: ρθ", "advection/tendency: moisture scalars")),
    ("acoustic substeps", ("acoustic substeps",)),
    ("TKE closure: implicit diffusion solves", ("closure: implicit vertical diffusion solves",)),
    ("TKE closure: N², ℓ, K, sources", ("closure: N², mixing length, K, TKE sources",)),
    ("microphysics + sedimentation", ("microphysics + sedimentation",)),
    ("halo fills", ("halo fills",)),
    ("radiation (amortized)", ("radiation (RRTMGP, amortized)",)),
    ("other (diagnostics, limiter, coupling, nesting, RK)", None),
]

def figure_table(outs, path):
    with open(path, "w") as io:
        io.write("config\t" + "\t".join(g for g, _ in FIGURE_GROUPS) + "\tGPU idle\n")
        for o in outs:
            cats = {k: v["ms_per_step"] for k, v in o["categories"].items()}
            # the window holds exactly one hourly radiation solve: amortize it over an hour, not the window
            rad = "radiation (RRTMGP, amortized)"
            if rad in cats:
                cats[rad] *= o["nsteps"] / o["steps_per_hour"]
            named = set(c for _, cs in FIGURE_GROUPS if cs for c in cs)
            row = []
            for g, cs in FIGURE_GROUPS:
                row.append(sum(cats.get(c, 0.0) for c in cs) if cs else
                           sum(v for c, v in cats.items() if c not in named))
            # steady-state idle, plus the hourly stalls (gaps > 5 ms, at the parent-window update) amortized per hour
            idle = (o["gap_ms_per_step"] - o["big_gap_ms_total"] / o["nsteps"]) + o["big_gap_ms_total"] / o["steps_per_hour"]
            label = o["prefix"].split("/")[-1]
            io.write(label + "\t" + "\t".join(f"{x:.4f}" for x in row) + f"\t{idle:.4f}\n")

if __name__ == "__main__":
    args = sys.argv[1:]
    table = None
    if args and args[0] == "--table":
        table, args = args[1], args[2:]
    outs = []
    for p in args:
        o = analyze(p)
        report(o)
        json.dump(o, open(p + "_summary.json", "w"), indent=1, default=str)
        outs.append(o)
    if table:
        figure_table(outs, table)
