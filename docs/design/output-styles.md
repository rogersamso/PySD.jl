# Design proposal: three output styles for the PySD Julia builder

*Status: proposal for discussion (October 2026). Prototype in [`prototype/`](prototype/).*

PySD's Julia builder (`pysd.translate_to_julia`) writes models that are correct
for most test models, but **hard to read, hard to edit by hand and slower than
necessary**. This proposal has three output styles, each meant for a different
use:

| Style | What it is | For |
|---|---|---|
| **ODE** | Plain Julia, cleaner: named state, constants written once, array operations | Everyday runs, large models, editing a translated model |
| **MTK** | ModelingToolkit, symbolic equations | Symbolic analysis, model transformations, LaTeX |
| **DSL** | Our own modelling language: Vensim's good parts, mathematical notation | Writing new models from scratch; translator output that reads like the source |

The idea is that a model written in the DSL can later **generate** both the
ODE and the MTK forms, so the Python translator only has to produce DSL text.

Every ODE and MTK example below was run and compared with Vensim's output for
the same test model (see [Measurements](#measurements)).

---

## 1. What the current output looks like

Vensim (test-models `subscript_2d_arrays`):

```
Stock A[One Dimensional Subscript, Second Dimension Subscript] = INTEG(Inflow A[...], Initial Values[...])
Inflow A[One Dimensional Subscript, Second Dimension Subscript] = Rate A[...]
Rate A[One Dimensional Subscript, Second Dimension Subscript]   = 0.01, 0.02; 0.03, 0.04; 0.05, 0.06;
Initial Values[...] = 1, 2; 3, 4; 5, 6;
```

Current Julia output (excerpt; `observe` repeats the whole auxiliary part):

```julia
function rhs!(du, u, p, t)
    stock_a = reshape(@view(u[1:6]), N_ONE_DIMENSIONAL_SUBSCRIPT, N_SECOND_DIMENSION_SUBSCRIPT)
    inflow_a = pysd_safe(zeros(N_ONE_DIMENSIONAL_SUBSCRIPT, N_SECOND_DIMENSION_SUBSCRIPT))
    initial_values = pysd_safe(zeros(3, 2))
    rate_a = pysd_safe(zeros(3, 2))
    initial_values[1, 1] = 1.0
    initial_values[1, 2] = 2.0
    # … one line per cell, rebuilt at every time step
    rate_a[3, 2] = 0.06
    for _i0 in 1:N_ONE_DIMENSIONAL_SUBSCRIPT, _i1 in 1:N_SECOND_DIMENSION_SUBSCRIPT
        inflow_a[_i0, _i1] = rate_a[_i0, _i1]
    end
    du_stock_a = reshape(@view(du[1:6]), N_ONE_DIMENSIONAL_SUBSCRIPT, N_SECOND_DIMENSION_SUBSCRIPT)
    for _i0 in 1:N_ONE_DIMENSIONAL_SUBSCRIPT, _i1 in 1:N_SECOND_DIMENSION_SUBSCRIPT
        du_stock_a[_i0, _i1] = inflow_a[_i0, _i1]
    end
end

u0 = … Float64[initial_values[1, 1], initial_values[2, 1], initial_values[3, 1], …]
```

The problems:
- **State by position**: stocks are slices of `u` (`u[1:6]`), reshaped by hand, with initial values listed in column-major order.
- **Constants rebuilt cell by cell** at every time step, in both `rhs!` and `observe`.
- **Loops** where one array operation would do.
- **Everything written twice** (`rhs!` and `observe`).
- **Hidden stocks** of SMOOTH / DELAY / TREND written out (`_df_pipe_1 … _df_pipe_32`, `_sm_…`).
- **Size**: a 4-equation model with 10,000 stocks becomes **10,190 lines** (see [Measurements](#measurements)).

---

## 2. Style 1: ODE (plain Julia, cleaner)

A model is a module with four definitions; everything else (solver function,
running, reading results, saving) is generic and lives in PySD.jl.

```julia
control                 # Control(initial_time, final_time, time_step, saveper)
params()                # Params(name = value, …): can be changed between or during runs
initial_state(p)        # State(stock = value, …): named state vector
model!(d, s, p, t)      # writes d.<stock> (rates of change), returns the auxiliaries
```

The state is a named, shaped vector ([ComponentArrays.jl](https://github.com/jonniedie/ComponentArrays.jl)):
`s.stock_a` *is* the 3×2 stock, and `d.stock_a .= inflow_a` reads as
"d stock_a / dt = inflow_a". There is no index arithmetic and no column-order
bookkeeping. One `model!` serves both the solver and result reading.

### `subscript_2d_arrays`

```julia
module SubscriptArrays2D
using PySD

# Subscripts
const one_dimensional_subscript = ["Entry 1", "Entry 2", "Entry 3"]
const second_dimension_subscript = ["Column 1", "Column 2"]

const control = Control(initial_time = 0, final_time = 100, time_step = 1)

params() = Params(
    initial_values = [1 2; 3 4; 5 6],
    rate_a = [0.01 0.02; 0.03 0.04; 0.05 0.06],
)

initial_state(p) = State(stock_a = p.initial_values)

function model!(d, s, p, t)
    (; rate_a) = p
    inflow_a = rate_a
    d.stock_a .= inflow_a
    return (; inflow_a)
end

end
```

### `subscript_transposition` (sums over a dimension)

```julia
params() = Params(
    input = [1, 10, 5, 7, 9],
    io_matrix = [ 1  2  3  4  5;
                 10 20 30 40 50;
                  1  2  3  4  5;
                  2  3  4  5  6;
                 -1  2 -3  4 -5],
)

initial_state(p) = State()          # no stocks

function model!(d, s, p, t)
    (; input, io_matrix) = p
    # output[sector1]  = SUM(input[sector!] * io matrix[sector!, sector1])
    output = [sum(input[i] * io_matrix[i, j] for i in eachindex(sector)) for j in eachindex(sector1)]
    # output2[sector1] = SUM(input[sector!] * io matrix[sector1, sector!])
    output2 = [sum(input[i] * io_matrix[j, i] for i in eachindex(sector)) for j in eachindex(sector1)]
    return (; output, output2)
end
```

### `smooth` (stateful functions)

SMOOTH of any order is a chain of stage stocks; `smooth!` (PySD.jl) writes
their rates of change, and the output is the last stage.

```julia
params() = Params(initial_value = 5)

input(t) = -1 + pysd_step(t, 5, 5)
adjustment_time(t) = 2 + pysd_step(t, 2, 10)

initial_state(p) = State(
    smooth   = smooth_initial(input(0)),                 # SMOOTH
    smoothi  = smooth_initial(p.initial_value),          # SMOOTHI
    smooth3  = smooth_initial(input(0), 3),              # SMOOTH3
    smooth3i = smooth_initial(p.initial_value, 3),       # SMOOTH3I
)                                                        # (SMOOTH N omitted in this excerpt)

function model!(d, s, p, t)
    x, τ = input(t), adjustment_time(t)
    smooth!(d.smooth,   s.smooth,   x, τ)
    smooth!(d.smoothi,  s.smoothi,  x, τ)
    smooth!(d.smooth3,  s.smooth3,  x, τ)
    smooth!(d.smooth3i, s.smooth3i, x, τ)
    return (; input = x, adjustment_time = τ,
              smooth_output = s.smooth[end], smoothi_output = s.smoothi[end],
              smooth3_output = s.smooth3[end], smooth3i_output = s.smooth3i[end])
end
```

### Running and analysing

```julia
sol = run_model(SubscriptArrays2D)                 # Euler, as Vensim
res = results(SubscriptArrays2D, sol)              # every variable at every saved time
sol = run_model(SubscriptArrays2D; p = Params(…))  # another scenario
```

Because the model is a standard `f(du, u, p, t)` with named state and
parameters, it can be wrapped as a
[DynamicalSystems.jl](https://juliadynamics.github.io/DynamicalSystemsDocs.jl/)
`CoupledODEs`. That gives step-by-step runs, parameter changes during a run, and
saving/restoring the state, which PySD's Python models offer and the Julia
output does not yet. It also opens up DynamicalSystems' analysis tools
(attractors, continuation, Lyapunov exponents). Tested in `prototype/ds_demo.jl`:

```julia
ds = CoupledODEs(rule!, u0, params; diffeq = (alg = Euler(), dt = 0.25, adaptive = false))
step!(ds, 50.0, true)                  # run to t = 50
set_parameter!(ds, :growth, 0.01)      # scenario switch at t = 50
step!(ds, 50.0, true)                  # continue to t = 100
saved = copy(current_state(ds))        # export the state …
reinit!(ds, saved; t0 = 100.0)         # … and restart from it
```

---

## 3. Style 2: MTK (ModelingToolkit, hand-written quality)

The same models as a person would write them with ModelingToolkit 10
(`System`, `@mtkcompile`, array variables and array equations).

### `subscript_2d_arrays`

```julia
using ModelingToolkit
using ModelingToolkit: t_nounits as t, D_nounits as D

@parameters rate_a[1:3, 1:2] = [0.01 0.02; 0.03 0.04; 0.05 0.06]
@variables begin
    stock_a(t)[1:3, 1:2] = [1.0 2.0; 3.0 4.0; 5.0 6.0]
    inflow_a(t)[1:3, 1:2]
end

equations = [
    inflow_a ~ rate_a
    D(stock_a) ~ inflow_a
]

@mtkcompile sys = System(equations, t)
```

### `subscript_transposition`

Sums over a dimension become linear algebra:

```julia
@parameters input[1:5] = [1.0, 10.0, 5.0, 7.0, 9.0]  io_matrix[1:5, 1:5] = […]
@variables output(t)[1:5] output2(t)[1:5]

equations = [
    output ~ io_matrix' * input     # SUM(input[sector!] * io matrix[sector!, sector1])
    output2 ~ io_matrix * input     # SUM(input[sector!] * io matrix[sector1, sector!])
]
```

### `smooth`

```julia
smooth_equations(s, input, delay_time) = Equation[
    D(s[1]) ~ (input - s[1]) * length(s) / delay_time;
    [D(s[k]) ~ (s[k-1] - s[k]) * length(s) / delay_time for k in 2:length(s)]
]

equations = Equation[
    input ~ -1 + pysd_step(t, 5, 5)
    adjustment_time ~ 2 + pysd_step(t, 2, 10)
    smooth_equations(smooth3, input, adjustment_time)
    smooth3_output ~ smooth3[end]
    …
]
```

MTK is elegant to read, but expensive to start: building and compiling took
**35–50 s plus 25–30 s for the first run**, even for these tiny models. It suits
analysis and transformations better than everyday runs.

---

## 4. Style 3: our DSL

Goals: **concise**, **close to the mathematics**, **easy to start a model from a
blank page**, and taking only the good parts of Vensim's `.mdl` (one equation
per variable, subscripts, the function library), not its separators, sketch
section or `:EXCEPT:` syntax.

Rules:
- It is **valid Julia syntax** (checked with Julia's parser), read by a `@model` macro.
- **Time is implicit**: `STEP(5, 5)`, as in Vensim.
- **Subscripts are index sets** with labels: `@index i ∈ entries = (entry_1, entry_2, entry_3)`.
- **Stocks** are written as differential equations, `∂t(stock[i, j]) = …`, or Vensim-style with `INTEG(…)`.
- **Stateful functions create their stocks automatically**, and related Vensim functions merge into one with options.
- **Descriptions and units** go in a docstring above the equation.

These are syntax sketches (the macro doesn't exist yet), but all three parse as valid Julia.

### `subscript_2d_arrays`

```julia
@model subscript_2d_arrays begin
    @time 0:1:100                                  # initial time : time step : final time

    @index i ∈ entries = (entry_1, entry_2, entry_3)
    @index j ∈ columns = (column_1, column_2)

    "Rate A [1/month]"
    rate_a[i, j] = [0.01 0.02; 0.03 0.04; 0.05 0.06]

    initial_values[i, j] = [1 2; 3 4; 5 6]

    "Stock A [units]"
    ∂t(stock_a[i, j]) = inflow_a[i, j]
    stock_a(0) = initial_values

    inflow_a[i, j] = rate_a[i, j]
end

# Vensim-style alternative, also accepted:
#     stock_a[i, j] = INTEG(inflow_a[i, j], initial_values[i, j])
```

### `subscript_transposition`

```julia
@model subscript_transposition begin
    @time 0:1:1

    @index s ∈ sectors = (agriculture, industry, transport, tourism, comercial)
    @index r ∈ sectors                             # a second index over the same set

    input[s] = [1, 10, 5, 7, 9]
    io_matrix[s, r] = [ 1  2  3  4  5;
                       10 20 30 40 50;
                        1  2  3  4  5;
                        2  3  4  5  6;
                       -1  2 -3  4 -5]

    output[r] = ∑(input[s] * io_matrix[s, r] for s ∈ sectors)
    output2[r] = ∑(input[s] * io_matrix[r, s] for s ∈ sectors)

    # or, as linear algebra:
    #   output = io_matrix' * input
    #   output2 = io_matrix * input
end
```

### `smooth`

One `SMOOTH` with options replaces SMOOTH, SMOOTHI, SMOOTH3, SMOOTH3I and SMOOTH N;
the macro creates the hidden stage stocks.

```julia
@model smooth begin
    @time 0:0.25:20

    initial_value = 5
    input = -1 + STEP(5, 5)
    adjustment_time = 2 + STEP(2, 10)
    variable_order = 2 + STEP(1, 10)

    smooth_output = SMOOTH(input, adjustment_time)
    smoothi_output = SMOOTH(input, adjustment_time; init = initial_value)
    smooth3_output = SMOOTH(input, adjustment_time; order = 3)
    smooth3i_output = SMOOTH(input, adjustment_time; order = 3, init = initial_value)
    smooth_n_output = SMOOTH(input, adjustment_time; order = variable_order, init = initial_value)
end
```

### Further ideas for the DSL
- **Equations per group of elements** (Vensim's per-element definitions and
  subranges, without `:EXCEPT:`), e.g. one equation for the youngest age group
  and another for the rest:
  ```julia
  @index a ∈ ages = (young, adult, old)
  @subset middle = (adult,)
  ∂t(population[young]) = births - ageing[young]
  ∂t(population[a ∈ middle]) = ageing[a-1] - ageing[a]
  ```
- **Flows between stocks** as an optional notation, as in
  [StockFlow.jl](https://github.com/AlgebraicJulia/StockFlow.jl):
  `susceptible => infection(rate) => infected`, with `☁` for sources and sinks.
- **Data by name** from Excel/CSV, read when the model runs, with scenarios kept separate from the equations.
- **Modules** that can run on their own or linked.

### Ideas from BPTK-Py

[BPTK-Py](https://github.com/transentis/bptk_py) (the Business Prototyping
Toolkit, MIT licence) builds SD models in Python with its own DSL, and puts a lot
of work into what happens *around* the equations: scenarios, step-by-step runs and
a few stock types Vensim doesn't have. These parts are worth taking:

- **Scenarios as data, separate from the model.** BPTK keeps a model's base
  values plus named scenarios that override only what changes, for constants
  *and* lookup points, usually in JSON files next to the model. All scenarios run
  in one call, and the results come back as one table to compare:
  ```julia
  @scenarios customer_acquisition begin
      base = ()
      low_word_of_mouth = (word_of_mouth_success = 0.001,)
      high_word_of_mouth = (word_of_mouth_success = 0.1,)
      new_productivity = (productivity = [(0, 0.4), (1, 1.0), (2.5, 1.25)],)  # lookup points
  end

  res = run_scenarios(customer_acquisition; vars = [:customers])  # a column per scenario
  ```
  The same scenarios could live in a TOML file, so they can be edited without
  touching the model.
- **Strategies: changes at given times.** A scenario can also change constants
  *during* the run (`"strategy": {"20": {"deadline": 120}}` in BPTK). With the
  ODE style this is a preset-time callback, or `step!` plus `set_parameter!` on a
  `CoupledODEs`:
  ```julia
  late_deadline = (initial_open_tasks = 120,
                   strategy = (20 => (deadline = 120,),))   # from t = 20 on
  ```
- **Sessions: step-by-step runs with new settings each step.** BPTK uses these for
  management games and simulation servers (`begin_session`, `run_step(settings)`,
  `session_results`). DynamicalSystems.jl already provides the mechanics (see
  [Running and analysing](#running-and-analysing)); a thin wrapper with the
  model's names would make it as easy to use:
  ```julia
  session = begin_session(customer_acquisition, :base)
  run_step!(session; advertising_budget = 200)    # one time step with a new budget
  results(session)
  ```
- **Non-negative stocks.** XMILE stocks can be marked non-negative: the outflows
  are cut back so the stock never goes below zero. BPTK supports this with
  separate inflow and outflow lists. In the DSL, a `∂t` equation already shows
  which flows go in (+) and which go out (−), so one line can ask for it:
  ```julia
  @nonnegative inventory
  ∂t(inventory) = production - shipments - losses
  ```
  PySD's XMILE translator already reads this flag and the Python builder uses it;
  the Julia builder ignores it today, which is why the `non_negative_*` test models
  fail there (SDXorg/pysd#499).
- **Conveyors** (XMILE): a stock where material leaves after a transit time,
  with optional leakage on the way. Like `SMOOTH`, it fits as one stateful
  function whose stage stocks the macro creates:
  ```julia
  arrivals = CONVEYOR(shipments, transit_time; leakage = 0.02)
  ```
- **A builder API next to the macro.** BPTK models are built with plain calls
  (`model.stock("customers")`, then `customers.equation = …`). A Julia
  equivalent would let programs generate models (from a database, or as
  variants of a model), with `@model` as a shorter way to write the same thing:
  ```julia
  m = SDModel(:customer_acquisition; time = 1:1:60)
  customers = stock!(m, :customers; init = 0.0)
  acquisition = aux!(m, :customer_acquisition, :(min(potential_customers, ads + word_of_mouth)))
  ```
- **Modules with qualified names.** Parts of a model are written once and used
  several times; their variables appear in the results with the module name in
  front (`retailer.inventory`, `wholesaler.inventory`), as in BPTK's beer game.
- **Error messages that name the loop.** When auxiliaries form an algebraic
  loop, BPTK names it (`a → b → a`) instead of only saying there is one. The
  macro can do the same when it sorts the equations.

Not needed in Julia: BPTK's compiled Rust engine (Julia models are compiled
already) and biflows (any flow in the DSL can be negative).

---

## Measurements

All in `prototype/`; Julia 1.12.6 on a 2-core laptop (Intel i3-7100U).

**Correctness:** every column of the reference output (test-models), compared at every saved time:

| Model | ODE style | MTK style |
|---|---|---|
| `subscript_2d_arrays` | 2,424 values, max. relative error 2.2e-6 | same |
| `subscript_transposition` | 50 values, exact | same |
| `smooth` | 729 values, max. relative error 3.6e-6 | same |

(The remaining differences are the rounding of Vensim's saved output.)

**Size and speed:** synthetic model with 10,000 stocks (`stock[A, B]`, 200 × 50),
`inflow[A, B] = growth * stock[A, B] * weight[B] / SUM(weight[B!])`, 400 Euler steps:

| | Current output | ODE style |
|---|---|---|
| Lines of code | 10,190 | 25 |
| One evaluation of the equations | 0.065 ms | 0.018 ms (3.6× faster) |
| Whole run | 53 ms, 154 MiB | 18 ms, 62 MiB (2.9× faster) |
| Result | wrong (SDXorg/pysd#504) | correct |

**MTK start-up:** 35–50 s to build the system plus 25–30 s for the first run per model (compilation).

---

## Proposed decisions

1. **Three styles**, chosen with `translate_to_julia(model; style = "ode" | "mtk" | "dsl")`, all checked against the reference outputs by the same test matrix (`tests/pytest_builders/pytest_julia_reference.py` in PySD).
2. **ODE style:** named state (ComponentArrays), parameters in `p` (`Params`), a single `model!(d, s, p, t)`, constants written once, array operations where dimensions line up and comprehensions where they don't, stateful functions as stage-stock helpers in PySD.jl.
3. **Results** keep Vensim's variable names and labelled dimensions (as `save_results` does since PySD.jl 0.2.0).
4. **The DSL** is the long-term target. It is built in PySD.jl as a macro that generates the ODE and MTK forms. The translator then emits DSL text.
5. **DynamicalSystems.jl** integration (`CoupledODEs`) replaces building our own step-by-step, parameter-change and state-saving features. It is an **optional dependency**: a package extension (`[weakdeps]` + `[extensions]` in PySD.jl's `Project.toml`), like the existing ModelingToolkit extension. `using PySD, DynamicalSystemsBase` adds e.g. `CoupledODEs(model)`; without it, DynamicalSystems is not installed or loaded.

## Open questions

- **Names of helpers in models:** keep the `pysd_` prefix (`pysd_step`), or use Vensim names (`STEP`, `SMOOTH`)? The DSL uses Vensim names; plain-Julia models could too (in a module, to avoid clashes such as `Base.step`).
- **Names of variables:** snake_case (as now) or the original Vensim names via `var"Stock A"`? Snake_case with the Vensim name kept as a label for results is proposed.
- **DSL index syntax:** declared index letters (`@index i ∈ entries`), or named dimensions only (`stock[entries, columns]`, as Vensim)?
- **MTK:** keep generating it from the translator, or only from the DSL?
- **Units:** checked (e.g. with Unitful.jl) or documentation only?
- **Scenarios:** in Julia only (`@scenarios`), or also in a file (TOML) that can be edited without touching the model?

## Plan

1. Agree on this proposal (or change it).
2. ODE style in the translator, step by step, guarded by the reference tests.
3. DSL macro in PySD.jl for a first set of constructs (stocks, auxiliaries, subscripts, SUM, SMOOTH/DELAY), generating the ODE style.
4. Translator emits the DSL; MTK generated from the DSL.
5. DynamicalSystems.jl integration as a package extension (optional dependency), and documentation.

## Related work
- [Vensim](https://vensim.com/) `.mdl`: equations, subscripts and function library.
- [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl): symbolic modelling, used by the MTK style.
- [StockFlow.jl](https://github.com/AlgebraicJulia/StockFlow.jl): stock-and-flow diagrams with composition and stratification; the source of the optional flow notation.
- [BPTK-Py](https://github.com/transentis/bptk_py): SD DSL in Python; the source of the scenario, strategy, session, non-negative stock and conveyor ideas.
- [DynamicalSystems.jl](https://juliadynamics.github.io/DynamicalSystemsDocs.jl/): standard interface for running and analysing dynamical systems.
- [ComponentArrays.jl](https://github.com/jonniedie/ComponentArrays.jl): named, shaped state vectors.
