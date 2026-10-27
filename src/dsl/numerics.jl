# Python's digits for translated models: `Model(…; numerics = :python)` builds
# a model with PySD.jl's own functions in place of Julia's, so it keeps the
# last digits of Python PySD (and values equal up to rounding take the same
# branch of an `ifelse`): the C maths library for exp, log, sin, …, numpy's
# order of additions in sums, LAPACK's gesv for inverses.  The model text keeps
# the ordinary names; only the generated code calls PySD.jl's functions.

const _PYTHON_FUNCTIONS = Dict{Any,Any}(
    :exp => pysd_exp, :log => pysd_ln, :sin => pysd_sin, :cos => pysd_cos, :tan => pysd_tan,
    :atan => pysd_atan, :asin => pysd_asin, :acos => pysd_acos, :sinh => pysd_sinh,
    :cosh => pysd_cosh, :sqrt => pysd_sqrt, :^ => pysd_power)

_python(f, numerics) = numerics === :python ? get(_PYTHON_FUNCTIONS, f, f) : f

# SUM as numpy adds: pairwise along the last dimension, one after the other
# along any other (`w` has the dimensions of `x` without the k-th)
function _sum_python!(w, x, ::Val{k}) where {k}
    n = ndims(x)
    for J in CartesianIndices(w)
        j = Tuple(J)
        slice = view(x, j[1:(k - 1)]..., :, j[k:end]...)
        @inbounds w[J] = k == n ? pysd_sum(slice) : pysd_sum_seq(slice)
    end
    return w
end

# the same on DimArrays, for constants computed once
function _sum_over_python(x::AbstractDimArray, d)
    k = DimensionalData.dimnum(x, DimensionalData.name(d))
    rest = Tuple(e for (i, e) in enumerate(DimensionalData.dims(x)) if i != k)
    isempty(rest) && return pysd_sum(parent(x))
    w = zeros(length.(rest))
    _sum_python!(w, parent(x), Val(k))
    return DimArray(w, rest)
end

_inv_python(x::AbstractDimArray) = DimArray(_numpy_inv(parent(x)), reverse(DimensionalData.dims(x)))
_inv_python(x::AbstractMatrix) = _numpy_inv(x)

# the functions to call in constants (computed once, on DimArrays)
function _python_once(x)
    x isa Symbol && return get(_PYTHON_FUNCTIONS, x, x)
    _isfn(x, sum_over) && return QuoteNode(_sum_over_python)
    _isfn(x, LinearAlgebra.inv) && return QuoteNode(_inv_python)
    x isa Expr && return Expr(x.head, map(_python_once, x.args)...)
    return x
end
