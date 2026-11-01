# Writing models

A model is one or more sets of equations, written with [`@equations`](@ref),
built into a [`Model`](@ref).

```@example writing
using PySD, Unitful

teacup = @equations begin
    @parameters begin
        room_temperature = 70, [unit = u"°F", description = "Room temperature"]
        characteristic_time = 10, [unit = u"minute"]
    end
    @variables begin
        teacup_temperature(t), [unit = u"°F"]
        heat_loss_to_room(t), [unit = u"°F/minute"]
    end

    ∂t(teacup_temperature) ~ -heat_loss_to_room          # Newton's law of cooling
    teacup_temperature(t₀) ~ 180
    heat_loss_to_room ~ (teacup_temperature - room_temperature) / characteristic_time
end

m = Model(teacup; time = 0:0.125:30, time_unit = u"minute")
```

## Declarations

Every name is declared before it is used, with its unit:

- `@parameters`: what is known before the run, with its value
  (`k = 0.1, [unit = u"1/yr"]`).  A run can give it another
  (`run_model(m; params = (; k = 0.2))`).
- `@variables`: what an equation computes; `x(t)` when it changes with time,
  `x` alone when it is computed once, at the start.

After the unit, optionally:

- `description = "…"`, kept with the results and in the LaTeX export;
- `nonnegative = true`, for a stock that can't go below zero: its outflow is
  cut to what empties it in one step of Δt;
- `input = true`, `output = true`, for the variables a component takes from
  and gives to the rest of the model ([Components](@ref)).

