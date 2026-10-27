# The generated code.  Names become local variables (v1, v2, …), operator
# values o1, o2, …, their hidden stocks s1, s2, …; captured Julia values are
# fields of `env`, input sheets fields of `inputs`.  Parameters and constants
# are computed once, with DimArrays (params); the code that runs at every step
# works on plain arrays (lower.jl), with buffers in `p.work`.

_compile(ex) = RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, ex)

# Parameters and constants are computed once per run: compiling their code
# (a statement per name, thousands for a large model) costs much more than
# running it, so it runs with as little compiling as Julia allows, in a module
# of its own (the option is a module's), with PySD's names.
module Once
Base.Experimental.@compiler_options compile=min optimize=0 infer=false
end

function _in_once(ex)
    locals = Set{Symbol}()
    function bound!(x)                       # assigned, function arguments, loop variables
        x isa Expr || return
        if x.head in (:(=), :kw) || (x.head === :in && length(x.args) == 2)
            foreach(_lhs!, x.args[1:1])
        elseif x.head === :function || x.head === :->
            _lhs!(x.args[1])
        end
        foreach(bound!, x.args)
    end
    _lhs!(x) = x isa Symbol ? push!(locals, x) :
               x isa Expr && x.head in (:tuple, :parameters, :call, :(::), :kw) ? foreach(_lhs!, x.args) : nothing
    bound!(ex)
    ref(x) = x isa Symbol && !(x in locals) && isdefined(@__MODULE__, x) ? GlobalRef(@__MODULE__, x) :
             x isa Expr && x.head !== :quote && x.head !== :. ? Expr(x.head, map(ref, x.args)...) :
             x isa Expr && x.head === :. ? Expr(:., ref(x.args[1]), x.args[2:end]...) : x
    return Core.eval(Once, ref(ex))
end

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
        return :($(v.id) = $_named($(QuoteNode(v.name)), () -> $_with_dims($rhs, $(QuoteNode(v.dims)))))
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

# errors while computing a parameter or a constant name it
function _named(name, @nospecialize(f))      # one closure per name: not compiled for each
    try
        return f()
    catch e
        e isa ErrorException ? error("`$name`: " * e.msg) : rethrow()
    end
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

_size(dims) = Tuple(length(_labels(d)) for d in dims)

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

# the arguments its initial hidden stocks need: with `init`, those it says; without, also the input
function _needed_init(o::Operator)
    haskey(o.call.kwargs, :init) || return eachindex(o.call.args)
    n = init_args(o.op)
    return n === :all ? eachindex(o.call.args) : n
end
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

_shown(vars) = [v for v in vars if v.kind in (:stock, :aux)]

# lowered once: the same code, and so the same compiled function, for the three
_lowered_aux(v::Var, L::Lowering) = get!(() -> _assign(v, v.parts, L), L.lowered, v.name)
_lowered_opout(k, o::Operator, L::Lowering) = get!(() -> _opout_code(k, o, L), L.lowered, k)

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
    units = Any[]
    for n in _dynamic_order(vars, L.byname, ops)
        push!(units, n isa Var ? _lowered_aux(n, L) : _lowered_opout(n, ops[n], L))
    end
    if mode === :observe
        # saved results: copies, in the order of _shown; their dimensions are
        # added when they are read (a DimArray of each type here would compile
        # the constructor again for every combination of dimensions)
        vals = [isempty(v.dims) ? v.id : :(copy($(v.id))) for v in _shown(vars)]
        last = :(return Any[$(vals...)])
        return _split(units, last, (:u, :p, :t), vars, ops, statevec, :u)
    end
    for v in vars
        v.kind === :stock || continue
        r = statevec[v.name]
        nonneg = get(v.decl.metadata, :nonnegative, false)
        if isempty(v.dims)
            i = first(r)
            push!(units, Expr(:block, _block!(L, v.rate[1].source, () -> _store(:(du[$i]), v.rate[1].rhs, (), L)),
                              nonneg ? :(du[$i] = max(du[$i], -$(v.id) / p.dt)) : nothing))
        else
            dv = Symbol("d", v.id)
            push!(units, Expr(:block, :($dv = reshape(view(du, $r), $(_size(v.dims)))),
                              _assign(v, v.rate, L; target = dv, fresh = false),
                              nonneg ? :($dv .= max.($dv, .-$(v.id) ./ p.dt)) : nothing))
        end
    end
    for (k, o) in enumerate(ops)
        push!(units, _block!(L, o.call.source, () -> isempty(o.dims) ?
            :($rates!(view(du, $(o.range)), $(QuoteNode(o.op)), $(Symbol("s", k)), $(_opargs(o, L)...))) :
            :($_op_rates!($(_opstates(o, :du)), $(QuoteNode(o.op)), $(Symbol("s", k)), $(_opargs(o, L)...)))))
    end
    return _split(units, :(return nothing), (:du, :u, :p, :t), vars, ops, statevec, :u)
