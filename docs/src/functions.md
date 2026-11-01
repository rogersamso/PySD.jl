# Vensim functions

Each Vensim function: what it is for, its definition, and how to write it in
PySD.jl (what the translator writes).  They fall into groups by how they
behave in time, which decides how they run with other solvers than Vensim's
Euler steps ([Solvers and the model's ticks](@ref)):

- **Memory as a stock**: hidden stocks with rates.  Any solver integrates
  them.
- **Memory by counting steps**: values at earlier steps of Δt.  They move at
  the model's ticks, whatever the solver.
- **Switches at given times**: functions of the time.  The solver stops at
  the ticks, so a switch at a tick is exact.
- **Switches on values, and plain calculations**: no time behaviour of their
  own.

In the definitions, ``t_k = t_0 + k\,Δt`` are the ticks.

## Memory as a stock

### SMOOTH, SMOOTHI

`SMOOTH(input, T)` · `SMOOTHI(input, T, initial_value)`

Perception and adjustment: what people believe about a quantity lags behind
its real value (perceived demand, an expected price, the average of a noisy
series).  Each unit of time the output closes a share 1/T of its gap to the
input: after a jump, 63 % of the way in T, 95 % in 3T.

```math
S(t_0) = \text{input}(t_0) \;\; (\text{SMOOTHI: initial\_value}), \qquad
\frac{dS}{dt} = \frac{\text{input} - S}{T}, \qquad \text{SMOOTH} = S
```

**PySD.jl:** `smooth(input, T)`, `smooth(input, T; init = initial_value)`.

### SMOOTH3, SMOOTH3I, SMOOTH N

`SMOOTH3(input, T)` · `SMOOTH3I(input, T, initial_value)` · `SMOOTH N(input, T, initial_value, n)`

The same through a chain of n smooths, each of time T/n: the output hardly
reacts at first, then catches up (an S-shape).  Information that goes
through several stages: measured, reported, then acted on.

```math
\frac{dS_1}{dt} = (\text{input} - S_1)\,\frac{n}{T}, \qquad
\frac{dS_i}{dt} = (S_{i-1} - S_i)\,\frac{n}{T}, \qquad \text{output} = S_n
```

with every ``S_i(t_0)`` the input's (or `initial_value`).

**PySD.jl:** `smooth(input, T; order = 3)`, `smooth(input, T; order = n, init = initial_value)`.

### DELAY1, DELAY1I

`DELAY1(input, T)` · `DELAY1I(input, T, initial_value)`

Material in transit: goods being shipped, buildings under construction,
people in training.  Whatever goes in comes out later and nothing is lost;
things stay T on average, some leaving early and some late.

```math
L(t_0) = \text{input}(t_0)\,T, \qquad \frac{dL}{dt} = \text{input} - \frac{L}{T}, \qquad
\text{DELAY1} = \frac{L}{T}
```

With a constant T this is the curve of SMOOTH.  They differ when T changes:
a delay keeps its contents L, so its outflow changes at once; a smooth keeps
its output.

**PySD.jl:** `delay(input, T)`, `delay(input, T; init = initial_value)`.

### DELAY3, DELAY3I, DELAY N

`DELAY3(input, T)` · `DELAY3I(input, T, initial_value)` · `DELAY N(input, T, initial_value, n)`

Material through n stages in a row, each of T/n: most of it comes out
around T after it went in (construction, ageing chains).  The larger n, the
closer to a fixed delay.

```math
\frac{dL_1}{dt} = \text{input} - L_1\frac{n}{T}, \qquad
\frac{dL_i}{dt} = (L_{i-1} - L_i)\,\frac{n}{T}, \qquad
\text{output} = L_n\,\frac{n}{T}
```

with ``L_i(t_0) = \text{input}(t_0)\,T/n`` (or `initial_value`·T/n).

**PySD.jl:** `delay(input, T; order = 3)`, `delay(input, T; order = n, init = initial_value)`.

### TREND

`TREND(input, T, initial_trend)`

The growth rate someone watching the input perceives, as a fraction per unit
of time ("sales grow 5 % a year"): the input against its smoothed past.

```math
A(t_0) = \frac{\text{input}(t_0)}{1 + \text{initial\_trend}\cdot T}, \qquad
\frac{dA}{dt} = \frac{\text{input} - A}{T}, \qquad
\text{TREND} = \frac{\text{input} - A}{T\,|A|} \;\; (0 \text{ if } A = 0)
```

For an input growing steadily at a rate g, TREND settles on g.

**PySD.jl:** `trend(input, T; init = initial_trend)`.

### FORECAST

`FORECAST(input, T, horizon)`

The input's perceived trend extended a `horizon` ahead, to plan capacity or
investment.

```math
\frac{dA}{dt} = \frac{\text{input} - A}{T}, \qquad
\text{FORECAST} = \text{input}\left(1 + \text{horizon}\,\frac{\text{input} - A}{T\,A}\right)
```

with ``A(t_0) = \text{input}(t_0) / (1 + \text{initial trend})``, as Python PySD.

**PySD.jl:** the translator writes it with a smooth for A:
`input * (1 + zidz(input - A, T * A) * horizon)`, `A = smooth(input, T; init =
input / (1 + initial_trend))`.

### INITIAL

`INITIAL(value)`

A value frozen at the start of the run: a reference level ("population in
the base year"), or a starting value computed from other variables.

```math
\text{INITIAL}(x)(t) = x(t_0) \quad \text{for every } t
```

**PySD.jl:** `x(t₀)`.

## Memory by counting steps

These move at the model's ticks, with any solver: the solver stops at every
tick, where they record and move, and holds them in between.

### DELAY FIXED

`DELAY FIXED(input, T, initial_value)`

An exact pipeline: everything comes out exactly T later, unchanged.  A fixed
construction or maturing time, a legal waiting period: a conveyor belt
rather than a mixing tank.

```math
n = \max\!\left(1, \operatorname{round}\frac{T}{Δt}\right), \qquad
\text{output}(t_k) = \begin{cases} \text{initial\_value} & k < n \\ \text{input}(t_{k-n}) & k \ge n \end{cases}
```

n is fixed when the model is built: changing T needs a rebuild.

**PySD.jl:** `input(t - T; init = initial_value)`.

### SAMPLE IF TRUE

`SAMPLE IF TRUE(condition, input, initial_value)`

Follows the input while a condition holds and keeps the last value when it
stops: a value fixed at a given year, the price at the last review.

```math
\text{output}(t_k) = \begin{cases} \text{input}(t_k) & \text{condition}(t_k) \\
\text{output}(t_{k-1}) & \text{otherwise} \end{cases}
```

and `initial_value` until the condition first holds.  A condition such as
`t == 2020` is read at the ticks, so it holds there with any solver.

**PySD.jl:** `sample_if_true(condition, input; init = initial_value)`.

### RANDOM 0 1, RANDOM UNIFORM, RANDOM NORMAL, RANDOM EXPONENTIAL

Noise: demand fluctuations, measurement errors, Monte Carlo experiments.
Vensim draws one number per step and keeps it for the step; the seed makes
a run repeatable.

As Python PySD: RANDOM UNIFORM is uniform on [min, max]; RANDOM NORMAL(min,
max, mean, sd, seed) a normal truncated to [min, max] (drawn again while
outside); RANDOM EXPONENTIAL(min, max, shift, stretch, seed) is shift +
stretch times an exponential, from at least min, truncated at max.

**PySD.jl:** `random_0_1()`, `random_uniform(min, max; seed)`,
`random_normal(min, max, mean, sd; seed)`, `random_exponential(min, max,
shift, stretch; seed)`; `dims = d` for a draw per element of `d` where the
arguments are numbers.  Drawn once per tick from a generator seeded from the
seed, the call, the element and the tick: held between ticks, and the same
in every run, with any solver.

## Switches at given times

Functions of the time.  A model with them stops at every tick, and a
solver's step that ends at a tick sees the time just before it, so a switch
at a tick changes the rates from that tick on.

### PULSE

`PULSE(start, width)`: a one-off event of a given length (a two-year
subsidy, a test shock).

```math
\text{PULSE} = \begin{cases} 1 & \text{start} \le t < \text{start} + \text{width} \\ 0 & \text{otherwise} \end{cases}
```

**PySD.jl:** `(start ≤ t < start + width)`.

### PULSE TRAIN

`PULSE TRAIN(start, width, interval, end)`: a repeating event (a yearly
harvest, periodic maintenance).

```math
\text{PULSE TRAIN} = \begin{cases} 1 & \text{start} \le t < \text{end} \text{ and } (t - \text{start}) \bmod \text{interval} < \text{width} \\ 0 & \text{otherwise} \end{cases}
```

**PySD.jl:** `pysd_pulse_train(t, start, interval, width, end)`.

### STEP

`STEP(height, step_time)`: a permanent change from a given time (a new tax
rate, a policy switch); also the standard test input.

```math
\text{STEP} = \begin{cases} \text{height} & t \ge \text{step\_time} \\ 0 & \text{before} \end{cases}
```

**PySD.jl:** `height * (t ≥ step_time)`.

### RAMP

`RAMP(slope, start, end)`: a gradual change between two times (a phase-in).

```math
\text{RAMP} = \text{slope} \cdot \operatorname{clamp}(t - \text{start},\; 0,\; \text{end} - \text{start})
```

**PySD.jl:** `slope * clamp(t - start, 0, finish - start)`.

### Data series

`GET XLS DATA`, `GET DIRECT DATA`, and data variables: historical series or
scenarios read from a spreadsheet or file.  Between two data points, a
straight line (or the value kept, looking forward, or the raw values);
before the first and after the last, held.

**PySD.jl:** `data(sheet, time, cells; method = :interpolate)` as a parameter,
called as `series(t)`; `data(parents, :name)` for a series from another
model's run or a file ([Data from other models or from files](@ref)).

## Switches on values, limits and choices

### IF THEN ELSE

`IF THEN ELSE(condition, a, b)`: rules that switch (order when the stock is
below target, start a policy once a threshold is passed).  `a` if the
condition holds, `b` otherwise.

**PySD.jl:** `ifelse(condition, a, b)`; `ifelse.(…)` for arrays.

### MIN, MAX

Physical limits: shipments can't exceed what is in stock, a flow can't go
below zero (`MAX(0, x)`).

**PySD.jl:** `min(a, b)`, `max(a, b)`.

### INTEGER, QUANTUM, MODULO

Whole units (power plants, people), rounding to a batch size, cycles such as
the month within a year.

```math
\text{INTEGER}(x) = \operatorname{trunc}(x), \qquad
\text{QUANTUM}(x, q) = q\,\operatorname{trunc}(x / q), \qquad
\text{MODULO}(x, m) = x - m\left\lfloor \frac{x}{m} \right\rfloor
```

**PySD.jl:** `trunc(x)`, `pysd_quantum(x, q)`, `mod(x, m)`.

### VECTOR SELECT, VECTOR RANK, VECTOR SORT ORDER, VECTOR REORDER

Working along a dimension: rank technologies by cost, pick the cheapest,
add up only the selected elements.

**PySD.jl:** not translated yet: the model stops with an error naming it
([`pysd_not_implemented`](@ref)).  Helpers for the older backends:
[`pysd_vector_select`](@ref) and the `pysd_vector_*` functions.

### ALLOCATE BY PRIORITY, ALLOCATE AVAILABLE

Sharing a limited supply among users who each ask for an amount, the
highest priority served first.

**PySD.jl:** not translated yet: the model stops with an error naming it
([`pysd_not_implemented`](@ref)).  Helpers for the older backends:
`pysd_allocate_by_priority`, `pysd_allocate_available`.

## Plain calculations

### XIDZ, ZIDZ

Divisions that may hit zero (a share of a total that can be empty).

```math
\text{XIDZ}(a, b, x) = \begin{cases} a / b & b \ne 0 \\ x & b = 0 \end{cases}, \qquad
\text{ZIDZ}(a, b) = \text{XIDZ}(a, b, 0)
```

**PySD.jl:** `xidz(a, b, x)`, `zidz(a, b)`.

### SUM, PROD, VMIN, VMAX, ELMCOUNT

Collapsing a dimension (the `!` in Vensim): a world total from regions, the
most expensive technology, the number of regions.

**PySD.jl:** `sum_over(x, d)`, `prod_over(x, d)`, `minimum_over(x, d)`,
`maximum_over(x, d)` (several dimensions: `sum_over(x, (d1, d2))`);
`length(d)`.

### Lookups

A relationship known as a curve or from data (the effect of price on
demand); its argument can be any variable.  Between two points, a straight
line; outside them, held at the first or last value.

**PySD.jl:** `piecewise_linear(x₁ => y₁, x₂ => y₂, …)` (`WITH LOOKUP` and
lookups written in the model), `lookup(sheet, x, cells)` (`GET XLS LOOKUPS`,
`GET DIRECT LOOKUPS`); called as `f(x)`.

### Maths and the rest

| Vensim | PySD.jl |
|---|---|
| `+ - * / ^`, `ABS`, `SQRT`, `EXP`, `LN` | `+ - * / ^`, `abs`, `sqrt`, `exp`, `log` |
| `LOG(x, b)` | `log(x) / log(b)` |
| `SIN`, `COS`, `TAN`, `ARCSIN`, `ARCCOS`, `ARCTAN`, `SINH`, `COSH`, `TANH` | `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `sinh`, `cosh`, `tanh` |
| `PI` | `π` |
| `= <> < <= > >=`, `:AND:`, `:OR:`, `:NOT:` | `== != < <= > >=`, `&`, `\|`, `!` |
| `INVERT MATRIX(A)` | `inv(A)` |
| `GET XLS CONSTANTS`, `GET DIRECT CONSTANTS` | `constant(sheet, cells)` |
| `ACTIVE INITIAL(x, x0)` | `x`, with the initial value `x0` (inside an expression, a variable of its own) |
| `GET TIME VALUE(0, offset, 0)` | `t + offset` |
| `GAME` | not translated yet (the model stops with an error naming it) |