Names without a unit are `NoUnits`.  Units are
[Unitful.jl](https://github.com/PainterQubits/Unitful.jl)'s (`u"kg/yr"`), and
a model can declare its own (`@unit case "case" Case 1 false` in a module,
registered with `Unitful.register`).

## Equations

Equations use `~`, and any Julia expression on the right:

| Equation | Meaning |
|---|---|
| `g ~ k * x` | `g` at every step |
| `∂t(x) ~ inflow - outflow` | a stock: its rate of change |
| `x(t₀) ~ 1` | the stock's initial value |
| `y ~ x(t₀)` | the value `x` had at the start (Vensim's `INITIAL`) |
| `y ~ x(t - 2; init = 0)` | the value `x` had 2 time units ago (`DELAY FIXED`) |

`t` is the time, `t₀` the initial time and `Δt` the time step.  `ifelse(c,
a, b)` is Vensim's `IF THEN ELSE`, and the usual Julia functions (`min`,
`max`, `exp`, `log`, …) are Vensim's.  [Vensim functions](@ref) lists them
all.

The order of the equations doesn't matter: `Model` sorts them, and stops with
an error that names the loop (`a → b → a`) when some depend on each other
with no stock in between.

### Operators with memory

| Function | Vensim |
|---|---|
| `smooth(x, τ)`, `smooth(x, τ; init = x0)` | `SMOOTH`, `SMOOTHI` |
| `smooth(x, τ; order = 3)` (`; order = n, init = x0`) | `SMOOTH3`, `SMOOTH N` |
| `delay(x, τ)`, `delay(x, τ; init = x0)` | `DELAY1`, `DELAY1I` |
| `delay(x, τ; order = 3)` (`; order = n, init = x0`) | `DELAY3`, `DELAY N` |
| `trend(x, τ; init = r0)` | `TREND` |
| `x(t - τ; init = x0)` | `DELAY FIXED` |
| `sample_if_true(c, x; init = x0)` | `SAMPLE IF TRUE` |
| `x(t₀)` | `INITIAL` |

The smooths, delays and trends have hidden stocks of their own, which the
model integrates with the rest.  The fixed delay and the sample move by
whole steps of Δt, as Vensim ([Solvers and the model's ticks](@ref)).  New
operators are new subtypes of [`StatefulOperator`](@ref).

### Lookups and data

```julia
@parameters begin
    effect = piecewise_linear(0 => 1.0, 1 => 0.8, 2 => 0.5), [unit = NoUnits]
    price_history = data(sheet, "year", "price"), [unit = u"USD"]
end
…
demand ~ base_demand * effect(price / reference_price)
price ~ price_history(t)
```

A lookup is called with its argument; it interpolates linearly between its
points and keeps the first or last value outside them.  A data series is a
lookup of the time.

### Excel

```julia
sheet = excel("inputs.xlsx", "Sheet1")
@parameters begin
    capacity[region] = constant(sheet, "B2:B5"), [unit = u"MW"]
    efficiency = lookup(sheet, "A10:A20", "B10:B20"), [unit = NoUnits]
    demand = data(sheet, "year", "demand"; method = :interpolate), [unit = u"MW"]
end
```

`constant`, `lookup` and `data` read cells or named ranges, as Vensim's `GET
XLS` and `GET DIRECT` functions.  A sheet given to `Model` by name (`Model(…;
inputs = (; scenario = sheet))`) can be replaced by another for a run
(`run_model(m; inputs = (; scenario = excel(…)))`).

## Arrays

Dimensions are [DimensionalData.jl](https://github.com/rafaqz/DimensionalData.jl)
dimensions, Vensim's subscript ranges:

```@example arrays
using PySD, DimensionalData

const region = Dim{:region}([:north, :south])

regions = @equations begin
    @parameters begin
        initial_population[region] = [10.0, 20.0], [unit = NoUnits]
        growth = 0.02, [unit = u"1/yr"]
    end
    @variables begin
        population(t)[region], [unit = NoUnits]
        births(t)[region], [unit = u"1/yr"]
        total(t), [unit = NoUnits]
    end
    ∂t(population) ~ births
    population(t₀) ~ initial_population
    births[region = At(:north)] ~ growth * population[region = At(:north)]
    births[region = Not(At(:north))] ~ 2 * growth .* population[region = Not(At(:north))]
    total ~ sum_over(population, region)
end

r = run_model(Model(regions; time = 0:1:10, time_unit = u"yr"))
r[:population][end]
```

- `x[region]` declares an array over `region`; its equation is for all of it,
  with Julia's broadcasting (`.*`).
- An equation can be for a part: `x[region = At(:south)] ~ …`, and
  `Not(At(…))` for the rest.  The parts can't overlap: `Model` says which
  equations do.
- `sum_over(x, d)`, `prod_over`, `maximum_over`, `minimum_over` reduce over
  a dimension (Vensim's `SUM(x[d!])`); `previous(x, d)` shifts along one.
- Matrices are matrices: `inv(I - A)`, `A * v`.

## Components

A set with a name is a component.  Several of them, with an unnamed set
that connects them, make a model; each component's names are kept apart
(`retailer.inventory`, `wholesaler.inventory`):

```julia
function stage(; name, target = 12)
    @equations name begin
        @parameters begin
            target_inventory = target, [unit = u"case"]
        end
        @variables begin
            incoming_orders(t) = 4, [unit = u"case/wk", input = true]
            shipments(t), [unit = u"case/wk", output = true]
            inventory(t), [unit = u"case", nonnegative = true]
            …
        end
        …
    end
end

retailer, wholesaler = stage(; name = :retailer), stage(; name = :wholesaler)
connections = @equations begin
    retailer.incoming_orders ~ customer_orders
    wholesaler.incoming_orders ~ retailer.orders_placed
    …
end
m = Model(retailer, wholesaler, connections; time = 0:1:52, time_unit = u"wk")
```

An `input` variable's own equation (`= 4`) is the value it takes when the
model doesn't connect it.  The equations are Julia code: a component is a
function, and a choice in it (an ordering rule) can be a type, chosen by
dispatch.

## Building

```julia
Model(sets…; time = t₀:Δt:t_final, time_unit, saveat = step(time), inputs = (;),
      numerics = :julia)
```

checks the declarations and the dimensions, and sorts and compiles the
equations.  `saveat` is Vensim's `SAVEPER`.  [`check_units`](@ref) lists
the equations whose units don't add up, and `run_model(m; check_units =
true)` checks them before running (`:warn` to only print them).
