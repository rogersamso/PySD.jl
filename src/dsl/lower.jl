# Lowering array equations to plain arrays.  Model knows the dimensions of
# every name, so it works out the dimensions of every expression when the model
# is built, and generates code on plain Julia arrays: the arrays a broadcast
# reads are laid out once in the target's order (a lazy permutation plus axes
# of length 1), element-by-element operations fuse into one loop that writes
# into a buffer allocated once per run, selections are index views, and what
# can't fuse (sums over a dimension, inverses, matrix products) writes into a
# buffer of its own.  Nothing is allocated while the model runs.

const _Dims = Tuple

# Each dimension is a type of its own (Dim{:name}), and so is each tuple of
# them.  The functions here take dimensions unspecialized (@nospecialize) and
# go through them in loops, not closures (a closure is a type of its own for
# each tuple it holds): Julia compiles them once, not again for each
# combination of dimensions of each model.
_dname(@nospecialize(d)) = DimensionalData.name(d)
_labels(@nospecialize(d)) = collect(parent(DimensionalData.lookup(d)))
_samedim(@nospecialize(a), @nospecialize(b)) = _dname(a) === _dname(b) && _labels(a) == _labels(b)

# dimensions as a Vector{Any}, without compiling anything for the tuple's type
function _dimvec(@nospecialize(ds))
    out = Any[]
    if ds isa Tuple
        for i in 1:nfields(ds)
            push!(out, getfield(ds, i))
        end
    else
        append!(out, ds)
    end
    return out
end

function _findname(name::Symbol, ds::Vector{Any})
    for i in eachindex(ds)
        _dname(ds[i]) === name && return i
    end
    return nothing
end
_hasname(name::Symbol, @nospecialize(ds)) = _findname(name, _dimvec(ds)) !== nothing

function _without(@nospecialize(ds), name::Symbol)
    out = Any[]
    for d in _dimvec(ds)
        _dname(d) === name || push!(out, d)
    end
    return Tuple(out)
end

function _dimstr(@nospecialize(ds))
    names = String[]
    for d in _dimvec(ds)
        push!(names, string(_dname(d)))
    end
    return "(" * join(names, ", ") * ")"
end

function _union(src, @nospecialize(shapes...))
    out = Any[]
    for s in shapes, d in _dimvec(s)
        k = _findname(_dname(d), out)
        if k === nothing
            push!(out, d)
        elseif !_samedim(out[k], d)
            error("$(_where(src)): dimension `$(_dname(d))` with different elements in one expression " *
                  "(two different subsets? use a loop over the pairs)")
        end
    end
    return Tuple(out)
end

mutable struct Lowering
    byname::Dict{Symbol,Var}
    env::NamedTuple
    buffers::Vector{Pair{Symbol,Any}}   # name => dims, allocated once per run
    pre::Vector{Any}                    # statements that fill buffers before the current one
    src::LineNumberNode
    opdims::Vector{Any}                 # the dimensions of each operator's value
    numerics::Symbol                    # :julia, or :python for Python PySD's digits (numerics.jl)
    lowered::Dict{Any,Any}              # each equation's code, the same at t₀, at every step and when saving
end
Lowering(byname, env; numerics = :julia) =
    Lowering(byname, env, Pair{Symbol,Any}[], Any[], LineNumberNode(0), Any[], numerics, Dict{Any,Any}())

function _buffer!(L::Lowering, @nospecialize(dims))
    name = Symbol("w", length(L.buffers) + 1)
    push!(L.buffers, name => dims)
    return name
end

_isfn(x, f) = x isa QuoteNode && x.value === f
_isI(x) = x === :I || _isfn(x, LinearAlgebra.I)

# a resolved expression that is known when the model is built
_is_static(x::Union{VarRef,OpRef}) = false
_is_static(x::Symbol) = x !== :t
_is_static(x::Expr) = all(_is_static, x.args)
_is_static(x) = true
function _static_eval(x, L::Lowering)
    sub(y) = y isa EnvRef ? QuoteNode(getfield(L.env, y.key)) :
             y isa Expr ? Expr(y.head, map(sub, y.args)...) : y
    return _in_once(sub(x))
end

