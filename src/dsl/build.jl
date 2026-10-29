# Model: joins equation sets into one system, checks it, sorts it and
# generates the functions that run it: params (parameters and constants,
# computed once), init (the initial state) and rhs! (the rates of change).

"An equation for a variable or a part of it (`sels`: selectors, none for the whole)."
struct Part
    sels::Vector{Pair{Symbol,Any}}
    rhs::Any
    source::LineNumberNode
end

mutable struct Var
    name::Symbol
    decl::Declaration
    set::Int
    dims::Tuple
    kind::Symbol                  # :parameter, :constant, :stock, :aux
    rate::Vector{Part}            # ∂t(x) ~ …
    init::Union{Nothing,Part}     # x(t₀) ~ …
    parts::Vector{Part}           # x ~ …
    id::Symbol                    # its name in the generated code
end

struct Operator
    call::OperatorCall
    op::StatefulOperator
    dims::Tuple                   # an operator of arrays: one set of hidden stocks per element
    range::UnitRange{Int}         # its hidden stocks in the state vector
    slot::Int                     # a history operator's place among the run's histories of its kind
end

"""
    Model(sets…; time, time_unit, saveat = step(time), inputs = (;))

Build a model from equation sets (views, components, connections): join them,
check the declarations, units, dimensions and equations, sort the equations
and generate the code that runs it.  `time = t₀:Δt:t_final`; `inputs` are the
input sheets, by name.  `numerics = :python` keeps Python PySD's last digits
(for translated models: the C maths library, numpy's order of additions,
LAPACK's gesv); the default, `:julia`, uses Julia's own functions.
"""
struct Model
    vars::Vector{Var}
    byname::Dict{Symbol,Var}
    operators::Vector{Operator}
    nstates::Int
    t0::Float64
    dt::Float64
    tf::Float64
    saveat::Float64
    time_unit::Any
    inputs::NamedTuple
    env::NamedTuple
    buffers::Vector{Pair{Symbol,Tuple}}   # arrays the code at every step fills in place
    params::Function
    init::Function
    rhs!::Function
    observe::Function
    units::Base.RefValue{Any}             # check_units' result, once it has run
    structural::Dict{Symbol,Any}          # parameters fixed when built (a delay's steps, an order): => where
    sets::Vector{EquationSet}             # as written (for pysd_export_latex)
end

Base.show(io::IO, m::Model) = print(io, "Model(", length(m.vars), " names, ",
    count(v -> v.kind === :stock, m.vars), " stocks, ", m.nstates, " states)")

_flatten_sets(x::EquationSet) = [x]
_flatten_sets(x::AbstractVector) = reduce(vcat, (_flatten_sets(y) for y in x); init = EquationSet[])

function Model(sets...; kwargs...)
    sets = _flatten_sets(collect(Any, sets))
    isempty(sets) && throw(ArgumentError("Model needs at least one set of @equations"))
    M = _model_module(first(sets).defined_in)
    # (in the world where the model's module exists)
    return Base.invokelatest(_within, () -> _model(sets; kwargs...), M)
end

