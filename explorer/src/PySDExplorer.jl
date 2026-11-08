"""
    PySDExplorer

A web page to explore a PySD.jl model: its names by set (module), with their
units and descriptions; runs with other parameter values or input sheets,
kept on disk and compared; a sensitivity table; figures and data exported.

```julia
using PySDExplorer
serve("path/to/model.jl"; dir = "explorer-data")    # http://127.0.0.1:8080
```
"""
module PySDExplorer

using PySD
using PySD: Model, Results, ExcelSheet
import PySD.Tables as Tables
import PySD.XLSX as XLSX
using DimensionalData
using HTTP, JSON3, Dates, Sockets

export serve, static_page

const ASSETS = joinpath(@__DIR__, "..", "assets")

# ---------------------------------------------------------------------------
# the state: a model, its table of names, the runs kept in `dir`

mutable struct Run
    meta::Dict{String,Any}
    columns::Vector{String}
    index::Dict{String,Vector{Int}}     # name => its columns
    data::Matrix{Float64}               # time × column
end

struct Explorer
    model::Model
    title::String
    vars::NamedTuple
    row::Dict{Symbol,Int}
    editable::Dict{Symbol,Any}          # parameter => its value in the model (Float64 or Vector, Tables order)
    sizes::Dict{Symbol,Tuple}
    inputs::Dict{String,Vector{Tuple{String,String}}}   # input => (file, sheet) choices
    input_dirs::Vector{String}
    dir::String
    sensitivity::Union{Nothing,Dict{String,Any}}
    separator::String
    code::Vector{Pair{String,String}}   # file id => path: the model's code
    sources::Dict{Symbol,Vector{Tuple{String,Int}}}   # name => (file id, line) of its declaration and equations
    runs::Dict{String,Run}
    lock::ReentrantLock
    cache::Dict{String,String}          # answers that don't change (the model, its code), as JSON
end

"""
    serve(model; dir = "explorer-data", host = "127.0.0.1", port = 8080,
          title = "", input_dirs = String[], sensitivity = nothing,
          separator = "-")

Serve the explorer of `model` (a `Model`, or the path of the `.jl` file that
builds one) at `http://host:port`.  Runs are kept in `dir` (a file each, read
again next time).  `input_dirs`: folders whose `.xlsx` sheets can replace the
model's input sheets in a run.  `sensitivity`: a TSV file, a row per parameter
and a column per result (elasticities), shown in its own tab.  `separator`
splits set titles into a tree (`"ENERGY-DEMAND-Heat"` → ENERGY › DEMAND › Heat;
`""` for none).

`host = "127.0.0.1"` serves this computer only.  Anyone who can reach the page
can run the model: serve other addresses only on a network you trust.
"""
function serve(model; dir = "explorer-data", host = "127.0.0.1", port::Integer = 8080, kwargs...)
    ex = explorer(model; dir, kwargs...)
    router = routes(ex)
    @info "PySD explorer: http://$host:$port ($(length(ex.vars.name)) names, $(length(ex.runs)) runs in $(abspath(dir)))"
    return HTTP.serve(router, host, port; stream = false)
end

