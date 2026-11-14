# Spreadsheet and text data readers for Vensim GET XLS/DIRECT CONSTANTS / LOOKUPS / DATA.
#
# File formats, as in Python PySD:
#   - .xlsx / .xlsm   XLSX.jl
#   - .xls            LibXLS.jl
#   - any other file  delimited text (.csv, .tab, ...); the "sheet" argument is the
#                     separator when it is not alphanumeric (e.g. ","), otherwise
#                     "," for .csv and tab for other files
#
# Supports three reference modes matching the Vensim conventions:
#   - Named ranges  (e.g. cell = "my_param", x = "year_range"), .xlsx files only
#   - Cell refs     (e.g. cell = "B2")
#   - Row/column    (e.g. x = "4" for row 4, x = "A" for column A)

# A sheet as a grid of cells: `_cells(s, r1, c1, r2, c2)` returns the cells of a
# rectangle as a Matrix, `_lastcell(s)` the last (row, column) holding data.
abstract type _Sheet end

struct _XLSXSheet <: _Sheet
    ws::XLSX.Worksheet
end

struct _GridSheet <: _Sheet
    grid::Matrix{Any}
end

const _XLSX_CACHE = Dict{String, XLSX.XLSXFile}()
const _SHEET_CACHE = Dict{Tuple{String, String}, _Sheet}()
# (runs on several threads may read input sheets at once: one at a time here;
# reentrant, as a sheet opens its file)
const _CACHE_LOCK = ReentrantLock()

function _xlsx_open(path::String)
    p = abspath(path)
    lock(() -> get!(() -> XLSX.readxlsx(p), _XLSX_CACHE, p), _CACHE_LOCK)
end

_file_ext(path::AbstractString) = lowercase(splitext(path)[2])
_is_xlsx(path::AbstractString) = _file_ext(path) in (".xlsx", ".xlsm")

function _open_sheet(path::String, sheet::String)
    p = abspath(path)
    lock(_CACHE_LOCK) do
        get!(_SHEET_CACHE, (p, sheet)) do
            if _is_xlsx(p)
                _XLSXSheet(_xlsx_open(p)[sheet])
            elseif _file_ext(p) == ".xls"
                _GridSheet(_xls_grid(p, sheet))
            else
                _GridSheet(_text_grid(p, sheet))
            end
        end
    end
end

function _xls_grid(path::String, sheet::String)
    LibXLS.openxls(path) do wb
        ws = wb[sheet]
        nr, nc = size(ws)
        Any[ws[i, j] for i in 1:nr, j in 1:nc]
    end
end

function _text_grid(path::String, sheet::String)
    delim = if !isempty(sheet) && !isletter(sheet[1]) && !isdigit(sheet[1])
        sheet[1]
    else
        _file_ext(path) == ".csv" ? ',' : '\t'
    end
    content = read(path, String)
    isempty(strip(content)) && return Matrix{Any}(undef, 0, 0)
    # any line ending, as pysd_tab_read_series
    return readdlm(IOBuffer(replace(content, r"\r\n?" => "\n")), delim, Any)
end

# (XLSX.jl reads a worksheet's cells on first use, filling a cache of its own:
# one thread at a time)
function _cells(s::_XLSXSheet, r1::Int, c1::Int, r2::Int, c2::Int)
    data = lock(_CACHE_LOCK) do
        s.ws[XLSX.CellRange(XLSX.CellRef(r1, c1), XLSX.CellRef(r2, c2))]
    end
    return data isa AbstractMatrix ? data : reshape(Any[data], 1, 1)
end

function _cells(s::_GridSheet, r1::Int, c1::Int, r2::Int, c2::Int)
    nr, nc = size(s.grid)
    return Any[(i <= nr && j <= nc) ? s.grid[i, j] : missing for i in r1:r2, j in c1:c2]
end

function _lastcell(s::_XLSXSheet)
    stop = lock(() -> XLSX.get_dimension(s.ws).stop, _CACHE_LOCK)
    return stop.row_number, stop.column_number
end

_lastcell(s::_GridSheet) = size(s.grid)

const _CELL_RE = r"^\$?([A-Za-z]{1,3})\$?([0-9]+)$"

_xlsx_is_cell_ref(s::AbstractString) = match(_CELL_RE, s) !== nothing

function _parse_cell(s::AbstractString)
    m = match(_CELL_RE, s)
    return parse(Int, m[2]), _xlsx_col_to_num(m[1])
end

