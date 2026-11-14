# A run's scenario as Excel files: copies of the workbooks it read, with its
# values in the cells the model reads them from, zipped with a list of what
# went where (and what has no cell: values written in the model's code).

# Where a parameter's value comes from, as its declaration writes it:
# constant(sheet, "cells"; transpose), lookup(sheet, "x", "cells") or
# data(sheet, "time", "cells"; method), or a list of them (one per element of
# the first dimension).
struct CellsOf
    input::Symbol
    cells::String
    transpose::Bool
end
struct SeriesOf
    input::Symbol
    x::String
    cells::String
end

function _excel_source(m::Model, e)
    e isa Expr || return nothing
    if e.head === :vect
        items = [_excel_source(m, a) for a in e.args]
        return isempty(items) || any(isnothing, items) ? nothing : items
    end
    (e.head === :call && e.args[1] in (:constant, :lookup, :data)) || return nothing
    args, kw = Any[], Dict{Symbol,Any}()
    for a in e.args[2:end]
        if a isa Expr && a.head === :parameters
            foreach(k -> k isa Expr && k.head === :kw && (kw[k.args[1]] = k.args[2]), a.args)
        elseif a isa Expr && a.head === :kw
            kw[a.args[1]] = a.args[2]
        else
            push!(args, a)
        end
    end
    (!isempty(args) && args[1] isa Symbol && haskey(m.inputs, args[1]) && m.inputs[args[1]] isa ExcelSheet &&
     all(a -> a isa String, args[2:end])) || return nothing
    if e.args[1] === :constant
        length(args) == 2 || return nothing
        return CellsOf(args[1], args[2], get(kw, :transpose, false) === true)
    end
    length(args) == 3 || return nothing
    return SeriesOf(args[1], args[2], args[3])
end

_excel_source(ex::Explorer, name::Symbol) = _excel_source(ex.model, ex.model.byname[name].decl.default)

# The file and sheet a run read an input from: the model's, or the one it chose
# (if the user may still see it)
function _run_sheet(ex::Explorer, user, r::Run, input::Symbol)
    own = ex.model.inputs[input]
    id = get(r.meta["inputs"], String(input), nothing)
    id === nothing && return (own.path, own.sheet, basename(own.path))
    f, s = _split_choice(id)
    choices, _ = input_choices(ex, user)
    any(c -> c == (f, s), get(choices, String(input), Tuple{String,String}[])) ||
        throw(_NoCells("it read a sheet you can't see ($s of a file uploaded by someone else, or deleted)"))
    # an upload keeps the name of the model's file it replaces
    name = startswith(f, _uploads_dir(ex)) ? basename(own.path) : basename(f)
    return (f, s, name)
end

struct _NoCells <: Exception
    why::String
end

# A cell to write: its sheet, where, the value; the parameter it is for.
const _Write = @NamedTuple{sheet::String, at::CartesianIndex{2}, value::Float64}

# The writes of a value from where it is read: `vals` is the run's value (a
# number, numbers first dimension slowest, or a list of tables) over
# dimensions of sizes `sz`; a pair (input => writes) per sheet.
function _writes(src::CellsOf, path_of, vals, sz::Tuple)
    path, sheet, _ = path_of(src.input)
    s, cells = PySD._constant_cells(path, sheet, src.cells; transpose = src.transpose)
    A = vals isa Real ? [Float64(vals)] : isempty(sz) ? [Float64(only(vals))] : _unflat(Float64.(vals), sz)
    if length(A) == length(cells)
        M = reshape(A, size(cells))                          # (as the model reads it: reshape(values, size))
    elseif length(cells) == 1 && allequal(A)
        M = [first(A);;]                                     # one cell for all the elements, all the same
    else
        throw(_NoCells("$(length(cells)) cells for $(length(A)) values (the model repeats them over elements)"))
    end
    return [src.input => [_Write((s, cells[k], M[k])) for k in eachindex(cells)]]
end

function _writes(src::SeriesOf, path_of, ys, sz::Tuple)
    path, sheet, _ = path_of(src.input)
    s, xs, cells = PySD._series_cells(path, sheet, src.x, src.cells; n = length(ys))
    length(cells) == length(ys) || throw(_NoCells("$(length(cells)) series in $(src.cells) for $(length(ys)) tables"))
    order = PySD._series_order(xs)
    out = _Write[]
    for (cs, y) in zip(cells, ys)
        # the points as the model keeps them (a series of one point: two, the same)
        (length(y) == length(order) || (length(order) == 1 && length(y) == 2)) ||
            throw(_NoCells("the sheet has $(length(order)) points where the table has $(length(y))"))
        for (i, j) in enumerate(order)
            push!(out, _Write((s, cs[j], Float64(y[i]))))
        end
    end
    return [src.input => out]