function explorer(model; dir = "explorer-data", title = "", input_dirs = String[], sensitivity = nothing,
                  separator = "-")
    m = model isa Model ? model : _build(model)
    title = isempty(title) && !(model isa Model) ? splitext(basename(model))[1] : title
    mkpath(joinpath(dir, "runs")); mkpath(joinpath(dir, "views"))
    vars = variables(m)
    row = Dict(n => i for (i, n) in enumerate(vars.name))
    base = Base.invokelatest(run_model, m)
    editable, sizes = Dict{Symbol,Any}(), Dict{Symbol,Tuple}()
    for (i, n) in enumerate(vars.name)
        (vars.kind[i] === :parameter && !haskey(m.structural, n)) || continue
        x = getfield(base.par, m.byname[n].id)      # (not base[n]: arrays of lookups aren't DimArrays)
        if x isa Real
            editable[n] = Float64(x)
        elseif x isa AbstractArray{<:Real}
            editable[n] = _flat(x)
            sizes[n] = size(x)
        end
    end
    code, sources = _code(m, vars.name)
    ex = Explorer(m, title, vars, row, editable, sizes, _input_choices(m, input_dirs), String.(input_dirs), String(dir),
                  sensitivity === nothing ? nothing : _sensitivity(sensitivity, row),
                  separator, code, sources, Dict{String,Run}(), ReentrantLock(), Dict{String,String}())
    for f in readdir(joinpath(dir, "runs"); join = true)
        endswith(f, ".json") || continue
        try
            r = _load(f)
            ex.runs[r.meta["id"]] = r
        catch e
            @warn "can't read the run in $f" exception = e
        end
    end
    isempty(ex.runs) && _save!(ex, base, "Base", Dict{String,Any}(), Dict{String,Any}(), 0.0)
    return ex
end

function _build(path)
    mod = Module()
    Core.eval(mod, :(using PySD, DimensionalData))
    Core.eval(mod, :(include(p) = Base.include($mod, p)))
    m = Base.include(mod, abspath(path))
    m isa Model || error("$path doesn't end with a Model")
    return m
end

# an array's values, the first dimension slowest (as the tables' columns)
function _flat(x::AbstractArray)
    sz = size(x)
    return vec(Float64[x[reverse(Tuple(J))...] for J in CartesianIndices(reverse(sz))])
end
function _unflat(v::AbstractVector, sz::Tuple)
    A = Array{Float64}(undef, sz)
    for (k, J) in enumerate(CartesianIndices(reverse(sz)))
        A[reverse(Tuple(J))...] = v[k]
    end
    return A
end

# ---------------------------------------------------------------------------
# the model's code: the files its declarations and equations are written in

function _code(m::Model, names)
    lines = Dict{Symbol,Vector{Tuple{String,Int}}}()
    files = String[]
    where(src::LineNumberNode) = src.file === nothing ? nothing : (abspath(String(src.file)), src.line)
    for n in names
        v = m.byname[n]
        srcs = [v.decl.source; [p.source for p in v.rate]; v.init === nothing ? LineNumberNode[] : [v.init.source];
                [p.source for p in v.parts]]
        out = Tuple{String,Int}[]
        for s in srcs
            w = where(s)
            (w === nothing || !isfile(w[1])) && continue
            w[1] in files || push!(files, w[1])
            w in out || push!(out, w)
        end
        lines[n] = out
    end
    # the main file (Model(…)) and the others next to them
    dirs = unique(dirname.(files))
    for d in dirs, f in readdir(d; join = true)
        endswith(f, ".jl") && !(f in files) && push!(files, f)
    end
    ids = Dict{String,String}()
    for f in files
        b = basename(f)
        id = b; k = 1
        while id in values(ids)
            k += 1; id = "$k-$b"
        end
        ids[f] = id
    end
    code = sort!([ids[f] => f for f in files]; by = first)
    return code, Dict(n => [(ids[f], l) for (f, l) in ls] for (n, ls) in lines)
end

code_text(ex::Explorer, id) =
    (i = findfirst(c -> first(c) == id, ex.code); i === nothing ? nothing : read(last(ex.code[i]), String))

function code_info(ex::Explorer)
    sets = Dict{String,Set{String}}()
    for (n, srcs) in ex.sources, (id, _) in srcs
        push!(get!(sets, id, Set{String}()), ex.vars.set[ex.row[n]])
    end
    return [Dict("id" => id, "sets" => sort!(collect(get(sets, id, Set{String}())))) for (id, _) in ex.code]
end

# ---------------------------------------------------------------------------
# inputs: the model's sheets, and the sheets of the files in input_dirs