function _xlsx_col_to_num(col::AbstractString)
    n = 0
    for c in uppercase(col)
        n = n * 26 + (Int(c) - Int('A') + 1)
    end
    return n
end

function _xlsx_num_to_col(n::Int)
    s = ""
    while n > 0
        n, r = divrem(n - 1, 26)
        s = Char('A' + r) * s
    end
    return s
end

function _xlsx_resolve_range(xf::XLSX.XLSXFile, sheet::String, name::String)
    wb = xf.workbook
    if haskey(wb.workbook_names, name)
        return string(wb.workbook_names[name].value)
    end
    sheet_lower = lowercase(sheet)
    sheet_idx = nothing
    for (i, s) in enumerate(XLSX.sheetnames(xf))
        if lowercase(s) == sheet_lower
            sheet_idx = i
            break
        end
    end
    # A name local to several sheets (a scenario sheet and its copy): the one
    # of the requested sheet.  XLSX.jl keys local names by the sheet's id
    # (sheetId), which is not its position once sheets are added and moved,
    # so the sheet is recognised by the name's reference, then by its id.
    sheet_id = sheet_idx === nothing ? nothing : wb.sheets[sheet_idx].sheetId
    fallback = nothing
    for ((idx, n), dn) in wb.worksheet_names
        if n == name
            ref = string(dn.value)
            occursin('!', ref) || (ref = sheet * "!" * ref)
            ref_sheet = lowercase(strip(String(split(ref, '!')[1]), ['\'', '=']))
            if ref_sheet == sheet_lower || (sheet_id !== nothing && idx == sheet_id)
                return ref
            end
            fallback === nothing && (fallback = ref)
        end
    end
    fallback !== nothing && return fallback
    error("Named range '" * name * "' not found in " * string(xf.source))
end

"""Whether `name` is a defined name (named range) of the `.xlsx` file at `path`."""
function _is_defined_name(path::String, name::String)
    _is_xlsx(path) || return false
    wb = _xlsx_open(path).workbook
    haskey(wb.workbook_names, name) && return true
    return any(n == name for ((_, n), _) in wb.worksheet_names)
end

function _xlsx_split_ref(ref::String)
    parts = split(ref, '!')
    return String(parts[1]), String(parts[2])
end

"""
    _range_ref(path, sheet, name) -> (sheet, r1, c1, r2, c2)

Where a cell (`"B2"`), a cell range (`"B2:D5"`) or a named range (`.xlsx`
only) is: its sheet (a named range may point to another one) and its corners.
"""
function _range_ref(path::String, sheet::String, name::String)
    parts = split(name, ':')
    if all(_xlsx_is_cell_ref, parts) && length(parts) <= 2 && !_is_defined_name(path, name)
        r1, c1 = _parse_cell(parts[1])
        r2, c2 = length(parts) == 2 ? _parse_cell(parts[2]) : (r1, c1)
        return sheet, r1, c1, r2, c2
    end
    _is_xlsx(path) || error("Named range '" * name * "' in " * path *
                            ": named ranges are only supported in .xlsx files")
    sname, cells = _xlsx_split_ref(_xlsx_resolve_range(_xlsx_open(path), sheet, name))
    return _range_ref(path, String(strip(sname, '\'')), cells)
end

"""
    _read_range(path, sheet, name)

Cells of a cell (`"B2"`), a cell range (`"B2:D5"`) or a named range (`.xlsx` only),
as a Matrix.
"""
function _read_range(path::String, sheet::String, name::String)
    s, r1, c1, r2, c2 = _range_ref(path, sheet, name)
    return _cells(_open_sheet(path, s), r1, c1, r2, c2)
end

_is_blank(v) = v === nothing || ismissing(v) || (v isa AbstractString && isempty(v))

function _to_float(x)
    x === nothing && return NaN
    ismissing(x) && return NaN
    x isa Number && return Float64(x)
    # numbers stored as text, as Python PySD reads them
    x isa AbstractString && return something(tryparse(Float64, strip(x)), NaN)
    return NaN
end

"""
    _clean_series(xs, ys, method=:interpolate)

A series as Python PySD reads it from Excel: x values that are missing (blank
or not a number) are dropped with their y values, the series is sorted by x,
and missing y values are filled with `method` (`:interpolate` linearly,
`:hold_backward` with the previous value, `:look_forward` with the next one;
the first and last known values at the ends).  `:raw` data are not filled.
`ys` is a vector, or a matrix with one series per row.
"""
# A series of one point has the same value everywhere (as in Python PySD):
# two points with that value, which every interpolation can take.
function _one_point_constant(xs::AbstractVector, ys::AbstractVecOrMat)
    length(xs) == 1 || return xs, ys
    return [xs[1], xs[1] + 1.0], ys isa AbstractVector ? [ys[1], ys[1]] : hcat(ys, ys)
