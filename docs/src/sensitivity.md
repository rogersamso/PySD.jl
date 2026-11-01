# Sensitivity and derivatives

```@setup sens
using PySD, Unitful
teacup = @equations begin
    @parameters begin
        room_temperature = 70, [unit = u"°F"]
        characteristic_time = 10, [unit = u"minute"]
    end
    @variables begin
        teacup_temperature(t), [unit = u"°F"]
        heat_loss_to_room(t), [unit = u"°F/minute"]
    end
    ∂t(teacup_temperature) ~ -heat_loss_to_room
    teacup_temperature(t₀) ~ 180
    heat_loss_to_room ~ (teacup_temperature - room_temperature) / characteristic_time
end
m = Model(teacup; time = 0:0.125:30, time_unit = u"minute")
```

A model is compiled once, when it is built; every run after that, with any
parameter values or input sheets, compiles nothing.  That is what a
sensitivity analysis needs: many runs with different values.

## One parameter at a time

How much the final temperature of the teacup moves when each parameter is
1 % higher (its elasticity: the % change of the result for a 1 % change of
the parameter):

```@example sens
final(r) = r[:teacup_temperature][end]
base = run_model(m)
for p in (:room_temperature, :characteristic_time)
    x = base[p]
    r = run_model(m; params = NamedTuple{(p,)}((1.01 * x,)))
    println(rpad(p, 22), round((final(r) - final(base)) / final(base) / 0.01; digits = 3))
end
```

Three things to watch in a large model:

- **Years.**  A parameter that is a year (`policy_start = 2025`) moves 20
  years with 1 %.  Move it by one year instead.
- **Switches.**  A parameter that chooses between options (`scenario = 2`)
  has no elasticity; run each option.
- **Structure.**  A parameter that sets the number of steps of a fixed delay
  or the order of a smooth can't change without building the model again;
  `run_model` says so.

## Many runs

```julia
values = range(0.05, 0.15; length = 100)
finals = [run_model(m; params = (; k))[:x][end] for k in values]
```

Once compiled, a run of a large model takes about a second, so a sweep
over every parameter of such a model takes minutes.  The runs are
independent, so they can share the work between threads (start Julia with
`--threads=auto`):

```julia
finals = fetch.([Threads.@spawn run_model(m; params = (; k))[:x][end] for k in values])
```

Each run has its own buffers and histories; the input sheets they read are
cached once for all.

## Derivatives: ForwardDiff

A run computes in the number type of its parameters, so other kinds of
numbers go through it.  With [ForwardDiff.jl](https://github.com/JuliaDiff/ForwardDiff.jl),
the derivative of any result in any parameter:

```@example sens
using ForwardDiff
ForwardDiff.derivative(R -> run_model(m; params = (; room_temperature = R))[:teacup_temperature][end], 70.0)
```

It is the exact derivative of the run, with its Euler steps, not an estimate
from runs with nearby values; here, 1 − (1 − Δt/τ)²⁴⁰.  The first call
compiles the model again for ForwardDiff's numbers; later ones don't.

`ForwardDiff.gradient` gives the derivatives in several parameters at once,
for calibration with an optimiser.

### A derivative that comes out NaN

A function whose derivative is infinite where the model takes it, such as
`sqrt(x)` at `x = 0`, gives ∞ · 0 = NaN when `x` doesn't depend on the
parameter, although the derivative is 0; the NaN then spreads to the stocks.
ForwardDiff's NaN-safe mode counts ∞ · 0 as 0:

```julia
using Preferences, ForwardDiff
set_preferences!(ForwardDiff, "nansafe_mode" => true)    # then start Julia again
```

It is saved in the environment's `LocalPreferences.toml`, and makes
ForwardDiff a little slower.  On a large model where an
abundance reached exactly zero, it turned NaN derivatives into ones that
agree with central differences to 10⁻⁸.

## Uncertainties: Measurements

With [Measurements.jl](https://github.com/JuliaPhysics/Measurements.jl), a
parameter's uncertainty carried to every result:

```@example sens
using Measurements
r = run_model(m; params = (; characteristic_time = 10 ± 1))
r[:teacup_temperature][end]
```

This is first-order error propagation: right for small uncertainties.  For
large ones, or to see the whole distribution, run the model for many values
drawn at random (a Monte Carlo analysis, as above).
