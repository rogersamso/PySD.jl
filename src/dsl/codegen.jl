# The generated code.  Names become local variables (v1, v2, …), operator
# values o1, o2, …, their hidden stocks s1, s2, …; captured Julia values are
# fields of `env`, input sheets fields of `inputs`.  Parameters and constants
# are computed once, with DimArrays (params); the code that runs at every step
# works on plain arrays (lower.jl), with buffers in `p.work`.

_compile(ex) = RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)

# --- parameters and constants: computed once ------------------------------------

function _lower_once(x, byname)
    x isa VarRef && return byname[x.name].id
    x isa EnvRef && return :(env.$(x.key))
    x isa InputRef && return :(inputs.$(x.name))
    x isa Expr && return Expr(x.head, (_lower_once(a, byname) for a in x.args)...)
    return x
end

function _assign_once(v::Var, byname, numerics)
    fix(x) = numerics === :python ? _python_once(x) : x
    if length(v.parts) == 1 && isempty(v.parts[1].sels)
        rhs = fix(_lower_once(v.parts[1].rhs, byname))
        return :($(v.id) = $_with_dims($rhs, $(QuoteNode(v.dims))))
    end
    code = Any[:($(v.id) = $_blank($(QuoteNode(v.dims))))]
    for p in v.parts
        push!(code, :($_setpart!($(v.id), $(fix(_lower_once(p.rhs, byname))), $(QuoteNode((; p.sels...))))))
    end
    return Expr(:block, code...)
end

function _params_code(order, env, numerics)
    body = Any[:(p = (; t0, dt))]
    byname = Dict(v.name => v for v in order)
    for v in order
        if v.kind === :parameter
            key = QuoteNode(v.name)
            push!(body, :(if haskey(overrides, $key)
                              $(v.id) = $_with_dims(overrides[$key], $(QuoteNode(v.dims)))
                          else
                              $(_assign_once(v, byname, numerics))
                          end))
        else
            push!(body, _assign_once(v, byname, numerics))
        end
    end
    # what the code at every step reads: plain arrays in the declared order
    plain = [Expr(:(=), v.id, :($_plain($(v.id), $(QuoteNode(v.dims))))) for v in order]
    push!(body, Expr(:tuple, Expr(:parameters, plain...)))
    return :(function (inputs, overrides, env, t0, dt)
                 $(body...)
             end)
end

_plain(x, ::Tuple{}) = x
_plain(x::AbstractDimArray, dims) = Array(parent(_align(x, dims)))
_plain(x::AbstractDimArray, ::Tuple{}) = ndims(x) == 0 ? x[] : x
_plain(x, dims) = x

# --- the code at every step ---------------------------------------------------------

function _block!(L::Lowering, src, build)
    L.pre = Any[]
    L.src = src
    code = build()
    return Expr(:block, L.pre..., code)
end

_unpack(vars) = [:($(v.id) = p.par.$(v.id)) for v in vars if v.kind in (:parameter, :constant)]

_size(dims) = Tuple(length(_labels(d)) for d in dims)

function _unpack_states(vars, ops, statevec, u)
    code = Any[]
    for v in vars
        v.kind === :stock || continue
        r = statevec[v.name]
        push!(code, isempty(v.dims) ? :($(v.id) = $u[$(first(r))]) :
                                      :($(v.id) = reshape(view($u, $r), $(_size(v.dims)))))
    end
    for (k, o) in enumerate(ops)
        push!(code, :($(Symbol("s", k)) = $(_opstates(o, u))))
    end
    return code
end

# an operator's hidden stocks: a vector, or (stages × elements) for arrays
_opstates(o::Operator, u) = isempty(o.dims) ? :(view($u, $(o.range))) :
    :(reshape(view($u, $(o.range)), $((nstates(o.op), _size(o.dims)...))))

# the target of an equation for a part: an element or a view
function _part_target(target, v::Var, p::Part, L::Lowering)
    isempty(p.sels) && return target, v.dims
    idx = Any[Colon() for _ in v.dims]
    dims = Any[d for d in v.dims]
    for (name, sel) in p.sels
        k = findfirst(d -> _dname(d) === name, v.dims)
        k === nothing && error("$(_where(p.source)): `$(v.name)` has no dimension `$name`")
        labels = _labels(v.dims[k])
        i = _select_indices(labels, sel, L)
        idx[k] = i
        dims[k] = i isa Integer ? nothing : Dim{name}(labels[i])
    end
    dims = Tuple(d for d in dims if d !== nothing)
    return (isempty(dims) ? :($target[$(idx...)]) : :(view($target, $(map(QuoteNode, idx)...)))), dims
end

# a variable from its equations: a number, or its buffer filled in place
function _assign(v::Var, parts, L::Lowering; target = v.id, fresh = true)
    code = Any[]
    !isempty(v.dims) && fresh && push!(code, :($(v.id) = p.work.$(v.id)))
    for p in parts
        push!(code, _block!(L, p.source, () -> begin
            t, dims = _part_target(target, v, p, L)
            _store(t, p.rhs, dims, L)
        end))
    end
    return Expr(:block, code...)
end

# the arguments: numbers, or arrays laid out in the operator's dimensions
_oparg(a, o::Operator, L::Lowering) = isempty(_shape(a, L)) ? _emit(a, (), L) : _materialize_as(a, o.dims, L)
_opargs(o::Operator, L::Lowering) = [_oparg(a, o, L) for a in o.call.args]

_needed(o::Operator) = (n = output_args(o.op); n === :all ? eachindex(o.call.args) : n)
_needed_refs(o::Operator) = reduce(vcat, (_refs(o.call.args[i]) for i in _needed(o)); init = Symbol[])

