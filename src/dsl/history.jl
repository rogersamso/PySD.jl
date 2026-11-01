# The histories of fixed delays and SAMPLE IF TRUE, one per operator and run.
#
# Vensim moves them by whole steps of Δt: a fixed delay gives the input n steps
# before, SAMPLE IF TRUE keeps the input of the last step where the condition
# held.  Hidden stocks with rates (x - s) / Δt did that too, but only to the
# last digit (s + (x - s) is not always x).  So they keep a record per step
# instead, read by step: exact copies, as Vensim's.
#
# The steps are the model's ticks, t₀ + k·Δt, whatever the solver's steps.
# `run_model(m)` steps by Δt itself: the tick is the time's.  A SciML solver is
# made to stop at every tick, where a callback records (ext/PySDSciMLBaseExt.jl); between
# two ticks the solver may evaluate anywhere, so the callback says which tick
# it is in, and the operators hold the values set at that tick.

"A run's ticks: from t₀, every Δt; `tick ≥ 0` while a solver drives them."
mutable struct Clock
    t0::Float64
    dt::Float64
    tick::Int                    # -1: the tick is the time's
    held::Bool                   # between ticks: samples hold what their tick set
end
Clock(t0, dt) = Clock(t0, dt, -1, false)

# (from the time: the last tick at or before t, as the values hold until the next)
_step(c::Clock, t) = c.tick >= 0 ? c.tick : floor(Int, (t - c.t0) / c.dt + 1e-9)

"A fixed delay's inputs, `E` values (its elements) per step."
mutable struct DelayHistory{T}
    clock::Clock
    n::Int
    init::Vector{T}
    input::Vector{T}              # the input at the last step computed
    values::Vector{T}
end

"SAMPLE IF TRUE's held values, `E` per step (the first, at t₀, the initial value)."
mutable struct SampleHistory{T}
    clock::Clock
    input::Vector{T}
    cond::Vector{Bool}
    values::Vector{T}
end

"A RANDOM call: its draws are a function of the call (`key`), the element and the tick."
struct RandomHistory
    clock::Clock
    key::Int
end

_elements(h::Union{DelayHistory,SampleHistory}) = length(h.input)
_records(h) = length(h.values) ÷ _elements(h)

# an argument for element e: a number, or an array laid out in the operator's dimensions
_elem(a::AbstractArray, e) = @inbounds a[e]
_elem(a, e) = a

# the step's values reach the history only for the run's own number type (a
# stiff solver's Jacobian calls the step with Duals: nothing to remember then)
_keeps(::Type{T}, x) where {T} = promote_type(T, _numtype(x)) === T

# --- the start of a run --------------------------------------------------------

function _start!(h::DelayHistory, ::FixedDelay, t, x; init = x)
    for e in eachindex(h.init)
        h.init[e] = _elem(init, e)
    end
    empty!(h.values)
    return h
end

function _start!(h::SampleHistory, ::SampleIfTrue, t, c, x; init = x)
    empty!(h.values)
    for e in eachindex(h.input)
        push!(h.values, _elem(init, e))
    end
    return h
end

_start!(h::RandomHistory, ::RandomDraw, t, args...; kws...) = h

# --- the operator's value at time t --------------------------------------------

# (a solver may look ahead, at the end of a step, before the step's record: it
# computes that again once the record is there)
function _delayed(h::DelayHistory, e, t)
    j, n = _step(h.clock, t) - h.n, _records(h)
    return j < 0 || n == 0 ? h.init[e] : h.values[min(j, n - 1) * _elements(h) + e]
end

# (between ticks, the tick's own record: one more than the tick's start)
_held(h::SampleHistory, e, t) =
    h.values[min(_step(h.clock, t) + h.clock.held, _records(h) - 1) * _elements(h) + e]

_hvalue(h::DelayHistory, ::FixedDelay, t, x) = _delayed(h, 1, t)
_hvalue(h::RandomHistory, op::RandomDraw, t, args...) = _draw(h, op, 1, t, args...)

