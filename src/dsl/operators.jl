# Stateful operators and array helpers used in @equations.

"""
    StatefulOperator

What `smooth`, `delay`, `trend`, `sample_if_true` and the fixed delay
`x(t - τ)` implement: how many hidden stocks they have, their initial values,
their rates of change and the operator's value.  `Model` creates the hidden
stocks.  A new operator is a new subtype with these methods:

    nstates(op)
    initial_states(op, x, args...; init)
    rates!(d, op, s, x, args...)
    output(op, s, x, args...)

(`s` are the hidden stocks, `x` the input, `args` the other arguments).
"""
abstract type StatefulOperator end

function nstates end
function initial_states end
function rates! end
function output end

# The arguments the operator's value needs at the same time (by position);
# with none it depends on its hidden stocks only, and breaks loops as a stock
# does.  A new operator needs all of them unless it says otherwise.
output_args(::StatefulOperator) = :all

# The arguments the initial hidden stocks need when an initial value is given
# (`init = …`; without one, it is the input, the first argument).
init_args(::StatefulOperator) = :all

"Exponential smoothing of any order (SMOOTH, SMOOTHI, SMOOTH3, SMOOTH3I, SMOOTH N)."
struct Smooth <: StatefulOperator
    order::Int
end
nstates(op::Smooth) = op.order
initial_states(op::Smooth, x, τ; init = x) = fill(float(init), op.order)
function rates!(d, op::Smooth, s, x, τ)
    k = op.order / τ
    d[1] = k * (x - s[1])
    for i in 2:op.order
        d[i] = k * (s[i-1] - s[i])
    end
end
output(::Smooth, s, x, τ) = s[end]
output_args(::Smooth) = ()
init_args(::Smooth) = ()

"Material delay of any order (DELAY1, DELAY3, DELAY N): the stages hold material."
struct MaterialDelay <: StatefulOperator
    order::Int
end
nstates(op::MaterialDelay) = op.order
initial_states(op::MaterialDelay, x, τ; init = x) = fill(float(init) * τ / op.order, op.order)
function rates!(d, op::MaterialDelay, s, x, τ)
    k = op.order / τ
    d[1] = x - k * s[1]
    for i in 2:op.order
        d[i] = k * (s[i-1] - s[i])
    end
end
output(op::MaterialDelay, s, x, τ) = s[end] * op.order / τ
output_args(::MaterialDelay) = (2,)
init_args(::MaterialDelay) = (2,)

"TREND, as Python PySD: a smoothed level and the fractional growth rate."
struct Trend <: StatefulOperator end
nstates(::Trend) = 1
initial_states(::Trend, x, τ; init = 0.0) = [x / (1 + init * τ)]
rates!(d, ::Trend, s, x, τ) = (d[1] = (x - s[1]) / τ)
output(::Trend, s, x, τ) = ifelse(s[1] == 0, zero(x / τ), (x - s[1]) / (τ * abs(s[1])))
output_args(::Trend) = (1, 2)

# Operators that remember past values instead of integrating: no hidden stocks,
# but a history of each run (src/dsl/history.jl).  With Euler steps of Δt they
# move by whole steps, as Vensim; with other solvers they follow continuous time.
abstract type HistoryOperator <: StatefulOperator end
nstates(::HistoryOperator) = 0

"""
A fixed delay `x(t - τ; init)` (DELAY FIXED): with Euler steps of Δt, the input
round(τ / Δt) steps before, copied exactly; with other solvers, the input at
t - τ, interpolated between the solver's steps.
"""
struct FixedDelay <: HistoryOperator
    n::Int                        # steps of Δt
    τ::Float64
end
output_args(::FixedDelay) = ()
init_args(::FixedDelay) = ()

"""
SAMPLE IF TRUE: the input while the condition holds, the last sampled value
after.  `switches`: the times at which the condition can change because it
compares `t` (numbers, or the ids of parameters read in each run), so that
other solvers than Euler stop there.
"""
struct SampleIfTrue <: HistoryOperator
    switches::Vector{Any}
end

# a condition: true or false, or a number (an array of conditions holds 1.0 and 0.0)
_true(c::Bool) = c
_true(c::Real) = !iszero(c)
output_args(::SampleIfTrue) = (1, 2)
init_args(::SampleIfTrue) = ()

"INITIAL: the value at the initial time, `x(t₀)` on the right of an equation."
struct Initial <: StatefulOperator end
nstates(::Initial) = 1
initial_states(::Initial, x; init = x) = [float(x)]
rates!(d, ::Initial, s, x) = (d[1] = zero(eltype(d)))
output(::Initial, s, x) = s[1]
output_args(::Initial) = ()

# The functions written in equations; `Model` turns their calls into operators.
const _OPERATOR_NAMES = (:smooth, :delay, :trend, :sample_if_true)

