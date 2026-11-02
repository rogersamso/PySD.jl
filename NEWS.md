# PySD.jl news

What changes in each version, newest first.  Each version's
[release](https://github.com/rogersamso/PySD.jl/releases) has the full notes
and the tests run before it.

## 0.6.1 (2026-11-02)

Documentation only (#46): install the translator from PySD (not a fork), and
what isn't translated yet, as of 0.6.0.  The code is the same as 0.6.0.

## 0.6.0 (2026-11-01)

### Added

- **RANDOM in models written with `@equations`**: `random_0_1`,
  `random_uniform`, `random_normal` and `random_exponential`, drawn once per
  tick and held in between, from a generator seeded from the seed, the call,
  the element and the tick: every run draws the same, with any solver.
  `dims = d` draws per element of `d` where the arguments are numbers.
- **`pysd_not_implemented(name, args...)`**: what PySD's translator writes for
  a function it does not translate, as Python PySD: the model stops with an
  error naming it when it evaluates it (before, a placeholder 0.0 or an
  undefined name).

### Fixed

- **RANDOM NORMAL and RANDOM EXPONENTIAL as Python PySD's** in translated
  models: `pysd_tick_normal(record, a, b, t)` and `pysd_tick_exponential(record,
  b, t)` draw truncated (again while outside), where 0.5.0's translations cut
  the draws at the bounds, and took RANDOM EXPONENTIAL's third argument as its
  scale (it is the shift; the fourth, the stretch).

## 0.5.0 (2026-11-01)

### Added

- **RANDOM functions drawn once per tick, in translated models**:
  `pysd_tick_uniform`, `pysd_tick_normal` and `pysd_tick_exponential` give a
  standard draw for the tick, from a generator seeded from the call's stream,
  the element and the tick.  So a draw holds between ticks, the values read
  after a run are the ones the run used, and every run, with any solver,
  draws the same.  (`pysd_random_*` draw at every call, and ignore the seed.)
- **Switches on the time exact at the ticks, in translated models**
  (`pysd_tick_time`), as in models written with `@equations` since 0.4.0.

### Changed

- **The warning for equations written for Euler steps of Δt names fewer**:
  not an equation that depends on the time alone (parameters, data series,
  lookups, and fixed delays or samples of them), such as a finite difference
  of data, `(data(t + Δt) - data(t)) / Δt`, the same with any solver.

### Fixed

- **PySD compiles in 40 s again** (about 7 min with 0.4.0).  The functions
  0.4.0 registered with Symbolics for MTK models took up to nine arguments,
  and Symbolics adds a method for every combination of plain and symbolic
  arguments: 19,437 for `pysd_sampled`.  The record they read is now one
  argument, `PySDRecord(ticks, key, n, I...)` (163 methods).  The calls of
  0.4.0 still work in ODE models.
- **Runs on several threads at once** (a sweep, an ensemble): the input
  sheets the runs read are cached behind a lock.  Tested with two threads.

## 0.4.0 (2026-11-01)

### Added

- **Fixed delays and samples of models translated with PySD's ODE and MTK
  backends, with any solver** (`src/ticks.jl`).  `PySDTicks` keeps a record
  per fixed delay and sample, a value per tick of the model; the generated
  code reads them (`pysd_fixed_delay`, `pysd_sampled`, registered with
  Symbolics for MTK) and `pysd_ticks_callback` makes a solver stop at every
  tick to record them.  Before, the translator wrote them as stocks that are
  exact only with Euler steps of TIME STEP.

### Changed

- **Fixed delays and SAMPLE IF TRUE keep histories instead of hidden stocks**
  ([#33](https://github.com/rogersamso/PySD.jl/issues/33)).  With Euler steps
  of Δt (`run_model(m)`, or `Euler()` with `dt = Δt`) they give Vensim's values
  as before, now copied exactly (the stocks gave s + (x - s), off in the last
  digit at times), and the state vector no longer holds a stage per step of
  delay.
- **Fixed delays and SAMPLE IF TRUE run with any solver.**  They move at the
  model's ticks, every Δt, as Vensim: a solver now stops at each tick, where
  they record and move, and holds them between ticks.  Before, other solvers
  gave values that weren't Vensim's model (the delays acted as smooths of
  time Δt, and `sample_if_true(t == year, x)` never sampled).  `Euler()` with
  `dt = Δt` still gives Vensim's values; other solvers give more accurate
  stocks, never faster runs.
- **Switches on the time are exact at the ticks with any solver.**  A model
  with `t ≥ 2015`, STEP, PULSE or PULSE TRAIN stops at the ticks too, and a
  solver's step ending at a tick sees the time just before it (Runge-Kutta's
  last stage saw the switch already on, a sixth of a step early with RK4).
- **A warning names the equations written for Euler steps of Δt** (Δt as a
  value, the time tested for equality, non-negative stocks) when a model is
  solved with any other solver than `Euler()` with `dt = Δt`.
- **First runs compile faster** (#34): each equation reads the state itself,
  so the function that calls them is much quicker to compile.  On a large
  model (about 71,000 states), the initial values, a step and a saved row
  compile in 113, 38 and 36 s, from 143, 52 and 55 s.
- **Documentation** (#38), built with Documenter.jl and published at
  https://rogersamso.github.io/PySD.jl/: the guide, every Vensim function,
  the reference.

## 0.3.2 (2026-10-29)

### Fixed

- Stiff solvers that compute the Jacobian with ForwardDiff (`Rodas5P()` and
  the other Rosenbrock methods, by default) work on models with arrays: the
  step writes into buffers of its state's number type when it isn't the
  run's ([#31](https://github.com/rogersamso/PySD.jl/pull/31)).

## 0.3.1 (2026-10-29)

### New

- **Derivatives and uncertainties through a run**
  ([#26](https://github.com/rogersamso/PySD.jl/pull/26)).  A run computes in
  the number type of its parameters: with ForwardDiff.jl, the exact
  derivative of any result in a parameter (for calibration, or sensitivity),
  and with Measurements.jl, a parameter's uncertainty carried to every
  result, in one run.
- **SciML's ODE solvers** ([#27](https://github.com/rogersamso/PySD.jl/pull/27)).
  `run_model(m, solver)` runs a model with any of them and gives the same
  `Results`; `ODEProblem(m)` is the model as a SciML problem (callbacks,
  ensembles of runs, …), and `Results(m, sol)` the values from its solution.
  Euler with steps of Δt gives Vensim's values; with other solvers, fixed
  delays and `sample_if_true` aren't Vensim's, and `run_model` warns.
  Loaded with SciMLBase, which any SciML solver package loads.
- **Results as tables** ([#28](https://github.com/rogersamso/PySD.jl/pull/28)).
  `Results` is a Tables.jl table, a column per name and element named as in
  Vensim's outputs and Python PySD's DataFrame (`stock[north,a]`), so
  `DataFrame(r)` and `CSV.write(path, r)` work; `DimStack(r)` is a
  DimensionalData dataset, a layer per name over the time and its
  dimensions.

### Project

- MIT license ([#23](https://github.com/rogersamso/PySD.jl/pull/23)), a
  contributing guide ([#22](https://github.com/rogersamso/PySD.jl/pull/22)),
  and test coverage on Codecov
  ([#24](https://github.com/rogersamso/PySD.jl/pull/24)).

### Compatibility

Nothing changes for models translated for 0.3.0 or 0.2.x.  New dependency:
Tables.jl (already loaded through DimensionalData and XLSX).  New optional
one: SciMLBase (2.116 or later).

## 0.3.0 (2026-10-28)

### New

- **The DSL** ([#21](https://github.com/rogersamso/PySD.jl/pull/21)): models
  written in Julia with `@equations`, `Model` and `run_model`, every name
  declared with its unit and description; arrays with DimensionalData
  dimensions, smooths, delays, trends, sample-if-true, lookups, and inputs
  from Excel.
- Units checked with `check_units(m)`; other parameter values and input
  sheets without compiling again; data from other models' runs or files of
  series; models as packages (`@precompile_model`), loaded in seconds;
  Python's digits (`numerics = :python`); the equations as LaTeX.
- `benchmark/`: a translated model timed against Python PySD, and their
  results compared.

PySD's DSL backend (`translate_to_julia(model, backend = "dsl")`) writes
Vensim and XMILE models in this language.

### Compatibility

Models of the ODE and MTK backends translated for 0.2.x still load.  On
Julia 1.10 a model's step sometimes allocates a few hundred bytes; from
Julia 1.11 it allocates nothing.

## 0.2.7 (2026-10-24)

### Changed

- The same digits as numpy: `pysd_sum` adds in numpy's pairwise order and
  `pysd_sum_seq` one element after the other, `INVERT MATRIX` uses LAPACK's
  `gesv`, and `pysd_exp`, `pysd_ln`, `pysd_sin`, … and `pysd_power` call the
  platform's C maths library, as numpy does.  `SafeArray` reads elements
  outside its size as NaN, as Python PySD.

## 0.2.6 (2026-10-23)

### Fixed

- `LN`, `SQRT`, `ARCSIN`, `ARCCOS` and `LOG` out of their domain give NaN,
  as numpy, instead of a `DomainError` (a branch of `IF THEN ELSE` that
  isn't taken stopped the run)
  ([#15](https://github.com/rogersamso/PySD.jl/pull/15)).
- A named range local to several sheets is read from the requested sheet.

## 0.2.5 (2026-10-23)

### New

- Scenarios for generated ODE models: `params(; name = value, …)` builds the
  constants, lookups and data with other values, and what is computed from
  them follows; replacing a lookup doesn't compile the model again
  ([#14](https://github.com/rogersamso/PySD.jl/pull/14)).

### Fixed

- A series of one point has the same value everywhere, as in Python PySD.
- XLSX.jl 0.11 at least: with 0.10, named ranges failed.

## 0.2.4 (2026-10-22)

### Fixed

- `pysd_xidz` and `pysd_zidz` treat denominators below 1e-6 as zero, also
  in MTK models ([#12](https://github.com/rogersamso/PySD.jl/pull/12)).
- Excel numbers stored as text are read as numbers, and square blocks of
  Excel series take their direction from the x range
  ([#13](https://github.com/rogersamso/PySD.jl/pull/13)).

## 0.2.3 (2026-10-22)

### Changed

- `pysd_vector_select` takes Vensim's five arguments and its 11 numerical
  actions; `:raw` data give values at the data times only; Excel series with
  missing values are filled as Python PySD does
  ([#9](https://github.com/rogersamso/PySD.jl/pull/9)).

## 0.2.2 (2026-10-22)

### New

- `.xls` files and delimited text files (`.csv`, `.tab`, …) for GET XLS and
  GET DIRECT CONSTANTS, LOOKUPS and DATA, as Python PySD
  ([#7](https://github.com/rogersamso/PySD.jl/pull/7)).

### Fixed

- A defined name takes precedence over a cell reference that looks the same.

## 0.2.1 (2026-10-21)

### Fixed

- `pysd_power` with a negative base, `pysd_pulse` and `pysd_pulse_train`
  with Vensim's time tolerance, XMILE's `PULSE`, 0-based
  `pysd_vector_sort_order`, and `.tab` files with any line ending, as
  Vensim and Python PySD.

## 0.2.0 (2026-10-21)

### Changed

- `save_results` writes one NetCDF dimension per subscript range, as Python
  PySD's NetCDF output.

### New

- `ALLOCATE AVAILABLE` and `ALLOCATE BY PRIORITY`; data from `.tab` and
  `.csv` files; a test suite against SDXorg/test-models, and CI.

## 0.1.0 (2026-06-28)

The first version: the runtime functions for models generated by PySD's
Julia builder.