# A sheet can replace another from a file named like the model's own
# (scen_w.xlsx: scen_w.xlsx, scen_w_high.xlsx…), in the model's folder or in
# input_dirs; sheets of notes (Readme, Info…) are left out.
function _input_choices(m::Model, dirs)
    files = String[]
    for d in dirs, f in readdir(d; join = true)
        endswith(lowercase(f), ".xlsx") && !startswith(basename(f), "~") && push!(files, abspath(f))
    end
    sheets = Dict(f => _sheets(f) for f in unique(files))
    notes = r"^(readme|info|notes?)\b"i
    out = Dict{String,Vector{Tuple{String,String}}}()
    for (k, v) in pairs(m.inputs)
        v isa ExcelSheet || continue
        own = (abspath(v.path), v.sheet)
        stem = lowercase(splitext(basename(v.path))[1])
        choices = [own]
        for f in sort!(collect(keys(sheets))), s in sheets[f]
            startswith(lowercase(basename(f)), stem) && !occursin(notes, s) && (f, s) != own && push!(choices, (f, s))
        end
        out[string(k)] = choices
    end
    return out
end

# the choices again, with the files there now
function refresh_inputs!(ex::Explorer)
    new = _input_choices(ex.model, ex.input_dirs)
    lock(ex.lock) do
        empty!(ex.inputs); merge!(ex.inputs, new)
    end
    return ex.inputs
end

inputs_info(ex::Explorer) =
    Dict(k => [Dict("id" => _choice_id(c), "label" => _choice_label(c)) for c in cs] for (k, cs) in ex.inputs)

function _sheets(f)
    try
        return XLSX.openxlsx(f) do xf
            String.(XLSX.sheetnames(xf))
        end
    catch e
        @warn "can't read the sheets of $f" exception = e
        return String[]
    end
end

_choice_id((f, s)) = f * "|" * s
_choice_label((f, s)) = basename(f) * " › " * s

# ---------------------------------------------------------------------------
# sensitivity: a TSV, a row per parameter; the columns that are results

function _sensitivity(path, row)
    lines = filter(!isempty, readlines(path))
    header = split(lines[1], '\t')
    rows = [split(l, '\t') for l in lines[2:end]]
    num(s) = tryparse(Float64, s)
    outputs = [h for h in header if haskey(row, Symbol(h)) && !(h in ("parameter", "value"))]
    out = Any[]
    for r in rows
        length(r) == length(header) || continue
        p = String(r[1])
        d = Dict{String,Any}("parameter" => p)
        for (h, x) in zip(header, r)
            h in outputs && (v = num(x); d[h] = v === nothing || !isfinite(v) ? nothing : v)
            h == "value" && (d["value"] = num(x))
            h == "kind" && (d["kind"] = String(x))
        end
        push!(out, d)
    end
    return Dict{String,Any}("file" => basename(path), "outputs" => outputs, "rows" => out)
end

# ---------------------------------------------------------------------------
# runs: run, save (a .json and a .f64 file), load

function run!(ex::Explorer, label, params, inputs)
    ps = Pair{Symbol,Any}[]
    for (k, v) in params
        n = Symbol(k)
        haskey(ex.editable, n) || throw(ArgumentError("`$k` is not a parameter that can change"))
        if v isa Real
            ex.editable[n] isa Real || throw(ArgumentError("`$k` is an array"))
            push!(ps, n => Float64(v))
        elseif v isa AbstractVector && haskey(ex.sizes, n) && length(v) == prod(ex.sizes[n]) && all(x -> x isa Real, v)
            push!(ps, n => _unflat(Float64.(v), ex.sizes[n]))
        else
            throw(ArgumentError("`$k`: a number, or $(get(ex.sizes, n, ())) numbers"))
        end
    end
    ins = Pair{Symbol,Any}[]
    isempty(inputs) || refresh_inputs!(ex)
    for (k, id) in inputs
        choices = get(ex.inputs, String(k), nothing)
        choices === nothing && throw(ArgumentError("`$k` is not an input sheet"))
        c = findfirst(c -> _choice_id(c) == id, choices)
        c === nothing && throw(ArgumentError("`$id` is not a sheet for `$k`"))
        c == 1 || push!(ins, Symbol(k) => PySD.excel(choices[c]...))
    end
    lock(ex.lock) do
        t = @elapsed r = Base.invokelatest(run_model, ex.model; params = (; ps...), inputs = (; ins...))
        _save!(ex, r, label, Dict{String,Any}(string(k) => v for (k, v) in params),
               Dict{String,Any}(string(k) => v for (k, v) in inputs if v != _choice_id(ex.inputs[string(k)][1])), t)
    end