function _hvalue!(out, h::RandomHistory, op::RandomDraw, t, args...)
    for e in eachindex(out)
        @inbounds out[e] = _draw(h, op, e, t, map(a -> _elem(a, e), args)...)
    end
    return out
end

# a RANDOM draw, as Python PySD's: uniform; normal(mean, sd) truncated to [lo, hi];
# shift + stretch · exponential, shift at least lo, truncated at hi
function _draw(h::RandomHistory, op::RandomDraw, e, t, args...)
    rng = Random.Xoshiro(hash((op.seed, h.key, e, _step(h.clock, t))))
    k = op.kind
    k === :random_0_1 && return rand(rng)
    if k === :random_uniform
        lo, hi = args
        return lo + (hi - lo) * rand(rng)
    elseif k === :random_normal
        lo, hi, mean, sd = args
        return mean + sd * _truncnormal(rng, pysd_xidz(lo - mean, sd, -Inf), pysd_xidz(hi - mean, sd, Inf))
    end
    lo, hi, shift, stretch = args
    loc = max(lo, shift)
    return loc + stretch * _truncexp(rng, pysd_xidz(hi - loc, stretch, Inf))
end
_hvalue(h::SampleHistory, ::SampleIfTrue, t, c, x) =
    (s = _held(h, 1, t); _true(c) && !h.clock.held ? promote(x, s)[1] : promote(x, s)[2])

function _hvalue!(out, h::DelayHistory, ::FixedDelay, t, x)
    for e in eachindex(out)
        @inbounds out[e] = _delayed(h, e, t)
    end
    return out
end

function _hvalue!(out, h::SampleHistory, ::SampleIfTrue, t, c, x)
    for e in eachindex(out)
        @inbounds out[e] = _true(_elem(c, e)) && !h.clock.held ? _elem(x, e) : _held(h, e, t)
    end
    return out
end

# --- the inputs at the step computed last ----------------------------------------

_hinput!(h::RandomHistory, ::RandomDraw, args...) = h      # nothing to keep

function _hinput!(h::DelayHistory{T}, ::FixedDelay, x) where {T}
    _keeps(T, x) || return h
    for e in eachindex(h.input)
        @inbounds h.input[e] = _elem(x, e)
    end
    return h
end

function _hinput!(h::SampleHistory{T}, ::SampleIfTrue, c, x) where {T}
    _keeps(T, x) || return h
    for e in eachindex(h.input)
        @inbounds h.input[e] = _elem(x, e)
        @inbounds h.cond[e] = _true(_elem(c, e))
    end
    return h
end

# --- after a step ------------------------------------------------------------------

# A Euler step of Δt, with the inputs at its start: the delay keeps the input,
# the sample its new held value from the next step on.
_advance!(h::DelayHistory) = append!(h.values, h.input)

function _advance!(h::SampleHistory)
    E, last = _elements(h), (_records(h) - 1) * _elements(h)
    for e in 1:E
        push!(h.values, h.cond[e] ? h.input[e] : h.values[last + e])
    end
    return h
end

_advance!(h::RandomHistory) = h

function _advance_all!(p)
    foreach(_advance!, p.delays)
    foreach(_advance!, p.samples)
end

# --- a run's histories -----------------------------------------------------------

function _histories(m, ::Type{T}) where {T}
    clock = Clock(m.t0, m.dt)
    nsteps = round(Int, (m.tf - m.t0) / m.dt) + 1
    delays, samples, randoms = DelayHistory{T}[], SampleHistory{T}[], RandomHistory[]
    for o in m.operators
        E = prod(_size(o.dims); init = 1)
        if o.op isa FixedDelay
            h = DelayHistory{T}(clock, o.op.n, zeros(T, E), zeros(T, E), T[])
            sizehint!(h.values, nsteps * E)
            push!(delays, h)
        elseif o.op isa SampleIfTrue
            h = SampleHistory{T}(clock, zeros(T, E), falses(E), T[])
            sizehint!(h.values, (nsteps + 1) * E)
            push!(samples, h)
        elseif o.op isa RandomDraw
            push!(randoms, RandomHistory(clock, length(randoms) + 1))
        end
    end
    return clock, delays, samples, randoms
end