end

function _clean_series(xs::AbstractVector, ys::AbstractVecOrMat, method::Symbol=:interpolate)
    order = _series_order(xs)
    xs_c = Float64.(xs[order])
    ys_c = ys isa AbstractVector ? Float64.(ys[order]) : Float64.(ys[:, order])
    xs_c, ys_c = _one_point_constant(xs_c, ys_c)
    method === :raw && return xs_c, ys_c
    if ys_c isa AbstractVector
        _fill_missing!(ys_c, xs_c, method)
    else
        for k in axes(ys_c, 1)
            row = ys_c[k, :]
            _fill_missing!(row, xs_c, method)
            ys_c[k, :] = row
        end
    end
    return xs_c, ys_c
end

# the points a series keeps, in the order it keeps them: those with an x, by x
function _series_order(xs::AbstractVector)
    keep = findall(!isnan, xs)
    return keep[sortperm(xs[keep])]
end

function _fill_missing!(ys::AbstractVector, xs::AbstractVector, method::Symbol)
    known = findall(!isnan, ys)
    (isempty(known) || length(known) == length(ys)) && return ys
    for i in eachindex(ys)
        isnan(ys[i]) || continue
        x = xs[i]
        if x <= xs[known[1]]
            ys[i] = ys[known[1]]
        elseif x >= xs[known[end]]
            ys[i] = ys[known[end]]
        else
            k = searchsortedlast(xs[known], x)
            a, b = known[k], known[k + 1]
            ys[i] = method === :hold_backward ? ys[a] :
                    method === :look_forward ? ys[b] :
                    ys[a] + (ys[b] - ys[a]) * (x - xs[a]) / (xs[b] - xs[a])
        end
    end
    return ys
end

function _to_float64_vec(data)
    v = vec(data isa AbstractMatrix ? data : reshape([data], 1, 1))
    return Float64[_to_float(x) for x in v]
end

"""
    _read_row_or_col(path, sheet, x_row_or_col, y_cell, n)

Row mode (`x_row_or_col` is a row number) and column mode (a column letter):
the x values run along that row or column from the column or row of `y_cell` until
the last non-blank one; the y values are the `n` rows (row mode) or columns (column
mode) starting at `y_cell`.  Returns `(xs, ys)` with `ys` an `n × length(xs)` Matrix.
"""
function _read_row_or_col(path::String, sheet::String, x_row_or_col::String,
                          y_cell::String, n::Int)
    s = _open_sheet(path, sheet)
    nr, nc = _lastcell(s)
    y_row, y_col = _parse_cell(y_cell)
    if all(isdigit, x_row_or_col)
        x_raw = vec(_cells(s, parse(Int, x_row_or_col), y_col, parse(Int, x_row_or_col), max(nc, y_col)))
        last_valid = findlast(!_is_blank, x_raw)
        last_valid === nothing && error("No x data found in row " * x_row_or_col)
        ys = _cells(s, y_row, y_col, y_row + n - 1, y_col + last_valid - 1)
    else
        x_col = _xlsx_col_to_num(x_row_or_col)
        x_raw = vec(_cells(s, y_row, x_col, max(nr, y_row), x_col))
        last_valid = findlast(!_is_blank, x_raw)
        last_valid === nothing && error("No x data found in column " * x_row_or_col)
        ys = permutedims(_cells(s, y_row, y_col, y_row + last_valid - 1, y_col + n - 1))
    end
    xs = Float64[_to_float(x_raw[i]) for i in 1:last_valid]
    return xs, Float64[_to_float(v) for v in ys]
end

# A defined name (e.g. "xs", which is also a column) takes precedence, as in Excel
_is_row_or_col(path::String, x::String, y::String) =
    _xlsx_is_cell_ref(y) && !_is_defined_name(path, y) && !_is_defined_name(path, x) &&
    (all(isdigit, x) || occursin(r"^[A-Za-z]{1,3}$", x))

