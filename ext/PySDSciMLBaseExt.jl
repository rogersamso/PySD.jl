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

A model with fixed delays or `sample_if_true` gets a callback that keeps their
histories: with `Euler()` and `dt = Δt` they move by whole steps, as Vensim;
with other solvers they follow continuous time (see `run_model`).
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
    saved = Base.invokelatest(PySD._observed, m, p, sol.t, sol.u)
    return PySD._results(m, p, collect(Float64, sol.t), saved)
end

"""
    run_model(model, solver; params = (;), inputs = (;), check_units = false, kwargs...)

Run `model` with a SciML ODE solver instead of Vensim's Euler steps, and save
every `saveat`, as `run_model(model)`.  `kwargs` go to `solve` (`dt` is Δt
unless given, `abstol`, `reltol`, …).

`Euler()` with steps of Δt gives Vensim's values.  With other solvers, fixed
delays and `sample_if_true` follow continuous time, the limit of Vensim's
results as Δt → 0: a fixed delay gives its input at t - τ (interpolated between
the solver's steps; a delay shorter than a step gives the input at the last
step), and the sample takes the input at the end of each step and at the times
where a condition comparing `t` switches.  Their values aren't Vensim's then,
and the run warns.
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
# A callback after each accepted step keeps their histories.  It finds out at
# the start which solver runs: Euler's steps of Δt keep a record per step, the
# inputs at the step's start, as run_model(m); others a record at the end of
# each step, and stop where conditions switch and where delays start.

function _histories_callback(m::Model)
    any(o -> o.op isa HistoryOperator, m.operators) || return nothing
    du = Ref{Any}(nothing)
    switches = Ref(Float64[])
    function start!(c, u, t, integrator)
        p = integrator.p
        steps = nameof(typeof(integrator.alg)) === :Euler && isapprox(integrator.dt, m.dt; rtol = 1e-12)
        p.clock.steps = steps
        Base.invokelatest(m.init.f, p)                  # the histories from the start
        du[] = similar(u)
        if !steps
            @warn "the model has fixed delays or sample_if_true: with $(nameof(typeof(integrator.alg)))" *
                  (nameof(typeof(integrator.alg)) === :Euler ? " and dt = $(integrator.dt)" : "") *
                  " they follow continuous time, the limit of Vensim's results as Δt → 0, so the values " *
                  "aren't Vensim's (Euler() with dt = Δt gives them)"
            switches[] = PySD._switch_times(m, p)
            for ts in (switches[], PySD._delay_starts(m)), s in ts
                SciMLBase.add_tstop!(integrator, s)
            end
            Base.invokelatest(m.rhs!.f, du[], u, p, t)
            foreach(PySD._arrived_start!, p.delays)
            foreach(PySD._arrived_start!, p.samples)
        end
        SciMLBase.u_modified!(integrator, true)
    end
    function step!(integrator)
        p = integrator.p
        if p.clock.steps
            # the inputs at the step's start: the values Euler stepped with
            Base.invokelatest(m.rhs!.f, du[], integrator.uprev, p, integrator.tprev)
            PySD._advance_all!(p, integrator.tprev, integrator.t)
        else
            t = integrator.t
            switch = insorted(t, switches[])
            if switch
                Base.invokelatest(m.rhs!.f, du[], integrator.u, p, prevfloat(t))
                foreach(PySD._before!, p.samples)
            end
            Base.invokelatest(m.rhs!.f, du[], integrator.u, p, t)
            foreach(h -> PySD._arrived!(h, t, switch), p.delays)
            foreach(h -> PySD._arrived!(h, t, switch), p.samples)
        end
        SciMLBase.u_modified!(integrator, true)          # the next step reads the new histories
    end
    return SciMLBase.DiscreteCallback((u, t, integrator) -> true, step!;
                                      initialize = start!, save_positions = (false, false))
end

end