# the operator's value, from its hidden stocks and the arguments it needs
function _opout_code(k, o::Operator, L::Lowering)
    _block!(L, o.call.source, () -> begin
        all = _opargs(o, L)
        args = [i in _needed(o) ? a : nothing for (i, a) in enumerate(all)]
        ok, OP, sk = Symbol("o", k), QuoteNode(o.op), Symbol("s", k)
        isempty(o.dims) ? :($ok = $output($OP, $sk, $(args...))) :
            :($ok = $_op_output!(p.work.$ok, $OP, $sk, $(args...)))
    end)
end

function _dynamic_order(vars, byname, ops)
    nodes = Any[v for v in vars if v.kind === :aux]
    append!(nodes, 1:length(ops))
    function deps(n)
        refs = n isa Var ? reduce(vcat, (_refs(p.rhs) for p in n.parts); init = Symbol[]) : _needed_refs(ops[n])
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

function _rhs_code(vars, ops, statevec, L::Lowering, mode)
    body = Any[_unpack(vars)..., _unpack_states(vars, ops, statevec, :u)...]
    for n in _dynamic_order(vars, L.byname, ops)
        push!(body, n isa Var ? _assign(n, n.parts, L) : _opout_code(n, ops[n], L))
    end
    if mode === :observe
        shown = [v for v in vars if v.kind in (:stock, :aux)]
        # saved results get copies, with their dimensions
        vals = [isempty(v.dims) ? v.id : :(DimArray(copy($(v.id)), $(QuoteNode(v.dims)))) for v in shown]
        push!(body, :(return NamedTuple{$(Tuple(v.name for v in shown))}(($(vals...),))))
        return :(function (u, p, t)
                     $(body...)
                 end)
    end
    for v in vars
        v.kind === :stock || continue
        r = statevec[v.name]
        nonneg = get(v.decl.metadata, :nonnegative, false)
        if isempty(v.dims)
            i = first(r)
            push!(body, _block!(L, v.rate[1].source, () -> _store(:(du[$i]), v.rate[1].rhs, (), L)))
            nonneg && push!(body, :(du[$i] = max(du[$i], -$(v.id) / p.dt)))
        else
            dv = Symbol("d", v.id)
            push!(body, :($dv = reshape(view(du, $r), $(_size(v.dims)))))
            push!(body, _assign(v, v.rate, L; target = dv, fresh = false))
            nonneg && push!(body, :($dv .= max.($dv, .-$(v.id) ./ p.dt)))
        end
    end
    for (k, o) in enumerate(ops)
        push!(body, _block!(L, o.call.source, () -> isempty(o.dims) ?
            :($rates!(view(du, $(o.range)), $(QuoteNode(o.op)), $(Symbol("s", k)), $(_opargs(o, L)...))) :
            :($_op_rates!($(_opstates(o, :du)), $(QuoteNode(o.op)), $(Symbol("s", k)), $(_opargs(o, L)...)))))
    end
    push!(body, :(return nothing))
    return :(function (du, u, p, t)
                 $(body...)
             end)
end

function _init_code(vars, ops, statevec, n, L::Lowering)
    byname = L.byname
    node(s::Symbol) = startswith(string(s), "#op") ? (:opout, parse(Int, string(s)[4:end])) :
                      byname[s].kind === :stock ? (:stock, byname[s]) :
                      byname[s].kind === :aux ? (:aux, byname[s]) : nothing
    function deps(nd)
        kind, x = nd
        refs = kind === :stock ? _refs(x.init.rhs) :
               kind === :aux ? reduce(vcat, (_refs(p.rhs) for p in (x.init === nothing ? x.parts : [x.init])); init = Symbol[]) :
               kind === :opinit ? reduce(vcat, (_refs(a) for a in [ops[x].call.args; collect(values(ops[x].call.kwargs))]); init = Symbol[]) :
               _needed_refs(ops[x])
        out = Any[]
        kind === :opout && push!(out, (:opinit, x))
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
    body = Any[:(t = p.t0), :(u0 = zeros($n)), _unpack(vars)...]
    for (kind, x) in _toposort(nodes, deps)
        if kind === :stock
            r = statevec[x.name]
            if isempty(x.dims)
                push!(body, _block!(L, x.init.source, () -> _store(x.id, x.init.rhs, (), L)))
                push!(body, :(u0[$(first(r))] = $(x.id)))
            else
                push!(body, :($(x.id) = reshape(view(u0, $r), $(_size(x.dims)))))
                push!(body, _block!(L, x.init.source, () -> _store(x.id, x.init.rhs, x.dims, L)))
            end
        elseif kind === :aux
            push!(body, _assign(x, x.init === nothing ? x.parts : [x.init], L))
        elseif kind === :opinit
            o = ops[x]
            push!(body, _block!(L, o.call.source, () -> begin
                kws = [Expr(:kw, k, _oparg(v, o, L)) for (k, v) in o.call.kwargs if k === :init]
                s = Symbol("s", x)
                isempty(o.dims) ? quote
                    $s = $initial_states($(QuoteNode(o.op)), $(_opargs(o, L)...); $(kws...))
                    u0[$(o.range)] .= $s
                end : quote
                    $s = $(_opstates(o, :u0))
                    $_op_init!($s, $(QuoteNode(o.op)), $(_opargs(o, L)...); $(kws...))
                end
            end))
        else
            push!(body, _opout_code(x, ops[x], L))
        end
    end
    push!(body, :(return u0))
    return :(function (p)
                 $(body...)
             end)
end

# --- helpers -----------------------------------------------------------------------

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
