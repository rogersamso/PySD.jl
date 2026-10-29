module PySDSciMLBaseExt

# Models written with @equations as SciML ODE problems: any of SciML's
# solvers, ensembles, callbacks.  The generated rates already have SciML's
# in-place form, rhs!(du, u, p, t).

using PySD
using PySD: Model, FixedDelay, SampleIfTrue
import SciMLBase

"""
    ODEProblem(model; params = (;), inputs = (;), kwargs...)

The model as a SciML `ODEProblem` from t₀ to t_final, with the given
parameters and input sheets (as `run_model`'s).  Solve it with any ODE solver
(`Euler()` with `dt = Δt` is Vensim's); `Results(model, sol)` gives the values
of every name from the solution.  `kwargs` go to `ODEProblem`.
"""
function SciMLBase.ODEProblem(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;), kwargs...)
    p = PySD._runparams(m; params, inputs)
    u0 = Base.invokelatest(m.init.f, p)
    return SciMLBase.ODEProblem{true}(m.rhs!.f, u0, (m.t0, m.tf), p; kwargs...)
end

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
"""
function PySD.run_model(m::Model, alg::SciMLBase.AbstractODEAlgorithm; params::NamedTuple = (;),
                        inputs::NamedTuple = (;), check_units::Union{Bool,Symbol} = false, kwargs...)
    PySD._check_units_first(m, check_units)
    _warn_fixed_steps(m, alg)
    prob = SciMLBase.ODEProblem(m; params, inputs)
    saveat = collect(range(m.t0, m.tf; step = m.saveat))
    last(saveat) == m.tf || push!(saveat, m.tf)
    # (the model's functions are newer than this call: solve from the newest world)
    sol = Base.invokelatest(SciMLBase.solve, prob, alg; dt = m.dt, saveat, kwargs...)
    SciMLBase.successful_retcode(sol) || error("the solver stopped at t = $(sol.t[end]): $(sol.retcode)")
    return PySD.Results(m, sol)
end

# A fixed delay and SAMPLE IF TRUE move by whole steps of Δt: only Euler's
# steps of Δt give their values.
function _warn_fixed_steps(m::Model, alg)
    any(o -> o.op isa Union{FixedDelay,SampleIfTrue}, m.operators) || return
    nameof(typeof(alg)) === :Euler && return
    @warn "the model has fixed delays or sample_if_true, which move by whole steps of Δt: " *
          "with $(nameof(typeof(alg))) their values aren't Vensim's (use Euler() with dt = Δt)"
end

end