const _ELEMENTWISE = (:+, :-, :*, :/, :^)
const _REDUCTIONS = Dict{Any,Any}(sum_over => sum!, maximum_over => maximum!,
                                  minimum_over => minimum!, prod_over => prod!)
const _REDUCE_ALL = Dict{Any,Any}(sum_over => sum, maximum_over => maximum,
                                  minimum_over => minimum, prod_over => prod)

_fn(x) = x isa QuoteNode ? x.value : x

# --- dimensions of an expression ----------------------------------------------

function _shape(x, L::Lowering)
    x isa VarRef && return L.byname[x.name].dims
    x isa OpRef && return L.opdims[x.k]
    x isa Expr || return ()
    if x.head === :ref
        return _selection(x, L)[2]
    elseif x.head === :call
        f = _fn(x.args[1])
        args = x.args[2:end]
        if f === _bc
            return _union(L.src, (_shape(a, L) for a in args[2:end])...)
        elseif haskey(_REDUCTIONS, f)
            d = _static_eval(args[2], L)
            s = _shape(args[1], L)
            for e in (d isa Tuple ? d : (d,))
                s = _without(s, _dname(e))
            end
            return s
        elseif f === DimensionalData.set
            return _renamed(_shape(args[1], L), _static_eval.(args[2:end], Ref(L)))
        elseif f === previous
            return _shape(args[1], L)
        elseif f === LinearAlgebra.inv
            s = _shape(args[1], L)
            length(s) == 2 || error("$(_where(L.src)): inv of an array of $(length(s)) dimensions")
            return Tuple(reverse(_dimvec(s)))
        elseif f in (:+, :-) && length(args) == 2 && (_isI(args[1]) || _isI(args[2]))
            return _shape(_isI(args[1]) ? args[2] : args[1], L)
        elseif f === :* && length(args) == 2
            a, b = _shape(args[1], L), _shape(args[2], L)
            (isempty(a) || isempty(b)) && return _union(L.src, a, b)
            _dname(last(_dimvec(a))) === _dname(first(_dimvec(b))) ||
                error("$(_where(L.src)): a matrix product needs the last dimension of one to be the first of the other " *
                      "($(_dimstr(a)) * $(_dimstr(b))); use .* element by element")
            av, bv = _dimvec(a), _dimvec(b)
            return Tuple([av[1:end-1]; bv[2:end]])
        elseif f in _ELEMENTWISE || f === :ifelse || f === ifelse
            shapes = [_shape(a, L) for a in args]
            f in (:/, :^) && length(args) == 2 && !isempty(shapes[2]) &&
                error("$(_where(L.src)): `$f` with an array on the right; use ./ or .^ element by element")
            (f === :ifelse || f === ifelse) && !isempty(shapes[1]) &&
                error("$(_where(L.src)): ifelse with an array condition; use ifelse.(…)")
            return _union(L.src, shapes...)
        elseif x.args[1] isa VarRef && !isempty(L.byname[x.args[1].name].dims)
            # a lookup with dimensions: its series, at the argument's elements
            return _union(L.src, L.byname[x.args[1].name].dims, (_shape(a, L) for a in args)...)
        elseif args isa Vector && any(a -> !isempty(_shape(a, L)), args)
            if x.args[1] isa VarRef      # a lookup called with an array: element by element
                return _union(L.src, (_shape(a, L) for a in args)...)
            end
            error("$(_where(L.src)): can't tell the dimensions of `$x`; " *
                  "call functions element by element with f.(…)")
        end
    end
    return ()
end

# set(x, :a => :b) renames a dimension; set(x, :a => Dim{:b}(labels)) also gives
# it new labels, position by position (Vensim's subscript mappings)
function _renamed(@nospecialize(s), pairs)
    new = Dict{Symbol,Any}(Symbol(first(p)) => last(p) for p in pairs)
    out = Any[]
    for d in _dimvec(s)
        if !haskey(new, _dname(d))
            push!(out, d)
            continue
        end
        n = new[_dname(d)]
        n isa Symbol && (push!(out, Dim{n}(_labels(d))); continue)
        length(_labels(n)) == length(_labels(d)) ||
            error("set: $(length(_labels(n))) labels for a dimension of $(length(_labels(d)))")
        push!(out, n)
    end
    return Tuple(out)
end

