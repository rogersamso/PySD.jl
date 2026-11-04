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

A model with fixed delays, `sample_if_true` or switches on the time (`t ≥ 2015`,
a pulse) gets a callback that stops the solver at every step of Δt (the model's
ticks), where they move or switch, as Vensim's.  With another solver than
`Euler()` with `dt = Δt`, equations written for steps of Δt (that use Δt as a
value, test the time for equality, or keep a stock non-negative) are named in a
warning: those are the ones that may mean something else.
"""
function SciMLBase.ODEProblem(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;), kwargs...)
    isempty(m.changing) ||
        error("the time settings $(join(keys(m.changing), ", ")) change during the run: run_model(model) steps through them")
    p = PySD._runparams(m; params, inputs)
    u0 = Base.invokelatest(m.init.f, p)
    cb = _ticks_callback(m)
    if cb !== nothing
        kwargs = haskey(kwargs, :callback) ?
            merge(NamedTuple(kwargs), (; callback = SciMLBase.CallbackSet(kwargs[:callback], cb))) :
            merge(NamedTuple(kwargs), (; callback = cb))
    end
    # a model without stocks (only fixed delays and samples remember): one state
    # that stays 0, as solvers need a state to step and to interpolate
    isempty(u0) && return SciMLBase.ODEProblem{true}(_no_states(LeftOfTicks(m.rhs!.f)), [zero(eltype(u0))],
                                                    (m.t0, m.tf), p; kwargs...)
    return SciMLBase.ODEProblem{true}(LeftOfTicks(m.rhs!.f), u0, (m.t0, m.tf), p; kwargs...)
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

# --- the model's ticks: fixed delays, SAMPLE IF TRUE, switches on the time ------
#
# Fixed delays and samples move by whole steps of Δt, the model's ticks, as
# Vensim (src/dsl/history.jl): the solver is made to stop at every tick, where
# a callback records the inputs there and sets what the operators give until
# the next tick.  The solver's own steps in between only integrate the stocks.
# With Euler() and dt = Δt the ticks are the solver's steps, and the values
# Vensim's.  A model that switches on the time (`t ≥ 2015`, a pulse) stops at
# the ticks too: a switch there then falls between two of the solver's steps.

_ticks(m::Model) = (m.t0 + k * m.dt for k in 1:round(Int, (m.tf - m.t0) / m.dt))

# The rates as the solver calls them.  A step ending at the next tick, before
# the callback has moved to it, evaluates there (Runge-Kutta's last stage):
# it is still the step before the tick, so it sees the time just before, as
# the rest of the step (a switch at the tick is not on yet).  The time goes
# back by more than SMALL_VENSIM, which PULSE TRAIN allows for.
struct LeftOfTicks{F}
    rhs!::F
end
function (r::LeftOfTicks)(du, u, p, t)
    c = p.clock
    if c.tick >= 0
        next = c.t0 + (c.tick + 1) * c.dt
        t >= next - 1e-9 * c.dt && (t = next - min(1e-5, c.dt / 100))
    end
    return r.rhs!(du, u, p, t)
end

function _ticks_callback(m::Model)
    histories = any(o -> o.op isa HistoryOperator, m.operators)
    stepwise = _stepwise(m)
    ticks = histories || stepwise.switches
    ticks || !isempty(stepwise.names) || return nothing
    du = Ref{Any}(nothing)
    function tick!(integrator, k)
        p = integrator.p
        p.clock.tick, p.clock.held = k, false
        if histories
            # the values at the tick, from the state there: the operators' inputs
            Base.invokelatest(m.rhs!.f, du[], integrator.u, p, integrator.t)
            PySD._advance_all!(p)
        end
        p.clock.held = true                              # until the next tick
        SciMLBase.u_modified!(integrator, true)          # the rates change at the tick
    end
    function start!(c, u, t, integrator)
        _vensims(integrator, m) || _warn_stepwise(m, stepwise)
        ticks || return SciMLBase.u_modified!(integrator, false)
        Base.invokelatest(m.init.f, integrator.p)       # the histories from the start
        du[] = similar(u)
        foreach(τ -> SciMLBase.add_tstop!(integrator, τ), _ticks(m))
        tick!(integrator, 0)
    end
    # (a solver that stops just short of a tick, by rounding, is at the tick)
    next(integrator) = integrator.p.clock.t0 + (integrator.p.clock.tick + 1) * integrator.p.clock.dt
    at_tick(u, t, integrator) = ticks && t >= next(integrator) - 1e-9 * integrator.p.clock.dt
    return SciMLBase.DiscreteCallback(at_tick, integrator -> tick!(integrator, integrator.p.clock.tick + 1);
                                      initialize = start!, save_positions = (false, false))
end

# Euler with steps of Δt: Vensim's own integration, where every equation means
# what it was written for
_vensims(integrator, m) = nameof(typeof(integrator.alg)) === :Euler &&
    hasproperty(integrator, :dt) && isapprox(integrator.dt, m.dt; rtol = 1e-9)

# --- equations written for steps of Δt ------------------------------------------
#
# What the ticks can't fix: equations whose meaning is a step of Δt.
# - Δt as a value: `(target - x) / Δt` sets a stock in one step, `t / Δt` keeps
#   the year in one, `growth / Δt` is a growth per step.  With smaller or
#   other steps they become rates, not one-step moves.  (A time `t - Δt` or
#   `t + Δt` given to a delay or a data series is a time, not one of these;
#   nor is Δt in what depends on the time alone, such as a finite difference
#   of data, `(data(t + Δt) - data(t)) / Δt`: _of_time.)
# - the time tested for equality (`t == 2020`): true for one Euler step, but at
#   one instant for another solver (a sample's condition is read at the ticks,
#   so it is not one of these).
# - non-negative stocks: their outflow is cut to what empties them in one step.
# Their names are given in a warning; whether a result changes, only running
# the model with smaller steps tells.

const _EQUALS = (:(==), :(!=), :≠, :(.==), :(.!=), :.≠, :isequal)
const _SWITCHES = (:<, :>, :<=, :>=, :≤, :≥, :.<, :.>, :.<=, :.>=, :.≤, :.≥, _EQUALS...,
                   :floor, :ceil, :round, :trunc, :rem, :mod, :pysd_quantum)
const _SWITCH_CALLS = (:pysd_pulse, :pysd_pulse_train, :pysd_step)

_has_t(ex) = ex === :t || (ex isa Expr && any(_has_t, ex.args))
_time_arg(ex) = ex isa Expr && ex.head === :call && ex.args[1] in (:+, :-) && ex.args[2] === :t

# (the equations as built: Δt is the run's `p.dt`, and an operator's call,
# `sample_if_true` or `x(t - τ)`, is its output, with its arguments apart)
_is_dt(ex) = ex === :Δt || (ex isa Expr && ex.head === :. && ex.args[1] === :p && ex.args[2] == QuoteNode(:dt))

function _scan!(found, ex)
    _is_dt(ex) && return push!(found, :dt)
    ex isa Expr || return
    if ex.head === :call
        f, args = ex.args[1], ex.args[2:end]
        f in _EQUALS && any(_has_t, args) && push!(found, :equals)
        ((f in _SWITCHES && any(_has_t, args)) || f in _SWITCH_CALLS) && push!(found, :switch)
        for a in args
            _time_arg(a) || _scan!(found, a)
        end
    elseif ex.head === :comparison
        ops = ex.args[2:2:end]
        _has_t(ex) && push!(found, :switch)
        _has_t(ex) && any(in(_EQUALS), ops) && push!(found, :equals)
        foreach(a -> _scan!(found, a), ex.args[1:2:end])
    else
        foreach(a -> _scan!(found, a), ex.args)
    end
end

# The variables that depend on the time alone: parameters, data series and
# lookups, and what is computed from them only (with fixed delays and samples of
# them).  Δt in one of these is a finite difference or a lag of data, the same
# function of the time with any solver; Δt that reaches the stocks' rates
# through anything else (a rate per step, a latch) is not.
function _of_time(m::Model)
    of_time = Set{Symbol}(v.name for v in m.vars if v.kind in (:parameter, :constant))
    refs(x) = (out = Any[]; _refs!(out, x); out)
    known(x) = all(r -> r isa PySD.OpRef ? _op_of_time(m, r.k, known) : r.name in of_time, refs(x))
    grown = true
    while grown
        grown = false
        for v in m.vars
            (v.kind === :aux && !(v.name in of_time)) || continue
            if all(q -> known(q.rhs), v.parts)
                push!(of_time, v.name)
                grown = true
            end
        end
    end
    return of_time
end
_refs!(out, x::Union{PySD.VarRef,PySD.OpRef}) = push!(out, x)
_refs!(out, x::Expr) = foreach(a -> _refs!(out, a), x.args)
_refs!(out, x) = out
# a fixed delay or a sample of what depends on the time alone (a smooth keeps a state)
_op_of_time(m, k, known) = (o = m.operators[k]; o.op isa HistoryOperator &&
                            all(known, o.call.args) && all(known, values(o.call.kwargs)))

function _stepwise(m::Model)
    names = (dt = Symbol[], equals = Symbol[], nonnegative = Symbol[])
    switches = false
    of_time = _of_time(m)
    for v in m.vars
        v.kind in (:stock, :aux) || continue
        found = Set{Symbol}()
        foreach(q -> _scan!(found, q.rhs), v.kind === :stock ? v.rate : v.parts)
        :dt in found && !(v.name in of_time) && push!(names.dt, v.name)
        :equals in found && push!(names.equals, v.name)
        switches |= :switch in found
        v.kind === :stock && get(v.decl.metadata, :nonnegative, false) && push!(names.nonnegative, v.name)
    end
    # the arguments of smooths, delays and trends, named by where they are
    # (those of fixed delays and samples are read at the ticks)
    for o in m.operators
        o.op isa HistoryOperator && continue
        found = Set{Symbol}()
        foreach(a -> _scan!(found, a), o.call.args)
        foreach(a -> _scan!(found, a), values(o.call.kwargs))
        here = Symbol(o.call.kind, " at ", PySD._where(o.call.source))
        :dt in found && push!(names.dt, here)
        :equals in found && push!(names.equals, here)
        switches |= :switch in found
    end
    return (; switches, names = (; (k => ns for (k, ns) in pairs(names) if !isempty(ns))...))
end

function _warn_stepwise(m::Model, stepwise)
    isempty(stepwise.names) && return
    what = (dt = "use Δt as a value (a move or a rate per step)",
            equals = "test the time for equality (true for one Euler step, at one instant here)",
            nonnegative = "are non-negative stocks (their outflow is cut to what empties them in one step)")
    lines = ["  $(length(ns)) $(what[k]): " * join(first(ns, 8), ", ") * (length(ns) > 8 ? ", …" : "")
             for (k, ns) in pairs(stepwise.names)]
    @warn "Equations written for Euler steps of Δt, which may mean something else with this solver " *
          "(only Euler() with dt = Δt gives Vensim's values); compare with smaller steps to see " *
          "whether the results change:\n" * join(lines, "\n") equations = stepwise.names _id = (:pysd_stepwise, objectid(m)) maxlog = 1
end


# --- the ticks of translated ODE and MTK models (src/ticks.jl) --------------

function PySD.pysd_ticks_callback(T::PySD.PySDTicks, record!; t_final)
    ticks = (T.t0 + k * T.dt for k in 1:round(Int, (t_final - T.t0) / T.dt))
    function tick!(integrator)
        PySD.pysd_begin_tick!(T, integrator.t)
        record!(integrator.u, integrator.t)
        PySD.pysd_end_tick!(T)                           # held until the next tick
        SciMLBase.u_modified!(integrator, true)          # the rates change at the tick
    end
    function start!(c, u, t, integrator)
        PySD.pysd_reset_ticks!(T)
        foreach(τ -> SciMLBase.add_tstop!(integrator, τ), ticks)
        tick!(integrator)
    end
    # (a solver that stops just short of a tick, by rounding, is at the tick)
    at_tick(u, t, integrator) = t >= T.t0 + (T.tick + 1) * T.dt - 1e-9 * T.dt
    return SciMLBase.DiscreteCallback(at_tick, tick!; initialize = start!, save_positions = (false, false))
end

end
