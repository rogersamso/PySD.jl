# Reference

## Writing and building models

```@docs
@equations
EquationSet
Model
StatefulOperator
check_units
variables
```

## Inputs: Excel, lookups, other models

These are written inside `@equations`, where they are found without being
imported.

```@docs
PySD.ExcelSheet
PySD.constant
PySD.lookup
PySD.data
series_file
PySD.piecewise_linear
```

## Arrays

```@docs
PySD.sum_over
PySD.previous
PySD.vector_sort_order
PySD.vector_rank
PySD.vector_reorder
PySD.vector_select
PySD.allocate_by_priority
PySD.allocate_available
```

## Running and results

```@docs
run_model
Results
SciMLBase.ODEProblem(::Model)
```

## Precompiling a model

```@docs
@precompile_model
```

## The equations as LaTeX

```@docs
pysd_export_latex
```

## Helpers for translated ODE and MTK models

Models translated with PySD's `backend="mtk"` are ModelingToolkit systems
that call these helpers, as do plain Julia ODE functions translated with its
former `backend="ode"`.  Models written with `@equations`, or translated with
`backend="dsl"`, don't need them.

### Helpers for Vensim functions

| Function | Vensim equivalent |
|---|---|
| `pysd_xidz(x, y, z)` | `XIDZ`: `x / y`, or `z` when `y == 0` |
| `pysd_zidz(x, y)` | `ZIDZ`: `x / y`, or `0` when `y == 0` |
| `pysd_pulse(t, start, width)` | `PULSE` |
| `pysd_pulse_train(t, start, interval, width, end)` | `PULSE TRAIN` |
| `pysd_ramp(t, slope, start, end)` | `RAMP` |
| `pysd_step(t, height, step_time)` | `STEP` |
| `PythonMath.exp(x)`, `PythonMath.log(x)`, `PythonMath.sin(x)`, … | `EXP`, `LN`, `SIN`, … with Python PySD's digits |
| `PythonMath.log(x) / PythonMath.log(base)` | `LOG` |
| `trunc(x)`; in ModelingToolkit equations `ifelse(x < 0, ceil(x), floor(x))`, as Symbolics has no symbolic `trunc` | `INTEGER` |
| `pysd_logical_and(a, b)`, `pysd_logical_or(a, b)`, `pysd_logical_not(a)` | `:AND:`, `:OR:`, `:NOT:` |
| `pysd_random_0_1()`, `pysd_random_uniform(…)`, `pysd_random_normal(…)`, `pysd_random_exponential(…)` | the `RANDOM` functions (a new number at every evaluation) |
| `pysd_vector_sort_order`, `pysd_vector_rank`, `pysd_vector_reorder` | the `VECTOR` functions |
| `pysd_allocate_by_priority`, `pysd_allocate_available` | `ALLOCATE BY PRIORITY`, `ALLOCATE AVAILABLE` |

```@docs
PythonMath
pysd_vector_select
pysd_not_implemented
```

### Excel and data files

Excel files are cached in memory: one read per file per session.

```@docs
pysd_xlsx_read_constant
pysd_xlsx_read_series
pysd_xlsx_build_lookup_dispatch
pysd_tab_read_series
pysd_build_tab_itp
```

### Changing a model's inputs between runs

A model translated with PySD's former ODE backend: its `params(; name = value, ...)` builds its constants,
lookups and data with the given values in place of its own (see PySD's
documentation, "Scenarios").

```@docs
pysd_input
pysd_lookup
PySDFunction
pysd_check_inputs
pysd_check_fixed
pysd_file
```

### Fixed delays and samples

What the ODE and MTK backends write for `DELAY FIXED` and `SAMPLE IF TRUE`:
records at the model's ticks, which a solver stops at
([Solvers and the model's ticks](@ref)).

```@docs
PySDTicks
PySDRecord
pysd_fixed_delay
pysd_sampled
pysd_tick_time
pysd_tick_uniform
pysd_tick_normal(::PySDRecord, ::Any, ::Any, ::Any)
pysd_record!
pysd_ticks_callback
pysd_begin_tick!
pysd_reset_ticks!
pysd_free_ticks!
```

### Results and versions

```@docs
save_results
check_compat
```