function _model(sets; time, time_unit, saveat = step(time), inputs::NamedTuple = (;),
                numerics::Symbol = :julia)
    numerics in (:julia, :python) || throw(ArgumentError("numerics is :julia or :python, not $(repr(numerics))"))
    r = Resolver(sets, inputs)
    vars, byname = Var[], Dict{Symbol,Var}()
    for (full, (d, i)) in sort!(collect(r.decls); by = first)
        haskey(d.metadata, :unit) || error("$(_where(d.source)): `$full` has no unit: [unit = …], NoUnits if it has none")
        v = Var(full, d, i, Tuple(d.dims), d.kind === :parameter ? :parameter : :aux,
                Part[], nothing, Part[], Symbol("v", length(vars) + 1))
        push!(vars, v)
        byname[full] = v
    end
    for (i, s) in enumerate(sets), e in s.equations
        _add_equation!(r, byname, i, e)
    end
    for v in vars
        _classify!(r, v)
    end
    # parameters and constants, computed once
    pconst = filter(v -> v.kind in (:parameter, :constant), vars)
    order = _toposort(pconst, v -> [byname[n] for n in _deps(v) if byname[n].kind in (:parameter, :constant)])
    for v in pconst
        any(p -> _uses_time(p.rhs), v.parts) &&
            error("$(_where(v.decl.source)): `$(v.name)` has no (t), but depends on time")
        for n in _deps(v)
            w = byname[n]
            w.kind in (:parameter, :constant) ||
                error("$(_where(v.decl.source)): `$(v.name)` has no (t), but depends on `$(w.name)`, which changes with time")
        end
    end
    env = NamedTuple{Tuple(keys(r.env))}(Tuple(values(r.env)))
    t0, dt = Float64(first(time)), Float64(step(time))
    # parameters and constants run once per run: a plain function (comprehensions
    # in declarations need it; RuntimeGeneratedFunctions mishandles them), barely compiled
    params = _in_once(_params_code(order, env, numerics))
    p0 = Base.invokelatest(params, inputs, (;), env, t0, dt)
    # the stocks, then the operators' hidden stocks, in the state vector
    statevec = Dict{Symbol,UnitRange{Int}}()
    k = 0
    for v in vars
        v.kind === :stock || continue
        len = prod(_size(v.dims); init = 1)
        statevec[v.name] = (k + 1):(k + len)
        k += len
    end
    ops = Operator[]
    L = Lowering(byname, env; numerics)
    structural = Dict{Symbol,Any}()
    for call in r.operators
        op = _make_operator(call, byname, p0, env, inputs, t0, dt)
        for x in (get(call.kwargs, :order, nothing), call.kind === :fixed_delay ? call.kwargs[:τ] : nothing)
            x === nothing || foreach(n -> structural[n] = call.source, _parameters_of(x, byname))
        end
        L.src = call.source
        dims = _union(call.source, (_shape(a, L) for a in [call.args; [v for (k, v) in call.kwargs if k === :init]])...)
        push!(L.opdims, dims)
        n = nstates(op) * prod(_size(dims); init = 1)
        slot = op isa HistoryOperator ? count(o -> typeof(o.op) === typeof(op), ops) + 1 : 0
        push!(ops, Operator(call, op, dims, (k + 1):(k + n), slot))
        k += n
    end
    for (i, o) in enumerate(ops)
        isempty(o.dims) || push!(L.buffers, Symbol("o", i) => o.dims)     # the operator's value
    end
    for v in vars
        v.kind === :aux && !isempty(v.dims) && push!(L.buffers, v.id => v.dims)
    end
    init = _compile(_init_code(vars, ops, statevec, k, L))
    rhs! = _compile(_rhs_code(vars, ops, statevec, L, :rhs))
    observe = _compile(_rhs_code(vars, ops, statevec, L, :observe))
    buffers = Pair{Symbol,Tuple}[name => _size(dims) for (name, dims) in L.buffers]
    return Model(vars, byname, ops, k, t0, dt, Float64(last(time)), Float64(saveat), time_unit,
                 inputs, env, buffers, params, init, rhs!, observe, Ref{Any}(nothing), structural,
                 collect(EquationSet, sets))
end

# --- equations --------------------------------------------------------------

function _target(r::Resolver, i, x, src)
    if x isa Symbol
        full = _declared(r, i, x)
        full === nothing && error("$(_where(src)): `$x` is not declared")
        return full, Pair{Symbol,Any}[]
    elseif x isa Expr && x.head === :ref
        full, _ = _target(r, i, x.args[1], src)
        _, kw = _split_kwargs(x.args[2:end])
        length(kw) == length(x.args) - 1 ||
            error("$(_where(src)): select parts of an array by dimension: x[d = At(:e)]")
        return full, Pair{Symbol,Any}[k => _static(r, i, v) for (k, v) in kw]
    elseif x isa Expr && x.head === :.
        ref = resolve(r, i, x, src)
        ref isa VarRef || error("$(_where(src)): can't give an equation to `$x`")
        return ref.name, Pair{Symbol,Any}[]
    end
    error("$(_where(src)): can't read `$x` as the left of an equation")
end