# x[d = sel, …]: the indices into x, its dimensions after the selection, and
# whether the indices are known when the model is built
function _selection(x::Expr, L::Lowering)
    base = x.args[1]
    s = _dimvec(_shape(base, L))
    isempty(s) && error("$(_where(L.src)): selecting from `$base`, which has no dimensions")
    _, kw = _split_kwargs(x.args[2:end])
    idx = Any[Colon() for _ in s]
    dims = copy(s)
    for (name, sel) in kw
        k = _findname(name, s)
        k === nothing && error("$(_where(L.src)): `$base` has no dimension `$name`")
        labels = _labels(s[k])
        if _is_static(sel)
            v = _static_eval(sel, L)
            i = _select_indices(labels, v, L)
            idx[k] = i
            dims[k] = i isa Integer ? nothing : Dim{name}(labels[i])
        else
            # At(value) with a value known only when the model runs: its position then
            (sel isa Expr && sel.head === :call && _isfn(sel.args[1], DimensionalData.At) && length(sel.args) == 2) ||
                error("$(_where(L.src)): a selection that changes with time must be At(value)")
            idx[k] = (:dynamic, labels, sel.args[2])
            dims[k] = nothing
        end
    end
    return idx, Tuple(d for d in dims if d !== nothing)
end

function _select_indices(labels, v, L)
    if v isa DimensionalData.At
        val = DimensionalData.val(v)
        if val isa AbstractVector
            return [_position(labels, e, L) for e in val]
        end
        return _position(labels, val, L)
    elseif v isa DimensionalData.InvertedIndices.InvertedIndex
        out = _select_indices(labels, v.skip, L)
        return setdiff(eachindex(labels), out)
    end
    error("$(_where(L.src)): selectors are At(…) and Not(At(…)), not `$v`")
end

function _position(labels, v, L)
    i = findfirst(isequal(v), labels)
    i === nothing && error("$(_where(L.src)): no element `$v` (elements: $(join(labels, ", ")))")
    return i
end

_pos(labels, v) = (i = findfirst(isequal(v), labels); i === nothing ? error("no element $v") : i)

# --- code -----------------------------------------------------------------------

# an array with dimensions `S`, laid out to broadcast in the dimensions `T`
function _layout(code, @nospecialize(S), @nospecialize(T), L::Lowering)
    isempty(S) && return code
    Sv, Tv = _dimvec(S), _dimvec(T)
    pos = Int[]
    for d in Sv
        k = _findname(_dname(d), Tv)
        k === nothing && error("$(_where(L.src)): dimension `$(_dname(d))` is not in $(_dimstr(T))")
        _samedim(d, Tv[k]) || error("$(_where(L.src)): dimension `$(_dname(d))` with different elements " *
                                    "(two different subsets? use a loop over the pairs)")
        push!(pos, k)
    end
    perm = Tuple(sortperm(pos))
    shp = Tuple(Int[(k = _findname(_dname(d), Sv); k === nothing ? 1 : length(_labels(Sv[k]))) for d in Tv])
    (perm == Tuple(1:length(Sv)) && length(Sv) == length(Tv)) && return code
    return :($_lay($code, $(Val(perm)), $(Val(shp))))
end

@inline function _lay(a, ::Val{perm}, ::Val{shp}) where {perm,shp}
    b = perm == ntuple(identity, length(perm)) ? a : PermutedDimsArray(a, perm)
    return size(b) == shp ? b : _reshape(b, shp)
end

# reshape without allocating: reshape of an Array makes a new Array (a small
# allocation); of a view, a lazy wrapper
_reshape(a::Array, shp) = reshape(view(a, :), shp)
_reshape(a, shp) = reshape(a, shp)

_dotcall(f, args) = Expr(:., f, Expr(:tuple, args...))

function _emit_all(args, @nospecialize(T), L)
    out = Any[]
    for a in args
        push!(out, _emit(a, T, L))
    end
    return out
end

