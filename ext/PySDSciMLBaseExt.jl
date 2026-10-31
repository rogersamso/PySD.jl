module PySDSciMLBaseExt

# Models written with @equations as SciML ODE problems: any of SciML's
# solvers, ensembles, callbacks.  The generated rates already have SciML's
# in-place form, rhs!(du, u, p, t).

using PySD
using PySD: Model, HistoryOperator
import SciMLBase

"""
    ODEProblem(model; params = (;), inputs = (;), kwargs...)

The model as a SciML `ODEProblem` from t₀ to t_final, with the given
parameters and input sheets (as `run_model`'s).  Solve it with any ODE solver
(`Euler()` with `dt = Δt` is Vensim's); `Results(model, sol)` gives the values
of every name from the solution.  `kwargs` go to `ODEProblem`.

A model with fixed delays or `sample_if_true` gets a callback that stops the
solver at every step of Δt (the model's ticks), where they move, as Vensim's.
"""
function SciMLBase.ODEProblem(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;), kwargs...)
    p = PySD._runparams(m; params, inputs)
    u0 = Base.invokelatest(m.init.f, p)
    cb = _histories_callback(m)
    if cb !== nothing
        kwargs = haskey(kwargs, :callback) ?
            merge(NamedTuple(kwargs), (; callback = SciMLBase.CallbackSet(kwargs[:callback], cb))) :
            merge(NamedTuple(kwargs), (; callback = cb))
    end
    # a model without stocks (only fixed delays and samples remember): one state
    # that stays 0, as solvers need a state to step and to interpolate
    isempty(u0) && return SciMLBase.ODEProblem{true}(_no_states(m.rhs!.f), [zero(eltype(u0))],
                                                    (m.t0, m.tf), p; kwargs...)
    return SciMLBase.ODEProblem{true}(m.rhs!.f, u0, (m.t0, m.tf), p; kwargs...)
end

_no_states(rhs!) = (du, u, p, t) -> (rhs!(view(du, 1:0), view(u, 1:0), p, t); du[1] = zero(eltype(du)); nothing)

"""
    Results(model, sol)

The values of every name at the times of `sol`, a solution of the model's
`ODEProblem`, as `run_model` gives them.
"""
function PySD.Results(m::Model, sol::SciMLBase.AbstractODESolution)
    p = sol.prob.p
    p.clock.tick, p.clock.held = -1, false          # the ticks are the times again
    saved = Base.invokelatest(PySD._observed, m, p, sol.t, sol.u)
    return PySD._results(m, p, collect(Float64, sol.t), saved)
end

"""
    run_model(model, solver; params = (;), inputs = (;), check_units = false, kwargs...)

Run `model` with a SciML ODE solver instead of Vensim's Euler steps, and save
every `saveat`, as `run_model(model)`.  `kwargs` go to `solve` (`dt` is Δt
unless given, `abstol`, `reltol`, …).

`Euler()` with steps of Δt gives Vensim's values.  Fixed delays and
`sample_if_true` move only at the model's ticks, every Δt, whatever the
solver: it stops at each, and its own steps in between integrate the stocks.
"""
function PySD.run_model(m::Model, alg::SciMLBase.AbstractODEAlgorithm; params::NamedTuple = (;),
                        inputs::NamedTuple = (;), check_units::Union{Bool,Symbol} = false, kwargs...)
    PySD._check_units_first(m, check_units)
    prob = SciMLBase.ODEProblem(m; params, inputs)
    saveat = collect(range(m.t0, m.tf; step = m.saveat))
    last(saveat) == m.tf || push!(saveat, m.tf)
    # (the model's functions are newer than this call: solve from the newest world)
    sol = Base.invokelatest(SciMLBase.solve, prob, alg; dt = m.dt, saveat, kwargs...)
    SciMLBase.successful_retcode(sol) || error("the solver stopped at t = $(sol.t[end]): $(sol.retcode)")
    return PySD.Results(m, sol)
end

# --- fixed delays and SAMPLE IF TRUE (src/dsl/history.jl) ----------------------
#
# They move by whole steps of Δt, the model's ticks, as Vensim: the solver is
# made to stop at every tick, where a callback records the inputs there and
# sets what the operators give until the next tick.  The solver's own steps
# in between only integrate the stocks.  With Euler() and dt = Δt the ticks
# are the solver's steps, and the values Vensim's.

_ticks(m::Model) = (m.t0 + k * m.dt for k in 1:round(Int, (m.tf - m.t0) / m.dt))

function _histories_callback(m::Model)
    any(o -> o.op isa HistoryOperator, m.operators) || return nothing
    du = Ref{Any}(nothing)
    function tick!(integrator, k)
        p = integrator.p
        p.clock.tick, p.clock.held = k, false
        # the values at the tick, from the state there: the operators' inputs
        Base.invokelatest(m.rhs!.f, du[], integrator.u, p, integrator.t)
        PySD._advance_all!(p)
        p.clock.held = true                              # until the next tick
        SciMLBase.u_modified!(integrator, true)          # the rates change at the tick
    end
    function start!(c, u, t, integrator)
        Base.invokelatest(m.init.f, integrator.p)       # the histories from the start
        du[] = similar(u)
        foreach(τ -> SciMLBase.add_tstop!(integrator, τ), _ticks(m))
        tick!(integrator, 0)
    end
    # (a solver that stops just short of a tick, by rounding, is at the tick)
    next(integrator) = integrator.p.clock.t0 + (integrator.p.clock.tick + 1) * integrator.p.clock.dt
    at_tick(u, t, integrator) = t >= next(integrator) - 1e-9 * integrator.p.clock.dt
    return SciMLBase.DiscreteCallback(at_tick, integrator -> tick!(integrator, integrator.p.clock.tick + 1);
                                      initialize = start!, save_positions = (false, false))
end

end
