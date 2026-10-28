# Inputs: Excel sheets as values, and the functions that read them in
# @parameters, with PySD.jl's readers (the same values as Python PySD).

"""
    excel(path, sheet)

An Excel sheet, given to `Model` by name in `inputs` and read in
`@parameters` with `constant`, `lookup` and `data`.  A different scenario is a
different sheet given to the run: `run_model(m; inputs = (; scen = excel(…)))`.
"""
struct ExcelSheet
    path::String
    sheet::String
end
function excel(path::AbstractString, sheet::AbstractString)
    # a model precompiled in a package is built again when one of its sheets changes
    ccall(:jl_generating_output, Cint, ()) == 1 && isfile(path) && Base.include_dependency(abspath(path))
    return ExcelSheet(abspath(path), String(sheet))
end
Base.show(io::IO, s::ExcelSheet) = print(io, "excel(", repr(basename(s.path)), ", ", repr(s.sheet), ")")

"""
    constant(sheet, cells; transpose = false)

A number or an array from a cell, a range or a named range (Vensim's GET
DIRECT CONSTANTS; `transpose = true` for its `*`).  The declaration gives it
its dimensions: rows are the first, columns the second.
"""
constant(s::ExcelSheet, cells::AbstractString; transpose::Bool = false) =
    pysd_xlsx_read_constant(s.path, s.sheet, String(cells); transpose)

"""
    lookup(sheet, x, cells)

A lookup read from Excel (Vensim's GET DIRECT LOOKUPS): `x` are the cells of
the x values (a named range, or a row number or column letter), `cells` those
of the y values; called as `f(x)`.  With dimensions, one series per element:
`f(x)` is an array, and with an array `x` the dimensions line up by name.
It is read when its declaration gives it its dimensions.
"""
lookup(s::ExcelSheet, x::AbstractString, cells::AbstractString) =
    SeriesCells(s, String(x), String(cells), :interpolate)

"""
    data(sheet, time, cells; method = :interpolate)

A data series read from Excel (Vensim's GET DIRECT DATA), called with time,
`d(t)`.  `method` is Vensim's keyword: `:interpolate`, `:hold_backward`,
`:look_forward` or `:raw`.
"""
data(s::ExcelSheet, time::AbstractString, cells::AbstractString; method::Symbol = :interpolate) =
    SeriesCells(s, String(time), String(cells), method)

"""
    data(parents, name)

A data series from outside the model (Vensim's data variables without an
equation): `parents` is an input given to `Model` and to the run, a tuple of
sources, and `name` the series' name; the first source that has it gives it.
A source is a run of another model (`run_model(world)`) or a file of series
([`series_file`](@ref)).  Called with time, `d(t)`, it interpolates linearly
between the source's times; with dimensions, they line up by name.
"""
data(parents, name::Symbol) = ParentSeries(parents, name)

struct ParentSeries
    parents::Any
    name::Symbol
end

_sources(c::ParentSeries) = c.parents isa Union{Results,SeriesFile} ? (c.parents,) : Tuple(c.parents)

function _parent(c::ParentSeries)
    for r in _sources(c)
        _has_series(r, c.name) && return r
    end
    return nothing
end

"Without its source: the error, when the model runs."
struct NoParent
    name::Symbol
end
(f::NoParent)(x) = error("`$(f.name)` comes from outside the model: give a run or a file that has it, " *
                         "run_model(m; inputs = (; parents = (run_model(parent),)))")

_with_dims(c::ParentSeries, ::Tuple{}) = _from_sources(c, ())
_with_dims(c::ParentSeries, dims::Tuple) = _from_sources(c, dims)
function _from_sources(c::ParentSeries, dims::Tuple)
    r = _parent(c)
    r === nothing && return isempty(dims) ? NoParent(c.name) :
                            LookupArray(DimArray(fill(NoParent(c.name), map(length, dims)), dims))
    return _series_of(r, c.name, dims)
end

# --- from a run: its saved times ---------------------------------------------------

_has_series(r, name) = haskey(r, name)

function _series_of(r, name, dims::Tuple)
    x = r[name]
    v = r.model.byname[name]
    v.kind in (:parameter, :constant) && (x = fill(x, length(r.time)))       # a constant
    isempty(dims) && return PiecewiseLinear(r.time, Float64.(x))
    vals = stack(parent.(x))                                                # the elements, then time
    series = [PiecewiseLinear(r.time, Float64.(vals[I, :])) for I in CartesianIndices(map(length, v.dims))]
    return _with_dims(LookupArray(DimArray(series, v.dims)), dims)         # in this model's order
end

# --- from a file -------------------------------------------------------------------------

"""
    series_file(path)

Data series read from a `.csv` or `.tab` file, as Python PySD's `data_files`:
the times in the first column and a column per series (or the times in the
first row and a row per series), named as in Vensim, `Temperature change` or
`GDP[EU]`, `Real demand[agriculture, EU]` for the elements of an array.  A
source of [`data`](@ref): names and elements match the model's as the
translation writes them (lower case, other characters as `_`).
"""
function series_file(path::AbstractString)
    delim = lowercase(splitext(path)[2]) == ".csv" ? ',' : '\t'
    cells = readdlm(path, delim, String; quotes = false)
    head = strip.(cells[1, 2:end])
    if !isempty(head) && all(h -> tryparse(Float64, h) !== nothing, head)   # a row per series
        cells = permutedims(cells)
    end
    time = [_number(x) for x in cells[2:end, 1]]
    series = Dict{Symbol,Dict{Vector{Symbol},Vector{Float64}}}()
    for j in 2:size(cells, 2)
        m = match(r"^(.*?)(\[(.*)\])?$", strip(cells[1, j], ['"', ' ']))
        name = _julia_name(m.captures[1])
        labels = m.captures[3] === nothing ? Symbol[] : [_julia_label(l) for l in split(m.captures[3], ",")]
        get!(series, name, Dict{Vector{Symbol},Vector{Float64}}())[labels] = [_number(x) for x in cells[2:end, j]]
    end
    return SeriesFile(abspath(path), time, series)
