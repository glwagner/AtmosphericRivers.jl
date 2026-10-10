#!/usr/bin/env python3
"""Split each setup stage of the log into compilation / GC / other, from <prefix>_setup.tsv.

    python3 perf/setup_phases.py perf/data/<tag> slurm/<job>.log
"""
import re, sys, bisect
prefix, log = sys.argv[1], sys.argv[2]
offset = 0.0
rows = []
for line in open(prefix + "_setup.tsv"):
    if line.startswith("# stage_clock_offset_s"):
        offset = float(line.split("\t")[1])
    elif line[0].isdigit():
        rows.append(tuple(float(x) for x in line.split("\t")))
times = [r[0] for r in rows]
def at(t):  # interpolate cumulative (compile, gc) at driver time t
    i = bisect.bisect_left(times, t)
    if i <= 0: return rows[0][1:3]
    if i >= len(rows): return rows[-1][1:3]
    (t0, c0, g0, _), (t1, c1, g1, _) = rows[i - 1], rows[i]
    f = (t - t0) / (t1 - t0) if t1 > t0 else 0
    return c0 + f * (c1 - c0), g0 + f * (g1 - g0)
stages = [(0.0, "package load + shims (before the stage clock)", -offset)]
for line in open(log):
    m = re.match(r"\[ Info: \[\s*([0-9.]+) s\] (.*)", line)
    if m:
        stages.append((float(m.group(1)), m.group(2)[:70], float(m.group(1))))
print(f"{'phase (ends with the log stage)':72s} {'wall s':>7s} {'compile s':>9s} {'GC s':>6s}")
prev_t = -offset; prev = at(0.0)
for _, label, t in stages[1:]:
    cur = at(t + offset)
    dt = t - prev_t
    if dt > 1.0:
        print(f"{label:72s} {dt:7.1f} {cur[0]-prev[0]:9.1f} {cur[1]-prev[1]:6.1f}")
    prev_t, prev = t, cur
print(f"{'package load + shims (driver t0 → stage clock 0)':72s} {offset:7.1f} {at(offset)[0]:9.1f} {at(offset)[1]:6.1f}")
