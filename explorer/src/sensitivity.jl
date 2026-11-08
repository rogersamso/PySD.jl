# Sensitivity: elasticities at the end of the run, one parameter at a time
# (the % a result changes when the parameter is `step` higher, the others as in
# the run it starts from).  An analysis keeps its table only, not its runs.
# Also a table from a file (a row per parameter, a column per result).

_looks_like_year(x) = x isa Real && isinteger(x) && 1900 <= x <= 2200

function _sensitivity_file(path, row)
    lines = filter(!isempty, readlines(path))
    header = split(lines[1], '\t')
    num(s) = tryparse(Float64, s)
    outputs = [String(h) for h in header if haskey(row, Symbol(h)) && !(h in ("parameter", "value"))]
    rows = Any[]
    for l in lines[2:end]
        r = split(l, '\t')
        length(r) == length(header) || continue
        d = Dict{String,Any}("parameter" => String(r[1]))
        for (h, x) in zip(header, r)
            h in outputs && (v = num(x); d[h] = v === nothing || !isfinite(v) ? nothing : v)
            h == "value" && (d["value"] = num(x))
        end
        push!(rows, d)
    end
    return Dict{String,Any}("id" => "file", "label" => "From $(basename(path))", "owner" => "", "shared" => true,
                            "created" => Dates.format(unix2datetime(mtime(path)), "yyyy-mm-dd HH:MM"),
                            "around" => "", "step" => 0.01, "outputs" => outputs, "rows" => rows,
                            "skipped" => Any[], "file" => basename(path))
end

function _load_analyses!(ex::Explorer)
    for f in readdir(joinpath(ex.dir, "analyses"); join = true)
        endswith(f, ".json") || continue
        try
            a = _plain(JSON3.read(read(f, String)))
            ex.analyses[a["id"]] = a
        catch e
            @warn "can't read the analysis in $f" exception = e
        end
    end
end

# JSON3's objects as Dicts and Vectors, to change and write again
_plain(x::JSON3.Object) = Dict{String,Any}(String(k) => _plain(v) for (k, v) in x)
_plain(x::JSON3.Array) = Any[_plain(v) for v in x]
_plain(x) = x

_summary(a) = Dict(k => v for (k, v) in a if k != "rows")

analyses_info(ex::Explorer, user) =
    sort!([_summary(a) for a in values(ex.analyses) if visible(ex, user, a)]; by = a -> a["id"])

function analysis(ex::Explorer, user, id)
    a = get(ex.analyses, id, nothing)
    (a === nothing || !visible(ex, user, a)) && throw(KeyError(id))
    return a
end

# the results an analysis reads at the end of the run: names of stocks and
# variables, an element each ("x[a,b]")
function _final_values(ex, r::Results, outputs)
    labels, values = String[], Float64[]
    for o in outputs
        x = r[o][end]
        if x isa Real
            push!(labels, String(o)); push!(values, Float64(x))
        else
            append!(labels, [string(o, "[", e, "]") for e in _element_labels(ex, o)])
            append!(values, _flat(parent(x)))
        end
    end
    return labels, values
end

