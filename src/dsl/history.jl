# The histories of fixed delays and SAMPLE IF TRUE, one per operator and run.
#
# Vensim moves them by whole steps of Δt: a fixed delay gives the input n steps
# before, SAMPLE IF TRUE keeps the input of the last step where the condition
# held.  Hidden stocks with rates (x - s) / Δt did that too, but only to the
# last digit (s + (x - s) is not always x).  So they keep a record per step
# instead, read by step: exact copies, as Vensim's.  Only Euler steps of Δt
# (`run_model(m)`, or a SciML `Euler()` with `dt = Δt`) have those steps.

"A run's steps: from t₀, of Δt."
struct Clock
    t0::Float64
    dt::Float64
end

_step(c::Clock, t) = round(Int, (t - c.t0) / c.dt)

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

# --- the operator's value at time t --------------------------------------------

# (a solver may look ahead, at the end of a step, before the step's record: it
# computes that again once the record is there)
function _delayed(h::DelayHistory, e, t)
    j, n = _step(h.clock, t) - h.n, _records(h)
    return j < 0 || n == 0 ? h.init[e] : h.values[min(j, n - 1) * _elements(h) + e]
end

_held(h::SampleHistory, e, t) = h.values[min(_step(h.clock, t), _records(h) - 1) * _elements(h) + e]

_hvalue(h::DelayHistory, ::FixedDelay, t, x) = _delayed(h, 1, t)
_hvalue(h::SampleHistory, ::SampleIfTrue, t, c, x) = (s = _held(h, 1, t); _true(c) ? promote(x, s)[1] : promote(x, s)[2])

function _hvalue!(out, h::DelayHistory, ::FixedDelay, t, x)
    for e in eachindex(out)
        @inbounds out[e] = _delayed(h, e, t)
    end
    return out
end

function _hvalue!(out, h::SampleHistory, ::SampleIfTrue, t, c, x)
    for e in eachindex(out)
        @inbounds out[e] = _true(_elem(c, e)) ? _elem(x, e) : _held(h, e, t)
    end
    return out
end

# --- the inputs at the step computed last ----------------------------------------

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

function _advance_all!(p)
    foreach(_advance!, p.delays)
    foreach(_advance!, p.samples)
end

# --- a run's histories -----------------------------------------------------------

function _histories(m, ::Type{T}) where {T}
    clock = Clock(m.t0, m.dt)
    nsteps = round(Int, (m.tf - m.t0) / m.dt) + 1
    delays, samples = DelayHistory{T}[], SampleHistory{T}[]
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
        end
    end
    return clock, delays, samples
end