for f in _OPERATOR_NAMES
    @eval $f(args...; kw...) = error($(string(f)) * "(…) can only be used in @equations")
end

# --- functions for arrays with named dimensions ------------------------------

_dimof(x::AbstractDimArray, d) = DimensionalData.dims(x, DimensionalData.name(d))

"""
    sum_over(x, d)
    sum_over(x, (d1, d2, …))

The sum over dimension `d`, or over several at once, which the result no
longer has (Vensim's `SUM(x[d!])`, `SUM(x[d1!, d2!])`; Julia's
`sum(x; dims = d)` keeps `d` with length 1).  `maximum_over`, `minimum_over`
and `prod_over` likewise.
"""
sum_over(x::AbstractDimArray, d) = _reduce_over(sum, x, d)
maximum_over(x::AbstractDimArray, d) = _reduce_over(maximum, x, d)
minimum_over(x::AbstractDimArray, d) = _reduce_over(minimum, x, d)
prod_over(x::AbstractDimArray, d) = _reduce_over(prod, x, d)

function _reduce_over(f, x, d)
    n = d isa Tuple ? map(DimensionalData.name, d) : DimensionalData.name(d)
    r = dropdims(f(x; dims = n); dims = n)
    return ndims(r) == 0 ? r[] : r
end

"""
    previous(x, d)

Each element takes the value of the one before it along dimension `d`; the
first takes zero.
"""
function previous(x::AbstractDimArray, d)
    k = DimensionalData.dimnum(x, DimensionalData.name(d))
    y = zero(x)
    src = selectdim(parent(x), k, 1:(size(x, k) - 1))
    selectdim(parent(y), k, 2:size(x, k)) .= src
    return y
end

"A lookup given by its points: piecewise linear, constant outside them."
struct PiecewiseLinear
    x::Vector{Float64}
    y::Vector{Float64}
end

"""
    piecewise_linear(x₁ => y₁, x₂ => y₂, …)

A lookup: called as `f(x)`, it interpolates linearly between the points and
keeps the first or last value outside them, as Vensim.
"""
piecewise_linear(points::Pair...) =
    PiecewiseLinear(Float64[first(p) for p in points], Float64[last(p) for p in points])

function (f::PiecewiseLinear)(x::Real)
    xs, ys = f.x, f.y
    x <= xs[1] && return oftype(float(x), ys[1])
    x >= xs[end] && return oftype(float(x), ys[end])
    i = searchsortedlast(xs, x)
    w = (x - xs[i]) / (xs[i+1] - xs[i])
    return ys[i] + w * (ys[i+1] - ys[i])
end
(f::PiecewiseLinear)(x::AbstractArray) = f.(x)

# Broadcasting in generated code: arrays line up by dimension name.
_bc(f, args...) = any(a -> a isa AbstractDimArray, args) ? _bc_dims(f, args...) : f.(args...)
function _bc_dims(f, args...)
    arrays = [a for a in args if a isa AbstractDimArray]
    all(a -> DimensionalData.dims(a) == DimensionalData.dims(arrays[1]), arrays) && return f.(args...)
    all(a -> a isa AbstractDimArray, args) && return broadcast_dims(f, args...)
    # numbers among the arrays (broadcast_dims takes only arrays): in the function
    pos = findall(a -> a isa AbstractDimArray, collect(Any, args))
    g(xs...) = f(ntuple(i -> (k = findfirst(==(i), pos); k === nothing ? args[i] : xs[k]), length(args))...)
    return broadcast_dims(g, arrays...)
end

# --- operators of arrays: the scalar operator, element by element -------------
# The hidden stocks of an operator with dimensions are a matrix: its stages,
# then the elements (`s[:, I]` for element I); arguments are numbers or arrays
# laid out in the operator's dimensions.  (The helpers are specialized on
# their arguments, otherwise Julia passes them on as a tuple it allocates.)

_at(a::AbstractArray, I) = @inbounds a[I]
_at(a, I) = a
_at(kw::NamedTuple, I) = map(v -> _at(v, I), kw)

function _op_output!(out, op::O, s, args::Vararg{Any,N}) where {O,N}
    for I in CartesianIndices(out)
        @inbounds out[I] = output(op, view(s, :, I), map(a -> _at(a, I), args)...)
    end
    return out
end

function _op_rates!(d, op::O, s, args::Vararg{Any,N}) where {O,N}
    for I in CartesianIndices(Base.tail(axes(s)))
        rates!(view(d, :, I), op, view(s, :, I), map(a -> _at(a, I), args)...)
    end
    return d
end

function _op_init!(s, op, args...; kw...)
    for I in CartesianIndices(Base.tail(axes(s)))
        s[:, I] .= initial_states(op, map(a -> _at(a, I), args)...; _at(values(kw), I)...)
    end
    return s
end
