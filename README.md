# PySD.jl

[![CI](https://github.com/rogersamso/PySD.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/rogersamso/PySD.jl/actions/workflows/CI.yml)
[![Coverage](https://codecov.io/gh/rogersamso/PySD.jl/graph/badge.svg)](https://codecov.io/gh/rogersamso/PySD.jl)
[![Docs](https://img.shields.io/badge/docs-stable-blue.svg)](https://rogersamso.github.io/PySD.jl/stable/)
[![Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://rogersamso.github.io/PySD.jl/dev/)

System dynamics models in Julia: Vensim models translated by
[PySD](https://github.com/SDXorg/pysd), or models written directly in Julia.
They run with Vensim's Euler steps, with the same results as Vensim and
Python PySD, or with any of [SciML](https://docs.sciml.ai/DiffEqDocs/stable/)'s
ODE solvers; and again with other parameters without compiling anything, for
sensitivity analyses, derivatives and uncertainties.

**[Documentation](https://rogersamso.github.io/PySD.jl/stable/)**

## Installation

PySD.jl isn't in Julia's General registry yet.  Install it from GitHub:

```julia
using Pkg
Pkg.develop(url = "https://github.com/rogersamso/PySD.jl")
```

(`Pkg.add(url = …)` doesn't work: it can't clone the test models' git
submodule.)

## A first model

```julia
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

m = Model(growth; time = 0:0.25:100, time_unit = u"yr")
r = run_model(m)
r[:x]                                   # x at each saved time
run_model(m; params = (; k = 0.2))      # again, with another rate: nothing compiled
```

## In the documentation

- [Translating a Vensim model](https://rogersamso.github.io/PySD.jl/stable/translating/)
- [Writing models](https://rogersamso.github.io/PySD.jl/stable/writing/): units, arrays, components
- [Running a model](https://rogersamso.github.io/PySD.jl/stable/running/): other values, input sheets, data from other models, tables
- [Solvers and the model's ticks](https://rogersamso.github.io/PySD.jl/stable/solvers/): Euler as Vensim, or any SciML solver
- [Sensitivity and derivatives](https://rogersamso.github.io/PySD.jl/stable/sensitivity/): sweeps on several threads, ForwardDiff, Measurements
- [Models as packages](https://rogersamso.github.io/PySD.jl/stable/packages/): load a large model in seconds
- [Vensim functions](https://rogersamso.github.io/PySD.jl/stable/functions/), and the [reference](https://rogersamso.github.io/PySD.jl/stable/api/)
- [News](NEWS.md)

## Running the tests

```sh
git submodule update --init test/test-models
julia --project -e 'using Pkg; Pkg.test()'
```

More in [Development](https://rogersamso.github.io/PySD.jl/stable/development/).

## License

PySD.jl is released under the [MIT License](LICENSE).