function _add_equation!(r::Resolver, byname, i, e::Equation)
    lhs, src = e.lhs, e.source
    rhs = resolve(r, i, e.rhs, src)
    if lhs isa Expr && lhs.head === :call && lhs.args[1] === :∂t
        full, sels = _target(r, i, lhs.args[2], src)
        push!(byname[full].rate, Part(sels, rhs, src))
    elseif lhs isa Expr && lhs.head === :call && length(lhs.args) == 2 && lhs.args[2] === :t₀
        full, sels = _target(r, i, lhs.args[1], src)
        isempty(sels) || error("$(_where(src)): give the whole initial value: x(t₀) ~ …")
        v = byname[full]
        v.init === nothing || error("$(_where(src)): `$full` has two initial values")
        v.init = Part(sels, rhs, src)
    else
        full, sels = _target(r, i, lhs, src)
        push!(byname[full].parts, Part(sels, rhs, src))
    end
end

function _classify!(r::Resolver, v::Var)
    d, src = v.decl, v.decl.source
    if v.kind === :parameter
        (isempty(v.rate) && isempty(v.parts) && v.init === nothing) ||
            error("$(_where(src)): `$(v.name)` is a parameter: its value goes in the declaration, not in an equation")
        d.default === nothing && error("$(_where(src)): parameter `$(v.name)` has no value")
        v.parts = [Part(Pair{Symbol,Any}[], resolve(r, v.set, d.default, src), src)]
        return
    end
    if !isempty(v.rate)
        isempty(v.parts) || error("$(_where(src)): `$(v.name)` has a ∂t equation and another one")
        v.init === nothing && error("$(_where(src)): stock `$(v.name)` has no initial value: $(d.name)(t₀) ~ …")
        d.timevarying || error("$(_where(src)): stock `$(v.name)` is declared without (t)")
        v.kind = :stock
        _check_cover(v, v.rate)
        return
    end
    if isempty(v.parts)
        if d.default !== nothing && get(d.metadata, :input, false)
            v.parts = [Part(Pair{Symbol,Any}[], resolve(r, v.set, d.default, src), src)]   # an input not connected
        else
            error("$(_where(src)): `$(v.name)` has no equation")
        end
    end
    v.kind = d.timevarying ? :aux : :constant
    v.init === nothing || v.kind === :aux ||
        error("$(_where(src)): `$(v.name)` has an initial value but no (t)")
    _check_cover(v, v.parts)
end

# The parts of an array cover it once and only once.
function _check_cover(v::Var, parts)
    if isempty(v.dims)
        (length(parts) == 1 && isempty(parts[1].sels)) ||
            error("$(_where(parts[end].source)): `$(v.name)` has no dimensions but several equations")
        return
    end
    # (plain positions, not a DimArray: compiled once for all dimensions)
    vdims = _dimvec(v.dims)
    count = zeros(Int, _size(v.dims)...)
    for p in parts
        idx = Any[Colon() for _ in vdims]
        for (name, sel) in p.sels
            k = _findname(name, vdims)
            k === nothing && error("$(_where(p.source)): `$(v.name)` has no dimension `$name`")
            idx[k] = _select_indices(_labels(vdims[k]), sel, (; src = p.source))
        end
        view(count, idx...) .+= 1
    end
    any(>(1), count) && error("$(_where(parts[end].source)): equations for `$(v.name)` overlap")
    any(==(0), count) && error("$(_where(parts[end].source)): equations for `$(v.name)` don't cover all its elements")
end

# --- dependencies and sorting -------------------------------------------------

_refs!(out, x::VarRef) = push!(out, x.name)
_refs!(out, x::OpRef) = push!(out, Symbol("#op", x.k))
_refs!(out, x::Expr) = (foreach(a -> _refs!(out, a), x.args); out)
_refs!(out, x) = out
_refs(x) = _refs!(Symbol[], x)

_uses_time(x::Symbol) = x === :t
_uses_time(x::Expr) = any(_uses_time, x.args)
_uses_time(x) = false