# code for `x`, laid out to broadcast in dimensions `T` (`T = ()`: a number)
function _emit(x, @nospecialize(T), L::Lowering)
    if x isa VarRef
        v = L.byname[x.name]
        return _layout(v.id, v.dims, T, L)
    end
    x isa OpRef && return _layout(Symbol("o", x.k), L.opdims[x.k], T, L)
    x isa EnvRef && return :(p.env.$(x.key))
    x isa InputRef && return :(p.inputs.$(x.name))
    x isa Expr || return x
    x.head === :ref && return _emit_selection(x, T, L)
    x.head === :call || return Expr(x.head, _emit_all(x.args, T, L)...)
    f = _fn(x.args[1])
    args = x.args[2:end]
    shape = _shape(x, L)
    y = _nested_reduction(x, shape, L)
    y === x || return _emit(y, T, L)
    if f === _bc
        return _dotcall(_python(_emit(args[1], (), L), L.numerics), _emit_all(args[2:end], T, L))
    elseif f === DimensionalData.set
        return _emit_renamed(x, T, L)
    elseif haskey(_REDUCTIONS, f) || f === previous || f === LinearAlgebra.inv ||
           (f in (:+, :-) && length(args) == 2 && (_isI(args[1]) || _isI(args[2]))) ||
           (f === :* && length(args) == 2 && !isempty(_shape(args[1], L)) && !isempty(_shape(args[2], L)))
        return _emit_materialized(x, shape, T, L)
    elseif f isa VarRef && !isempty(L.byname[f.name].dims)
        v = L.byname[f.name]                     # its series, broadcast as any array
        return _dotcall(_callf, [_layout(:($(v.id).series), v.dims, T, L); _emit_all(args, T, L)])
    elseif !isempty(shape) && (f in _ELEMENTWISE || f === :ifelse || f === ifelse || x.args[1] isa VarRef)
        fcode = f in _ELEMENTWISE ? f : f === ifelse ? :ifelse : _emit(x.args[1], (), L)
        return _dotcall(_python(fcode, L.numerics), _emit_all(args, T, L))
    end
    return Expr(:call, _python(_emit(x.args[1], (), L), L.numerics), (_emit(a, (), L) for a in args)...)
end

function _emit_selection(x, @nospecialize(T), L)
    idx, dims = _selection(x, L)
    base = x.args[1]
    bcode = base isa VarRef ? L.byname[base.name].id : _materialize(base, _shape(base, L), L)
    icode = map(idx) do i
        i isa Tuple && i[1] === :dynamic ? :($_pos($(QuoteNode(i[2])), $(_emit(i[3], (), L)))) : QuoteNode(i)
    end
    isempty(dims) && return :($bcode[$(icode...)])          # one element: a number
    return _layout(:(view($bcode, $(icode...))), dims, T, L)
end

function _emit_renamed(x, @nospecialize(T), L)
    # only the names of the dimensions change: lay out the original under its new names
    inner = x.args[2]
    S0 = _shape(inner, L)
    S1 = _shape(x, L)
    code = inner isa VarRef ? L.byname[inner.name].id : _materialize(inner, S0, L)
    return _layout(code, S1, T, L)
end

# compute `x` (dimensions `S`) into a buffer of its own, before the statement
function _materialize(x, @nospecialize(S), L)
    isempty(S) && return _emit(x, (), L)
    y = _nested_reduction(x, S, L)
    y === x || return _materialize(y, S, L)
    w = _buffer!(L, S)
    push!(L.pre, :($w = p.work.$w))
    f = x isa Expr && x.head === :call ? _fn(x.args[1]) : nothing
    args = x isa Expr && x.head === :call ? x.args[2:end] : Any[]
    if haskey(_REDUCTIONS, f)
        Sx = _shape(args[1], L)
        d = _static_eval(args[2], L)
        k = _findname(_dname(d), _dimvec(Sx))
        k === nothing && error("$(_where(L.src)): no dimension `$(_dname(d))` to reduce over in $(_dimstr(Sx))")
        src = _source(args[1], Sx, L)
        if f === sum_over && L.numerics === :python
            push!(L.pre, :($_sum_python!($w, $src, $(Val(k)))))
        else
            keep = Tuple(Int[i == k ? 1 : length(_labels(e)) for (i, e) in enumerate(_dimvec(Sx))])
            push!(L.pre, :($(_REDUCTIONS[f])($_reshape($w, $keep), $src)))
        end
    elseif f === previous
        Sx = _shape(args[1], L)
        d = _static_eval(args[2], L)
        k = _findname(_dname(d), _dimvec(Sx))
        push!(L.pre, :($_previous!($w, $(_source(args[1], Sx, L)), $(Val(k)))))
    elseif f === LinearAlgebra.inv
        Sx = _shape(args[1], L)
        inv_ = L.numerics === :python ? _numpy_inv : LinearAlgebra.inv
        push!(L.pre, :(copyto!($w, $inv_(Matrix($(_source(args[1], Sx, L)))))))
    elseif f in (:+, :-) && length(args) == 2 && (_isI(args[1]) || _isI(args[2]))
        a = _isI(args[1]) ? args[2] : args[1]
        sign = f === :+ ? 1 : (_isI(args[1]) ? -1 : 1)        # I - A: -A + I;  A - I: A - I
        idiag = f === :+ ? 1 : (_isI(args[1]) ? 1 : -1)
        push!(L.pre, :($w .= $sign .* $(_emit(a, S, L))))
        push!(L.pre, :($_add_diagonal!($w, $idiag)))
    elseif f === :*
        Sa, Sb = _shape(args[1], L), _shape(args[2], L)
        push!(L.pre, :(LinearAlgebra.mul!($w, $(_source(args[1], Sa, L)), $(_source(args[2], Sb, L)))))
    else
        push!(L.pre, :($w .= $(_emit(x, S, L))))
    end
    return w