end

# --- one small function per variable -------------------------------------------------
#
# Julia compiles a function as a whole, and the time grows much faster than its
# length: one function with every equation of a large model takes hours.  So each
# equation (a variable, an operator's value, a stock's rate) is a function of its
# own, and the code at every step calls them in order.  Each gets only what it
# reads (parameters, stocks, buffers, numbers computed by others), never all of
# `p`, whose type, with a field per name, would be compiled again for each.
# Numbers are returned and passed on; arrays live in the buffers `p.work`.

# the names an expression reads or assigns
function _symbols!(out, x)
    if x isa Symbol
        push!(out, x)
    elseif x isa Expr
        x.head === :. && x.args[2] isa QuoteNode && return _symbols!(out, x.args[1])   # p.work.v1: `p`
        x.head === :kw && return _symbols!(out, x.args[2])
        foreach(a -> _symbols!(out, a), x.args)
    end
    return out
end

function _assigned!(out, x)
    x isa Expr || return out
    x.head === :(=) && x.args[1] isa Symbol && push!(out, x.args[1])
    foreach(a -> _assigned!(out, a), x.args)
    return out
end

# where a function finds each name of the generated code: `nothing` for numbers
# computed by other functions (passed as arguments)
function _loaders(vars, ops, statevec, u)
    load = Dict{Symbol,Any}()
    for v in vars
        if v.kind in (:parameter, :constant)
            load[v.id] = :(p.par.$(v.id))
        elseif v.kind === :stock
            r = statevec[v.name]
            load[v.id] = isempty(v.dims) ? :($u[$(first(r))]) : :(reshape(view($u, $r), $(_size(v.dims))))
        elseif v.kind === :aux
            load[v.id] = isempty(v.dims) ? nothing : :(p.work.$(v.id))
        end
    end
    for (k, o) in enumerate(ops)
        load[Symbol("s", k)] = _opstates(o, u)
        load[Symbol("o", k)] = isempty(o.dims) ? nothing : :(p.work.$(Symbol("o", k)))
    end
    return load
end

# The equations' functions: compiled when first called, like the step code that
# calls them (RuntimeGeneratedFunctions), but through a function of their own:
# Julia's compiler, seeing one generated function call itself with more and more
# arguments, would stop working out the types and allocate at every step.
const _EQUATIONS = Dict{UInt64,Tuple{Tuple,Expr}}()
const _EQUATIONS_LOCK = ReentrantLock()

function _equation!(args::Tuple, body::Expr)
    id = hash((args, body))
    lock(_EQUATIONS_LOCK) do
        old = get!(_EQUATIONS, id, (args, body))
        old == (args, body) || error("two equations with the same hash")
    end
    return id
end

function _expand(id)
    args, body = lock(() -> _EQUATIONS[id], _EQUATIONS_LOCK)
    return quote
        $(Expr(:meta, :noinline))
        $((:($a = values[$i]) for (i, a) in enumerate(args))...)
        $body
    end
end
@generated _equation(::Val{id}, values...) where {id} = _expand(id)

