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
| **DSL** | Our own modelling language: plain Julia and mathematical notation, built from reusable components | Writing new models from scratch; translator output that a mathematician can read and edit |

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

A model in the DSL should read **as if a Julia developer who is also a
mathematician had written it**: the equations as they would appear in a paper,
in ordinary Julia. At the same time it must be **easy to read and edit** by
someone who opens the file for the first time, and **very modular**: a model
is built from small, self-contained components that can be reused, swapped and
run on their own.

Vensim's notation was designed for people who prefer not to write mathematics
(`INTEG`, `STEP`, `SMOOTH3I`, `:EXCEPT:`, `|` separators), and a Vensim model is
one flat list of equations. The DSL does not copy either. Instead, the translator
turns Vensim and XMILE models into the DSL (see
[From Vensim to the DSL](#from-vensim-to-the-dsl)).

Rules:
- **Plain Julia.** Every model is valid Julia syntax (checked with Julia's
  parser), read by a `@model` macro. Functions are Julia's own (`exp`, `log`,
  `min`, `clamp`, `sum`, `ifelse`, `x > 0 ? a : b`) or short lowercase helpers
  from PySD.jl, never Vensim's capitalised names.
- **Time is the variable `t`**, written where it is used, as in mathematics:
  `5 * (t ≥ 5)` rather than `STEP(5, 5)`. `@time t ∈ 0:0.25:20` declares it
  as a Julia range (initial time : time step : final time).
- **Stocks are differential equations**: `∂t(x) = inflow - outflow` with the
  initial value as `x(0) = x₀`. There is no `INTEG`.
- **Arrays have named dimensions**, as `xarray` gives Python PySD. Each
  dimension (a Vensim subscript range) is declared once with its element labels,
  and every array knows its dimensions by name
  ([DimensionalData.jl](https://github.com/rafaqz/DimensionalData.jl), see
  [Arrays with named dimensions](#arrays-with-named-dimensions)). Equations are
  written for whole arrays and line up by dimension *name*, not position, so
  there are no index letters and no loops. Elements are picked by label
  (`io_matrix[sector = At(industry)]`). Parts of an array are selections or
  named subsets, not `:EXCEPT:`.
- **Functions are functions.** A lookup is a piecewise-linear function `f`, used
  as `f(x)`. A fixed delay is the delayed value `x(t - τ)`.
- **Stateful operators** (smoothing, delays of material, trends) are functions
  with keyword options. The macro creates their hidden stocks. Writing the ODE out
  by hand (`∂t(y) = (x - y) / τ`) is always possible as well.
- **Readable first.** Variables have descriptive names (`temperature`,
  `room_temperature`); Greek letters only where a reader expects them (`τ` for a
  time constant). One equation per line, in the order a reader would explain the
  model, and a docstring above it with the description and the unit. The macro
  sorts the equations itself, so they can be moved freely.
- **Modular.** Every part of a model is a component with declared inputs and
  outputs (see [Components](#components)). Components are written once, used
  many times, kept one per file, and each one runs and is tested on its own.

These are syntax sketches (the macro doesn't exist yet), but every block below
parses as valid Julia.

### `teacup`

```julia
@model teacup begin
    @time t ∈ 0:0.125:30                           # minutes

    "Room temperature [°F]"
    room_temperature = 70

    "Characteristic time [min]"
    τ = 10

    "Teacup temperature [°F]: Newton's law of cooling"
    ∂t(temperature) = -heat_loss
    temperature(0) = 180

    "Heat loss to room [°F/min]"
    heat_loss = (temperature - room_temperature) / τ
end
```

### `subscript_2d_arrays`

```julia
@model subscript_2d_arrays begin
    @time t ∈ 0:1:100

    @dims entries = (entry_1, entry_2, entry_3)
    @dims columns = (column_1, column_2)

    "Rate A [1/month]"
    rate_a = @on (entries, columns) [0.01 0.02; 0.03 0.04; 0.05 0.06]

    "Stock A [units]: each element grows linearly"
    ∂t(stock_a) = rate_a
    stock_a(0) = @on (entries, columns) [1 2; 3 4; 5 6]
end
```

`@on (entries, columns)` attaches the dimensions to the values once. After that
`stock_a` is a 3 × 2 array over `entries` and `columns`, and `∂t(stock_a) =
rate_a` is one array equation, with no loop and no index.

### `subscript_transposition` (sums over a dimension)

```julia
@model subscript_transposition begin
    @time t ∈ 0:1:1

    @dims sector = (agriculture, industry, transport, tourism, comercial)
    @dims sector1 = sector                         # a second dimension over the same elements

    input = @on sector [1, 10, 5, 7, 9]
    io_matrix = @on (sector, sector1) [ 1  2  3  4  5;
                                       10 20 30 40 50;
                                        1  2  3  4  5;
                                        2  3  4  5  6;
                                       -1  2 -3  4 -5]

    "output[sector1] = Σ over sector of input × io_matrix"
    output = sum(input .* io_matrix; dims = sector)

    "the same with the roles of the two dimensions swapped"
    output2 = sum(input .* swapdims(io_matrix, sector => sector1, sector1 => sector); dims = sector)
end
```

`input .* io_matrix` lines up `input`'s `sector` with `io_matrix`'s `sector`
(by name, whatever the order of the dimensions), and `sum(…; dims = sector)`
leaves an array over `sector1`. This is xarray's behaviour, and the Vensim
`SUM(input[sector!] * io_matrix[sector!, sector1])` read literally.

### `smooth` (stateful operators)

One `smooth` with options replaces SMOOTH, SMOOTHI, SMOOTH3, SMOOTH3I and SMOOTH N.
The macro creates the hidden stage stocks.

```julia
@model smooth begin
    @time t ∈ 0:0.25:20

    initial_value = 5
    input = -1 + 5 * (t ≥ 5)                       # a step of 5 at t = 5
    τ = 2 + 2 * (t ≥ 10)                           # adjustment time
    order = 2 + (t ≥ 10)                           # read at t = 0

    smooth_output = smooth(input, τ)               # first-order exponential smoothing
    smoothi_output = smooth(input, τ; init = initial_value)
    smooth3_output = smooth(input, τ; order = 3)
    smooth3i_output = smooth(input, τ; order = 3, init = initial_value)
    smooth_n_output = smooth(input, τ; order, init = initial_value)

    # the same as smooth_output, written as the ODE it stands for:
    ∂t(smoothed) = (input - smoothed) / τ
    smoothed(0) = input
end
```

### Delays, lookups and data

```julia
@model supply_line begin
    @time t ∈ 0:0.25:50

    "Effect of inventory on orders [dimensionless]"
    effect = piecewise_linear(0 => 1.5, 0.5 => 1.2, 1 => 1.0, 2 => 0.6)

    demand = data("inputs.xlsx", "demand")         # a time series, read at load time
    target_inventory = 400
    orders = demand(t) * effect(inventory / target_inventory)

    received = delay(orders, 4; order = 3)         # material delay (third order)
    reported_orders = orders(t - 2)                # fixed delay: the value 2 time units ago
    orders_trend = trend(orders, 6)

    "Inventory [units]: never negative"
    @nonnegative ∂t(inventory) = received - shipments
    inventory(0) = 400
    shipments = min(demand(t), inventory / 0.25)
end
```

### Several equations for one array

Vensim defines parts of an array with separate equations and `:EXCEPT:`. In
the DSL these are slices, or named subsets of a dimension:

```julia
@dims age = (young, adult, old)
@subset older = age[adult:old]                     # a subrange, by label

∂t(population[age = At(young)]) = births - ageing[age = At(young)]
∂t(population[age = older]) = previous(ageing, age)[age = older] .- ageing[age = older]
# previous(x, age): each element takes the value of the one before it along age
ageing = population ./ duration
```

### Arrays with named dimensions

Python PySD keeps subscripted variables as `xarray.DataArray`s: arrays whose
dimensions have names and labels, and whose operations line up dimensions by
name. The DSL works the same way. Three Julia packages were compared (each
checked with a vector over `a` times a matrix over `a` and `b`, and with the matrix's
dimensions in the other order):

| Package | Named dimensions | Labels | Lines up by name in `.*`, `.+` | Reduce by name | Notes |
|---|---|---|---|---|---|
| [NamedArrays.jl](https://github.com/davidavdav/NamedArrays.jl) 0.10.5 | yes | yes | no: `x[a] .* m[a, b]` fails (DimensionMismatch) | no, by position only (`dims = 1`) | labels for indexing and printing |
| [AxisKeys.jl](https://github.com/mcabbott/AxisKeys.jl) 0.2.17 | yes (NamedDims) | yes | only in the same order: `x[a] .* m[b, a]` fails | `sum(x; dims = :a)` | light |
| [DimensionalData.jl](https://github.com/rafaqz/DimensionalData.jl) 0.30.2 | yes | yes (lookups, selectors) | yes, in any order (`broadcast_dims`) | `sum(x; dims = Sector)` | closest to xarray; datasets (`DimStack`), NetCDF through Rasters.jl / YAXArrays.jl |

Maintenance and use (GitHub and the General registry, 22 October 2026; downloads
from the Julia package server logs, September 2021 to February 2026, the latest
published):

| | NamedArrays.jl | AxisKeys.jl | DimensionalData.jl |
|---|---|---|---|
| Latest release | 0.10.5 (Sep 2025) | 0.2.17 (Aug 2025) | 0.30.2 (Aug 2026) |
| Commits in the last 12 months | 0 | 8 | 55 |
| Contributors | 22 | 23 | 50 |
| GitHub stars | 128 | 154 | 335 |
| Registered packages that depend on it (+ optional) | 42 | 29 (+11) | 78 (+26) |
| Downloads by users (unique addresses) | 29,500 | 6,100 | 7,300 |

NamedArrays has the most downloads, mostly as an older dependency of other
packages, but no commits in the last year. DimensionalData is the most actively
developed, has the most contributors and the most packages built on it
(Rasters.jl, YAXArrays.jl and others in the geoscience and climate ecosystem,
which reads and writes NetCDF as PySD does).

**Proposed: DimensionalData.jl.** Tested on `subscript_transposition`
(Julia 1.12, DimensionalData 0.30.2):
- `sum(broadcast_dims(*, input, io_matrix); dims = Sector)` gives `output`
  over `sector1`, the same as the Vensim reference;
- after renaming the two dimensions, the same line gives `output2`;
- with `io_matrix`'s dimensions stored in the other order, the result is the same;
- `io_matrix[Sector = At(:industry), Sector1 = At(:transport)]` picks one element by label.

Speed: in an ODE right-hand side (200 × 50 stock times a weight over the second
dimension), named-dimension broadcasting took 15 µs per evaluation against 8 µs
for plain arrays, because `broadcast_dims` allocates. So the names are used where
people see them, and are gone where the solver runs:
- parameters, initial values, data and **results** are DimArrays (results as a
  `DimStack`, like an xarray Dataset, saved to NetCDF with their dimension names
  and labels);
- the `@model` macro checks and lines up the dimensions **once, when the model is
  built**, and generates plain-array code for `model!` (the ODE style above), so
  the solver loop costs the same as hand-written Julia.

Element labels follow Vensim's (`agriculture`, `entry_1`). A dimension used twice
in one array (Vensim's subscript mapping, e.g. `sector` and `sector1`) is a second
dimension over the same labels.

### Components

A component is a small model with **declared inputs and outputs** (its
interface). Everything else inside it is private. It is defined once and then
used like a function, as many times as needed. The supply-chain stage of the
beer game, for example:

```julia
# file: components/stage.jl
"One stage of a supply chain: keeps an inventory and orders from upstream."
@component stage begin
    @input incoming_orders = 4                     # default, so the stage runs alone
    @input deliveries = 4
    @output orders_placed
    @output shipments

    @param τ_adjust = 4                            # inventory adjustment time
    @param target = 12

    @nonnegative ∂t(inventory) = deliveries - shipments
    inventory(0) = target
    ∂t(backlog) = incoming_orders - shipments
    backlog(0) = 0

    shipments = min(backlog + incoming_orders, inventory)
    expected_orders = smooth(incoming_orders, 2)
    orders_placed = max(0, expected_orders + (target - inventory + backlog) / τ_adjust)
end
```

A model then connects components by their inputs and outputs:

```julia
# file: beer_game.jl
include("components/stage.jl")

@model beer_game begin
    @time t ∈ 0:1:52                               # weeks

    customer_orders = 4 + 4 * (t ≥ 4)

    retailer = stage(incoming_orders = customer_orders, deliveries = wholesaler.shipments)
    wholesaler = stage(incoming_orders = retailer.orders_placed, deliveries = factory.shipments)
    factory = stage(incoming_orders = wholesaler.orders_placed,
                    deliveries = delay(factory.orders_placed, 2; order = 1); target = 20)
end
```

What this gives:
- **Reuse.** One `stage` file serves all three stages. Changing it changes them all.
- **Parameters per instance.** `; target = 20` overrides a `@param` for one
  instance only. Scenarios can override any `@param` in any instance
  (`factory.target`).
- **Qualified names.** Results keep the component path (`retailer.inventory`,
  `factory.backlog`), so the three inventories don't clash.
- **Runs on its own.** `run_model(stage)` uses the input defaults. Each component
  can be tested alone before it is connected.
- **Arrays of components.** `stages = [stage(...) for k in 1:4]`, where each
  stage's `incoming_orders` is the previous one's `orders_placed`, for chains of
  any length.
- **Swappable.** A component can be replaced by any other with the same inputs
  and outputs (e.g. a stage with a different ordering rule) without touching
  the rest of the model.
- **Nested.** A component can contain components, so a large model is a tree of
  small files, each a page or less.

When translating a Vensim model, the components follow PySD's `split_views`
option: with `split_views=True`, each view (or subview, with
`subview_sep`) becomes one component, in its own file. Its inputs are the
variables it uses from other views, and its outputs are the ones other views use
from it; the model file only connects them. Without `split_views`, the model is
one component. This replaces today's `split_views` modules, which share one flat
namespace.

### From Vensim to the DSL

The translator rewrites each Vensim construct as the mathematics it stands for:

| Vensim | DSL |
|---|---|
| `x = INTEG(f - g, x0)` | `∂t(x) = f - g`, `x(0) = x0` |
| `STEP(h, t0)` | `h * (t ≥ t0)` |
| `PULSE(t0, w)` | `(t0 ≤ t < t0 + w)` |
| `RAMP(s, t0, t1)` | `s * clamp(t - t0, 0, t1 - t0)` |
| `IF THEN ELSE(c, a, b)` | `ifelse(c, a, b)` |
| `XIDZ(a, b, x)`, `ZIDZ(a, b)` | `b == 0 ? x : a / b`, `b == 0 ? 0 : a / b` |
| `MIN`, `MAX`, `ABS`, `EXP`, `LN`, `SQRT`, `INTEGER` | `min`, `max`, `abs`, `exp`, `log`, `sqrt`, `trunc` |
| Subscript range `dim: a, b, c` | `@dims dim = (a, b, c)` |
| Subrange, subscript mapping | `@subset sub = dim[b:c]`, `@dims dim2 = dim` |
| `x[dim] = 1, 2, 3` | `x = @on dim [1, 2, 3]` |
| `SUM(x[i!])`, `VMAX(x[i!])` | `sum(x; dims = i)`, `maximum(x; dims = i)` |
| `SUM(a[i!] * m[i!, j])` | `sum(a .* m; dims = i)` |
| `x[elem]` | `x[dim = At(elem)]` |
| `lookup(x)` with inline points | `f = piecewise_linear(x₁ => y₁, …)`, `f(x)` |
| `SMOOTH`, `SMOOTHI`, `SMOOTH3`, `SMOOTH3I`, `SMOOTH N` | `smooth(x, τ; order, init)` |
| `DELAY1`, `DELAY3`, `DELAY N` | `delay(x, τ; order, init)` |
| `DELAY FIXED(x, τ, x0)` | `x(t - τ)` (with `x0` before `t0 + τ`) |
| `TREND(x, τ, g0)` | `trend(x, τ; init = g0)` |
| `GET XLS DATA`, `GET DIRECT LOOKUPS` | `data(file, name)`, used as `d(t)` / `f(x)` |
| `x[a] = …; x[b] = …` | slices `x[a]`, `x[b:c]`, or named subsets |
| `:EXCEPT:` | a slice or subset of the remaining elements |
| `TIME`, `TIME STEP`, `INITIAL TIME`, `FINAL TIME` | `t`, `Δt`, `first(t)`, `last(t)` from `@time` |
| Vensim macros | components |
| Views, with `split_views=True` | one component per view (or subview) |

Where Vensim's semantics differ from the plain mathematics, the helper keeps
Vensim's behaviour, so translated models still match the reference outputs. For
example, `x(t - τ)` fixes the number of stages from τ at the initial time, as
DELAY FIXED does, and comparisons with `t` use Vensim's tolerance of half a time
step.

### Further ideas for the DSL
- **Flows between stocks** as an optional notation, as in
  [StockFlow.jl](https://github.com/AlgebraicJulia/StockFlow.jl):
  `susceptible => infection(rate) => infected`, with `☁` for sources and sinks.
- **Units** with [Unitful.jl](https://github.com/PainterQubits/Unitful.jl)
  (`τ = 10u"minute"`), checked when the model is built, instead of units in
  comments.
- **Data by name** from Excel/CSV, read when the model runs, with scenarios kept
  separate from the equations.

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
  @nonnegative ∂t(inventory) = production - shipments - losses
  ```
  PySD's XMILE translator already reads this flag. The Python builder uses it, and
  the Julia builder does too since SDXorg/pysd#512.
- **Conveyors** (XMILE): a stock where material leaves after a transit time,
  with optional leakage on the way. Like `SMOOTH`, it fits as one stateful
  function whose stage stocks the macro creates:
  ```julia
  arrivals = conveyor(shipments, transit_time; leakage = 0.02)
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
  several times, and their variables appear in the results with the module name
  in front (`retailer.inventory`, `wholesaler.inventory`), as in BPTK's beer
  game. The DSL's [components](#components) do this.
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
4. **The DSL** is the long-term target: plain Julia and mathematical notation (no Vensim syntax), readable names, arrays with named dimensions (DimensionalData.jl, as xarray in Python PySD), and models built from components with declared inputs and outputs. It is built in PySD.jl as a macro that generates the ODE and MTK forms. The translator then emits DSL text, with components following `split_views` (one per view) and one per Vensim macro.
5. **DynamicalSystems.jl** integration (`CoupledODEs`) replaces building our own step-by-step, parameter-change and state-saving features. It is an **optional dependency**: a package extension (`[weakdeps]` + `[extensions]` in PySD.jl's `Project.toml`), like the existing ModelingToolkit extension. `using PySD, DynamicalSystemsBase` adds e.g. `CoupledODEs(model)`; without it, DynamicalSystems is not installed or loaded.

## Open questions

- **Names of helpers in the ODE style:** keep the `pysd_` prefix (`pysd_step`), or use the DSL's lowercase names (`smooth`, `delay`, in a module to avoid clashes)? The DSL itself uses Julia and mathematical notation (`5 * (t ≥ 5)`, `smooth(x, τ)`).
- **Names of variables:** snake_case (as now) or the original Vensim names via `var"Stock A"`? Snake_case with the Vensim name kept as a label for results is proposed.
- **Component connections:** as keyword arguments (`stage(incoming_orders = …)`, as proposed), or separate `connect(a.output, b.input)` lines as in ModelingToolkit?
- **MTK:** keep generating it from the translator, or only from the DSL?
- **Units:** checked (e.g. with Unitful.jl) or documentation only?
- **Scenarios:** in Julia only (`@scenarios`), or also in a file (TOML) that can be edited without touching the model?

## Plan

1. Agree on this proposal (or change it).
2. ODE style in the translator, step by step, guarded by the reference tests.
3. DSL macro in PySD.jl for a first set of constructs (stocks, auxiliaries, arrays, sums, `smooth`/`delay`, components), generating the ODE style.
4. Translator emits the DSL; MTK generated from the DSL.
5. DynamicalSystems.jl integration as a package extension (optional dependency), and documentation.

## Related work
- [Vensim](https://vensim.com/) `.mdl`: equations, subscripts and function library.
- [ModelingToolkit.jl](https://github.com/SciML/ModelingToolkit.jl): symbolic modelling, used by the MTK style.
- [StockFlow.jl](https://github.com/AlgebraicJulia/StockFlow.jl): stock-and-flow diagrams with composition and stratification; the source of the optional flow notation.
- [BPTK-Py](https://github.com/transentis/bptk_py): SD DSL in Python; the source of the scenario, strategy, session, non-negative stock and conveyor ideas.
- [DynamicalSystems.jl](https://juliadynamics.github.io/DynamicalSystemsDocs.jl/): standard interface for running and analysing dynamical systems.
- [ComponentArrays.jl](https://github.com/jonniedie/ComponentArrays.jl): named, shaped state vectors.
- [DimensionalData.jl](https://github.com/rafaqz/DimensionalData.jl): arrays with named dimensions and labels, Julia's closest match to xarray; used by the DSL.
