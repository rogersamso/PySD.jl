# Running a model

```@setup running
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
    ∂t(x) ~ g
    x(t₀) ~ 1
end
m = Model(growth; time = 0:0.25:20, time_unit = u"yr")
```

[`run_model`](@ref) runs a model with Euler steps of Δt, as Vensim, and
saves every `saveat`:

```@example running
r = run_model(m)
r[:x]
```

The results give each name's values at the saved times (`r.time`): a vector
of numbers, or of arrays with their dimensions.  A parameter gives its value.

## Running again with other values

`Model` compiles the model once.  After that, running it with other parameter
values or other input sheets is fast, and compiles nothing:

```julia
r2 = run_model(m; params = (; k = 0.2))
r3 = run_model(m; inputs = (; scenario = excel("scenarios.xlsx", "High")))
```

The one exception is a parameter that sets the structure of an operator,
such as the time of a fixed delay (the number of steps it keeps) or the
order of a smooth.  Changing it needs the model built again, and `run_model`
says so with an error rather than ignoring the new value.

## Checking units

```julia
run_model(m; check_units = true)      # stops if an equation's units don't add up
run_model(m; check_units = :warn)     # prints them and runs
check_units(m)                        # the list
```

## Results as tables

The results are a [Tables.jl](https://github.com/JuliaData/Tables.jl) table,
with a column for the time and one per name and element, named as in
Vensim's outputs and Python PySD's DataFrame (`stock[north,a]`); and
`DimStack(r)` is a DimensionalData `DimStack`, a layer per name over the time
(`Ti`) and its dimensions, as xarray's datasets:

```julia
using DataFrames, CSV
df = DataFrame(r)                       # a column per name and element
CSV.write("results.csv", r)
st = DimStack(r)                        # st[:x][Ti = At(10.0)]
```

Parameters are in both, as in Python PySD's DataFrame (a column at every
time in the table; without the time in the `DimStack`); lookups and data
series are functions, in neither.

## Data from other models or from files

A model can take series from outside it, as Vensim's data variables without
an equation: from another model's run (a regional model fed by a global one),
or from a file of series:

```julia
@parameters begin
    temperature_change = data(parents, :temperature_change), [unit = u"K"]
end
…
damage ~ f(temperature_change(t))
```

`parents` is an input, a tuple of sources given when the model is built and
when it runs; each series comes from the first source that has it, by name,
interpolated linearly between the source's times.  A source is a run
(`run_model(…)`) or a file, [`series_file`](@ref)`("history.tab")`: a `.csv`
or `.tab` with the times in the first column and a column per series named
as in Vensim (`Temperature change`, `GDP[EU]`), or a row per series, as
Python PySD's `data_files`.

```julia
w  = run_model(world)
eu = run_model(europe; inputs = (; parents = (w,)))
w2 = run_model(world; params = (; k = 0.2))           # another world …
eu2 = run_model(europe; inputs = (; parents = (w2,)))  # … the same Europe, no rebuild
eu3 = run_model(europe; inputs = (; parents = (series_file("world.tab"),)))   # from a file
```

## The equations as LaTeX

```julia
using Latexify                          # loads PySD.jl's LaTeX export
pysd_export_latex(m; filename = "model.tex")
```

writes the equations as they are written: a section per set of equations (a
view of a translated model), stocks as dx/dt, `sum_over` as Σ, `ifelse` as
cases, selections as `x[a]`, and a table of the names with their units and
descriptions.  Without `filename` it returns the LaTeX as a string.
