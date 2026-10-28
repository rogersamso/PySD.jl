# Resolving names: what each name in an equation refers to.  Declared names
# first (the set's own, then those of the sets without a name, which share one
# set of names as Vensim's views), then input sheets, then Julia values from
# the code around the set, then PySD's functions for equations.

"A declared name in a resolved expression."
struct VarRef
    name::Symbol
end
"A Julia value the equations use, captured by @equations."
struct EnvRef
    key::Symbol
end
"An input sheet given to `Model` by name."
struct InputRef
    name::Symbol
end
"The value of the k-th stateful operator."
struct OpRef
    k::Int
end

Base.show(io::IO, r::VarRef) = print(io, r.name)
Base.show(io::IO, r::EnvRef) = print(io, "env.", r.key)
Base.show(io::IO, r::InputRef) = print(io, "inputs.", r.name)
Base.show(io::IO, r::OpRef) = print(io, "op", r.k)

# PySD's functions for equations, found even when not imported.
const _BUILTINS = Dict{Symbol,Any}(
    :sum_over => sum_over, :maximum_over => maximum_over, :minimum_over => minimum_over,
    :prod_over => prod_over, :previous => previous, :piecewise_linear => piecewise_linear,
    :zidz => pysd_zidz, :xidz => pysd_xidz,
    :At => DimensionalData.At, :Not => DimensionalData.Not, :set => DimensionalData.set,
    :I => LinearAlgebra.I, :inv => LinearAlgebra.inv,
    :constant => constant, :lookup => lookup, :data => data)

"A stateful operator call found in an equation."
struct OperatorCall
    kind::Symbol            # :smooth, :delay, :trend, :sample_if_true, :fixed_delay, :initial
    args::Vector{Any}       # resolved
    kwargs::Dict{Symbol,Any}
    source::LineNumberNode
end

mutable struct Resolver
    sets::Vector{EquationSet}
    prefixes::Vector{Union{Nothing,Symbol}}
    local_names::Vector{Dict{Symbol,Symbol}}   # per set: declared name → full name
    shared::Dict{Symbol,Symbol}                # names of sets without a name
    decls::Dict{Symbol,Tuple{Declaration,Int}} # full name → declaration, set
    inputs::NamedTuple
    env::Dict{Symbol,Any}                      # captured values, by key
    operators::Vector{OperatorCall}
end

_full(prefix, name) = prefix === nothing ? name : Symbol(prefix, ".", name)

function Resolver(sets, inputs)
    r = Resolver(sets, [s.name for s in sets], Dict{Symbol,Symbol}[], Dict{Symbol,Symbol}(),
                 Dict{Symbol,Tuple{Declaration,Int}}(), inputs, Dict{Symbol,Any}(), OperatorCall[])
    for (i, s) in enumerate(sets)
        names = Dict{Symbol,Symbol}()
        for d in s.declarations
            full = _full(s.name, d.name)
            haskey(r.decls, full) &&
                error("$(_where(d.source)): `$full` is declared twice (also at $(_where(r.decls[full][1].source)))")
            r.decls[full] = (d, i)
            names[d.name] = full
            s.name === nothing && (r.shared[d.name] = full)
        end
        push!(r.local_names, names)
    end
    return r
end

_where(l::LineNumberNode) = string(l.file === nothing ? "" : basename(string(l.file)), ":", l.line)

# a Julia value from Base, Core or a standard library: declared names take its place
_is_base_value(v) = (m = v isa Module ? v : parentmodule(v isa Function || v isa Type ? v : typeof(v));
                     m in (Base, Core, LinearAlgebra, Base.MathConstants))

function _declared(r::Resolver, i, s::Symbol)
    full = get(r.local_names[i], s, nothing)
    full === nothing && r.prefixes[i] === nothing && (full = get(r.shared, s, nothing))
    return full
end

function _envref(r::Resolver, i, s::Symbol, v)
    key = Symbol(s, "_", i)
    r.env[key] = v
    return EnvRef(key)
end

# Evaluate a Julia expression now, with the set's captured values (selectors on
# the left of `~`, component references such as `stages[k]`).
function _static(r::Resolver, i, ex)
    env = r.sets[i].env
    ex isa Symbol && haskey(env, ex) && return env[ex]
    used = _symbols!(Set{Symbol}(), ex, Symbol[])
    binds = [:($s = $(QuoteNode(env[s]))) for s in used if haskey(env, s)]
    for s in used
        haskey(env, s) || haskey(_BUILTINS, s) || isdefined(@__MODULE__, s) ||
            error("`$s` in `$ex` must be a Julia value")
    end
    builtins = [:($s = $(QuoteNode(_BUILTINS[s]))) for s in used if !haskey(env, s) && haskey(_BUILTINS, s)]
    return _in_once(Expr(:let, Expr(:block, binds..., builtins...), ex))
end

resolve(r::Resolver, i, x, src) = _resolve(r, i, x, Symbol[], src)

_resolve(r, i, x, bound, src) = x
function _resolve(r::Resolver, i, s::Symbol, bound, src)
    s in bound && return s
    s === :t && return :t
    s === :t₀ && return :(p.t0)
    s === :Δt && return :(p.dt)
    env = r.sets[i].env
    full = _declared(r, i, s)
    if full !== nothing
        if haskey(env, s) && !_is_base_value(env[s])
            error("$(_where(src)): `$s` is declared in the model and is also a Julia value here")
        end
        return VarRef(full)
    end
    haskey(r.inputs, s) && return InputRef(s)
    # PySD's functions for equations come before Julia values of the same name
    # (DimensionalData exports `lookup`, for instance)
    haskey(_BUILTINS, s) && return QuoteNode(_BUILTINS[s])
    if haskey(env, s)
        v = env[s]
        v isa EquationSet && error("$(_where(src)): `$s` is a component; use its variables, `$s.name`")
        haskey(_BUILTINS, s) && v === _BUILTINS[s] && return QuoteNode(v)
        isdefined(@__MODULE__, s) && getfield(@__MODULE__, s) === v && return s   # Base's own: exp, min
        return _envref(r, i, s, v)
    end
    haskey(_BUILTINS, s) && return QuoteNode(_BUILTINS[s])
    (isdefined(@__MODULE__, s) || !Base.isidentifier(s)) && return s     # Base: exp, min, +, …
    error("$(_where(src)): `$s` is not declared in the model, an input or a Julia value")
