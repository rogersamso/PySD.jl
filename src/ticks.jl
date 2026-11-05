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
    PySDRecord(ticks, key, n, I...)

Which record a translated equation reads: of `ticks`, the one of `key` (a
fixed delay, a sample, a RANDOM call's stream), `n` ticks back (a fixed
delay's), element `I` of an array.  One argument instead of several, built
with plain numbers when the equation is written: Symbolics registers a
method for every combination of plain and symbolic arguments, 3ⁿ of them, so
few arguments keep PySD quick to compile.
"""
struct PySDRecord{N}
    ticks::PySDTicks
    key::Int
    n::Int
    I::NTuple{N,Int}
end
PySDRecord(T::PySDTicks, key::Integer, n::Integer, I::Integer...) = PySDRecord(T, Int(key), Int(n), Int.(I))

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
    pysd_at_first_tick(f, ticks)

Call `f()` while the first tick is being recorded, for what is fixed there:
a fixed delay whose initial value is an expression keeps its value at the
start, so a model whose delays are not otherwise computed at the first tick
(ModelingToolkit: only what a solver needs) computes them in `f`.

    pysd_at_first_tick(_ticks) do
        _initials(u, p, t)
    end
"""
pysd_at_first_tick(f, T::PySDTicks) = (T.tick == 0 && !T.held && f(); nothing)

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
pysd_fixed_delay(R::PySDRecord, init, t) = pysd_fixed_delay(R.ticks, R.key, R.n, init, t, R.I...)
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
pysd_sampled(R::PySDRecord, condition, x, init, t) = pysd_sampled(R.ticks, R.key, condition, x, init, t, R.I...)
_holds(c::Bool) = c
_holds(c::Real) = c > 0.5          # Vensim's conditions are 0 or 1

"""
    pysd_tick_time(ticks, t)

The time the model sees.  While a solver runs, a step that ends at the next
tick, before the callback has moved to it (Runge-Kutta's last stage), is
still in the tick before: it sees the time just before the next tick, so a
switch at a tick (`STEP`, `PULSE`, `Time >= 2015`) changes the rates from that
tick on.  Otherwise, `t`.  (Back by more than `SMALL_VENSIM`, which `PULSE
TRAIN` allows for.)
"""
function pysd_tick_time(T::PySDTicks, t)
    T.tick >= 0 || return t
    next = T.t0 + (T.tick + 1) * T.dt
    return t >= next - 1e-9 * T.dt ? next - min(1e-5, T.dt / 100) : t
end

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

# --- RANDOM functions: one draw per tick ---------------------------------------
#
# Vensim draws a new number at every step of TIME STEP and keeps it for the
# step.  Here a draw is a function of the call's stream (a number the
# translator gives each RANDOM call, its seed included), the element of an
# array and the tick: a generator seeded from them gives it.  So it holds
# between ticks, the values read after a run are the draws the run used, and
# every run, with any solver, draws the same.  The draws are standard ones,
# which the translated equations scale and cut (RANDOM UNIFORM's lo + (hi -
# lo) u, RANDOM NORMAL's mean + std z): the bounds stay ordinary expressions.

_rng(T::PySDTicks, stream, t, I) = Random.Xoshiro(hash((stream, I, _tick(T, t))))

"""
    pysd_tick_uniform(record, t)
    pysd_tick_normal(record, t)
    pysd_tick_exponential(record, t)

A standard draw (uniform on [0, 1), normal (0, 1), exponential (1)) for the
tick at `t`, the same for the whole tick: from a generator seeded from the
record's key (the RANDOM call's stream), its element and the tick.  The same
draws in every run, with any solver.
"""
pysd_tick_uniform(R::PySDRecord, t) = rand(_rng(R.ticks, R.key, t, R.I))
pysd_tick_normal(R::PySDRecord, t) = randn(_rng(R.ticks, R.key, t, R.I))
pysd_tick_exponential(R::PySDRecord, t) = Random.randexp(_rng(R.ticks, R.key, t, R.I))

"""
    pysd_tick_normal(record, a, b, t)
    pysd_tick_exponential(record, b, t)

A standard draw truncated, as Vensim's and Python PySD's RANDOM NORMAL and
RANDOM EXPONENTIAL: a normal (0, 1) between `a` and `b`, an exponential (1)
below `b`.  Drawn again while outside (from the same generator, so the same in
every run).
"""
pysd_tick_normal(R::PySDRecord, a, b, t) = _truncnormal(_rng(R.ticks, R.key, t, R.I), a, b)
pysd_tick_exponential(R::PySDRecord, b, t) = _truncexp(_rng(R.ticks, R.key, t, R.I), b)

# (as scipy's truncnorm and truncexpon; after many tries, the nearest bound)
function _truncnormal(rng, a, b)
    for _ in 1:10_000
        z = randn(rng)
        a <= z <= b && return z
    end
    return clamp(randn(rng), a, b)
end
function _truncexp(rng, b)
    for _ in 1:10_000
        x = Random.randexp(rng)
        x <= b && return x
    end
    return min(Random.randexp(rng), b)
end

# In ModelingToolkit models (PySD's MTK backend) they are black boxes of the
# time, registered with Symbolics: the record they read is one plain argument
# (PySDRecord), as Symbolics adds a method for every combination of plain and
# symbolic arguments.
@register_symbolic pysd_fixed_delay(R::PySDRecord, init::Real, t::Real)
@register_symbolic pysd_sampled(R::PySDRecord, condition::Real, x::Real, init::Real, t::Real)
@register_symbolic pysd_tick_time(T::PySDTicks, t::Real)
@register_symbolic pysd_tick_uniform(R::PySDRecord, t::Real)
@register_symbolic pysd_tick_normal(R::PySDRecord, t::Real)
@register_symbolic pysd_tick_exponential(R::PySDRecord, t::Real)
@register_symbolic pysd_tick_normal(R::PySDRecord, a::Real, b::Real, t::Real) false
@register_symbolic pysd_tick_exponential(R::PySDRecord, b::Real, t::Real) false
