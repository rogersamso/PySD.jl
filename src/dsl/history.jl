# The histories of fixed delays and SAMPLE IF TRUE, one per operator and run.
#
# Vensim moves them by whole steps of Δt: a fixed delay gives the input n steps
# before, SAMPLE IF TRUE keeps the input of the last step where the condition
# held.  Hidden stocks with rates (x - s) / Δt did that too, but only with
# Euler steps of Δt, and only to the last digit (s + (x - s) is not always x).
# So they keep values instead: with Euler steps of Δt (`run_model(m)`, or a
# SciML `Euler()` with `dt = Δt`) a record per step, read by step, exact copies
# as Vensim's; with other solvers a record per accepted step, read by time: the
# delay interpolates its input at t - τ, the sample takes the input at the end
# of each step and at the times the condition switches.  Those are the limits
# of Vensim's results as Δt → 0, the continuous-time model.

"How the histories are read in a run: by steps of Δt, or by time."
mutable struct Clock
    steps::Bool
    t0::Float64
    dt::Float64
end

"A fixed delay's inputs: `times`, and `E` values (its elements) per record."
mutable struct DelayHistory{T}
    clock::Clock
    n::Int
    τ::Float64
    init::Vector{T}
    input::Vector{T}              # the input at the last step computed
    times::Vector{Float64}
    values::Vector{T}
end

"SAMPLE IF TRUE's held values: `times`, and `E` values per record (the first, at t₀, the initial value)."
mutable struct SampleHistory{T}
    clock::Clock
    input::Vector{T}
    cond::Vector{Bool}
    input_before::Vector{T}       # just before a switching time
    cond_before::Vector{Bool}
    times::Vector{Float64}
    values::Vector{T}
end

_elements(h::Union{DelayHistory,SampleHistory}) = length(h.input)
_records(h) = length(h.times)

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
    empty!(h.times); empty!(h.values)
    return h
end

function _start!(h::SampleHistory, ::SampleIfTrue, t, c, x; init = x)
    empty!(h.times); empty!(h.values)
    push!(h.times, t)
    for e in eachindex(h.input)
        push!(h.values, _elem(init, e))
    end
    return h
end

# --- the operator's value at time t --------------------------------------------

function _delayed(h::DelayHistory, e, t)
    c, E = h.clock, _elements(h)
    if c.steps
        # (a solver may look ahead, at the end of a step, before the step's
        # record: it computes that again once the record is there)
        j, n = round(Int, (t - c.t0) / c.dt) - h.n, _records(h)
        return j < 0 || n == 0 ? h.init[e] : h.values[min(j, n - 1) * E + e]
    end
    s = t - h.τ
    s < c.t0 - 1e-12 * max(1.0, abs(c.t0)) && return h.init[e]
    n = _records(h)
    n == 0 && return h.init[e]
    s >= h.times[n] && return h.values[(n - 1) * E + e]
    i = max(searchsortedlast(h.times, s), 1)
    a, b = h.values[(i - 1) * E + e], h.values[i * E + e]
    return a + (s - h.times[i]) / (h.times[i+1] - h.times[i]) * (b - a)
end

function _held(h::SampleHistory, e, t)
    c, E = h.clock, _elements(h)
    i = c.steps ? round(Int, (t - c.t0) / c.dt) + 1 : max(searchsortedlast(h.times, t), 1)
    return h.values[(min(i, _records(h)) - 1) * E + e]
end

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

# A Euler step of Δt from t to t + Δt, with the inputs at t: the delay keeps the
# input at t, the sample its new held value from t + Δt on.
function _advance!(h::DelayHistory, t, tnext)
    push!(h.times, t)
    append!(h.values, h.input)
    return h
end

function _advance!(h::SampleHistory, t, tnext)
    E, last = _elements(h), (_records(h) - 1) * _elements(h)
    push!(h.times, tnext)
    for e in 1:E
        push!(h.values, h.cond[e] ? h.input[e] : h.values[last + e])
    end
    return h
end

# Another solver's accepted step, ending at t, with the inputs at t (and just
# before t, when the condition can switch there).
_arrived!(h::DelayHistory, t, switch::Bool) = _advance!(h, t, t)