end

function _save!(ex::Explorer, r::Results, label, params, inputs, seconds)
    cols = Tables.columns(r)
    names = [String(n) for n in Tables.columnnames(cols) if n !== :time]
    data = Matrix{Float64}(undef, length(r.time), length(names))
    for j in eachindex(names)
        _copy!(view(data, :, j), Tables.getcolumn(cols, j + 1))     # (column 1 is the time)
    end
    id = Dates.format(now(), "yyyymmdd-HHMMSS") * "-" * string(length(ex.runs) + 1)
    meta = Dict{String,Any}("id" => id, "label" => isempty(strip(label)) ? "Run $(length(ex.runs) + 1)" : label,
                            "created" => Dates.format(now(), "yyyy-mm-dd HH:MM"), "params" => params,
                            "inputs" => inputs, "seconds" => round(seconds; digits = 2), "time" => r.time,
                            "columns" => names)
    base = joinpath(ex.dir, "runs", id)
    write(base * ".f64", data)
    open(io -> JSON3.write(io, meta), base * ".json", "w")
    run = _run(meta, names, data)
    ex.runs[id] = run
    return run
end

# (a function barrier: compiled for each column's type)
function _copy!(out, c)
    for i in eachindex(out, c)
        x = c[i]
        out[i] = x isa Real ? Float64(x) : NaN
    end
end

function _load(file)
    meta = Dict{String,Any}(String(k) => v for (k, v) in JSON3.read(read(file, String)))
    names = String.(meta["columns"])
    meta["time"] = Float64.(meta["time"])
    meta["params"] = Dict{String,Any}(String(k) => (v isa AbstractVector ? collect(v) : v) for (k, v) in meta["params"])
    meta["inputs"] = Dict{String,Any}(String(k) => String(v) for (k, v) in meta["inputs"])
    data = Matrix{Float64}(undef, length(meta["time"]), length(names))
    read!(splitext(file)[1] * ".f64", data)
    return _run(meta, names, data)
end

function _run(meta, names, data)
    index = Dict{String,Vector{Int}}()
    for (j, n) in enumerate(names)
        k = findfirst('[', n)
        push!(get!(index, k === nothing ? n : n[1:k-1], Int[]), j)
    end
    return Run(meta, names, index, data)
end

_public(r::Run) = Dict(k => v for (k, v) in r.meta if k != "columns" && k != "time")

function delete_run!(ex::Explorer, id)
    haskey(ex.runs, id) || return false
    delete!(ex.runs, id)
    base = joinpath(ex.dir, "runs", id)
    rm(base * ".json"; force = true); rm(base * ".f64"; force = true)
    return true
end

function rename_run!(ex::Explorer, id, label)
    r = ex.runs[id]
    r.meta["label"] = label
    open(io -> JSON3.write(io, r.meta), joinpath(ex.dir, "runs", id * ".json"), "w")
end

# a name's values in some runs: its elements' labels, a vector per element per run
function series(ex::Explorer, name, ids)
    runs = Dict{String,Any}()
    labels, time = String[], Float64[]
    for id in ids
        r = get(ex.runs, id, nothing)
        r === nothing && continue
        cols = get(r.index, name, Int[])
        isempty(cols) && continue
        time = r.meta["time"]
        labels = [(k = findfirst('[', r.columns[j]); k === nothing ? "" : r.columns[j][k+1:end-1]) for j in cols]
        runs[id] = [_finite(view(r.data, :, j)) for j in cols]
    end
    return Dict("name" => name, "time" => time, "elements" => labels, "runs" => runs)
