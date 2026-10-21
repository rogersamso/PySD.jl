"""
Prototype of the PySD.jl helpers for the cleaner ODE style.

A model is a module that defines:

    control                     # Control(initial_time, final_time, time_step)
    params()                    # Params(name = value, ...): constants that can be
                                # changed between or during runs
    initial_state(p)            # State(stock = value, ...), a named state vector
    model!(d, s, p, t)          # writes d.<stock> (rates of change), returns the
                                # auxiliaries as a NamedTuple

Everything else (solver function, running, reading results) is generic.
"""
module Proto

using ComponentArrays
using OrdinaryDiffEq
using PySD

export Control, Params, State, run_model, results, smooth!, smooth_initial

"""Simulation control (Vensim's INITIAL TIME, FINAL TIME, TIME STEP, SAVEPER)."""
Base.@kwdef struct Control
    initial_time::Float64 = 0.0
    final_time::Float64
    time_step::Float64 = 1.0
    saveper::Float64 = time_step
end

"""Named state vector: `State(stock_a = [1 2; 3 4], level = 0.0)`; `s.stock_a` is the 2×2 stock."""
State(; stocks...) = ComponentArray(; (k => float.(v) for (k, v) in stocks)...)

"""Named parameters: `Params(growth = 0.001, weight = 1:50)`; unpack with `(; growth, weight) = p`."""
Params(; values...) = ComponentArray(; (k => float.(v) for (k, v) in values)...)

"""Stock-free models still need a (empty) state vector for the solver."""
const EMPTY = ComponentArray(_none = Float64[])

"""Solver right-hand side for a model module."""
rhs!(m) = (d, s, p, t) -> (m.model!(d, s, p, t); nothing)

"""Run a model with Euler (as Vensim), saving every time step."""
function run_model(m; control = m.control, p = m.params(), u0 = m.initial_state(p), solver = Euler())
    u0 = isempty(u0) ? copy(EMPTY) : u0
    prob = ODEProblem(rhs!(m), u0, (control.initial_time, control.final_time), p)
    solve(prob, solver; dt = control.time_step, adaptive = false,
          saveat = control.initial_time:control.time_step:control.final_time)
end

"""All variables (stocks, parameters and auxiliaries) at every saved time: Vector of NamedTuples."""
function results(m, sol)
    p = sol.prob.p
    pars = NamedTuple(k => getproperty(p, k) for k in keys(p))
    map(eachindex(sol.t)) do i
        s, t = sol.u[i], sol.t[i]
        aux = m.model!(similar(s), s, p, t)
        stocks = NamedTuple(k => getproperty(s, k) for k in keys(s) if k != :_none)
        merge(pars, stocks, aux)
    end
end

# ---- stateful functions as stock chains --------------------------------------

"""
    smooth!(d, s, input, delay_time)

Rates of change of an N-stage SMOOTH (Vensim SMOOTH, SMOOTH3, SMOOTH N):
`s` holds the N stage levels, the output is the last stage `s[end]`.
"""
function smooth!(d, s, input, delay_time)
    n = length(s)
    rate = n / delay_time
    d[1] = (input - s[1]) * rate
    for k in 2:n
        d[k] = (s[k-1] - s[k]) * rate
    end
    return d
end

"""Initial levels of an N-stage SMOOTH (a vector, also for first order): all stages start at `value`."""
smooth_initial(value, n = 1) = fill(float(value), n)

end
