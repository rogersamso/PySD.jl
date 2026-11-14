# A run's scenario as a file, and loaded back: scenario.json (what the run
# changed, the sheets it read, the model and PySD.jl that ran it) zipped with
# the workbooks it read that aren't the model's own (uploads, server folders).
# Loading one fills the New run form; its workbooks become the user's uploads.

const SCENARIO_FORMAT = "pysd-explorer-scenario"

_sha256(path) = bytes2hex(open(SHA.sha256, path))
_version(m::Module) = (v = pkgversion(m); v === nothing ? "" : string(v))

# The model as the explorer loaded it: each of its code and Excel files' SHA-256,
# one fingerprint of them all, and PySD.jl's version
function _model_record(title, m::Model, code)
    files = Dict{String,Any}()
    for (id, path) in code
        isfile(path) && (files[id] = _sha256(path))
    end
    for v in values(m.inputs)
        v isa ExcelSheet && isfile(v.path) && (files[basename(v.path)] = _sha256(v.path))
    end
    fingerprint = bytes2hex(SHA.sha256(join(sort!(["$k $v" for (k, v) in files]), "\n")))
    return Dict{String,Any}("title" => title, "fingerprint" => fingerprint, "files" => files,
                            "pysd" => _version(PySD), "explorer" => _version(@__MODULE__))
end

# the model's own Excel files (as the input choices name them)
_own_files(ex) = Set(abspath(v.path) for v in values(ex.model.inputs) if v isa ExcelSheet)

# The scenario of a run: its scenario.json, and the workbooks to zip with it (name in the zip => path)
function _scenario(ex::Explorer, user, r::Run)
    own = _own_files(ex)
    choices, _ = input_choices(ex, user)
    sheets = Dict{String,String}()
    inputs = Dict{String,Any}()
    for (k, id) in sort!(collect(r.meta["inputs"]); by = first)
        f, s = _split_choice(id)
        e = Dict{String,Any}("sheet" => s)
        if f in own
            e["from"], e["file"] = "model", basename(f)
        else
            upload = findfirst(u -> joinpath(_uploads_dir(ex), u["file"]) == f, ex.uploads)
            e["from"] = upload === nothing ? "server folder" : "upload"
            upload === nothing || (e["label"] = ex.uploads[upload]["label"])
            e["file"] = basename(f)
            if !isfile(f)
                e["missing"] = "deleted from the server"
            elseif !any(==((f, s)), get(choices, k, Tuple{String,String}[]))
                e["missing"] = "someone else's upload, not shared with you"
            else
                name = "sheets/" * basename(f)
                i = 1
                while haskey(sheets, name) && sheets[name] != f
                    i += 1; name = "sheets/$i-" * basename(f)
                end
                sheets[name] = f
                e["path"], e["sha256"] = name, _sha256(f)
            end
        end
        inputs[k] = e
    end
    json = Dict{String,Any}("format" => SCENARIO_FORMAT, "version" => 1, "label" => r.meta["label"],
                            "run" => r.meta["id"], "created" => r.meta["created"], "owner" => r.meta["owner"],
                            "model" => get(r.meta, "model", nothing), "params" => r.meta["params"], "inputs" => inputs)
    return json, sheets
end

function _zip_scenario!(z, ex, user, r)
    json, sheets = _scenario(ex, user, r)
    io = IOBuffer()
    JSON3.pretty(io, JSON3.write(json))
    ZipArchives.zip_writefile(z, "scenario.json", take!(io))
    for (name, path) in sort!(collect(sheets); by = first)
        ZipArchives.zip_writefile(z, name, read(path))
    end
    return json
end

"""
    run_scenario(ex, user, id) -> (file name, the zip's bytes)

A run's scenario, to keep or load again: scenario.json (the values and
tables it changed, the input sheets it read, the model and PySD.jl
versions that ran it), the workbooks it read that aren't the model's own,
and a README.
"""
function run_scenario(ex::Explorer, user, id)
    r = _visible_run(ex, user, id)
    io = IOBuffer()
    ZipArchives.ZipWriter(io) do z
        json = _zip_scenario!(z, ex, user, r)
        ZipArchives.zip_writefile(z, "README.txt", codeunits(_scenario_readme(ex, json)))
    end
    return replace(r.meta["label"], r"[^A-Za-z0-9_\- ]" => "_") * " (scenario).zip", take!(io)
end

function _scenario_readme(ex::Explorer, json)
    m = json["model"]
    made = m === nothing ? "  (not recorded: the run is older than this record)" :
           "  model fingerprint $(m["fingerprint"])\n  PySD.jl $(m["pysd"]), explorer $(m["explorer"])"
    missing = ["  $k: $(e["file"]) › $(e["sheet"]): not included, $(e["missing"])"
               for (k, e) in sort!(collect(json["inputs"]); by = first) if haskey(e, "missing")]
    return """
    $(isempty(ex.title) ? "Model" : ex.title): the scenario of the run "$(json["label"])" ($(json["created"]))

    scenario.json is what the run changed (values and tables, as the explorer
    keeps them) and the input sheets it read; sheets/ holds the workbooks it
    read that aren't the model's own (uploads, files of the server's folders).
    An input not listed read the model's own sheet.

    To run it again: in the explorer's Runs tab, "Load a scenario" with this
    zip.  The New run form is filled in; its workbooks become your uploads.
    If the model has changed since, the explorer says which files differ.

    The model that ran it:
    $made
    $(isempty(missing) ? "" : "\nSheets the run read that aren't here:\n" * join(missing, "\n") * "\n")"""
end

