# Solvers and the model's ticks

## Euler steps of Δt, as Vensim

[`run_model`](@ref)`(m)` integrates the stocks as Vensim does by default:
Euler steps of Δt (Vensim's `TIME STEP`).  At each step it computes every
equation from the stocks, then moves each stock by its rate times Δt.  This
gives Vensim's and Python PySD's values, which the tests check against
[SDXorg/test-models](https://github.com/SDXorg/test-models).

Three times are involved:

- **Δt** (`TIME STEP`): the model's step.  The fixed delays and samples
  count it, and some equations are written for it (below).
- **dt**: the step a solver takes.  For `run_model`, dt = Δt.
- **saveat** (`SAVEPER`): when results are saved.  Usually a multiple of Δt:
  a model may need a small Δt for accuracy, but its results are read yearly.

## Other solvers: SciML

With a SciML solver package loaded, a model also runs with any of
[SciML](https://docs.sciml.ai/DiffEqDocs/stable/)'s ODE solvers, and the
results are the same `Results`:

```julia
using OrdinaryDiffEqLowOrderRK                 # or OrdinaryDiffEq, for all of them
r = run_model(m, Euler())                      # Vensim's steps, the same values as run_model(m)
r = run_model(m, Euler(); dt = m.dt / 4)       # smaller steps: is Δt small enough?
r = run_model(m, RK4())                        # a higher order
r = run_model(m, BS3(); reltol = 1e-8)         # adaptive steps
```

Stiff models, with time constants far apart, take a stiff solver, such as
`Rodas5P()` from OrdinaryDiffEqRosenbrock.

`ODEProblem(m; params, inputs)` is the model as a SciML problem, for what
`run_model` doesn't do (callbacks, ensembles of runs, …), and
`Results(m, sol)` the values of every name from its solution.

What another solver is good for:

- **Checking that Δt is small enough.**  Euler's error shrinks with the
  step.  If the results at Δt/2 and Δt/4 differ from those at Δt, the
  model's stocks carry that much integration error; a higher-order or
  adaptive solver shows where they converge.
- **More accurate stocks** for the same work, with a higher-order method.
- **Stiff models**, which Euler only runs with a very small Δt.

It doesn't make a run faster when the model has fixed delays, samples or
switches on the time: the solver stops at every tick (below), so it never
takes steps longer than Δt.  And it doesn't give Vensim's numbers: only
`Euler()` with `dt = Δt` does.

## Functions that count steps: the model's ticks

Most of a model is defined by rates, and any solver integrates them towards
the same answer.  Two functions are defined by steps instead:

- **`DELAY FIXED`** (`x(t - τ; init)`): the input `round(τ / Δt)` steps ago.
- **`SAMPLE IF TRUE`** (`sample_if_true(c, x; init)`): at each step, the input
  if the condition holds, else the value of the step before.

Their meaning needs a clock: the model's **ticks**, t₀ + k·Δt.  PySD.jl keeps
them as a recording of their inputs at each tick, and whatever the solver:

1. When the solve starts, every tick is added as a stop: the solver lands on
   each one.
2. **At each tick**, a callback computes the model there, from the stocks at
   that moment.  The delays and samples record their inputs and move one
   step, exactly as after an Euler step.
3. **Between two ticks**, they are held: a fixed delay gives its input from n
   ticks before, a sample the value it took at the tick.  The solver's own
   steps in between only integrate the stocks.

With `Euler()` and `dt = Δt` the ticks are the solver's steps, and the values
Vensim's.  With smaller or better steps, the stocks around the delays and
samples converge on one answer.  A model with a stock filled through a
fixed delay, and a capital that a sample spends from, with Δt = 0.5:

```@example solvers
using PySD, OrdinaryDiffEqLowOrderRK

clock_example = @equations begin
    @variables begin
        orders(t), [unit = NoUnits]
        arrivals(t), [unit = NoUnits]
        stock(t), [unit = NoUnits]
        capital(t), [unit = NoUnits]
        spending(t), [unit = NoUnits]
    end
    orders ~ ifelse(t >= 1, 1.0, 0.0)
    arrivals ~ orders(t - 2; init = 0)                  # DELAY FIXED
    ∂t(stock) ~ arrivals - stock / 2
    stock(t₀) ~ 0
    spending ~ sample_if_true(rem(t, 2) == 0, 0.2 * capital; init = 0)
    ∂t(capital) ~ 0.25 * capital - spending
    capital(t₀) ~ 1
end
m = Model(clock_example; time = 0:0.5:10, time_unit = NoUnits)

for (label, r) in (("Vensim (Euler, Δt)", run_model(m)),
                   ("Euler, Δt/2", run_model(m, Euler(); dt = m.dt / 2)),
                   ("Euler, Δt/8", run_model(m, Euler(); dt = m.dt / 8)),
                   ("RK4", run_model(m, RK4())))
    println(rpad(label, 20), "stock(3.5) = ", round(r[:stock][8]; digits = 4),
            "   capital(10) = ", round(r[:capital][end]; digits = 4))
end
```

The arrivals are the same under every solver: whole ticks, as Vensim.

### What Vensim does with Runge-Kutta

Vensim's manual says that `DELAY FIXED`'s output does "not change except at
TIME STEP intervals", "regardless of the integration technique used": what
PySD.jl does.  For `SAMPLE IF TRUE` it says that with methods other than
Euler the output "will change within the integration step", while "the
reported value will always be computed on an even time step".  PySD.jl
holds it between ticks instead; what Vensim does inside its step isn't
documented, so it can't be reproduced.

## Switches on the time

`t ≥ 2015`, `STEP`, `PULSE` and `PULSE TRAIN` are functions of the time, and
any solver evaluates them where it is.  A model that has them also stops at
every tick, so a switch at a tick falls between two of the solver's steps.
A step that ends at a tick, before the callback has moved to it (Runge-Kutta's
last stage), sees the time just before the tick: a switch there changes the
rates from that tick on, exactly.  (Without this, RK4 would turn it on a
sixth of a step early.)

A switch between two ticks (`STEP` at 2.3 with Δt = 1) is where it is written.
Vensim's Euler switches at the next tick (3).

## Equations written for steps of Δt

Some equations are written for Euler steps of Δt, and may mean something
else with another solver:

| Equation | With Euler steps of Δt | With another solver |
|---|---|---|
| `∂t(x) ~ (target - x) / Δt` | `x` is set to `target` in one step | `x` follows `target` with a time constant Δt |
| `∂t(year_met) ~ ifelse(c, t / Δt, 0)` | the year `c` holds is kept | depends on how long `c` holds within a step |
| `g ~ growth / Δt` | a growth per step | a rate per time |
| `ifelse(t == 2020, …)` | true for one step | true at one instant |
| `nonnegative = true` stocks | the outflow is cut to what empties the stock in one step | the stock decays towards zero instead |

The ticks can't fix these: they are ordinary equations, and only the
modeller knows what was meant.  So any solver other than `Euler()` with `dt =
Δt` names them in a warning, once per model:

```
┌ Warning: Equations written for Euler steps of Δt, which may mean something else with this solver
│ (only Euler() with dt = Δt gives Vensim's values); compare with smaller steps to see whether the
│ results change:
│   2 use Δt as a value (a move or a rate per step): year_met, drained
│   1 test the time for equality (true for one Euler step, at one instant here): year_met
│   1 are non-negative stocks (their outflow is cut to what empties them in one step): level
```

Not named, as they mean the same with any solver:

- an equation that depends on the time alone (parameters, data series,
  lookups, and fixed delays or samples of them), such as a finite difference
  of data, `(data(t + Δt) - data(t)) / Δt`;
- a time `t - Δt` or `t + Δt` given to a delay or a data series;
- the condition of a `sample_if_true`, which is read at the ticks.

Not every one named changes a result.  Running with smaller steps shows
which do: a difference that shrinks as the step halves is integration error;
one that stays is a change of meaning.