end

# a source per element of the first dimension: each its part of the values
function _writes(srcs::Vector, path_of, vals, sz::Tuple)
    (!isempty(sz) && length(srcs) == first(sz) && vals isa AbstractVector) ||
        throw(_NoCells("$(length(srcs)) blocks of cells that don't match its dimensions"))
    rest = Base.tail(sz)
    k = prod(rest)
    length(vals) == length(srcs) * k || throw(_NoCells("$(length(srcs)) blocks of cells for $(length(vals)) values"))
    return reduce(vcat, [_writes(src, path_of, vals[(i - 1) * k + 1:i * k], rest) for (i, src) in enumerate(srcs)])
end

"""
    run_excel(ex, user, id) -> (filename, bytes)

A run's scenario as a zip: a copy of each workbook in which the run changed
values, with its values in the cells the model reads them from (named
ranges, cells, rows or columns of series), and `changes.csv`, what went where
and what has no cell (a value written in the model's code, a sheet the user
can't see).  A formula in a cell that gets a value is replaced by it, and
noted.
"""
function run_excel(ex::Explorer, user, id)
    r = _visible_run(ex, user, id)
    isempty(r.meta["params"]) && throw(ArgumentError("this run changes no values: its sheets are the model's files"))
    files = Dict{String,String}()                     # path => the name in the zip
    writes = Dict{String,Vector{Tuple{_Write,String}}}()   # path => (write, parameter)
    rows = Vector{Vector{String}}()
    function path_of(input)
        p = _run_sheet(ex, user, r, input)
        lowercase(splitext(p[1])[2]) in (".xlsx", ".xlsm") ||
            throw(_NoCells("read from $(p[3]), which isn't an .xlsx file"))
        if !haskey(files, p[1])                      # (two files of one name: the second "2-name")
            name, i = p[3], 1
            while name in values(files)
                i += 1; name = "$i-" * p[3]
            end
            files[p[1]] = name
        end
        return (p[1], p[2], files[p[1]])
    end
    for (k, v) in sort!(collect(r.meta["params"]); by = first)
        n = Symbol(k)
        row = ex.row[n]
        title, unit = ex.vars.title[row], something(ex.vars.unit[row], "")
        src = haskey(ex.model.byname, n) ? _excel_source(ex, n) : nothing
        try
            src === nothing && throw(_NoCells("written in the model's code, not read from a sheet"))
            sz = haskey(ex.tables, n) ? last(ex.tables[n]) : get(ex.sizes, n, ())
            byinput = Dict{Symbol,Vector{_Write}}()        # (one row per file: blocks of cells joined)
            for (input, w) in _writes(src, path_of, v, sz)
                append!(get!(byinput, input, _Write[]), w)
            end
            for (input, w) in sort!(collect(byinput); by = first)
                path, _, zname = path_of(input)
                append!(get!(writes, path, Tuple{_Write,String}[]), [(x, k) for x in w])
                push!(rows, [k, title, unit, zname, _where(w), _value_text(v), ""])
            end
        catch e
            e isa _NoCells || rethrow()
            push!(rows, [k, title, unit, "", "", _value_text(v), "not written: " * e.why])
        end
    end
    copies, notes = _write_copies(writes, files)
    for row in rows, (key, note) in notes
        (row[1], row[4]) == key && (row[7] = isempty(row[7]) ? note : row[7] * "; " * note)
    end
    io = IOBuffer()
    ZipArchives.ZipWriter(io) do z
        for (path, bytes) in sort!(collect(copies); by = first)
            ZipArchives.zip_writefile(z, files[path], bytes)
        end
        ZipArchives.zip_writefile(z, "changes.csv", codeunits(_changes_csv(r, rows)))
        _zip_scenario!(z, ex, user, r)              # (the record: load it again with "Load a scenario")
        ZipArchives.zip_writefile(z, "README.txt", codeunits(_excel_readme(ex, r)))
    end
    return replace(r.meta["label"], r"[^A-Za-z0-9_\- ]" => "_") * ".zip", take!(io)
