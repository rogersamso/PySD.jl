# The generated code.  Names become local variables (v1, v2, …), operator
# values o1, o2, …, their hidden stocks s1, s2, …; captured Julia values are
# fields of `env`, input sheets fields of `inputs`.

_compile(ex) = RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)

function _lower(x, byname, mode)
    x isa VarRef && return byname[x.name].id
    x isa OpRef && return Symbol("o", x.k)
    x isa EnvRef && return mode === :params ? :(env.$(x.key)) : :(p.env.$(x.key))
    x isa InputRef && return mode === :params ? :(inputs.$(x.name)) : :(p.inputs.$(x.name))
    x isa Expr && return Expr(x.head, (_lower(a, byname, mode) for a in x.args)...)
    return x
end

# `id = …` for a variable from its equations (or its parts)
function _assign(v::Var, parts, byname, mode)
    if length(parts) == 1 && isempty(parts[1].sels)
        rhs = _lower(parts[1].rhs, byname, mode)
        return isempty(v.dims) ? :($(v.id) = $rhs) : :($(v.id) = $_with_dims($rhs, $(QuoteNode(v.dims))))
    end
    code = Any[:($(v.id) = $_blank($(QuoteNode(v.dims))))]
    for p in parts
        push!(code, :($_setpart!($(v.id), $(_lower(p.rhs, byname, mode)), $(QuoteNode((; p.sels...))))))
    end
    return Expr(:block, code...)
end

function _params_code(order, env)
    body = Any[:(p = (; t0, dt))]
    byname = Dict(v.name => v for v in order)
    for v in order
        if v.kind === :parameter
            key = QuoteNode(v.name)
            push!(body, :(if haskey(overrides, $key)
                              $(v.id) = $_with_dims(overrides[$key], $(QuoteNode(v.dims)))
                          else
                              $(_assign(v, v.parts, byname, :params))
                          end))
        else
            push!(body, _assign(v, v.parts, byname, :params))
        end
    end
    ids = [v.id for v in order]
    push!(body, :(return (; $(ids...))))
    return :(function (inputs, overrides, env, t0, dt)
                 $(body...)
             end)
end

function _unpack(vars, statevec)
    code = Any[]
    for v in vars
        if v.kind in (:parameter, :constant)
            push!(code, :($(v.id) = p.par.$(v.id)))
        end
    end
    return code
end

function _unpack_states(vars, ops, statevec, mode = :rhs)
    code = Any[]
    for v in vars
        v.kind === :stock || continue
        r = statevec[v.name]
        # saved results get copies: the state vector changes at the next step
        view_ = mode === :observe ? :(copy($_state_view(u, $r, $(QuoteNode(v.dims))))) :
                                    :($_state_view(u, $r, $(QuoteNode(v.dims))))
        push!(code, isempty(v.dims) ? :($(v.id) = u[$(first(r))]) : :($(v.id) = $view_))
    end
    for (k, o) in enumerate(ops)
        push!(code, :($(Symbol("s", k)) = view(u, $(o.range))))
    end
    return code
end

_opargs(o::Operator, byname, mode) = [_lower(a, byname, mode) for a in o.call.args]

_needed(o::Operator) = (n = output_args(o.op); n === :all ? eachindex(o.call.args) : n)
_needed_refs(o::Operator) = reduce(vcat, (_refs(o.call.args[i]) for i in _needed(o)); init = Symbol[])

# the operator's value, from its hidden stocks and the arguments it needs
function _opout_code(k, o::Operator, byname)
    args = [i in _needed(o) ? _lower(a, byname, :run) : nothing for (i, a) in enumerate(o.call.args)]
    :($(Symbol("o", k)) = $output($(QuoteNode(o.op)), $(Symbol("s", k)), $(args...)))
end

function _dynamic_order(vars, byname, ops)
    nodes = Any[v for v in vars if v.kind === :aux]
    append!(nodes, 1:length(ops))
    function deps(n)
        refs = n isa Var ? reduce(vcat, (_refs(p.rhs) for p in n.parts); init = Symbol[]) :
               _needed_refs(ops[n])
        out = Any[]
        for s in unique(refs)
            if startswith(string(s), "#op")
                push!(out, parse(Int, string(s)[4:end]))
            elseif byname[s].kind === :aux
                push!(out, byname[s])
            end
        end
        return out
    end
    return _toposort(nodes, deps)
end

function _rhs_code(vars, byname, ops, statevec, mode)
    body = Any[_unpack(vars, statevec)..., _unpack_states(vars, ops, statevec, mode)...]
    for n in _dynamic_order(vars, byname, ops)
        push!(body, n isa Var ? _assign(n, n.parts, byname, :run) : _opout_code(n, ops[n], byname))
    end
    if mode === :observe
        shown = [v for v in vars if v.kind in (:stock, :aux)]
        push!(body, :(return NamedTuple{$(Tuple(v.name for v in shown))}(($([v.id for v in shown]...),))))
        return :(function (u, p, t)
                     $(body...)
                 end)
    end
    for v in vars
        v.kind === :stock || continue
        r, dims = statevec[v.name], QuoteNode(v.dims)
        rate = gensym(:rate)
        if length(v.rate) == 1 && isempty(v.rate[1].sels)
            push!(body, :($rate = $(_lower(v.rate[1].rhs, byname, :run))))
        else
            push!(body, :($rate = $_blank($dims)))
            for p in v.rate
                push!(body, :($_setpart!($rate, $(_lower(p.rhs, byname, :run)), $(QuoteNode((; p.sels...))))))
            end
        end
        get(v.decl.metadata, :nonnegative, false) && push!(body, :($rate = $_nonneg($rate, $(v.id), p.dt)))
        push!(body, :($_set_rate!(du, $r, $rate, $dims)))
    end
    for (k, o) in enumerate(ops)
        push!(body, :($rates!(view(du, $(o.range)), $(QuoteNode(o.op)), $(Symbol("s", k)),
                               $(_opargs(o, byname, :run)...))))
    end
    push!(body, :(return nothing))
    return :(function (du, u, p, t)
                 $(body...)
             end)
