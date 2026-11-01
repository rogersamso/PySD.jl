# Translating a Vensim model

A Vensim model (`.mdl`) becomes a PySD.jl model with PySD's Julia builder.
It parses the model as Python PySD does, and writes the equations in
PySD.jl's language ([Writing models](@ref)): readable Julia files that can be
run, changed, and kept in version control.

## The translator

The builder is not in a PySD release yet.  It is on the `exp/julia-dsl`
branch of [rogersamso/pysd](https://github.com/rogersamso/pysd/tree/exp/julia-dsl):

```sh
git clone -b exp/julia-dsl https://github.com/rogersamso/pysd.git
pip install -e pysd
```

```python
import pysd
pysd.translate_to_julia("my_model.mdl", backend="dsl", split_views=True)
```

- `backend="dsl"` writes PySD.jl's language.  (The other backends, `"ode"`
  and `"mtk"`, write an older form: a plain ODE function or a
  ModelingToolkit system, which call the helpers listed under
  [Helpers for translated ODE and MTK models](@ref).)
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

A translated model needs the PySD.jl its translation is written for: the copy
in PySD's checkout, as a git submodule (the model's package requires that
version, and `check_compat` warns on load if another is installed):

```julia
using Pkg
Pkg.develop(path = "pysd/pysd/builders/julia/PySD.jl")
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

The translator stops with an error naming the equation for:

- `FORECAST`;
- the `RANDOM` functions;
- `VECTOR SELECT`, `VECTOR RANK`, `VECTOR SORT ORDER`, `VECTOR REORDER`;
- `ALLOCATE BY PRIORITY`, `ALLOCATE AVAILABLE`;
- `GET TIME VALUE`;
- `ACTIVE INITIAL` inside an expression (on its own, it is translated).

[Vensim functions](@ref) lists every function with its form in PySD.jl.