"""
    submit_analysis!(ex, user; label, around, params, outputs, step = 0.01, years = false) -> Job

A sensitivity analysis around the run `around` (its parameters and sheets;
`""` the model's), queued: each parameter in `params` `step` higher in turn
(an array: all its elements), the elasticity of each result in `outputs` at
the end of the run.  Parameters that are 0 have no elasticity; years
(whole numbers from 1900 to 2200) are left out unless `years`.
"""
function submit_analysis!(ex::Explorer, user; label = "", around = "", params, outputs, step = 0.01, years = false)
    admin = is_admin(ex, user)
    names = unique(Symbol.(params))
    isempty(names) && throw(ArgumentError("pick the parameters to change"))
    for n in names
        haskey(ex.editable, n) || throw(ArgumentError("`$n` is not a parameter that can change"))
    end
    limit = ex.settings["max_params_per_analysis"]
    !admin && length(names) > limit && throw(ArgumentError("$(length(names)) parameters: at most $limit in an analysis"))
    outs = unique(Symbol.(outputs))
    isempty(outs) && throw(ArgumentError("pick the results to look at"))
    length(outs) > 50 && throw(ArgumentError("at most 50 results in an analysis"))
    for o in outs
        (haskey(ex.row, o) && ex.vars.kind[ex.row[o]] in (:stock, :aux)) ||
            throw(ArgumentError("`$o` is not a stock or a variable of the model"))
    end
    (step isa Real && 0 < abs(step) <= 0.5) || throw(ArgumentError("step is a fraction, e.g. 0.01 for 1 %"))
    if !admin
        mine = count(a -> a["owner"] == user, values(ex.analyses)) +
               count(j -> j.user == user && j.kind == "analysis" && j.status in (:queued, :running), ex.jobs)
        mine >= ex.settings["max_analyses_per_user"] &&
            throw(ArgumentError("you keep $mine analyses, the most you can: delete some to make more"))
    end
    base = isempty(around) ? nothing : _visible_run(ex, user, String(around))
    ps, ins, _, _ = _run_args(ex, base === nothing ? Dict() : base.meta["params"],
                              base === nothing ? Dict() : base.meta["inputs"])
    label = isempty(strip(label)) ? "Analysis $(count(a -> a["owner"] == user, values(ex.analyses)) + 1)" : String(label)
    return submit!(ex, user, "analysis", label) do job
        _analyse(ex, job; label, owner = user, around = String(around), names, outs, ps, ins, step = Float64(step), years)
    end
end

function _analyse(ex, job; label, owner, around, names, outs, ps, ins, step, years)
    t = time()
    given = Dict(ps)
    value(n) = haskey(given, n) ? given[n] : (haskey(ex.sizes, n) ? _unflat(ex.editable[n], ex.sizes[n]) : ex.editable[n])
    labels, y0 = _final_values(ex, _simulate(ex, ps, ins), outs)
    rows, skipped = Any[], Any[]
    for (k, n) in enumerate(names)
        job.cancel[] && throw(Cancelled())
        x = value(n)
        if all(iszero, x)
            push!(skipped, Dict("parameter" => String(n), "why" => "it is 0"))
        elseif !years && _looks_like_year(x)
            push!(skipped, Dict("parameter" => String(n), "why" => "a year"))
        else
            moved = [p for p in ps if first(p) !== n]
            push!(moved, n => x .* (1 + step))
            _, y = _final_values(ex, _simulate(ex, moved, ins), outs)
            row = Dict{String,Any}("parameter" => String(n), "value" => x isa Real ? x : nothing)
            for (l, a, b) in zip(labels, y0, y)
                e = (b - a) / a / step
                row[l] = a == 0 || !isfinite(e) ? nothing : e
            end
            push!(rows, row)
        end
        job.progress = k / length(names)
    end
    id = _new_id()
    a = Dict{String,Any}("id" => id, "label" => label, "owner" => owner, "shared" => false,
                         "created" => Dates.format(now(), "yyyy-mm-dd HH:MM"), "around" => around, "step" => step,
                         "outputs" => labels, "rows" => rows, "skipped" => skipped,
                         "seconds" => round(time() - t; digits = 1))
    open(io -> JSON3.write(io, a), joinpath(ex.dir, "analyses", id * ".json"), "w")
    lock(() -> (ex.analyses[id] = a), ex.lock)
    return id
end

function _changeable_analysis(ex, user, id)
    a = analysis(ex, user, id)
    id == "file" && throw(Forbidden("the analysis from a file can't be changed here"))
    may_change(ex, user, a) || throw(Forbidden("only its author can change this analysis"))
    return a
end

function change_analysis!(ex::Explorer, user, id, change)
    a = _changeable_analysis(ex, user, id)
    haskey(change, :label) && (a["label"] = String(change[:label]))
    if haskey(change, :shared)
        change[:shared] isa Bool || throw(ArgumentError("shared is true or false"))
        a["shared"] = change[:shared]
    end
    open(io -> JSON3.write(io, a), joinpath(ex.dir, "analyses", id * ".json"), "w")
    return a
end

function delete_analysis!(ex::Explorer, user, id)
    _changeable_analysis(ex, user, id)
    lock(() -> delete!(ex.analyses, id), ex.lock)
    rm(joinpath(ex.dir, "analyses", id * ".json"); force = true)
    return true
end