end

# `x` laid out in exactly the dimensions `S`, in a buffer if it isn't already
function _materialize_as(x, @nospecialize(S), L)
    x isa VarRef && L.byname[x.name].dims == S && return L.byname[x.name].id
    w = _buffer!(L, S)
    push!(L.pre, :($w = p.work.$w))
    push!(L.pre, :($w .= $(_emit(x, S, L))))
    return w
end

# an array to read from: a name or a selection as it is, anything else computed first
_source(x::VarRef, @nospecialize(S), L) = L.byname[x.name].id
_source(x, @nospecialize(S), L) = x isa Expr && x.head === :ref ? _emit_selection(x, S, L) : _materialize(x, S, L)

_emit_materialized(x, @nospecialize(S), @nospecialize(T), L) = isempty(S) ? _reduce_scalar(x, L) : _layout(_materialize(x, S, L), S, T, L)

# a reduction over all the dimensions of an array: a number (a sum with
# Python's digits adds as numpy, in memory order, the last dimension fastest)
function _reduce_scalar(x, L)
    f = _fn(x.args[1])
    haskey(_REDUCE_ALL, f) || error("$(_where(L.src)): can't compute `$x` as a number")
    Sx = _shape(x.args[2], L)
    src = _source(x.args[2], Sx, L)
    f === sum_over && L.numerics === :python && return :($pysd_sum($_rowmajor($src)))
    return :($(_REDUCE_ALL[f])($src))
end

# sum_over(x, (a, b)) over some of the dimensions: one after the other (over
# all of them, it's a number: _reduce_scalar)
function _nested_reduction(x, shape, L)
    (x isa Expr && x.head === :call) || return x
    f = _fn(x.args[1])
    haskey(_REDUCTIONS, f) || return x
    ds = x.args[3]
    (ds isa Expr && ds.head === :tuple) || return x
    isempty(shape) && return x
    y = x.args[2]
    for e in ds.args
        y = Expr(:call, x.args[1], y, e)
    end
    return y
end

function _previous!(w, x, ::Val{k}) where {k}
    for i in CartesianIndices(w)
        w[i] = i[k] == 1 ? zero(eltype(w)) : x[Base.setindex(Tuple(i), i[k] - 1, k)...]
    end
    return w
end

function _add_diagonal!(w, c)
    for i in 1:min(size(w)...)
        w[i, i] += c
    end
    return w
end

# `target .= rhs` for a variable (or a part of it) with dimensions `T`
function _store(target, rhs, @nospecialize(T), L::Lowering)
    S = _shape(rhs, L)
    for d in _dimvec(S)
        _hasname(_dname(d), T) ||
            error("$(_where(L.src)): the equation has dimension `$(_dname(d))`, which its variable $(_dimstr(T)) hasn't")
    end
    code = _emit(rhs, T, L)
    return isempty(T) ? :($target = $code) : :($target .= $code)
end
