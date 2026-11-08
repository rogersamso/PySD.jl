# Runs: what a run may change, run, save (a .json and a .f64 file each), load,
# list, share, rename, delete; a name's values in some runs.

# A run's parameters and input sheets as run_model takes them, checked: only
# the model's parameters, numbers of the right shape, the listed sheets.
function _run_args(ex::Explorer, params, inputs; user = "local")
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
            throw(ArgumentError("`$k`: a number, or $(prod(get(ex.sizes, n, (1,)))) numbers"))
        end
    end
    ins = Pair{Symbol,Any}[]
    kept = Dict{String,Any}()
    isempty(inputs) || refresh_inputs!(ex)
    all_choices = isempty(inputs) ? ex.inputs : first(input_choices(ex, user))     # (the user's uploads too)
    for (k, id) in inputs
        choices = get(all_choices, String(k), nothing)
        choices === nothing && throw(ArgumentError("`$k` is not an input sheet"))
        c = findfirst(c -> _choice_id(c) == id, choices)
        c === nothing && throw(ArgumentError("`$(split(id, '|')[end])` of that file isn't a sheet you can use for `$k` (deleted, or not shared?)"))
        c == 1 && continue
        push!(ins, Symbol(k) => PySD.excel(choices[c]...))
        kept[String(k)] = String(id)
    end
    return ps, ins, Dict{String,Any}(string(k) => (v isa AbstractVector ? collect(v) : v) for (k, v) in params), kept
end

_simulate(ex::Explorer, ps, ins) = Base.invokelatest(run_model, ex.model; params = (; ps...), inputs = (; ins...))

"""
    submit_run!(ex, user, label, params, inputs) -> Job

A run, checked now and queued: it starts when a simulation slot is free.
"""
function submit_run!(ex::Explorer, user, label, params, inputs)
    ps, ins, kept_params, kept_inputs = _run_args(ex, params, inputs; user)
    if !is_admin(ex, user)
        mine = count(r -> r.meta["owner"] == user, values(ex.runs)) +
               count(j -> j.user == user && j.kind == "run" && j.status in (:queued, :running), ex.jobs)
        limit = ex.settings["max_runs_per_user"]
        mine >= limit && throw(ArgumentError("you keep $mine runs, the most you can: delete some to run more"))
    end
    label = isempty(strip(label)) ? "Run $(count(r -> r.meta["owner"] == user, values(ex.runs)) + 1)" : String(label)
    return submit!(ex, user, "run", label) do job
        t = @elapsed r = _simulate(ex, ps, ins)
        _save!(ex, r; label, owner = user, shared = false, params = kept_params, inputs = kept_inputs, seconds = t).meta["id"]
    end
end

_new_id() = Dates.format(now(), "yyyymmdd-HHMMSS") * "-" * randstring(['a':'z'; '0':'9'], 5)

function _save!(ex::Explorer, r::Results; label, owner, shared, params = Dict{String,Any}(),
                inputs = Dict{String,Any}(), seconds = 0.0)
    cols = Tables.columns(r)
    names = [String(n) for n in Tables.columnnames(cols) if n !== :time]
    data = Matrix{Float64}(undef, length(r.time), length(names))
    for j in eachindex(names)
        _copy!(view(data, :, j), Tables.getcolumn(cols, j + 1))     # (column 1 is the time)
    end
    id = _new_id()
    meta = Dict{String,Any}("id" => id, "label" => label, "owner" => owner, "shared" => shared,
                            "created" => Dates.format(now(), "yyyy-mm-dd HH:MM"), "params" => params,
                            "inputs" => inputs, "seconds" => round(seconds; digits = 2), "time" => r.time,
                            "columns" => names)
    base = joinpath(ex.dir, "runs", id)
    write(base * ".f64", data)
    open(io -> JSON3.write(io, meta), base * ".json", "w")
    run = _run(meta, names, data)
    lock(() -> (ex.runs[id] = run), ex.lock)
    return run
end

# (a function barrier: compiled for each column's type)
function _copy!(out, c)
    for i in eachindex(out, c)
        x = c[i]
        out[i] = x isa Real ? Float64(x) : NaN
    end
end

function _load_runs!(ex::Explorer)
    for f in readdir(joinpath(ex.dir, "runs"); join = true)
        endswith(f, ".json") || continue
        try
            r = _load(f)
            ex.runs[r.meta["id"]] = r
        catch e
            @warn "can't read the run in $f" exception = e
        end
    end
end

