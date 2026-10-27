# Running a model: fixed-step Euler, as Vensim, saving every `saveat`.

"""
    Results

What `run_model` returns: `res.time`, and the values of every name by name,
`res[:temperature]` (a vector over the saved times; parameters and constants
give their value).
"""
struct Results
    time::Vector{Float64}
    saved::Vector{NamedTuple}
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
    return [getfield(s, v.name) for s in r.saved]
end
Base.haskey(r::Results, name::Union{Symbol,AbstractString}) = haskey(r.model.byname, Symbol(name))
Base.keys(r::Results) = [v.name for v in r.model.vars]

# what the generated code reads: parameters, captured values, inputs, the
# time, and the buffers it fills in place (one set per run)
function _runparams(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;))
    inp = merge(m.inputs, inputs)
    par = Base.invokelatest(m.params, inp, params, m.env, m.t0, m.dt)
    work = NamedTuple{Tuple(first.(m.buffers))}(Tuple(zeros(last(b)) for b in m.buffers))
    return (; par, env = m.env, inputs = inp, t0 = m.t0, dt = m.dt, work)
end

"""
    run_model(model; params = (;), inputs = (;))

Run `model` from t₀ to t_final with Euler steps of Δt, as Vensim, and save
every `saveat`.  `params` changes parameters by name (`(; τ = 5)`), `inputs`
input sheets (`(; scen_w = excel(…))`).
"""
function run_model(m::Model; params::NamedTuple = (;), inputs::NamedTuple = (;))
    p = _runparams(m; params, inputs)
    u = m.init(p)
    du = similar(u)
    nsteps = round(Int, (m.tf - m.t0) / m.dt)
    every = max(1, round(Int, m.saveat / m.dt))
    times, saved = Float64[], NamedTuple[]
    for n in 0:nsteps
        t = m.t0 + n * m.dt
        if n % every == 0 || n == nsteps
            push!(times, t)
            push!(saved, m.observe(u, p, t))
        end
        n == nsteps && break
        m.rhs!(du, u, p, t)
        @. u += m.dt * du
    end
    return Results(times, saved, p.par, m)
end
