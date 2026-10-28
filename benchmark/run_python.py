"""Python PySD's run of a Vensim model, timed, as the reference for run_julia.jl.

usage: python run_python.py <model.mdl> <out.tab> [<parent results.tab> …]

A model whose data variables come from other models (no equation, filled from
their results) gets those results files, as PySD's ``data_files``.  The results
(a column per variable or element, a row per saved time, every SAVEPER from
the initial to the final time) go to <out.tab>, readable as a parent's results by the next model.
"""
import functools
import sys
import time
import warnings

import numpy as np
import pandas as pd
import pysd

warnings.filterwarnings("ignore")
# results files read to the last digit (pandas' default float parser isn't
# exact: it changes the last digit of many values)
pd.read_table = functools.partial(pd.read_table, float_precision="round_trip")
pd.read_csv = functools.partial(pd.read_csv, float_precision="round_trip")

mdl, out, parents = sys.argv[1], sys.argv[2], sys.argv[3:]
t = time.time()
model = pysd.read_vensim(mdl, data_files=parents or None)
print("translated and loaded", round(time.time() - t, 1), "s", flush=True)
c = model.components
t0, tf, save = c.initial_time(), c.final_time(), c.saveper()
t = time.time()
res = model.run(return_timestamps=list(np.arange(t0, tf + save / 2, save)), flatten_output=True)
print("run", round(time.time() - t, 1), "s", res.shape, flush=True)
res.index.name = "Time"
res.to_csv(out, sep="\t")
