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

"""
DELAY N as Python PySD runs it (`delay(x, τ; order = n, lagged_times = true)`):
when the delay time changes, stage k uses the delay time of k - 1 steps of Δt
before, and the output the one of the step before.  The past delay times are
hidden stocks too (each the one before it after a step of Δt: exact with Euler
steps of Δt).
"""
struct LaggedDelay <: StatefulOperator
    order::Int
    dt::Float64
end
_nlags(op::LaggedDelay) = max(op.order - 1, 1)
nstates(op::LaggedDelay) = op.order + _nlags(op)
initial_states(op::LaggedDelay, x, τ; init = x) =
    [fill(float(init) * τ / op.order, op.order); fill(float(τ), _nlags(op))]
# the delay time of stage i, τ(t - (i - 1)Δt): the current one, then the past ones
_stage_time(op::LaggedDelay, s, τ, i) = i == 1 ? τ : s[op.order + i - 1]
function rates!(d, op::LaggedDelay, s, x, τ)
    n = op.order
    d[1] = x - n * s[1] / τ
    for i in 2:n
        d[i] = n * (s[i-1] / _stage_time(op, s, τ, i - 1) - s[i] / _stage_time(op, s, τ, i))
    end
    d[n + 1] = (τ - s[n + 1]) / op.dt
    for j in 2:_nlags(op)
        d[n + j] = (s[n + j - 1] - s[n + j]) / op.dt
    end
end
output(op::LaggedDelay, s, x, τ) = s[op.order] * op.order / s[op.order + 1]
output_args(::LaggedDelay) = ()
init_args(::LaggedDelay) = (2,)

"TREND, as Python PySD: a smoothed level and the fractional growth rate."
struct Trend <: StatefulOperator end
nstates(::Trend) = 1
initial_states(::Trend, x, τ; init = 0.0) = [x / (1 + init * τ)]
rates!(d, ::Trend, s, x, τ) = (d[1] = (x - s[1]) / τ)
output(::Trend, s, x, τ) = ifelse(s[1] == 0, zero(x / τ), (x - s[1]) / (τ * abs(s[1])))
output_args(::Trend) = (1, 2)

# Operators that remember past values instead of integrating: no hidden stocks,
# but a history of each run (src/dsl/history.jl), by whole steps of Δt, as
# Vensim: only Euler steps of Δt run them.
abstract type HistoryOperator <: StatefulOperator end
nstates(::HistoryOperator) = 0

"""
A fixed delay `x(t - τ; init)` (DELAY FIXED): the input round(τ / Δt) steps
before, copied exactly.
"""
struct FixedDelay <: HistoryOperator
    n::Int                        # steps of Δt
end
output_args(::FixedDelay) = ()
init_args(::FixedDelay) = ()

"""
SAMPLE IF TRUE: the input while the condition holds, the value of the last
step where it held after.
"""
struct SampleIfTrue <: HistoryOperator end

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

"""
RANDOM 0 1, RANDOM UNIFORM, RANDOM NORMAL, RANDOM EXPONENTIAL: one draw per
step of Δt (the model's ticks), held in between, as Vensim; from a generator
seeded from the seed, the call, the element and the tick, so that every run
draws the same, with any solver.  Truncated as Vensim and Python PySD.
"""
struct RandomDraw <: HistoryOperator
    kind::Symbol                  # :random_0_1, :random_uniform, :random_normal, :random_exponential
    seed::Int
end
init_args(::RandomDraw) = ()

const _RANDOM_KINDS = (:random_0_1, :random_uniform, :random_normal, :random_exponential)

# The functions written in equations; `Model` turns their calls into operators.
const _OPERATOR_NAMES = (:smooth, :delay, :trend, :sample_if_true, _RANDOM_KINDS...)

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

# --- Vensim's VECTOR functions --------------------------------------------------
#
# Along one dimension, as Vensim and Python PySD: positions are 0-based (the
# first element is 0), as numbers.  The DimArray methods here are for code
# outside @equations; inside, the lowering (lower.jl) calls the same kernels on
# plain arrays.

