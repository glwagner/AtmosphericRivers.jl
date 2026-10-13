#!/usr/bin/env python3
"""Join kernel_audit tables by kernel identity and show per-kernel ms/step and registers side by side.

    python3 perf/kernel_diff.py base_kernels.tsv other_kernels.tsv [more ...] [--top N]

Kernel identity = function name + the first `Val<n>` token (the tracer index of compute_scalar_tendency), +
an ordinal for kernels that still collide (e.g. the closure's tridiagonal solves, ordered by time in the
first table). Types (Float32/Float64, workgroup sizes) are not part of the key, so builds that change them
still line up.
"""
import re, sys, collections

def load(path):
    rows = []
    with open(path) as f:
        next(f)
        for line in f:
            name, ms, launches, us, regs, local, block = line.rstrip('\n').split('\t')
            fn = name.split('(')[0]
            val = re.search(r'Val<(\d+)>', name)
            rows.append((fn + (f'[{val.group(1)}]' if val else ''), float(ms), float(launches), int(regs)))
    # disambiguate collisions by ordinal in descending time
    seen = collections.Counter(); out = {}
    for key, ms, l, r in sorted(rows, key=lambda x: -x[1]):
        seen[key] += 1
        out[key if seen[key] == 1 else f'{key}#{seen[key]}'] = (ms, l, r)
    return out

args = [a for a in sys.argv[1:] if not a.startswith('--')]
top = int(sys.argv[sys.argv.index('--top') + 1]) if '--top' in sys.argv else 30
args = [a for a in args if not a.isdigit()]
tables = [load(p) for p in args]
base = tables[0]
keys = sorted(base, key=lambda k: -base[k][0])[:top]
hdr = 'kernel'.ljust(58) + ''.join(f'{"ms":>8}{"regs":>6}' for _ in tables)
print(hdr)
for k in keys:
    line = k[:57].ljust(58)
    for t in tables:
        v = t.get(k)
        line += f'{v[0]:8.3f}{v[2]:6d}' if v else f'{"-":>8}{"-":>6}'
    print(line)
print('TOTAL'.ljust(58) + ''.join(f'{sum(v[0] for v in t.values()):8.2f}{"":6}' for t in tables))
