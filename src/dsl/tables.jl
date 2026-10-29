# Results as tables: a DimensionalData DimStack (a layer per name, over time
# and its dimensions), and Tables.jl's interface, a column per name and
# element, as Vensim's outputs and Python PySD's DataFrame (`x[north,a]`).
# Lookups and data series among the parameters are functions, not values:
# neither has them.

_tabular(x) = x isa Number || x isa AbstractArray{<:Number}

# the names a table has: every name but the lookups and data series (checked on
# the stored value: r[name] can't wrap an array of lookups as a DimArray)
_tabular_names(r::Results) =
    [name for name in keys(r) if (v = r.model.byname[name]; !(v.kind in (:parameter, :constant)) ||
                                  _tabular(getfield(r.par, v.id)))]

"""
    DimStack(results)

The results as a DimensionalData `DimStack`: a layer per name, over the time
(`Ti`) and the name's dimensions; parameters and constants without the time.
Saved to NetCDF, plotted, or as a long table (a row per time and element)
with Tables.jl.
"""
function DimensionalData.DimStack(r::Results)
    ti = Ti(r.time)
    names, layers = Symbol[], AbstractDimArray[]
    for name in _tabular_names(r)
        v, x = r.model.byname[name], r[name]
        if v.kind in (:parameter, :constant)
            push!(layers, isempty(v.dims) ? DimArray(fill(x), ()) : x)
        elseif isempty(v.dims)
            push!(layers, DimArray(x, (ti,)))
        else
            push!(layers, DimArray(stack(parent.(x); dims = 1), (ti, v.dims...)))
        end
        push!(names, name)
    end
    return DimStack(NamedTuple{Tuple(names)}(Tuple(layers)))
end

# The columns of a run's results: Vensim's names for the elements of arrays,
# the first dimension slowest.  (A NamedTuple would make Julia compile a type
# with a field per column: thousands for a large model.)
struct ResultsColumns <: Tables.AbstractColumns
    names::Vector{Symbol}
    columns::Vector{AbstractVector}
    index::Dict{Symbol,Int}
end

Tables.istable(::Type{Results}) = true
Tables.columnaccess(::Type{Results}) = true

function Tables.columns(r::Results)
    names, columns = Symbol[:time], AbstractVector[r.time]
    n = length(r.time)
    for name in _tabular_names(r)
        v, x = r.model.byname[name], r[name]
        constant = v.kind in (:parameter, :constant)
        if isempty(v.dims)
            push!(names, name)
            push!(columns, constant ? fill(x, n) : x)
            continue
        end
        labels = [string.(DimensionalData.lookup(d)) for d in v.dims]
        sz = map(length, v.dims)
        for J in CartesianIndices(reverse(sz))
            I = reverse(Tuple(J))
            push!(names, Symbol(name, "[", join((labels[k][I[k]] for k in eachindex(I)), ","), "]"))
            push!(columns, constant ? fill(parent(x)[I...], n) : [parent(y)[I...] for y in x])
        end
    end
    return ResultsColumns(names, columns, Dict(nm => i for (i, nm) in enumerate(names)))
end

Tables.columnnames(c::ResultsColumns) = getfield(c, :names)
Tables.getcolumn(c::ResultsColumns, i::Int) = getfield(c, :columns)[i]
Tables.getcolumn(c::ResultsColumns, name::Symbol) = getfield(c, :columns)[getfield(c, :index)[name]]
Tables.schema(c::ResultsColumns) = Tables.Schema(getfield(c, :names), eltype.(getfield(c, :columns)))