function _load(file)
    meta = Dict{String,Any}(String(k) => v for (k, v) in JSON3.read(read(file, String)))
    names = String.(meta["columns"])
    meta["time"] = Float64.(meta["time"])
    meta["params"] = Dict{String,Any}(String(k) => (v isa AbstractVector ? collect(v) : v) for (k, v) in meta["params"])
    meta["inputs"] = Dict{String,Any}(String(k) => String(v) for (k, v) in meta["inputs"])
    # runs saved before there were users: everyone's
    meta["owner"] = String(get(meta, "owner", ""))
    meta["shared"] = get(meta, "shared", true) === true
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

runs_info(ex::Explorer, user) =
    sort!([_public(r) for r in values(ex.runs) if visible(ex, user, r.meta)]; by = r -> r["id"])

# a run the user may see (a KeyError for "not found" either way: nothing told about others' runs)
function _visible_run(ex::Explorer, user, id)
    r = get(ex.runs, id, nothing)
    (r === nothing || !visible(ex, user, r.meta)) && throw(KeyError(id))
    return r
end

function _changeable_run(ex::Explorer, user, id)
    r = _visible_run(ex, user, id)
    may_change(ex, user, r.meta) || throw(Forbidden("only its author can change this run"))
    return r
end

function delete_run!(ex::Explorer, user, id)
    _changeable_run(ex, user, id)
    lock(() -> delete!(ex.runs, id), ex.lock)
    base = joinpath(ex.dir, "runs", id)
    rm(base * ".json"; force = true); rm(base * ".f64"; force = true)
    return true
end

function change_run!(ex::Explorer, user, id, change)
    r = _changeable_run(ex, user, id)
    haskey(change, :label) && (r.meta["label"] = String(change[:label]))
    if haskey(change, :shared)
        change[:shared] isa Bool || throw(ArgumentError("shared is true or false"))
        r.meta["shared"] = change[:shared]
    end
    open(io -> JSON3.write(io, r.meta), joinpath(ex.dir, "runs", id * ".json"), "w")
    return r
end

"""
    run_csv(ex, user, id) -> String

A run's results as CSV: a row per name (an array: a row per element,
`x[a,b]`), its unit, then its value at each time; first, the run's label
and what it changed.
"""
function run_csv(ex::Explorer, user, id)
    r = _visible_run(ex, user, id)
    q(x) = (x = string(x); any(c -> c in (',', '"', '\n', '\r'), x) ? "\"" * replace(x, "\"" => "\"\"") * "\"" : x)
    num(x) = isfinite(x) ? string(x) : ""
    io = IOBuffer()
    changes = join(vcat(["$k = $(v isa AbstractVector ? "[" * join(v, " ") * "]" : v)" for (k, v) in sort!(collect(r.meta["params"]))],
                        ["$k: $(split(v, '|')[end])" for (k, v) in sort!(collect(r.meta["inputs"]))]), "; ")
    println(io, "# ", q(r.meta["label"]), " (", r.meta["created"], isempty(r.meta["owner"]) ? "" : ", " * r.meta["owner"], ")",
            isempty(changes) ? "" : ": " * changes)
    println(io, join(["name", "unit", (num(t) for t in r.meta["time"])...], ","))
    for (j, n) in enumerate(r.columns)
        k = findfirst('[', n)
        row = get(ex.row, Symbol(k === nothing ? n : n[1:k-1]), nothing)
        unit = row === nothing ? "" : ex.vars.unit[row]
        print(io, q(n), ",", q(unit === nothing ? "" : unit))
        for i in axes(r.data, 1)
            print(io, ",", num(r.data[i, j]))
        end
        println(io)
    end
    return String(take!(io))
end

# a name's values in some runs: its elements' labels, a vector per element per run
function series(ex::Explorer, user, name, ids)
    runs = Dict{String,Any}()
    labels, time = String[], Float64[]
    for id in ids
        r = get(ex.runs, id, nothing)
        (r === nothing || !visible(ex, user, r.meta)) && continue
        cols = get(r.index, name, Int[])
        isempty(cols) && continue
        time = r.meta["time"]
        labels = [(k = findfirst('[', r.columns[j]); k === nothing ? "" : r.columns[j][k+1:end-1]) for j in cols]
        runs[id] = [_finite(view(r.data, :, j)) for j in cols]
    end
    return Dict("name" => name, "time" => time, "elements" => labels, "runs" => runs)
end

# ---------------------------------------------------------------------------
# saved views: what the page shows, by name, each user's own

function _views_dir(ex, user)
    d = joinpath(ex.dir, "views", user)
    mkpath(d)
    return d
end
_view_file(ex, user, name) = joinpath(_views_dir(ex, user), replace(name, r"[^\w\- ]" => "_") * ".json")

views_info(ex::Explorer, user) =
    [JSON3.read(read(f, String)) for f in readdir(_views_dir(ex, user); join = true) if endswith(f, ".json")]