end

struct SeriesFile
    path::String
    time::Vector{Float64}
    series::Dict{Symbol,Dict{Vector{Symbol},Vector{Float64}}}     # name => elements' labels => values
end
Base.show(io::IO, f::SeriesFile) = print(io, "series_file(", repr(basename(f.path)), ")")

_number(x) = (x = strip(x); isempty(x) ? NaN : something(tryparse(Float64, x), NaN))

# as the translation names them: lower case, other characters as _
_clean(s) = strip(replace(lowercase(strip(s, ['"', ' '])), r"[^a-z0-9]+" => "_"), '_')
function _julia_name(s)
    n = _clean(s)
    return Symbol(isempty(n) ? "_var" : isdigit(n[1]) ? "_" * n : n)
end
_julia_label(s) = Symbol(_clean(s))

_has_series(f::SeriesFile, name) = haskey(f.series, name)

function _series_of(f::SeriesFile, name, dims::Tuple)
    cols = f.series[name]
    if isempty(dims)
        haskey(cols, Symbol[]) || error("`$name` in $(basename(f.path)) has elements; the model has none")
        return PiecewiseLinear(f.time, cols[Symbol[]])
    end
    labels = [Symbol.(_labels(d)) for d in dims]
    # the file's elements in the model's order of the dimensions, or in another
    order = findfirst(p -> all(I -> haskey(cols, [labels[p[k]][I[p[k]]] for k in eachindex(p)]),
                               CartesianIndices(map(length, dims))),
                      _permutations(length(dims)))
    order === nothing && error("`$name` in $(basename(f.path)): not every element of " *
                               "$(_dimstr(dims)) has a column")
    p = _permutations(length(dims))[order]
    series = [PiecewiseLinear(f.time, cols[[labels[p[k]][I[p[k]]] for k in eachindex(p)]])
              for I in CartesianIndices(map(length, dims))]
    return LookupArray(DimArray(series, dims))
end

function _permutations(n)
    n == 1 && return [[1]]
    out = Vector{Int}[]
    for p in _permutations(n - 1), k in 0:(n - 1)
        push!(out, [p[1:k]; n; p[(k + 1):end]])
    end
    return sort!(out)                                   # the model's order first
end

"Where a lookup or data series is, read once its dimensions are known."
struct SeriesCells
    sheet::ExcelSheet
    x::String
    cells::String
    method::Symbol
end

_read(c::SeriesCells, n) = pysd_xlsx_build_lookup_dispatch(c.sheet.path, c.sheet.sheet, c.x, c.cells; n, c.method)

"""
A lookup or data series with dimensions: one series per element (a DimArray of
series where values are computed once, a plain array in the code at every step).
"""
struct LookupArray{F,N,A<:AbstractArray{F,N}}
    series::A
end

_with_dims(c::SeriesCells, ::Tuple{}) = only(_read(c, 1))
function _with_dims(c::SeriesCells, dims::Tuple)
    sz = map(length, dims)
    s = _read(c, prod(sz))
    length(s) == prod(sz) || error("$(length(s)) series in $(c.cells) for dimensions of size $sz")
    # series in Vensim's order (the last dimension fastest), into Julia's
    a = permutedims(reshape(s, reverse(sz)), reverse(1:length(sz)))
    return LookupArray(DimArray(a, dims))
end
# one block of cells per element of the first dimension
function _with_dims(cs::AbstractVector{SeriesCells}, dims::Tuple)
    length(cs) == length(first(dims)) || error("$(length(cs)) blocks of cells for $(length(first(dims))) elements")
    rest = Base.tail(dims)
    isempty(rest) && return LookupArray(DimArray([only(_read(c, 1)) for c in cs], dims))  # one series each
    parts = [parent(_with_dims(c, rest).series) for c in cs]
    return LookupArray(DimArray(stack(parts; dims = 1), dims))
end
_with_dims(f::LookupArray, dims::Tuple) =
    f.series isa AbstractDimArray ? LookupArray(_align(f.series, dims)) :
    size(f.series) == map(length, dims) ? f : error("series of size $(size(f.series)) for dimensions of size $(map(length, dims))")
_plain(f::LookupArray, dims::Tuple) = f.series isa AbstractDimArray ? LookupArray(Array(parent(_align(f.series, dims)))) : f
_plain(f::LookupArray, ::Tuple{}) = f

_callf(f, x) = f(x)

# called where values are computed once (constants): an array of the series' values
(f::LookupArray)(x::Number) = map(s -> s(x), f.series)
(f::LookupArray)(x::AbstractDimArray) = _bc(_callf, f.series, x)
_with_dims(cs::AbstractVector{SeriesCells}, ::Tuple{}) = error("several blocks of cells where the declaration has no dimensions")
_with_dims(f::LookupArray, ::Tuple{}) = error("series with dimensions where the declaration has none")