end

_finite(v) = [isfinite(x) ? x : nothing for x in v]

# ---------------------------------------------------------------------------
# what the page reads first: the model

function model_info(ex::Explorer)
    v = ex.vars
    m = ex.model
    names = [Dict("name" => String(v.name[i]), "title" => v.title[i], "set" => v.set[i], "kind" => String(v.kind[i]),
                  "unit" => v.unit[i], "description" => v.description[i],
                  "limits" => v.limits[i] === nothing ? nothing : [isfinite(x) ? x : nothing for x in v.limits[i]],
                  "dims" => String.(collect(v.dims[i])), "elements" => [collect(e) for e in v.elements[i]],
                  "value" => _json(get(ex.editable, v.name[i], nothing)),
                  "code" => [[f, l] for (f, l) in get(ex.sources, v.name[i], Tuple{String,Int}[])])
             for i in eachindex(v.name)]
    inputs = inputs_info(ex)
    return Dict("title" => ex.title, "time_unit" => string(m.time_unit), "t0" => m.t0, "tf" => m.tf,
                "separator" => ex.separator, "names" => names, "inputs" => inputs,
                "sensitivity" => ex.sensitivity !== nothing, "code" => !isempty(ex.code))
end

_json(::Nothing) = nothing
_json(x::Real) = isfinite(x) ? x : nothing
_json(x::AbstractVector) = _finite(x)

runs_info(ex::Explorer) = sort!([_public(r) for r in values(ex.runs)]; by = r -> r["id"])

# ---------------------------------------------------------------------------
# saved views: what the page shows, by name

_view_file(ex, name) = joinpath(ex.dir, "views", replace(name, r"[^\w\- ]" => "_") * ".json")

views_info(ex::Explorer) =
    [JSON3.read(read(f, String)) for f in readdir(joinpath(ex.dir, "views"); join = true) if endswith(f, ".json")]

# ---------------------------------------------------------------------------
# a page that works without the server: the runs and names given, in the file

"""
    static_page(ex, ids, names; view = nothing) -> String

The explorer's page with the runs `ids` and the values of `names` in it (and
the sensitivity table): one HTML file that opens anywhere, without a server.
"""
function static_page(ex::Explorer, ids, names; view = nothing)
    keep = Set(names)
    info = model_info(ex)
    info["names"] = [n for n in info["names"] if n["name"] in keep]
    data = Dict("model" => info, "runs" => [_public(ex.runs[i]) for i in ids if haskey(ex.runs, i)],
                "series" => Dict(n => series(ex, n, ids) for n in names),
                "sensitivity" => ex.sensitivity, "view" => view, "views" => [],
                "code" => code_info(ex), "texts" => Dict(id => code_text(ex, id) for (id, _) in ex.code))
    html = read(joinpath(ASSETS, "index.html"), String)
    inline(tag, file) = tag * replace(read(joinpath(ASSETS, file), String), "</script" => "<\\/script") *
                        (startswith(tag, "<style") ? "</style>" : "</script>")
    payload = replace(JSON3.write(data), "</" => "<\\/")
    html = replace(html,
        """<link rel="stylesheet" href="app.css">""" => inline("<style>", "app.css"),
        """<script src="vendor/plotly.min.js"></script>""" => inline("<script>", "vendor/plotly.min.js"),
        """<script src="app.js"></script>""" => "<script>window.PYSD_STATIC = $payload;</script>" *
                                               inline("<script>", "app.js"))
    return html
end

# ---------------------------------------------------------------------------
# the routes

const TYPES = Dict(".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
                   ".css" => "text/css; charset=utf-8", ".svg" => "image/svg+xml", ".png" => "image/png")

_json_response(x; status = 200) =
    HTTP.Response(status, ["Content-Type" => "application/json", "Cache-Control" => "no-store"], JSON3.write(x))
_error(msg; status = 400) = _json_response(Dict("error" => msg); status)

