# PySD's helpers in symbolic equations: what models translated by PySD's
# ModelingToolkit backend need from Symbolics.  ModelingToolkit loads
# Symbolics, which loads this extension; the DSL backend never does.
module PySDSymbolicsExt

using PySD
using PySD: PySDRecord, PySDTicks
import PySD: _trunc, _symbolic,
             pysd_inv_mat2d_elem, pysd_inv_mat3d_elem, pysd_power, pysd_quantum,
             pysd_random_0_1, pysd_random_uniform, pysd_random_normal, pysd_random_exponential,
             pysd_vector_rank, pysd_vector_sort_order, pysd_vector_reorder,
             pysd_fixed_delay, pysd_sampled, pysd_tick_time,
             pysd_tick_uniform, pysd_tick_normal, pysd_tick_exponential
using Symbolics: Symbolics, Num, @register_symbolic

# INTEGER: Julia's trunc, toward zero, of floor and ceil (which Symbolics has),
# so that models translated with pysd_trunc (deprecated) still build
_trunc(x::Num) = ifelse(x < 0, ceil(x), floor(x))

# Whether VECTOR SELECT, SORT ORDER, REORDER and RANK get symbolic values
_symbolic(::Num) = true
_symbolic(::AbstractArray{Num}) = true

# Black boxes in the equations, called with numbers when the model runs:
# the matrix inverse (Symbolics would invert the matrix symbolically, which
# hangs for large ones), the C library's power, the random draws (a new one
# at every call).
@register_symbolic pysd_inv_mat2d_elem(mat::AbstractMatrix, i::Int, j::Int)
@register_symbolic pysd_inv_mat3d_elem(mat::AbstractArray, b::Int, i::Int, j::Int)
@register_symbolic pysd_power(x::Real, y::Real)
@register_symbolic pysd_quantum(a::Real, b::Real)
@register_symbolic pysd_random_0_1()
@register_symbolic pysd_random_uniform(lo::Real, hi::Real, _seed::Real)
@register_symbolic pysd_random_normal(lo::Real, hi::Real, mean::Real, std::Real, _seed::Real)
@register_symbolic pysd_random_exponential(lo::Real, hi::Real, mean::Real, _seed::Real)

# The ticks (src/ticks.jl), black boxes of the time.  The record they read is
# one plain argument (PySDRecord), as Symbolics adds a method for every
# combination of plain and symbolic arguments.
@register_symbolic pysd_fixed_delay(R::PySDRecord, init::Real, t::Real)
@register_symbolic pysd_sampled(R::PySDRecord, condition::Real, x::Real, init::Real, t::Real)
@register_symbolic pysd_tick_time(T::PySDTicks, t::Real)
@register_symbolic pysd_tick_uniform(R::PySDRecord, t::Real)
@register_symbolic pysd_tick_normal(R::PySDRecord, t::Real)
@register_symbolic pysd_tick_exponential(R::PySDRecord, t::Real)
@register_symbolic pysd_tick_normal(R::PySDRecord, a::Real, b::Real, t::Real) false
@register_symbolic pysd_tick_exponential(R::PySDRecord, b::Real, t::Real) false

# VECTOR RANK, SORT ORDER and REORDER with symbolic values (ModelingToolkit
# builds its equations by calling them with them): no sorting, which needs the
# values, but comparisons, as ifelse.  The rank of element i counts the
# elements before it in the order (smaller, or larger, and the equal ones
# before i: a stable sort, as sortperm); n² comparisons, for the vectors of a
# model.
function pysd_vector_rank(vec::AbstractVector{Num}, dir)
    v = collect(vec)
    n = length(v)
    before(i, j) = ifelse(dir > 0, v[j] < v[i], v[j] > v[i])
    return [1 + sum((ifelse(before(i, j), 1, 0) + (j < i ? ifelse(v[j] == v[i], 1, 0) : 0)
                     for j in 1:n if j != i); init = 0) for i in 1:n]
end

function pysd_vector_sort_order(vec::AbstractVector{Num}, dir)
    r = pysd_vector_rank(vec, dir)
    n = length(r)
    return [sum(ifelse(r[i] == p, i - 1, 0) for i in 1:n) for p in 1:n]
end

function pysd_vector_reorder(vec::AbstractVector, order::AbstractVector{Num})
    n = length(order)
    return [sum(ifelse(order[p] == j - 1, vec[j], 0) for j in 1:n) for p in 1:n]
end

end # module