"""
    pysd_xlsx_read_constant(path, sheet, name; transpose=false)

Read a scalar or array constant from an Excel named range or cell reference.
The `name` may end with `*` to indicate transposition (Vensim convention).
"""
function pysd_xlsx_read_constant(path::String, sheet::String, name::String;
                                 transpose::Bool=false, scalar::Bool=false)
    data = _read_range(path, sheet, name)
    transpose && (data = permutedims(data))
    if scalar || length(data) == 1
        return _to_float(data[1])
    end
    nr, nc = size(data)
    if nc == 1
        return Float64[_to_float(data[i, 1]) for i in 1:nr]
    elseif nr == 1
        return Float64[_to_float(data[1, j]) for j in 1:nc]
    end
    return Float64[_to_float(data[i, j]) for i in 1:nr, j in 1:nc]
end

"""
    pysd_xlsx_read_constant(path, sheet, names::Vector; transpose=false)

Read multiple named ranges from Excel and concatenate them into a single array.
Each element of `names` is either a `String` (range name to read from Excel)
or a `Vector{Float64}` (literal values to insert directly).
"""
function pysd_xlsx_read_constant(path::String, sheet::String, names::Vector;
                                 transpose::Bool=false, dims::Tuple=())
    parts = Float64[]
    for spec in names
        if spec isa String
            v = pysd_xlsx_read_constant(path, sheet, spec; transpose=transpose)
            if v isa AbstractArray
                append!(parts, vec(v))
            else
                push!(parts, Float64(v))
            end
        elseif spec isa AbstractVector
            append!(parts, Float64.(spec))
        elseif spec isa Number
            push!(parts, Float64(spec))
        end
    end
    if !isempty(dims) && length(dims) >= 2
        return reshape(parts, dims...)
    end
    return parts
end

"""
    pysd_xlsx_read_series(path, sheet, x_name, y_names::Vector{String})

Read multiple y-series from Excel sharing the same x-axis.
Returns `(xs, ys_list)` where `ys_list` is a `Vector{Vector{Float64}}`.
"""
function pysd_xlsx_read_series(path::String, sheet::String,
                               x_name::String, y_names::Vector{String})
    xs = nothing
    ys_list = Vector{Float64}[]
    for y_name in y_names
        xi, yi = pysd_xlsx_read_series(path, sheet, x_name, y_name)
        xs === nothing && (xs = xi)
        push!(ys_list, yi)
    end
    return xs, ys_list
end

"""
    pysd_xlsx_build_lookup_dispatch(path, sheet, x_name, y_name; n=1, method=:interpolate)

Read a (possibly 2D) lookup or data series from Excel and return a vector of
interpolation functions, one per series of the y data.  With named ranges the
series are the columns (or rows) of the y range; in row or column mode (`x_name` a
row number or a column letter, `y_name` a cell) they are the `n` rows (or columns)
from `y_name`.  `method` is a DATA keyword (`:interpolate`, `:hold_backward`,
`:look_forward`), as in [`pysd_build_tab_itp`](@ref).
"""
function pysd_xlsx_build_lookup_dispatch(path::String, sheet::String,
                                         x_name::String, y_name::String;
                                         n::Int=1, method::Symbol=:interpolate)
    function itp(ys, xs)
        xs_c, ys_c = _clean_series(xs, ys, method)
        return pysd_build_tab_itp(ys_c, xs_c, method)
    end
    if _is_row_or_col(path, x_name, y_name)
        xs, ys = _read_row_or_col(path, sheet, x_name, y_name, n)
        return [itp(ys[k, :], xs) for k in 1:n]
    end
    x_data = _read_range(path, sheet, x_name)
    xs = _to_float64_vec(x_data)
    y_data = _read_range(path, sheet, y_name)
    nr, nc = size(y_data)
    # As Python PySD, the series run along the x range: x in a row gives one
    # series per row of y (this also decides square blocks)
    x_in_row = size(x_data, 1) == 1 && size(x_data, 2) > 1
    if nc == length(xs) && nr > 1 && (x_in_row || nr != length(xs))
        return [itp(Float64[_to_float(y_data[i, j]) for j in 1:nc], xs) for i in 1:nr]
    elseif nr == length(xs) && nc > 1
        return [itp(Float64[_to_float(y_data[i, j]) for i in 1:nr], xs) for j in 1:nc]
    end
    return [itp(_to_float64_vec(y_data), xs)]
end