end

_dotted(f::Symbol) = (n = string(f); length(n) > 1 && n[1] == '.' && n[2] != '.') ? Symbol(n[2:end]) : nothing
_dotted(f) = nothing

function _resolve(r::Resolver, i, x::Expr, bound, src)
    h = x.head
    if h === :quote || h === :inert
        return x
    elseif h === :. && length(x.args) == 2 && x.args[2] isa QuoteNode
        obj = x.args[1]
        if !(obj isa Symbol && (obj in bound || _declared(r, i, obj) !== nothing))
            v = obj isa Symbol && !haskey(r.sets[i].env, obj) ? nothing : _static(r, i, obj)
            if v isa EquationSet
                return _component_var(r, v, x.args[2].value, src)
            end
        end
        return Expr(:., _resolve(r, i, obj, bound, src), x.args[2])
    elseif h === :. && length(x.args) == 2 && x.args[2] isa Expr && x.args[2].head === :tuple
        # f.(args…): element by element, lined up by dimension name
        f = _resolve(r, i, x.args[1], bound, src)
        return Expr(:call, _bc, f, (_resolve(r, i, a, bound, src) for a in x.args[2].args)...)
    elseif h === :kw || (h === :(=) && x.args[1] isa Symbol)
        return Expr(h, x.args[1], _resolve(r, i, x.args[2], bound, src))
    elseif h === :generator || h === :flatten
        inner = copy(bound)
        iters = map(x.args[2:end]) do it
            if it isa Expr && it.head === :(=)
                rng = _resolve(r, i, it.args[2], inner, src)
                _loopvars!(inner, it.args[1])
                Expr(:(=), it.args[1], rng)
            else
                _resolve(r, i, it, inner, src)
            end
        end
        return Expr(h, _resolve(r, i, x.args[1], inner, src), iters...)
    elseif h === :call
        return _resolve_call(r, i, x, bound, src)
    end
    return Expr(h, (_resolve(r, i, a, bound, src) for a in x.args)...)
end

function _component_var(r::Resolver, set::EquationSet, name::Symbol, src)
    set.name === nothing && error("$(_where(src)): only components (sets with a name) have variables to refer to")
    full = _full(set.name, name)
    haskey(r.decls, full) || error("$(_where(src)): component `$(set.name)` has no variable `$name`")
    d = r.decls[full][1]
    (get(d.metadata, :input, false) || get(d.metadata, :output, false)) ||
        error("$(_where(src)): `$full` is not an input or output of `$(set.name)`")
    return VarRef(full)
end

function _split_kwargs(args)
    pos, kw = Any[], Dict{Symbol,Any}()
    for a in args
        if a isa Expr && a.head === :parameters
            for k in a.args
                k isa Symbol ? (kw[k] = k) : (kw[k.args[1]] = k.args[2])
            end
        elseif a isa Expr && a.head === :kw
            kw[a.args[1]] = a.args[2]
        else
            push!(pos, a)
        end
    end
    return pos, kw
end

function _resolve_call(r::Resolver, i, x, bound, src)
    f = x.args[1]
    pos, kw = _split_kwargs(x.args[2:end])
    res(a) = _resolve(r, i, a, bound, src)
    if f isa Symbol && !(f in bound)
        full = _declared(r, i, f)
        if full !== nothing && r.decls[full][1].kind === :variable
            # x(t₀): the value at the initial time;  x(t - τ; init): the value τ ago
            ref = VarRef(full)
            if pos == [:t₀]
                push!(r.operators, OperatorCall(:initial, Any[ref], Dict{Symbol,Any}(), src))
                return OpRef(length(r.operators))
            elseif length(pos) == 1 && pos[1] isa Expr && pos[1].head === :call &&
                   pos[1].args[1] === :- && pos[1].args[2] === :t
                kws = Dict{Symbol,Any}(k => res(v) for (k, v) in kw)
                kws[:τ] = res(pos[1].args[3])
                push!(r.operators, OperatorCall(:fixed_delay, Any[ref], kws, src))
                return OpRef(length(r.operators))
            elseif pos == [:t]
                return ref
            end
            error("$(_where(src)): `$x`: a variable is called only as x(t₀) or x(t - τ; init)")
        end
        if f in _OPERATOR_NAMES && (!haskey(r.sets[i].env, f) || r.sets[i].env[f] === getfield(@__MODULE__, f))
            push!(r.operators, OperatorCall(f, Any[res(a) for a in pos],
                                            Dict{Symbol,Any}(k => res(v) for (k, v) in kw), src))
            return OpRef(length(r.operators))
        end
        f === :∂t && error("$(_where(src)): ∂t(…) goes on the left of `~` only")
        op = _dotted(f)
        if op !== nothing
            return Expr(:call, _bc, _resolve(r, i, op, bound, src), (res(a) for a in pos)...)
        end
    end
    args = Any[res(a) for a in pos]
    isempty(kw) || pushfirst!(args, Expr(:parameters, (Expr(:kw, k, res(v)) for (k, v) in kw)...))
    return Expr(:call, res(f), args...)
end
