# The model: built from its file, its parameters, its code, its input sheets,
# and what the page reads first about it.

function _build(path)
    mod = Module()
    Core.eval(mod, :(using PySD, DimensionalData))
    Core.eval(mod, :(include(p) = Base.include($mod, p)))
    m = Base.include(mod, abspath(path))
    m isa Model || error("$path doesn't end with a Model")
    return m
end

# the parameters a run can change: numbers and arrays of numbers (not lookups,
# not those that fix the structure of an operator)
function _editable(m::Model, vars, base::Results)
    editable, sizes, tables = Dict{Symbol,Any}(), Dict{Symbol,Tuple}(), Dict{Symbol,Tuple{Vector{Any},Tuple}}()
    for (i, n) in enumerate(vars.name)
        (vars.kind[i] === :parameter && !haskey(m.structural, n)) || continue
        x = getfield(base.par, m.byname[n].id)      # (not base[n]: arrays of lookups aren't DimArrays)
        if x isa Real
            editable[n] = Float64(x)
        elseif x isa AbstractArray{<:Real}
            editable[n] = _flat(x)
            sizes[n] = size(x)
        elseif (tb = _as_table(x)) !== nothing
            tables[n] = tb
        end
    end
    return editable, sizes, tables
end

# an array's values, the first dimension slowest (as the tables' columns)
function _flat(x::AbstractArray)
    sz = size(x)
    return vec(Float64[x[reverse(Tuple(J))...] for J in CartesianIndices(reverse(sz))])
end
function _unflat(v::AbstractVector, sz::Tuple)
    A = Array{eltype(v)}(undef, sz)
    for (k, J) in enumerate(CartesianIndices(reverse(sz)))
        A[reverse(Tuple(J))...] = v[k]
    end
    return A
end

# the labels of an array's elements, in the same order ("a,b")
function _element_labels(ex, name::Symbol)
    els = ex.vars.elements[ex.row[name]]
    out = [String[]]
    for es in els
        out = [vcat(p, e) for p in out for e in es]
    end
    return [join(x, ",") for x in out]
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
    for d in unique(dirname.(files)), f in readdir(d; join = true)
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
# (scen_w.xlsx: scen_w.xlsx, scen_w_high.xlsx…), in input_dirs; sheets of
# notes (Readme, Info…) are left out.
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
# what the page reads first: the model

function model_info(ex::Explorer)
    v = ex.vars
    m = ex.model
    names = [Dict("name" => String(v.name[i]), "title" => v.title[i], "set" => v.set[i], "kind" => String(v.kind[i]),
                  "unit" => v.unit[i], "description" => v.description[i],
                  "limits" => v.limits[i] === nothing ? nothing : [isfinite(x) ? x : nothing for x in v.limits[i]],
                  "dims" => String.(collect(v.dims[i])), "elements" => [collect(e) for e in v.elements[i]],
                  "value" => _json(get(ex.editable, v.name[i], nothing)),
                  "table" => haskey(ex.tables, v.name[i]),
                  "code" => [[f, l] for (f, l) in get(ex.sources, v.name[i], Tuple{String,Int}[])])
             for i in eachindex(v.name)]
    return Dict("title" => ex.title, "time_unit" => string(m.time_unit), "t0" => m.t0, "tf" => m.tf,
                "separator" => ex.separator, "names" => names, "inputs" => inputs_info(ex),
                "code" => !isempty(ex.code))
end

_json(::Nothing) = nothing
_json(x::Real) = isfinite(x) ? x : nothing
_json(x::AbstractVector) = _finite(x)
_finite(v) = [isfinite(x) ? x : nothing for x in v]