_overname(d) = d isa Symbol ? d : DimensionalData.name(d)

"""
    vector_sort_order(x, direction, d)

Vensim's `VECTOR SORT ORDER` along dimension `d`: at each position, the
position (0-based) along `d` of the element that goes there when the elements
are sorted, smallest first if `direction > 0`, else largest first.
"""
function vector_sort_order(x::AbstractDimArray, direction, d)
    w = similar(x, Float64)
    _slices_along!(_sort_order!, parent(w), (parent(x),), Val(DimensionalData.dimnum(x, _overname(d))), direction)
    return w
end

"""
    vector_rank(x, direction, d)

Vensim's `VECTOR RANK` along dimension `d`: the rank of each element (1 for the
smallest if `direction > 0`, for the largest otherwise).
"""
function vector_rank(x::AbstractDimArray, direction, d)
    w = similar(x, Float64)
    _slices_along!(_rank!, parent(w), (parent(x),), Val(DimensionalData.dimnum(x, _overname(d))), direction)
    return w
end

"""
    vector_reorder(x, order, d)

Vensim's `VECTOR REORDER` along dimension `d`: the element at position `i` is
the one of `x` at position `order[i]` (0-based, as `vector_sort_order` gives).
`x` and `order` have the same dimensions.
"""
function vector_reorder(x::AbstractDimArray, order::AbstractDimArray, d)
    DimensionalData.dims(order) == DimensionalData.dims(x) ||
        throw(DimensionMismatch("vector_reorder: `order` needs the dimensions of `x`"))
    w = similar(x)
    _slices_along!(_reorder!, parent(w), (parent(x), parent(order)), Val(DimensionalData.dimnum(x, _overname(d))))
    return w
end

"""
    vector_select(selection, x, over, missing, action, error)

Vensim's `VECTOR SELECT`, over dimension `over` (or a tuple of them; Vensim's
`!` subscripts), which the result no longer has: the elements of `x` where
`selection` is not zero, combined by `action` (0 sum of selection·x, 1 product
of selection·x, 2 minimum, 3 maximum, 4 mean of selection·x, 5 product of
x^selection, 6 sum, 7 product, 8 minimum, 9 maximum, 10 mean of x); `missing`
where `selection` is all zeros.  `error` 1 (or 3) stops the model when
`selection` is all zeros, 2 (or 3) when it has more than one non-zero.
`selection` and `x` line up by dimension name.
"""
function vector_select(sel::AbstractDimArray, x::AbstractDimArray, over, missing_vals, action, err)
    S = DimensionalData.broadcast_dims((a, b) -> a, sel, x)
    E = DimensionalData.broadcast_dims((a, b) -> b, sel, x)
    names = over isa Tuple ? map(_overname, over) : (_overname(over),)
    ks = Tuple(DimensionalData.dimnum(S, n) for n in names)
    kept = Tuple(d for (i, d) in enumerate(DimensionalData.dims(S)) if !(i in ks))
    isempty(kept) && return pysd_vector_select(parent(S), parent(E), missing_vals, action, err)
    w = DimArray(zeros(promote_type(eltype(S), eltype(E), Float64), map(length, kept)), kept)
    _vector_select!(parent(w), parent(S), parent(E), Val(ks), missing_vals, action, err)
    return w
end

"""
    allocate_by_priority(request, priority, width, supply, d)

Vensim's `ALLOCATE BY PRIORITY` along dimension `d`: `supply` shared among the
elements of `request` along `d`, the highest `priority` first, with priorities
within `width` of each other served together.  `width` and `supply` may vary
over the other dimensions (not over `d`).
"""
function allocate_by_priority(request::AbstractDimArray, priority, width, supply, d)
    R, P, W, S = _spread(request, priority, width, supply)
    w = similar(R, Float64)
    _slices_along!(_allocate_priority!, parent(w), (parent(R), parent(P), parent(W), parent(S)),
                   Val(DimensionalData.dimnum(R, _overname(d))))
    return w
end

