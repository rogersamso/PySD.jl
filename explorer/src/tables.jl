# Tables: lookups and data series (a value for each x, or for each time), which
# a run can change: new values over the same x.  An array of them, a table per
# element.

const DI = PySD.DataInterpolations

# the kinds of series PySD.jl makes, which can be made again with other values
const _Series = Union{DI.LinearInterpolation, DI.ConstantInterpolation, PySD._RawSeries}

_points(f::DI.AbstractInterpolation) = (f.t, f.u)
_points(f::PySD._RawSeries) = (f.times, f.vals)

_with_values(f::DI.LinearInterpolation, y) =
    DI.LinearInterpolation(y, f.t; extrapolation_left = f.extrapolation_left, extrapolation_right = f.extrapolation_right)
_with_values(f::DI.ConstantInterpolation, y) =
    DI.ConstantInterpolation(y, f.t; dir = f.dir, extrapolation_left = f.extrapolation_left,
                             extrapolation_right = f.extrapolation_right)
_with_values(f::PySD._RawSeries, y) = PySD._RawSeries(f.times, y)

# a parameter's value as tables: its series (in Tables order) and its size, or nothing
_as_table(x::_Series) = (Any[x], ())
function _as_table(x::PySD.LookupArray)
    s = x.series
    all(f -> f isa _Series, s) || return nothing
    return (Any[s[reverse(Tuple(J))...] for J in CartesianIndices(reverse(size(s)))], size(s))
end
_as_table(_) = nothing

"""
    table_info(ex, name) -> Dict

A table's x and values in the model, a list per element (one for a table
without dimensions), with the elements' labels.
"""
function table_info(ex::Explorer, name::Symbol)
    series, sz = get(ex.tables, name) do
        throw(KeyError(name))
    end
    pts = [_points(f) for f in series]
    return Dict("name" => String(name), "elements" => isempty(sz) ? [""] : _element_labels(ex, name),
                "x" => [_finite(collect(first(p))) for p in pts], "y" => [_finite(collect(last(p))) for p in pts])
end

# the value a run gives a table: its new values `ys` (a list per element), checked
function _table_value(ex::Explorer, name::Symbol, ys)
    series, sz = ex.tables[name]
    (ys isa AbstractVector && length(ys) == length(series) && all(y -> y isa AbstractVector, ys)) ||
        throw(ArgumentError("`$name`: a list of values for each of its $(length(series)) tables"))
    new = map(series, ys) do f, y
        t = first(_points(f))
        (length(y) == length(t) && all(v -> v isa Real && isfinite(v), y)) ||
            throw(ArgumentError("`$name`: $(length(t)) numbers in each table, one per x"))
        _with_values(f, Float64.(y))
    end
    return isempty(sz) ? only(new) : PySD.LookupArray(_unflat(new, sz))
end
