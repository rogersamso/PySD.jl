# Compare every column of a Vensim reference output (SDXorg/test-models) with
# a model's results: the number of values compared and the largest relative
# error (relative to `floor` at least, for values that cancel to nearly zero).
const _CONTROL = Set(["time", "initial_time", "final_time", "time_step", "saveper"])
_clean(s) = replace(lowercase(strip(s)), r"[^a-z0-9]+" => "_")

function compare_reference(res, ref_file; floor = 1e-6, renames = Dict{Symbol,Symbol}())
    sep = endswith(ref_file, ".tab") ? '\t' : ','
    lines = split(replace(read(ref_file, String), r"\r\n?" => "\n"), '\n'; keepempty = false)
    header = [strip(strip(h), '"') for h in split(lines[1], sep)]
    rows = [split(l, sep) for l in lines[2:end]]
    worst, compared, missing = 0.0, 0, String[]
    for (c, col) in enumerate(header)
        name = Symbol(_clean(split(col, "[")[1]))
        string(name) in _CONTROL && continue
        name = get(renames, name, name)             # names the DSL had to change
        haskey(res, name) || (push!(missing, col); continue)
        labels = occursin("[", col) ? Symbol.(_clean.(split(rstrip(split(col, "[")[2], ']'), ","))) : Symbol[]
        vals = res[name]
        for row in rows
            isempty(strip(row[c])) && continue
            tref = parse(Float64, row[1])
            i = argmin(abs.(res.time .- tref))
            v = vals isa AbstractVector && !(vals isa AbstractDimArray) && length(vals) == length(res.time) ? vals[i] : vals
            x = isempty(labels) ? Float64(v) : Float64(v[At.(labels)...])
            ref = parse(Float64, row[c])
            worst = max(worst, abs(x - ref) / max(abs(ref), floor))
            compared += 1
        end
    end
    return (; compared, worst, missing)
end