"""
    pysd_xlsx_read_series(path, sheet, x_row_or_col, y_cell)

Read x/y series data from Excel for lookups or time-series data.
Handles three Vensim reference modes:
- **Row mode**: `x_row_or_col` is a number (row), `y_cell` is a cell ref
- **Column mode**: `x_row_or_col` is a column letter, `y_cell` is a cell ref
- **Name mode**: both are named ranges
Returns `(xs::Vector{Float64}, ys::Vector{Float64})`.
"""
function pysd_xlsx_read_series(path::String, sheet::String,
                               x_row_or_col::String, y_cell::String)
    if _is_row_or_col(path, x_row_or_col, y_cell)
        xs, ys = _read_row_or_col(path, sheet, x_row_or_col, y_cell, 1)
        return _clean_series(xs, vec(ys))
    end
    xs = _to_float64_vec(_read_range(path, sheet, x_row_or_col))
    y_data = _read_range(path, sheet, y_cell)
    nr, nc = size(y_data)
    n = length(xs)
    if nr == n
        ys = Float64[_to_float(y_data[i, 1]) for i in 1:nr]
    elseif nc == n
        ys = Float64[_to_float(y_data[1, i]) for i in 1:nc]
    else
        ys = _to_float64_vec(y_data)
    end
    return length(ys) == n ? _clean_series(xs, ys) : (xs, ys)
end

# --- where the values are: the cells the readers above read, to write them back -----------

"""
    _constant_cells(path, sheet, name; transpose = false) -> (sheet, cells)

Where `pysd_xlsx_read_constant(path, sheet, name; transpose)` reads its
values: the sheet and a Matrix of `CartesianIndex(row, column)`, arranged as
the values it reads (transposed with `transpose`).  The value of a variable
over dimensions of size `sz` is `reshape(values, sz)` (see `_over`), so a new
value `A` goes to `cells` as `reshape(A, size(cells))`.
"""
function _constant_cells(path::String, sheet::String, name::String; transpose::Bool=false)
    s, r1, c1, r2, c2 = _range_ref(path, sheet, name)
    cells = [CartesianIndex(r, c) for r in r1:r2, c in c1:c2]
    return s, transpose ? permutedims(cells) : cells
end

"""
    _series_cells(path, sheet, x_name, y_name; n = 1) -> (sheet, xs, cells)

Where `pysd_xlsx_build_lookup_dispatch(path, sheet, x_name, y_name; n)` reads
its series: the sheet of the y values, the x values as they are in the file
(before `_clean_series` drops those that are blank and sorts them), and for
each series the `CartesianIndex(row, column)` of its y value at each of those
x.  The series' points are those at `_series_order(xs)`.
"""
function _series_cells(path::String, sheet::String, x_name::String, y_name::String; n::Int=1)
    if _is_row_or_col(path, x_name, y_name)
        s = _open_sheet(path, sheet)
        nr, nc = _lastcell(s)
        y_row, y_col = _parse_cell(y_name)
        if all(isdigit, x_name)
            x_raw = vec(_cells(s, parse(Int, x_name), y_col, parse(Int, x_name), max(nc, y_col)))
            m = something(findlast(!_is_blank, x_raw), 0)
            cells = [[CartesianIndex(y_row + k - 1, y_col + j - 1) for j in 1:m] for k in 1:n]
        else
            x_raw = vec(_cells(s, y_row, _xlsx_col_to_num(x_name), max(nr, y_row), _xlsx_col_to_num(x_name)))
            m = something(findlast(!_is_blank, x_raw), 0)
            cells = [[CartesianIndex(y_row + i - 1, y_col + k - 1) for i in 1:m] for k in 1:n]
        end
        return sheet, Float64[_to_float(x_raw[i]) for i in 1:m], cells
    end
    x_data = _read_range(path, sheet, x_name)
    xs = _to_float64_vec(x_data)
    s, r1, c1, r2, c2 = _range_ref(path, sheet, y_name)
    nr, nc = r2 - r1 + 1, c2 - c1 + 1
    at(i, j) = CartesianIndex(r1 + i - 1, c1 + j - 1)
    # (the same choice as pysd_xlsx_build_lookup_dispatch)
    x_in_row = size(x_data, 1) == 1 && size(x_data, 2) > 1
    if nc == length(xs) && nr > 1 && (x_in_row || nr != length(xs))
        return s, xs, [[at(i, j) for j in 1:nc] for i in 1:nr]
    elseif nr == length(xs) && nc > 1
        return s, xs, [[at(i, j) for i in 1:nr] for j in 1:nc]
    end
    return s, xs, [vec([at(i, j) for i in 1:nr, j in 1:nc])]
end
