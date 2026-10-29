# PySD.jl news

What changes in each version, newest first.  Each version's
[release](https://github.com/rogersamso/PySD.jl/releases) has the full notes
and the tests run before it.

## Unreleased

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