end

# Copies of the workbooks with their writes; the formulas replaced, noted per (parameter, file)
function _write_copies(writes, files)
    copies = Dict{String,Vector{UInt8}}()
    notes = Dict{Tuple{String,String},String}()
    mktempdir() do tmp
        for (path, ws) in writes
            copy = joinpath(tmp, "copy" * splitext(path)[2])
            cp(path, copy; force = true)
            XLSX.openxlsx(copy; mode = "rw") do xf
                for (w, k) in ws
                    sheet = xf[w.sheet]
                    ref = XLSX.CellRef(w.at[1], w.at[2])
                    f = _formula(sheet, ref)
                    if f !== nothing
                        key = (k, files[path])
                        t = "$(string(ref)) was $f"
                        notes[key] = haskey(notes, key) ? notes[key] * ", " * t : "formula replaced: " * t
                    end
                    sheet[w.at[1], w.at[2]] = w.value
                end
            end
            copies[path] = read(copy)
            rm(copy)
        end
    end
    return copies, notes
end

# a cell's formula ("=A1+1"), or nothing
function _formula(sheet, ref)
    c = XLSX.getcell(sheet, ref)
    (c isa XLSX.Cell && c.formula) || return nothing
    f = try
        XLSX.get_formula_from_cache(sheet, ref)        # (XLSX.jl keeps them apart from the cells)
    catch
        return "a formula"
    end
    f isa XLSX.ExplicitFormula || return "a shared formula"
    return startswith(f.formula, "=") ? f.formula : "=" * f.formula
end

# "Sheet › B2:D4" or "Sheet › 30 cells"
function _where(ws::Vector{_Write})
    isempty(ws) && return ""
    sheets = unique(w.sheet for w in ws)
    parts = map(sheets) do s
        at = [w.at for w in ws if w.sheet == s]
        lo = CartesianIndex(minimum(a[1] for a in at), minimum(a[2] for a in at))
        hi = CartesianIndex(maximum(a[1] for a in at), maximum(a[2] for a in at))
        box = string(XLSX.CellRef(lo[1], lo[2])) * (lo == hi ? "" : ":" * string(XLSX.CellRef(hi[1], hi[2])))
        s * " › " * box * (length(at) == prod(Tuple(hi - lo) .+ 1) ? "" : " ($(length(at)) cells)")
    end
    return join(parts, "; ")
end

_value_text(v::Real) = string(v)
_value_text(v::AbstractVector) = any(x -> x isa AbstractVector, v) ? "a table" : join(v, " ")

function _changes_csv(r::Run, rows)
    q(x) = (x = string(x); any(c -> c in (',', '"', '\n', '\r'), x) ? "\"" * replace(x, "\"" => "\"\"") * "\"" : x)
    io = IOBuffer()
    println(io, "# ", q(r.meta["label"]), " (", r.meta["created"], isempty(r.meta["owner"]) ? "" : ", " * r.meta["owner"], ")")
    println(io, "name,title,unit,file,cells,value,note")
    foreach(row -> println(io, join(q.(row), ",")), rows)
    return String(take!(io))
end

function _excel_readme(ex::Explorer, r::Run)
    sheets = ["  $k: $(split(v, '|')[end]) of $(basename(split(v, '|')[1]))" for (k, v) in sort!(collect(r.meta["inputs"]); by = first)]
    return """
    $(isempty(ex.title) ? "Model" : ex.title): the scenario of the run "$(r.meta["label"])" ($(r.meta["created"]))

    The workbooks here are copies of those the run read, with the values the
    run changed in the cells the model reads them from.  Replace the model's
    files with them (or upload them in the explorer's Runs tab) to run the
    same scenario, here, in Python PySD or in Vensim.

    changes.csv lists each value the run changed: the file and cells it went
    to, or why it isn't in a sheet (a value written in the model's code has
    no cell: set it in the model, or in a run).

    A cell that had a formula now has the value (changes.csv names it).  Other
    formulas keep the values they had: Excel computes them again when it
    opens the file, PySD and Vensim read them as they are.

    scenario.json (with sheets/, the uploaded workbooks the run read, as they
    were) is the explorer's record of the run: load this zip in the Runs tab
    ("Load a scenario") to fill the New run form with it again.
    $(isempty(sheets) ? "" : "\nThe run read these sheets instead of the model's own:\n" * join(sheets, "\n") * "\n")"""
end