# the parameters an expression depends on, through constants and auxiliaries
function _parameters_of(x, byname, out = Set{Symbol}(), seen = Set{Symbol}())
    for n in _refs!(Symbol[], x)
        (n in seen || !haskey(byname, n)) && continue
        push!(seen, n)
        v = byname[n]
        v.kind === :parameter && push!(out, n)
        v.kind in (:constant, :aux) && foreach(p -> _parameters_of(p.rhs, byname, out, seen), v.parts)
    end
    return out
end

function _deps(v::Var; initial = false)
    out = Symbol[]
    parts = v.kind === :stock ? Part[] : (initial && v.init !== nothing ? [v.init] : v.parts)
    initial && v.kind === :stock && (parts = [v.init])
    for p in parts
        _refs!(out, p.rhs)
    end
    return filter(n -> !startswith(string(n), "#op"), unique!(out))
end

function _toposort(nodes, deps)
    order, state = eltype(nodes)[], Dict{Any,Int}()
    path = Any[]
    function visit(n)
        s = get(state, n, 0)
        s == 2 && return
        if s == 1
            loop = path[findfirst(==(n), path):end]
            error("algebraic loop: " * join([_nodename(x) for x in [loop; n]], " → "))
        end
        state[n] = 1
        push!(path, n)
        for m in deps(n)
            visit(m)
        end
        pop!(path)
        state[n] = 2
        push!(order, n)
    end
    foreach(visit, nodes)
    return order
end
_nodename(v::Var) = string(v.name)
_nodename(x::Tuple) = x[1] === :stock ? string(x[2].name, "(t₀)") : x[2] isa Var ? string(x[2].name) :
                      string("operator ", x[2])
_nodename(x) = string(x)

# --- stateful operators ---------------------------------------------------------

# The value of an expression when the model is built: parameters, constants,
# auxiliaries that depend only on them and on time (at t₀), Julia values.
# (What is known is held untyped, so this is compiled once for all models: as
# a type parameter of a closure, the parameters' NamedTuple would make Julia
# compile it again for each one.)
struct Known
    byname::Dict{Symbol,Var}
    p0::Any
    env::Any
    inputs::Any
    t0::Float64
    dt::Float64
    src::LineNumberNode
end

function _static_value(x, k::Known)
    # the usual cases, without compiling anything: a number, a parameter, a constant
    x isa Number && return x
    if x isa VarRef && k.byname[x.name].kind in (:parameter, :constant)
        return getfield(k.p0, k.byname[x.name].id)
    end
    return _in_once(:(let p = (; t0 = $(k.t0), dt = $(k.dt)); $(_known(x, k)); end))
end

function _known(x, k::Known)
    x isa VarRef || return x isa Expr ? Expr(x.head, Any[_known(a, k) for a in x.args]...) :
                          x isa EnvRef ? QuoteNode(k.env[x.key]) :
                          x isa InputRef ? QuoteNode(k.inputs[x.name]) :
                          x === :t ? k.t0 : x isa OpRef ? error("$(_where(k.src)): must be known when the model is built") : x
    v = k.byname[x.name]
    v.kind in (:parameter, :constant) && return QuoteNode(getfield(k.p0, v.id))
    (v.kind === :aux && length(v.parts) == 1 && isempty(v.parts[1].sels)) ||
        error("$(_where(k.src)): `$(v.name)` must be known when the model is built")
    return _known(v.parts[1].rhs, k)
end

function _make_operator(c::OperatorCall, byname, @nospecialize(p0), @nospecialize(env), @nospecialize(inputs), t0, dt)
    known = Known(byname, p0, env, inputs, t0, dt, c.source)
    sv(x) = _static_value(x, known)
    k = c.kind
    k === :smooth && return Smooth(Int(sv(get(c.kwargs, :order, 1))))
    k === :delay && return MaterialDelay(Int(sv(get(c.kwargs, :order, 1))))
    k === :trend && return Trend()
    k === :sample_if_true && return SampleIfTrue()
    k === :initial && return Initial()
    if k === :fixed_delay
        # as Python PySD: at least one step; 0.5 steps round to 1
        τ = sv(c.kwargs[:τ])
        n = round(Int, max(τ / dt, 1) + SMALL_VENSIM)
        return FixedDelay(n)
    end
    error("unknown operator $k")
end