function _asset(req)
    path = HTTP.URI(req.target).path
    path = path == "/" ? "index.html" : lstrip(path, '/')
    occursin("..", path) && return HTTP.Response(404)
    f = joinpath(ASSETS, path)
    isfile(f) || return HTTP.Response(404)
    return HTTP.Response(200, ["Content-Type" => get(TYPES, splitext(f)[2], "application/octet-stream")], read(f))
end

_query(req) = HTTP.queryparams(HTTP.URI(req.target))
_body(req) = JSON3.read(String(req.body))

function routes(ex::Explorer)
    r = HTTP.Router(_asset)
    guard(f) = req -> try
        f(req)
    catch e
        e isa ArgumentError && return _error(e.msg)
        @error "request failed" exception = (e, catch_backtrace())
        return _error(sprint(showerror, e); status = 500)
    end
    cached(key, f) = _ -> HTTP.Response(200, ["Content-Type" => "application/json"],
                                         get!(() -> JSON3.write(f()), ex.cache, key))
    HTTP.register!(r, "GET", "/api/model", guard(cached("model", () -> model_info(ex))))
    HTTP.register!(r, "GET", "/api/runs", guard(_ -> _json_response(runs_info(ex))))
    HTTP.register!(r, "GET", "/api/inputs", guard(_ -> (refresh_inputs!(ex); _json_response(inputs_info(ex)))))
    HTTP.register!(r, "POST", "/api/runs", guard() do req
        b = _body(req)
        run = run!(ex, String(get(b, :label, "")), pairs(get(b, :params, Dict())), pairs(get(b, :inputs, Dict())))
        _json_response(_public(run))
    end)
    HTTP.register!(r, "DELETE", "/api/runs/{id}", guard() do req
        id = HTTP.getparams(req)["id"]
        delete_run!(ex, id) ? _json_response(Dict("deleted" => id)) : _error("no run $id"; status = 404)
    end)
    HTTP.register!(r, "PATCH", "/api/runs/{id}", guard() do req
        id = HTTP.getparams(req)["id"]
        haskey(ex.runs, id) || return _error("no run $id"; status = 404)
        rename_run!(ex, id, String(_body(req).label))
        _json_response(_public(ex.runs[id]))
    end)
    HTTP.register!(r, "GET", "/api/series", guard() do req
        q = _query(req)
        _json_response(series(ex, q["name"], split(get(q, "runs", ""), ','; keepempty = false)))
    end)
    HTTP.register!(r, "GET", "/api/sensitivity", guard(cached("sensitivity", () -> ex.sensitivity)))
    HTTP.register!(r, "GET", "/api/code", guard(cached("code", () -> code_info(ex))))
    HTTP.register!(r, "GET", "/api/code/{id}", guard() do req
        text = code_text(ex, HTTP.unescapeuri(HTTP.getparams(req)["id"]))
        text === nothing ? _error("no such file"; status = 404) : _json_response(Dict("text" => text))
    end)
    HTTP.register!(r, "GET", "/api/views", guard(_ -> _json_response(views_info(ex))))
    HTTP.register!(r, "POST", "/api/views", guard() do req
        b = _body(req)
        name = strip(String(b.name))
        isempty(name) && return _error("a view needs a name")
        write(_view_file(ex, name), JSON3.write(b))
        _json_response(views_info(ex))
    end)
    HTTP.register!(r, "DELETE", "/api/views/{name}", guard() do req
        rm(_view_file(ex, HTTP.unescapeuri(HTTP.getparams(req)["name"])); force = true)
        _json_response(views_info(ex))
    end)
    HTTP.register!(r, "POST", "/api/static", guard() do req
        b = _body(req)
        html = static_page(ex, String.(b.runs), String.(b.names); view = get(b, :view, nothing))
        HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8",
                            "Content-Disposition" => "attachment; filename=\"$(isempty(ex.title) ? "model" : ex.title)-explorer.html\""], html)
    end)
    return r
end

end