end

function _init_code(vars, byname, ops, statevec, n)
    # nodes: (:stock, v), (:aux, v), (:opinit, k), (:opout, k)
    node(s::Symbol) = startswith(string(s), "#op") ? (:opout, parse(Int, string(s)[4:end])) :
                      byname[s].kind === :stock ? (:stock, byname[s]) :
                      byname[s].kind === :aux ? (:aux, byname[s]) : nothing
    function deps(nd)
        kind, x = nd
        refs = kind === :stock ? _refs(x.init.rhs) :
               kind === :aux ? reduce(vcat, (_refs(p.rhs) for p in (x.init === nothing ? x.parts : [x.init])); init = Symbol[]) :
               kind === :opinit ? reduce(vcat, (_refs(a) for a in [ops[x].call.args; collect(values(ops[x].call.kwargs))]); init = Symbol[]) :
               Symbol[]
        out = Any[]
        kind === :opout && push!(out, (:opinit, x))
        kind === :opout && (refs = _needed_refs(ops[x]))
        for s in unique(refs)
            m = node(s)
            m === nothing || push!(out, m)
        end
        return out
    end
    nodes = Any[(:stock, v) for v in vars if v.kind === :stock]
    append!(nodes, ((:aux, v) for v in vars if v.kind === :aux))
    append!(nodes, ((:opinit, k) for k in eachindex(ops)))
    append!(nodes, ((:opout, k) for k in eachindex(ops)))
    body = Any[:(t = p.t0), :(u0 = zeros($n)), _unpack(vars, statevec)...]
    for (kind, x) in _toposort(nodes, deps)
        if kind === :stock
            push!(body, _assign(x, [x.init], byname, :run))
            push!(body, :($_write!(u0, $(statevec[x.name]), $(x.id), $(QuoteNode(x.dims)))))
        elseif kind === :aux
            push!(body, _assign(x, x.init === nothing ? x.parts : [x.init], byname, :run))
        elseif kind === :opinit
            o = ops[x]
            kws = [Expr(:kw, k, _lower(v, byname, :run)) for (k, v) in o.call.kwargs if k === :init]
            s = Symbol("s", x)
            push!(body, :($s = $initial_states($(QuoteNode(o.op)), $(_opargs(o, byname, :run)...);
                                               $(kws...))))
            push!(body, :(u0[$(o.range)] .= $s))
        else
            push!(body, _opout_code(x, ops[x], byname))
        end
    end
    push!(body, :(return u0))
    return :(function (p)
                 $(body...)
             end)
end

# --- helpers the generated code calls ------------------------------------------

_with_dims(x, ::Tuple{}) = x isa Integer ? float(x) : x
function _with_dims(x, dims::Tuple)
    sz = map(length, dims)
    x isa AbstractDimArray && return _align(x, dims)
    x isa Number && return DimArray(fill(float(x), sz), dims)
    if x isa AbstractVector && !isempty(x) && first(x) isa AbstractArray
        a = stack(parent.(x); dims = 1)                  # one array per element of the first dimension
        size(a) == sz || error("values of size $(size(a)) for dimensions of size $sz")
        return DimArray(float.(a), dims)
    end
    a = collect(x)
    size(a) == sz || (length(a) == prod(sz) && ndims(a) == 1) ||
        error("values of size $(size(a)) for dimensions of size $sz")
    return DimArray(reshape(float.(a), sz), dims)
end

_align(x::AbstractDimArray, dims) = DimensionalData.dims(x) == dims ? x : permutedims(x, dims)

_blank(dims) = DimArray(zeros(map(length, dims)), dims)

function _setpart!(x::AbstractDimArray, val, sels::NamedTuple)
    target = view(x; sels...)
    target .= val isa AbstractDimArray && ndims(target) > 0 ? parent(_align(val, DimensionalData.dims(target))) : val
    return x
end

_state_view(u, r, dims) = DimArray(reshape(view(u, r), map(length, dims)), dims)

_set_rate!(du, r, x::Number, dims) = (du[first(r)] = x; nothing)
_set_rate!(du, r, x::AbstractDimArray, dims) = (copyto!(view(du, r), _align(x, dims)); nothing)

_write!(u0, r, x::Number, dims) = (u0[first(r)] = x; nothing)
_write!(u0, r, x::AbstractDimArray, dims) = (copyto!(view(u0, r), _align(x, dims)); nothing)

_nonneg(rate::Number, x::Number, dt) = max(rate, -x / dt)
_nonneg(rate, x, dt) = _bc((r, s) -> max(r, -s / dt), rate, x)