function _arrived!(h::SampleHistory, t, switch::Bool)
    E, last = _elements(h), (_records(h) - 1) * _elements(h)
    push!(h.times, t)
    for e in 1:E
        push!(h.values, h.cond[e] ? h.input[e] :
                        switch && h.cond_before[e] ? h.input_before[e] : h.values[last + e])
    end
    return h
end

# At t₀, for another solver: the delay's first record, and the sample of t₀
function _arrived_start!(h::DelayHistory)
    _advance!(h, h.clock.t0, h.clock.t0)
end

function _arrived_start!(h::SampleHistory)
    for e in eachindex(h.input)
        h.cond[e] && (h.values[e] = h.input[e])
    end
    return h
end

function _before!(h::SampleHistory)
    copyto!(h.input_before, h.input)
    copyto!(h.cond_before, h.cond)
    return h
end
_before!(h::DelayHistory) = h

# --- a run's histories -----------------------------------------------------------

function _histories(m, ::Type{T}) where {T}
    clock = Clock(true, m.t0, m.dt)
    nsteps = round(Int, (m.tf - m.t0) / m.dt) + 1
    delays, samples = DelayHistory{T}[], SampleHistory{T}[]
    for o in m.operators
        E = prod(_size(o.dims); init = 1)
        if o.op isa FixedDelay
            h = DelayHistory{T}(clock, o.op.n, o.op.τ, zeros(T, E), zeros(T, E), Float64[], T[])
            sizehint!(h.times, nsteps); sizehint!(h.values, nsteps * E)
            push!(delays, h)
        elseif o.op isa SampleIfTrue
            h = SampleHistory{T}(clock, zeros(T, E), falses(E), zeros(T, E), falses(E), Float64[], T[])
            sizehint!(h.times, nsteps + 1); sizehint!(h.values, (nsteps + 1) * E)
            push!(samples, h)
        end
    end
    return clock, delays, samples
end

function _advance_all!(p, t, tnext)
    foreach(h -> _advance!(h, t, tnext), p.delays)
    foreach(h -> _advance!(h, t, tnext), p.samples)
end

# The times another solver must stop at: where sample conditions can switch, and
# where each fixed delay starts giving its input instead of its initial value.
function _switch_times(m, p)
    ts = Float64[]
    for o in m.operators
        if o.op isa SampleIfTrue
            for s in o.op.switches
                v = s isa Symbol ? getfield(p.par, s) : s
                append!(ts, Float64.(vec(collect(v))))
            end
        end
    end
    return sort!(unique!(filter!(t -> m.t0 < t <= m.tf, ts)))
end

_delay_starts(m) = sort!(unique!(Float64[m.t0 + o.op.τ for o in m.operators
                                         if o.op isa FixedDelay && m.t0 + o.op.τ <= m.tf]))

# The times a condition compares `t` with: `t < y`, `t == 2015`, `y .>= t`, in
# any combination with &, |, !.  A parameter or constant: its id, read in each
# run; anything else known when the model is built: its value then.
const _COMPARISONS = (:<, :<=, :≤, :(==), :>, :>=, :≥, :.<, :.<=, :.≤, :.==, :.>, :.>=, :.≥)

function _comparison_times!(out, x, byname, sv)
    x isa Expr || return out
    if x.head === :call
        f = _fn(x.args[1])
        args = x.args[2:end]
        if f === _bc && !isempty(args)
            f, args = _fn(args[1]), args[2:end]
        end
        name = f isa Function ? nameof(f) : f
        if name in _COMPARISONS && length(args) == 2 && (args[1] === :t || args[2] === :t)
            other = args[1] === :t ? args[2] : args[1]
            if other isa Number
                push!(out, Float64(other))
            elseif other isa VarRef && byname[other.name].kind in (:parameter, :constant)
                push!(out, byname[other.name].id)
            else
                v = try sv(other) catch; nothing end
                v === nothing || push!(out, Float64.(vec(collect(v))))
            end
            return out
        end
    end
    foreach(a -> _comparison_times!(out, a, byname, sv), x.args)
    return out
end
