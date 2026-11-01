# PySD.jl

System dynamics models in Julia: Vensim models translated by
[PySD](https://github.com/SDXorg/pysd), or models written directly in Julia.

- **Write** a model as equations, with units and named dimensions
  ([Writing models](@ref)), or **translate** one from Vensim
  ([Translating a Vensim model](@ref)).
- **Run** it with Vensim's Euler steps, with the same results as Vensim and
  Python PySD, or with any of [SciML](https://docs.sciml.ai/DiffEqDocs/stable/)'s
  ODE solvers ([Solvers and the model's ticks](@ref)).
- **Run it again** with other parameters or input sheets without compiling
  anything: the many runs of a sensitivity analysis, derivatives with
  ForwardDiff.jl, uncertainties with Measurements.jl
  ([Sensitivity and derivatives](@ref)).
- **Load** a large model in seconds by keeping it in a package
  ([Models as packages](@ref)).

## Installation

PySD.jl isn't in Julia's General registry yet.  Install it from GitHub:

```julia
using Pkg
Pkg.develop(url = "https://github.com/rogersamso/PySD.jl")
```

`Pkg.develop` clones the repository (into `~/.julia/dev/PySD`, on `main`;
`git checkout v0.3.2` there for a release).  `Pkg.add(url = …)` doesn't work:
it can't clone the test models' git submodule.

## A first model

A stock `x` that grows at a rate `k`:

```@example index
using PySD, Unitful

growth = @equations begin
    @parameters begin
        k = 0.1, [unit = u"1/yr", description = "growth rate"]
    end
    @variables begin
        x(t), [unit = u"kg"]
        g(t), [unit = u"kg/yr"]
    end
    g ~ k * x
    ∂t(x) ~ g              # a stock: its rate of change
    x(t₀) ~ 1              # and its initial value
end

m = Model(growth; time = 0:0.25:20, time_unit = u"yr")
r = run_model(m)
r[:x][end]                 # x at the final time
```

`Model` checks the equations and their units, sorts them and compiles the
model once.  `run_model` takes Euler steps of Δt (here 0.25 years), as
Vensim, and saves every year.  Running it again with another growth rate
compiles nothing:

```@example index
run_model(m; params = (; k = 0.2))[:x][end]
```

## Where it comes from

Writing models in Julia borrows from:

- [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl):
  `@equations` takes the form of its `@mtkmodel`: `@parameters` and
  `@variables` blocks, `~` for equations, `x(t)` for what changes with time,
  and a unit and description after each declaration.
- [BPTK-Py](https://github.com/transentis/bptk_py): stocks that can't go
  below zero (`nonnegative = true`), parts of a model written once and used
  several times, with their names in the results after the part's
  (`retailer.inventory`, `wholesaler.inventory`), and errors that name the
  algebraic loop (`a → b → a`).
- [DimensionalData.jl](https://github.com/rafaqz/DimensionalData.jl): arrays
  with named dimensions, as xarray's in Python PySD.
- [Unitful.jl](https://github.com/PainterQubits/Unitful.jl): units, and
  checking that each equation's units add up.
- [Vensim](https://vensim.com/) and [PySD](https://github.com/SDXorg/pysd):
  the functions and their behaviour, and the reference outputs the tests
  compare against ([SDXorg/test-models](https://github.com/SDXorg/test-models)).

Also related: [StockFlow.jl](https://github.com/AlgebraicJulia/StockFlow.jl),
stock-and-flow diagrams in Julia, with composition and stratification.

PySD.jl is released under the MIT License.
