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
