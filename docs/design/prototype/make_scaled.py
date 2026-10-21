"""Write a synthetic 200 x 50 Vensim model and translate it with the current Julia builder (ODE)."""
import sys
import warnings
from pathlib import Path

import pysd

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
na, nb = 200, 50
a = ", ".join(f"a{i}" for i in range(1, na + 1))
b = ", ".join(f"b{i}" for i in range(1, nb + 1))
w = ", ".join(str(i) for i in range(1, nb + 1))
mdl = f"""{{UTF-8}}
A:
\t{a}
\t~\t~\t|

B:
\t{b}
\t~\t~\t|

growth=
\t0.001
\t~\t1/Month
\t~\t|

weight[B]=
\t{w}
\t~\t~\t|

inflow[A,B]=
\tgrowth * stock[A,B] * weight[B] / SUM(weight[B!])
\t~\t~\t|

stock[A,B]= INTEG (
\tinflow[A,B], 1)
\t~\t~\t|

total=
\tSUM(stock[A!,B!])
\t~\t~\t|

********************************************************
\t.Control
********************************************************~
\t\tSimulation Control Parameters
\t|

FINAL TIME  = 100
\t~\tMonth
\t~\t|

INITIAL TIME  = 0
\t~\tMonth
\t~\t|

SAVEPER  = 1
\t~\tMonth
\t~\t|

TIME STEP  = 0.25
\t~\tMonth
\t~\t|
"""
path = out / "scaled.mdl"
path.write_text(mdl, encoding="utf-8")
with warnings.catch_warnings():
    warnings.simplefilter("ignore")
    jl = pysd.translate_to_julia(path)
print(jl, len(jl.read_text().splitlines()), "lines")
