# Translating a Vensim model

A Vensim model (`.mdl`) becomes a PySD.jl model with PySD's Julia builder.
It parses the model as Python PySD does, and writes the equations in
PySD.jl's language ([Writing models](@ref)): readable Julia files that can be
run, changed, and kept in version control.

## The translator

The builder is part of [PySD](https://github.com/SDXorg/pysd):

```sh
pip install pysd
```

The DSL backend (`backend="dsl"`) comes with the PySD release that includes
[SDXorg/pysd#526](https://github.com/SDXorg/pysd/pull/526).  Until then,
install PySD from that pull request:

```sh
pip install "pysd @ git+https://github.com/SDXorg/pysd.git@refs/pull/526/head"
```

```python
import pysd
pysd.translate_to_julia("my_model.mdl", backend="dsl", split_views=True)
```

- `backend="dsl"` (the default) writes PySD.jl's language.  The other
  backend, `"mtk"`, writes a ModelingToolkit system, which calls the
  helpers listed under [Helpers for translated ODE and MTK models](@ref).
  (PySD's `"ode"` backend, a plain ODE function, was removed; models
  translated with it still run with these helpers.)
- `split_views=True` writes one file per view of the Vensim sketch, as the
  modeller grouped the equations.  Without it, one file holds them all.

## What it writes

A folder `my_model_dsl/` next to the model:

```
my_model_dsl/
├── my_model.jl        # includes the rest and ends with Model(…)
├── units.jl           # the model's own units (@refunit), registered with Unitful
├── dims.jl            # the subscript ranges, as DimensionalData dimensions
├── inputs.jl          # the Excel files and sheets the model reads, by name
├── <view>.jl          # one @equations set per view
├── names.tsv          # Vensim's name of each variable, and its Julia name
├── Project.toml       # the folder is also a package …
└── src/MyModel.jl     # … that loads in seconds (Models as packages)
```

Names become Julia names: lower case, `_` for spaces (`Teacup
temperature` → `teacup_temperature`).  The results are saved with Vensim's
names (`names.tsv`), so they compare directly with Vensim's or Python
PySD's outputs.

The last file, `my_model.jl`, builds the model:

```julia
my_model = Model(view_a, view_b, …, inputs, time = 1995:0.03125:2050, saveat = 1,
                 time_unit = u"yr", numerics = :python)
```

with Vensim's `INITIAL TIME`, `TIME STEP`, `FINAL TIME` and `SAVEPER`.
`numerics = :python` keeps Python PySD's last digits (the C maths library,
numpy's order of additions), to compare with its results bit for bit; the
default, `:julia`, uses Julia's own functions.

## Running it

A translated model needs the PySD.jl release its translation is written for:
the model's package names it (`[compat]` in its `Project.toml`), and
`check_compat` warns on load if another is installed.  Install PySD.jl as on
the [Home](@ref "PySD.jl") page, and check that release out:

```sh
cd ~/.julia/dev/PySD && git checkout v0.6.0      # the version in [compat]
```

Then:

```julia
using PySD
m = include("my_model_dsl/my_model.jl")
r = run_model(m)
```

or, to build and compile it only once, as a package
([Models as packages](@ref)):

```julia
using Pkg; Pkg.develop(path = "my_model_dsl")
using MyModel
r = run_model(MyModel.model)
```

### Input sheets and scenarios

Constants, lookups and data that Vensim reads from Excel (`GET DIRECT
CONSTANTS`, `GET DIRECT LOOKUPS`, `GET DIRECT DATA` and the `GET XLS`
forms) are read from the sheets named in `inputs.jl`.  A scenario that is
another sheet of the same layout is given to the run, with no rebuild:

```julia
r = run_model(m; inputs = (; scenario = excel("scenarios.xlsx", "High")))
```

### Models fed by other models

Vensim data variables without an equation (to be filled from another
model's results) become `data(parents, :name)`: the series is taken from the
runs or files given as `parents` ([Data from other models or from files](@ref)).

```julia
w  = run_model(world)
eu = run_model(europe; inputs = (; parents = (w,)))
```

## What isn't translated yet

**Functions it does not know** (as `LOOKUP FORWARD`): the translation
finishes with a warning, and writes `error("Not implemented function 'NAME' …")`:
the model stops with an error naming the function, as Python PySD's
translations do.

**Constructs.**  For these the translation stops with an error naming the
equation:

- `GET TIME VALUE` other than `GET TIME VALUE(0, offset, 0)` (the time plus an
  offset, which is translated);
- time settings that change during the run (a `FINAL TIME` that depends on a
  variable or on `Time`); time settings that are expressions of numbers are
  translated;
- `DELAY FIXED` of an expression (of a variable it is translated);
- macros with several outputs (`:MACRO: NAME(input : output)`); macros of one
  output are written in place, a copy of their equations per call.

[Vensim functions](@ref) lists every function with its form in PySD.jl.
PySD's reference tests list the test models still known to fail, with the
reason (`KNOWN_FAILURES` in `tests/pytest_builders/pytest_julia_reference.py`).
