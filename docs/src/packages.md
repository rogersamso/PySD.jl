# Models as packages

Building and compiling a large model takes minutes, every time a new Julia
session starts.  To do that only once, keep the model in a package: Julia
saves the built and compiled model when the package is first used, and later
sessions load it ready to run.

A model folder becomes a package with two more files:

```
mymodel/
├── Project.toml        # name = "MyModel", uuid, and PySD in [deps]
├── src/MyModel.jl
├── mymodel.jl          # the model, as before: it ends with Model(…)
└── …                   # its other files, as before
```

```julia
# src/MyModel.jl
module MyModel
using PySD
@precompile_model model = include("../mymodel.jl")
end
```

`[`@precompile_model`](@ref) defines `model` (a constant), and builds and runs it once
while Julia precompiles the package, so that all this compiles is saved with
the package.

Then:

```julia
using Pkg; Pkg.develop(path = "mymodel")   # once, in the environment that has PySD.jl
using MyModel                              # later sessions: seconds
r = run_model(MyModel.model; params = (; k = 0.2))
```

- The first `using MyModel` builds and compiles the model and saves it; it
  takes as long as building it without a package, but only once.  For a
  model of 1,867 names: about 8 minutes the first time, then about 8 s to
  load it and 6 s for its first run in every later session (instead of about
  9 minutes in each session).
- When one of the model's files or one of its Excel sheets changes, Julia
  notices at the next `using` and builds it again, once.
- Running with other parameters or inputs works as always and needs no
  rebuild.
- A unit module of the model's own (`@refunit`s) is registered with Unitful
  both when it's defined (`Unitful.register(MyUnits)` after the module) and
  when the package loads it (an `__init__` that does the same), as PySD
  writes it for translated models.

PySD (`translate_to_julia(model; backend = "dsl")`) writes Vensim models in
this form, package files included.