"""
    allocate_available(request, profiles, supply, d, p)

Vensim's `ALLOCATE AVAILABLE` along dimension `d`: `supply` shared among the
elements of `request` by their priority profiles, `profiles` over `d` and
the profile dimension `p` (type, priority, width, extra; Vensim's `pprofile`).
"""
function allocate_available(request::AbstractDimArray, profiles::AbstractDimArray, supply, d, p)
    pd = DimensionalData.dims(profiles, _overname(p))
    others = Tuple(x for x in DimensionalData.dims(profiles) if DimensionalData.name(x) !== _overname(p))
    flat = DimArray(zeros(map(length, others)), others)
    R, _, S = _spread(request, flat, supply)
    PP = DimensionalData.broadcast_dims((a, b) -> b, DimArray(zeros(size(R)..., length(pd)),
                                        (DimensionalData.dims(R)..., pd)), profiles)
    PP = permutedims(PP, (DimensionalData.dims(R)..., pd))
    w = similar(R, Float64)
    _allocate_available!(parent(w), parent(R), parent(PP), parent(S), Val(DimensionalData.dimnum(R, _overname(d))))
    return w
end

# arrays and numbers laid out alike, over all their dimensions
function _spread(xs...)
    arrays = [x for x in xs if x isa AbstractDimArray]
    template = DimensionalData.broadcast_dims((a...) -> 0.0, arrays...)
    return map(x -> DimensionalData.broadcast_dims((a, b) -> b, template, x isa AbstractDimArray ? x : DimArray(fill(float(x)), ())), xs)
end

_allocate_priority!(w, r, p, width, supply) =
    (w .= pysd_allocate_by_priority(r, p, width[firstindex(width)], supply[firstindex(supply)]); w)

# ALLOCATE AVAILABLE on each slice along dimension k; pp has the profile
# dimension after the others
function _allocate_available!(w, r, pp, supply, ::Val{k}) where {k}
    N = ndims(w)
    for I in CartesianIndices(ntuple(i -> i == k ? 1 : size(w, i), N))
        sel = ntuple(i -> i == k ? Colon() : I[i], N)
        s = view(supply, sel...)
        view(w, sel...) .= pysd_allocate_available(view(r, sel...), view(pp, sel..., :), s[firstindex(s)])
    end
    return w
end

# f!(w, sources..., args...) on each slice along dimension k
function _slices_along!(f!, w, srcs::Tuple, ::Val{k}, args...) where {k}
    N = ndims(w)
    for I in CartesianIndices(ntuple(i -> i == k ? 1 : size(w, i), N))
        sel = ntuple(i -> i == k ? Colon() : I[i], N)
        f!(view(w, sel...), map(s -> view(s, sel...), srcs)..., args...)
    end
    return w
end
_sort_order!(w, v, direction) = (w .= pysd_vector_sort_order(v, direction); w)
_rank!(w, v, direction) = (w .= pysd_vector_rank(v, direction); w)
function _reorder!(w, v, order)
    for i in eachindex(w, order)
        w[i] = v[firstindex(v) + round(Int, order[i])]
    end
    return w
end

# VECTOR SELECT over the dimensions at positions ks of sel and x (laid out
# alike): w has the other dimensions, in the same order
function _vector_select!(w, sel, x, ::Val{ks}, missing_vals, action, err) where {ks}
    N = ndims(sel)
    kept = Tuple(i for i in 1:N if !(i in ks))
    for J in CartesianIndices(w)
        idx = ntuple(i -> i in ks ? Colon() : J[findfirst(==(i), kept)], N)
        w[J] = pysd_vector_select(view(sel, idx...), view(x, idx...), missing_vals, action, err)
    end
    return w
end

"""
    piecewise_linear(x₁ => y₁, x₂ => y₂, …)

A lookup: called as `f(x)`, it interpolates linearly between the points and
keeps the first or last value outside them, as Vensim.  It is DataInterpolations'
`LinearInterpolation` with constant extrapolation, as the lookups read from
files.
"""
piecewise_linear(points::Pair...) =
    pysd_build_tab_itp(Float64[last(p) for p in points], Float64[first(p) for p in points], :interpolate)

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
