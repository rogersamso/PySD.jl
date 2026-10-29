# Running a model: fixed-step Euler, as Vensim, saving every `saveat`.

"""
    Results

What `run_model` returns: `res.time`, and the values of every name by name,
`res[:temperature]` (a vector over the saved times; parameters and constants
give their value).
"""
struct Results
    time::Vector{Float64}
    saved::Vector{Vector{Any}}            # at each saved time, the values in the order of _shown
    index::Dict{Symbol,Int}
    par::NamedTuple
    model::Model
end

function Base.getindex(r::Results, name::Union{Symbol,AbstractString})
    v = get(r.model.byname, Symbol(name), nothing)
    v === nothing && throw(KeyError(name))
    if v.kind in (:parameter, :constant)
        x = getfield(r.par, v.id)
        return isempty(v.dims) ? x : DimArray(x, v.dims)
    end
    i = r.index[v.name]
    return isempty(v.dims) ? [s[i] for s in r.saved] : [DimArray(s[i], v.dims) for s in r.saved]
end
Base.haskey(r::Results, name::Union{Symbol,AbstractString}) = haskey(r.model.byname, Symbol(name))
Base.keys(r::Results) = [v.name for v in r.model.vars]

# what the generated code reads: parameters, captured values, inputs, the
# time, and the buffers it fills in place (one set per run)
function _runparams(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;))
    for k in keys(params)
        haskey(m.structural, k) &&
            error("`$k` can't change between runs: it fixes the structure of the operator at $(_where(m.structural[k])) " *
                  "(a delay's number of steps, an order); build the model again with its new value")
    end
    inp = merge(m.inputs, inputs)
    par = Base.invokelatest(m.params, inp, params, m.env, m.t0, m.dt)
    T = promote_type(_numtype(par), _numtype(m.env))
    work = NamedTuple{Tuple(first.(m.buffers))}(Tuple(zeros(T, last(b)) for b in m.buffers))
    # the histories of fixed delays and SAMPLE IF TRUE (src/dsl/history.jl)
    clock, delays, samples = _histories(m, T)
    # `zero`: the run's number type, as a value (a type in a field would not be inferred)
    return (; par, env = m.env, inputs = inp, t0 = m.t0, dt = m.dt, work, zero = zero(T),
            clock, delays, samples)
end

# The number type the state and the buffers hold: Float64, or what the
# parameters hold instead (ForwardDiff's Dual for derivatives, a Measurement
# for uncertainties), so that it goes through the whole run.
_numtype(x::Number) = typeof(float(x))
_numtype(x::AbstractArray{<:Number}) = typeof(float(zero(eltype(x))))
_numtype(x::Union{Tuple,NamedTuple}) = mapreduce(_numtype, promote_type, x; init = Float64)
_numtype(x) = Float64

# Euler steps, as Vensim; fixed delays and samples move by whole steps
function _simulate(init, rhs!, observe, p, m::Model)
    p.clock.steps = true
    u = init(p)
    du = similar(u)
    nsteps = round(Int, (m.tf - m.t0) / m.dt)
    every = max(1, round(Int, m.saveat / m.dt))
    times, saved = Float64[], Vector{Any}[]
    for n in 0:nsteps
        t = m.t0 + n * m.dt
        if n % every == 0 || n == nsteps
            push!(times, t)
            push!(saved, observe(u, p, t))
        end
        n == nsteps && break
        rhs!(du, u, p, t)
        @. u += m.dt * du
        _advance_all!(p, t, t + m.dt)
    end
    return times, saved
end

"""
    run_model(model; params = (;), inputs = (;), check_units = false)

Run `model` from t₀ to t_final with Euler steps of Δt, as Vensim, and save
every `saveat`.  `params` changes parameters by name (`(; τ = 5)`), `inputs`
input sheets (`(; scen_w = excel(…))`).  `check_units = true` checks the
units first ([`check_units`](@ref)) and stops if they don't add up;
`:warn` prints the issues and runs anyway.
"""
function run_model(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;),
                   check_units::Union{Bool,Symbol} = false)
    _check_units_first(m, check_units)
    p = _runparams(m; params, inputs)
    times, saved = Base.invokelatest(_simulate, m.init.f, m.rhs!.f, m.observe.f, p, m)
    return _results(m, p, times, saved)
end

function _check_units_first(m::Model, check_units)
    check_units === false && return
    issues = PySD.check_units(m)
    if !isempty(issues)
        msg = "units don't add up in $(length(issues)) equations:\n" * join(string.(issues), "\n")
        check_units === :warn ? @warn(msg) : error(msg)
    end
end

_results(m::Model, p, times, saved) =
    Results(times, saved, Dict(v.name => i for (i, v) in enumerate(_shown(m.vars))), p.par, m)

# the values of every name at the given times, from the states there (a
# solution of a SciML solver's)
_observed(m::Model, p, times, states) = [m.observe.f(u, p, t) for (u, t) in zip(states, times)]

"""
    @precompile_model name = expr

In a package: `const name = expr`, a [`Model`](@ref), built and run once while
Julia precompiles the package, so that the package saves the model with all
that building and running it compiled.  Later sessions load it ready to run:
`using MyModel; run_model(MyModel.name)`.

```julia
module MyModel
using PySD
@precompile_model model = include("../mymodel.jl")
end
```

Julia precompiles the package again when one of its files, or an Excel sheet
the model reads, changes.
"""
macro precompile_model(ex)
    (ex isa Expr && ex.head === :(=) && ex.args[1] isa Symbol) ||
        throw(ArgumentError("use @precompile_model name = Model(…)"))
    name, rhs = ex.args
    built = gensym(:built)
    # (all that's compiled inside @compile_workload is saved; a const can't be
    # assigned there, so the model built there is assigned after, or built then
    # if workloads are off)
    workload = Expr(:macrocall, GlobalRef(PrecompileTools, Symbol("@compile_workload")), __source__,
                    quote
                        $built[] = $rhs
                        $run_model($built[])
                    end)
    return esc(quote
        const $name = let $built = Ref{Any}(nothing)
            $workload
            $built[] === nothing ? $rhs : $built[]
        end
    end)
end
