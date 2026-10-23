# Changing a model's inputs between runs.  A generated ODE model's
# `params(; name = value, ...)` builds its constants, lookups and data, with
# the given values in place of the model's own; everything computed from them
# follows.  These helpers check and convert the given values.

"""
    PySDFunction{N}(f)

A lookup or data series of a model's parameters, called with `N` arguments
(`f(x)`, `f(i, x)`, ...).  Every lookup with `N` arguments has this type,
whatever function it holds, so replacing one (with `params`) does not change
the type of the parameters and the model is not compiled again.

Calls with integer indices and a `Float64` go through a FunctionWrapper
(FunctionWrappers.jl, as SciML does to avoid recompiling); other argument
types (e.g. the numbers of an automatic-differentiation solver) call `f`
directly.  The result is a number of the type of the last argument.
"""
struct PySDFunction{N,W} <: Function
    f::Any
    w::W
end
_pysd_wrapper_type(N) = FunctionWrapper{Float64,Tuple{ntuple(_ -> Int, N - 1)...,Float64}}
function PySDFunction{N}(f) where N
    g = (args...) -> Float64(f(args...))
    W = _pysd_wrapper_type(N)
    return PySDFunction{N,W}(f, W(g))
end
PySDFunction(f) = PySDFunction{_pysd_nargs(f)}(f)
# the number of arguments of a model's own lookup function (its only method)
_pysd_nargs(f) = (ms = methods(f); length(ms) == 1 ? first(ms).nargs - 1 : 1)

@inline (l::PySDFunction{1})(x::Float64) = l.w(x)
@inline (l::PySDFunction{2})(i::Int, x::Float64) = l.w(i, x)
@inline (l::PySDFunction{3})(i::Int, j::Int, x::Float64) = l.w(i, j, x)
@inline (l::PySDFunction{4})(i::Int, j::Int, k::Int, x::Float64) = l.w(i, j, k, x)
@inline function (l::PySDFunction)(args::Vararg{Any,N}) where N
    T = promote_type(Float64, typeof(args[N]))
    return convert(T, l.f(args...))::T
end

"""
    pysd_input(given, name, default)

The value of the model input `name`: `given[name]` when it is there, converted
to the kind of value the model has (see below), otherwise `default`.

- A constant takes a number, or an array of the constant's own size (a number
  fills the whole array).
- A lookup or data series takes anything [`pysd_lookup`](@ref) accepts.
"""
pysd_input(given::AbstractDict, name::Symbol, default) =
    haskey(given, name) ? _pysd_as(given[name], default, name) : _pysd_default(default)

# lookups and data are PySDFunction, whatever they hold
_pysd_default(default) = default
_pysd_default(f::Function) = PySDFunction(f)

_pysd_as(v::Real, ::Real, name) = Float64(v)
_pysd_as(v::Real, d::AbstractArray, name) = pysd_safe(fill(Float64(v), size(d)))
function _pysd_as(v::AbstractArray, d::AbstractArray, name)
    size(v) == size(d) ||
        throw(DimensionMismatch("$name has size $(size(d)), the value given has size $(size(v))"))
    return pysd_safe(Array{Float64}(v))
end
_pysd_as(v, d::Function, name) = PySDFunction{_pysd_nargs(d)}(pysd_lookup(v))
_pysd_as(v, d, name) =
    throw(ArgumentError("$name takes a $(d isa AbstractArray ? "number or an array" : "number"), " *
                        "not a $(typeof(v))"))

const _PYSD_FLAT = (extrapolation_left = ExtrapolationType.Constant,
                    extrapolation_right = ExtrapolationType.Constant)

"""
    pysd_lookup(value)

A lookup or data series from `value`, called as the model calls it
(`f(x)`, or `f(i, x)`, `f(i, j, x)` when it is subscripted):

- a function, used as it is;
- an interpolation from DataInterpolations.jl (any kind), the same for every
  element;
- `(x, y)`: two vectors, interpolated linearly and held constant outside `x`,
  as Vensim lookups; the same for every element;
- `(x, Y)`: a vector and a matrix with one column per element of a
  one-dimensional subscripted lookup;
- a number: the same value everywhere.
"""
pysd_lookup(f::PySDFunction) = f.f
pysd_lookup(f::Function) = f
pysd_lookup(itp::DataInterpolations.AbstractInterpolation) = (args...) -> itp(last(args))
pysd_lookup(v::Real) = (args...) -> Float64(v)
function pysd_lookup((x, y)::Tuple{AbstractVector,AbstractVector})
    itp = LinearInterpolation(Float64.(y), Float64.(x); _PYSD_FLAT...)
    return (args...) -> itp(last(args))
end
function pysd_lookup((x, y)::Tuple{AbstractVector,AbstractMatrix})
    itps = [LinearInterpolation(Float64.(c), Float64.(x); _PYSD_FLAT...) for c in eachcol(y)]
    return (i, xv) -> itps[i](xv)
end
pysd_lookup(v) = throw(ArgumentError(
    "a lookup or data series takes a function, an interpolation, (x, y) or a number, not a $(typeof(v))"))

"""
    pysd_check_inputs(given, values::NamedTuple)

Throw an error naming the entries of `given` that are not among the model's
constants, lookups and data (`values`), e.g. a misspelt name.
"""
function pysd_check_inputs(given::AbstractDict, values::NamedTuple)
    unknown = sort!([String(k) for k in keys(given) if !haskey(values, k)])
    isempty(unknown) || throw(ArgumentError(
        "not a constant, lookup or data series of this model: $(join(unknown, ", ")) " *
        "(only those can be given to params; variables that change during the run cannot)"))
    return nothing
end

"""
    pysd_file(dir, file, files)

The path of the input `file` (as written in the model, relative to the model
file's folder `dir`), or of its replacement in `files` (a Dict from the name
in the model, or its base name, to another path; relative paths are taken
from `dir`).
"""
pysd_file(dir::AbstractString, file::AbstractString, files::AbstractDict) =
    joinpath(dir, get(files, file, get(files, basename(file), file)))

"""
    pysd_check_fixed(given, fixed::NamedTuple)

Throw an error if `given` has a new value for a constant whose value was used
when the model was translated (`fixed`: name => what it fixed, e.g. the
number of stages of a DELAY FIXED): that needs the model translated again.
"""
function pysd_check_fixed(given::AbstractDict, fixed::NamedTuple)
    bad = sort!([k for k in keys(fixed) if haskey(given, k)])
    isempty(bad) || throw(ArgumentError(
        join(("$k sets $(fixed[k])" for k in bad), "; ") *
        ", which is fixed when the model is translated: translate the model again " *
        "with the new value instead of giving it to params"))
    return nothing
end
