# Fixed delays and SAMPLE IF TRUE in models translated with PySD's ODE
# backend: values recorded at the model's ticks, t₀ + k·Δt, as Vensim.
#
# A solver stops at every tick (`pysd_ticks_callback`, in the SciMLBase
# extension), where the model is computed from the state there and each
# delay's input and each sample's value are recorded.  Between ticks they
# are held, so the solver's own steps only integrate the stocks: with Euler
# steps of Δt the values are Vensim's, and with any other solver the model
# is the same.  (The DSL keeps its own, in src/dsl/history.jl.)

"""
    PySDTicks(t₀, Δt)

The records of a run of a translated model: one per fixed delay and sample,
by a key (a number or a name), a value per tick.  While a solver runs, the
tick is the callback's count (a step that ends at the next tick, before the
callback has moved to it, is still in the tick before); afterwards it is the
last tick at or before the time.
"""
mutable struct PySDTicks
    t0::Float64
    dt::Float64
    tick::Int                               # -1: the tick is the time's
    held::Bool                              # false while a tick is being recorded
    times::Vector{Float64}                  # of the ticks recorded
    records::Dict{Any,Vector{Any}}
    initial::Dict{Any,Any}                  # fixed delays' initial values, from the first tick
end
PySDTicks(t0, dt) = PySDTicks(t0, dt, -1, true, Float64[], Dict{Any,Vector{Any}}(), Dict{Any,Any}())

# the tick at t: the last one at or before t, as the values hold until the next
# (a run's ticks are where they were recorded: a TIME STEP may change in a run)
function _tick(T::PySDTicks, t)
    T.tick >= 0 && return T.tick
    isempty(T.times) && return floor(Int, (t - T.t0) / T.dt + 1e-9)
    return max(searchsortedlast(T.times, t + 1e-9 * T.dt) - 1, 0)
end
_record(T::PySDTicks, key) = get!(() -> Any[], T.records, key)
_element(x, I) = isempty(I) ? x : x[I...]

"""
    pysd_reset_ticks!(ticks)

Forget every record and count the ticks from the start: at the start of a run.
"""
pysd_reset_ticks!(T::PySDTicks) =
    (T.tick = -1; T.held = true; empty!(T.times); empty!(T.records); empty!(T.initial); T)

"""
    pysd_begin_tick!(ticks, t)
    pysd_end_tick!(ticks)

The next tick, at the time `t`: between the two, the model is computed from
the state there and its fixed delays and samples recorded (`pysd_record!`).
"""
pysd_begin_tick!(T::PySDTicks, t) = (T.tick += 1; T.held = false; push!(T.times, t); T)
pysd_end_tick!(T::PySDTicks) = (T.held = true; T)

"""
    pysd_fixed_delay(ticks, key, n, init, t, I...)

DELAY FIXED: the input recorded `n` ticks before the tick at `t`, or, before
the first `n` ticks, `init` as it was at the first tick (an initial value that
is an expression, such as the input itself, is its value at the start); with
indices `I`, that element of it.
"""
function pysd_fixed_delay(T::PySDTicks, key, n::Integer, init, t, I...)
    j = _tick(T, t) - n
    r = _record(T, key)
    return j < 0 || isempty(r) ? _initial(T, key, init, I) : _element(r[min(j, length(r) - 1) + 1], I)
end
# (frozen while the first tick is recorded; before a run, the value given)
_initial(T::PySDTicks, key, init, I) =
    T.tick == 0 && !T.held ? get!(T.initial, (key, I), init) : get(T.initial, (key, I), init)

"""
    pysd_sampled(ticks, key, condition, x, init, t, I...)

SAMPLE IF TRUE.  At a tick being recorded: `x` if `condition` holds, else
what it took at the tick before (`init` at the first).  Otherwise, what it
took at the tick at `t`.  With indices `I`, an element: `condition`, `x` and
`init` are that element's.
"""
function pysd_sampled(T::PySDTicks, key, condition, x, init, t, I...)
    r = _record(T, key)
    if T.tick >= 0 && !T.held
        before = isempty(r) ? init : _element(r[end], I)
        return _holds(condition) ? x : before
    end
    isempty(r) && return init
    return _element(r[min(_tick(T, t), length(r) - 1) + 1], I)
end
_holds(c::Bool) = c
_holds(c::Real) = c > 0.5          # Vensim's conditions are 0 or 1

"""
    pysd_record!(ticks, key, x)

Records `x` for `key` at the current tick: a fixed delay's input, or a
sample's value.
"""
pysd_record!(T::PySDTicks, key, x) = (push!(_record(T, key), copy(x)); nothing)

"""
    pysd_ticks_callback(ticks, record!; t_final)

A SciML callback (with SciMLBase loaded) that makes the solver stop at every
tick of `ticks` up to `t_final` and calls `record!(u, t)` there, to record
the fixed delays and samples from the state.  `pysd_free_ticks!(ticks)`
after the solve lets the records be read by time.
"""
function pysd_ticks_callback end

"""
    pysd_free_ticks!(ticks)

After a solve: the tick is the time's again, to read the records at any time.
"""
pysd_free_ticks!(T::PySDTicks) = (T.tick = -1; T.held = true; T)

# In ModelingToolkit models (PySD's MTK backend) they are black boxes of the
# time: an element's index, the key and the number of ticks are numbers.  (The
# type promotion is defined once per function: again would overwrite it.)
@register_symbolic pysd_fixed_delay(T::PySDTicks, key::Int, n::Int, init::Real, t::Real)
@register_symbolic pysd_fixed_delay(T::PySDTicks, key::Int, n::Int, init::Real, t::Real, i::Int) false
@register_symbolic pysd_fixed_delay(T::PySDTicks, key::Int, n::Int, init::Real, t::Real, i::Int, j::Int) false
@register_symbolic pysd_fixed_delay(T::PySDTicks, key::Int, n::Int, init::Real, t::Real, i::Int, j::Int, k::Int) false
@register_symbolic pysd_sampled(T::PySDTicks, key::Int, condition::Real, x::Real, init::Real, t::Real)
@register_symbolic pysd_sampled(T::PySDTicks, key::Int, condition::Real, x::Real, init::Real, t::Real, i::Int) false
@register_symbolic pysd_sampled(T::PySDTicks, key::Int, condition::Real, x::Real, init::Real, t::Real, i::Int, j::Int) false
@register_symbolic pysd_sampled(T::PySDTicks, key::Int, condition::Real, x::Real, init::Real, t::Real, i::Int, j::Int, k::Int) false