# The sheet of a scenario's workbook: an upload or a server folder's file the user
# sees with these bytes, or a new upload of them
function _scenario_sheet!(ex, user, k, e, z, label, found, notes)
    name = get(e, "path", "")
    if isempty(name) || !(name in ZipArchives.zip_names(z))
        push!(notes, "`$k`: $(get(e, "file", "its file")) › $(e["sheet"]) isn't in the zip ($(get(e, "missing", "left out"))): the model's sheet instead")
        return nothing
    end
    bytes = ZipArchives.zip_readentry(z, name)
    sha = bytes2hex(SHA.sha256(bytes))
    path = get(found, sha, nothing)
    if path === nothing
        choices, _ = input_choices(ex, user)
        for (f, _) in get(choices, k, Tuple{String,String}[])
            isfile(f) && filesize(f) == length(bytes) && _sha256(f) == sha && (path = f; break)
        end
    end
    if path === nothing
        stem = lowercase(splitext(basename(ex.model.inputs[Symbol(k)].path))[1])
        u = upload!(ex, user, bytes; replaces = stem, label = get(e, "label", "$(label): $(get(e, "file", stem))"))
        path = joinpath(_uploads_dir(ex), u["file"])
        push!(notes, "uploaded \"$(u["label"])\" (for `$k`)")
    end
    found[sha] = path
    return path
end

"""
    load_scenario(ex, user, bytes) -> Dict("label", "params", "inputs", "notes")

A scenario's zip (a run's Scenario or Excel download) for the New run form:
its values and tables, checked; its input sheets as choices, its workbooks
uploaded (or found among the user's); notes on what changed since or was
left out.
"""
function load_scenario(ex::Explorer, user, bytes::AbstractVector{UInt8})
    limit_mb = ex.settings["max_upload_mb"]
    length(bytes) > 4 * limit_mb * 2^20 && throw(ArgumentError("the file is larger than $(4limit_mb) MB"))
    _zip_unpacked_size(bytes) > UNPACKED_PER_MB * max(length(bytes), 2^20) &&
        throw(ArgumentError("this file unpacks to far more than a scenario of its size would"))
    z = try
        ZipArchives.ZipReader(bytes)
    catch
        throw(ArgumentError("this isn't a .zip file"))
    end
    "scenario.json" in ZipArchives.zip_names(z) ||
        throw(ArgumentError("no scenario.json in this zip: load the zip a run's Scenario (or Excel) button downloads"))
    s = try
        _plain(JSON3.read(ZipArchives.zip_readentry(z, "scenario.json", String)))
    catch
        throw(ArgumentError("its scenario.json can't be read"))
    end
    (s isa Dict && get(s, "format", "") == SCENARIO_FORMAT) || throw(ArgumentError("its scenario.json isn't an explorer's scenario"))
    get(s, "version", 0) == 1 || throw(ArgumentError("a scenario of a newer explorer: update this one to load it"))
    label = string(get(s, "label", "Scenario"))
    notes = String[]
    _compare_model!(notes, ex.record, get(s, "model", nothing))
    params = Dict{String,Any}()
    for (k, v) in get(s, "params", Dict())
        try
            _run_args(ex, [k => v], ())
            params[k] = _kept(v)
        catch e
            e isa ArgumentError || rethrow()
            push!(notes, "left out: " * e.msg)
        end
    end
    inputs = Dict{String,String}()
    found = Dict{String,String}()                 # sha => path (one upload for inputs that share a workbook)
    for (k, e) in get(s, "inputs", Dict())
        e isa Dict && haskey(e, "sheet") || continue
        haskey(ex.model.inputs, Symbol(k)) && ex.model.inputs[Symbol(k)] isa ExcelSheet ||
            (push!(notes, "`$k` isn't an input sheet of this model: left out"); continue)
        path = if get(e, "from", "") == "model"
            p = findfirst(f -> basename(f) == get(e, "file", ""), collect(_own_files(ex)))
            p === nothing && push!(notes, "`$k`: the model has no file $(get(e, "file", "")) now: its sheet instead")
            p === nothing ? nothing : collect(_own_files(ex))[p]
        else
            _scenario_sheet!(ex, user, k, e, z, label, found, notes)
        end
        path === nothing && continue
        choices, _ = input_choices(ex, user)
        if any(==((path, e["sheet"])), get(choices, k, Tuple{String,String}[]))
            inputs[k] = _choice_id((path, e["sheet"]))
        else
            push!(notes, "`$k`: no sheet $(e["sheet"]) in $(get(e, "file", basename(path))) to choose: the model's sheet instead")
        end
    end
    return Dict("label" => label, "params" => params, "inputs" => inputs, "notes" => notes)
end

# notes on how the model that ran a scenario differs from this one
function _compare_model!(notes, now, then)
    if then === nothing
        push!(notes, "the scenario doesn't record which model ran it (an older run): its results may differ")
        return notes
    end
    then isa Dict || return notes
    if get(then, "fingerprint", "") != now["fingerprint"]
        a, b = get(then, "files", Dict()), now["files"]
        changed = sort!([f for f in keys(b) if haskey(a, f) && a[f] != b[f]])
        added = sort!([f for f in keys(b) if !haskey(a, f)])
        gone = sort!([f for f in keys(a) if !haskey(b, f)])
        parts = String[]
        isempty(changed) || push!(parts, "changed: " * join(changed, ", "))
        isempty(added) || push!(parts, "new: " * join(added, ", "))
        isempty(gone) || push!(parts, "no longer there: " * join(gone, ", "))
        push!(notes, "another version of the model ran it (" * join(parts, "; ") * "): its results may differ")
    end
    v = get(then, "pysd", "")
    v == now["pysd"] || isempty(v) || push!(notes, "PySD.jl $v ran it; this is $(now["pysd"])")
    return notes
end