# p.par.v1, p.work.w3, p.dt…: the fields of `p` an expression reads, each
# replaced by a name of its own (_p_work_w3)
function _pfields!(chains, x)
    x isa Expr || return x
    if x.head === :. && x.args[2] isa QuoteNode
        root = x
        path = Symbol[]
        while root isa Expr && root.head === :. && root.args[2] isa QuoteNode
            pushfirst!(path, root.args[2].value)
            root = root.args[1]
        end
        if root === :p
            name = Symbol(join(["_p"; path], "_"))
            chains[name] = x
            return name
        end
    end
    return Expr(x.head, (_pfields!(chains, a) for a in x.args)...)
end

function _split(units, last, args, vars, ops, statevec, u; pre = Any[], caller = args)
    load = _loaders(vars, ops, statevec, u)
    loads(x, have) = [:($s = $(load[s])) for s in sort!(collect(setdiff(_symbols!(Set{Symbol}(), x), have)))
                      if haskey(load, s) && load[s] !== nothing]
    body = Any[]
    numbers = Set{Symbol}()                     # numbers computed so far, locals of the caller
    for x in units
        x === nothing && continue
        chains = Dict{Symbol,Any}()
        x = _pfields!(chains, x)
        defined = _assigned!(Set{Symbol}(), x)
        free = setdiff(_symbols!(Set{Symbol}(), x), defined)
        outs = [s for s in defined if haskey(load, s) && load[s] === nothing]
        length(outs) <= 1 || error("one equation computing $(length(outs)) numbers: $outs")
        # what it gets: the step's own arguments it uses, then names, fields of p, numbers
        names = Any[a for a in args if a in free]
        vals = Any[a for a in args if a in free]
        for s in sort!(collect(free))
            if haskey(load, s) && load[s] !== nothing
                push!(names, s); push!(vals, load[s])
            elseif haskey(chains, s)
                push!(names, s); push!(vals, chains[s])
            elseif s in numbers
                push!(names, s); push!(vals, s)
            end
        end
        id = _equation!(Tuple(names), quote
                           $x
                           return $(isempty(outs) ? nothing : only(outs))
                       end)
        call = :($_equation($(Val(id)), $(vals...)))
        push!(body, isempty(outs) ? call : :($(only(outs)) = $call))
        union!(numbers, outs)
    end
    return :(function ($(caller...),)
                 $(pre...)
                 $(body...)
                 $(loads(last, numbers)...)
                 $last
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
               kind === :opinit ? reduce(vcat, (_refs(a) for a in [ops[x].call.args[collect(_needed_init(ops[x]))];
                                                                   collect(values(ops[x].call.kwargs))]); init = Symbol[]) :
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
    body = Any[]
    for (kind, x) in _toposort(nodes, deps)
        if kind === :stock
            r = statevec[x.name]
            if isempty(x.dims)
                push!(body, Expr(:block, _block!(L, x.init.source, () -> _store(x.id, x.init.rhs, (), L)),
                                 :(u0[$(first(r))] = $(x.id))))
            else
                push!(body, Expr(:block, :($(x.id) = reshape(view(u0, $r), $(_size(x.dims)))),
                                 _block!(L, x.init.source, () -> _store(x.id, x.init.rhs, x.dims, L))))
            end
        elseif kind === :aux
            push!(body, x.init === nothing ? _lowered_aux(x, L) : _assign(x, [x.init], L))
        elseif kind === :opinit
            o = ops[x]
            push!(body, _block!(L, o.call.source, () -> begin
                kws = [Expr(:kw, k, _oparg(v, o, L)) for (k, v) in o.call.kwargs if k === :init]
                s = Symbol("s", x)
                need = _needed_init(o)
                args = [i in need ? _oparg(a, o, L) : nothing for (i, a) in enumerate(o.call.args)]
                isempty(o.dims) ? quote
                    $s = $initial_states($(QuoteNode(o.op)), $(args...); $(kws...))
                    u0[$(o.range)] .= $s
                end : quote
                    $s = $(_opstates(o, :u0))
                    $_op_init!($s, $(QuoteNode(o.op)), $(args...); $(kws...))
                end
            end))
        else
            push!(body, _lowered_opout(x, ops[x], L))
        end
    end
    return _split(body, :(return u0), (:u0, :p, :t), vars, ops, statevec, :u0;
                  pre = Any[:(t = p.t0), :(u0 = zeros($n))], caller = (:p,))
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
