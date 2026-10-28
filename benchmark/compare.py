"""Compares Julia's results (run_julia.jl) with Python PySD's (run_python.py).

usage: python compare.py <python results.tab> <julia results.tsv> <names.tsv> [first]

Prints how many values agree within each tolerance and the largest
differences; with ``first``, the variables that differ, the earliest first.
``names.tsv`` (written by the translation) maps Vensim's names to Julia's.
"""
import re
import sys

import numpy as np
import pandas as pd


def clean(name):
    return re.sub(r"_+", "_", re.sub(r"[^a-z0-9]", "_", name.lower())).strip("_")


py = pd.read_csv(sys.argv[1], sep="\t", index_col=0, float_precision="round_trip")
jl = pd.read_csv(sys.argv[2], sep="\t", index_col=0, float_precision="round_trip")
names = pd.read_csv(sys.argv[3], sep="\t", comment="#")
first = len(sys.argv) > 4 and sys.argv[4] == "first"
to_julia = {clean(v): j for v, j in zip(names["vensim"], names["julia"])}
jl.columns = [float(c) for c in jl.columns]
times = [t for t in py.index if t in jl.columns]

rows, missing, earliest = [], [], {}
for col in py.columns:
    m = re.match(r"^(.*?)(\[(.*)\])?$", col)
    ident = to_julia.get(clean(m.group(1)))
    key = None if ident is None else \
        ident + ("[" + ",".join(clean(x) for x in m.group(3).split(",")) + "]" if m.group(3) else "")
    if key is None or key not in jl.index:
        missing.append(col)
        continue
    a = py.loc[times, col].astype(float).to_numpy()
    b = jl.loc[key, times].astype(float).to_numpy()
    diff = np.where(np.isnan(a) & np.isnan(b), 0.0, np.abs(a - b))
    rel = np.where(np.isnan(diff), np.inf, diff / np.maximum(np.abs(a), 1e-6))
    worst = int(np.argmax(rel))
    rows.append((float(rel[worst]), col, times[worst], a[worst], b[worst]))
    bad = np.nonzero(rel > 0)[0]
    if len(bad):
        t = times[bad[0]]
        if ident not in earliest or t < earliest[ident][0]:
            earliest[ident] = (t, col, a[bad[0]], b[bad[0]])

rows.sort(reverse=True)
rels = np.array([r[0] for r in rows])
print(f"{len(rows)} values compared at {len(times)} times; {len(missing)} not in Julia's results "
      "(data series and lookups are not saved)")
for lim in (0, 1e-12, 1e-9, 1e-6, 1e-3):
    print(f"  relative difference <= {lim:g}: {int((rels <= lim).sum())}")
print("largest differences:")
for r in rows[:15]:
    print(f"  {r[0]:.3g}  {r[1]}  at {r[2]:g}: python {r[3]:.10g}, julia {r[4]:.10g}")
if first:
    print("first difference of each variable, the earliest first:")
    for ident, (t, col, a, b) in sorted(earliest.items(), key=lambda kv: kv[1][0])[:40]:
        print(f"  {t:g}  {col}: python {a!r}, julia {b!r}")
