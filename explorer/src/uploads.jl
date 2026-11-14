# Uploaded sheets: a user's own version of one of the model's Excel files
# (other values, another scenario), whose sheets can then replace the model's
# in a run.  Kept in dir/inputs: <id>.xlsx and <id>.json (who, what it
# replaces, its sheets); private until shared, as runs.

const UNPACKED_PER_MB = 20      # an .xlsx unpacks to at most 20 × its size here (a "zip bomb" doesn't)

_uploads_dir(ex) = (d = joinpath(ex.dir, "inputs"); mkpath(d); d)

# the model's Excel files, by their stem ("scen_w" for scen_w.xlsx)
_model_files(ex) = sort!(unique([lowercase(splitext(basename(v.path))[1]) for v in values(ex.model.inputs) if v isa ExcelSheet]))

function _load_uploads!(ex::Explorer)
    for f in readdir(_uploads_dir(ex); join = true)
        endswith(f, ".json") || continue
        try
            u = _plain(JSON3.read(read(f, String)))
            isfile(joinpath(_uploads_dir(ex), u["file"])) && (ex.uploads[u["id"]] = u)
        catch e
            @warn "can't read the upload in $f" exception = e
        end
    end
end

uploads_info(ex::Explorer, user) =
    sort!([u for u in values(ex.uploads) if visible(ex, user, u)]; by = u -> u["id"])

# The bytes of a ZIP file (an .xlsx is one): its entries' unpacked size in
# all, read from its central directory without unpacking anything.
function _zip_unpacked_size(b::AbstractVector{UInt8})
    n = length(b)
    bad() = throw(ArgumentError("this isn't an .xlsx file"))
    (n >= 22 && b[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04]) || bad()
    rd16(p) = (p + 1 <= n || bad(); Int(b[p]) | Int(b[p+1]) << 8)
    rd32(p) = rd16(p) | rd16(p + 2) << 16
    eocd = 0
    for k in n-21:-1:max(1, n - 65557)              # the end of central directory record, last
        if b[k] == 0x50 && b[k+1] == 0x4b && b[k+2] == 0x05 && b[k+3] == 0x06
            eocd = k; break
        end
    end
    eocd == 0 && bad()
    entries, p = rd16(eocd + 10), rd32(eocd + 16) + 1
    total = 0
    for _ in 1:entries
        rd32(p) == 0x02014b50 || bad()
        size = rd32(p + 24)
        size == 0xffffffff && throw(ArgumentError("this file is too large"))      # (ZIP64)
        total += size
        p += 46 + rd16(p + 28) + rd16(p + 30) + rd16(p + 32)
    end
    return total
end

"""
    upload!(ex, user, bytes; replaces, label) -> the upload's description

A version of the model's Excel file `replaces` (its stem, `"scen_w"`),
checked: an .xlsx file that opens, within the administrators' limits.
"""
function upload!(ex::Explorer, user, bytes::AbstractVector{UInt8}; replaces::AbstractString, label::AbstractString = "")
    stems = _model_files(ex)
    replaces in stems || throw(ArgumentError("`$replaces` isn't one of the model's Excel files ($(join(stems, ", ")))"))
    admin = is_admin(ex, user)
    limit_mb = ex.settings["max_upload_mb"]
    length(bytes) > limit_mb * 2^20 && throw(ArgumentError("the file is larger than $limit_mb MB"))
    if !admin
        mine = count(u -> u["owner"] == user, values(ex.uploads))
        mine >= ex.settings["max_uploads_per_user"] &&
            throw(ArgumentError("you keep $mine uploaded files, the most you can: delete some to upload more"))
    end
    _zip_unpacked_size(bytes) > UNPACKED_PER_MB * max(length(bytes), 2^20) &&
        throw(ArgumentError("this file unpacks to far more than an .xlsx file of its size would"))
    id = _new_id()
    file = "$(replaces)__$(id).xlsx"                 # (named like the model's file: it can replace its sheets)
    path = joinpath(_uploads_dir(ex), file)
    write(path, bytes)
    sheets = try
        XLSX.openxlsx(path) do xf
            String.(XLSX.sheetnames(xf))
        end
    catch
        rm(path; force = true)
        throw(ArgumentError("this file can't be read as an .xlsx file"))
    end
    u = Dict{String,Any}("id" => id, "file" => file, "replaces" => replaces, "owner" => user, "shared" => false,
                         "label" => isempty(strip(label)) ? "$(replaces).xlsx, $(user)'s" : String(strip(label)),
                         "sheets" => sheets, "bytes" => length(bytes),
                         "created" => Dates.format(now(), "yyyy-mm-dd HH:MM"))
    open(io -> JSON3.write(io, u), joinpath(_uploads_dir(ex), id * ".json"), "w")
    lock(() -> (ex.uploads[id] = u), ex.lock)
    return u
end

function _changeable_upload(ex, user, id)
    u = get(ex.uploads, id, nothing)
    (u === nothing || !visible(ex, user, u)) && throw(KeyError(id))
    may_change(ex, user, u) || throw(Forbidden("only who uploaded it can change this file"))
    return u
end

function change_upload!(ex::Explorer, user, id, change)
    u = _changeable_upload(ex, user, id)
    haskey(change, :label) && (u["label"] = String(change[:label]))
    if haskey(change, :shared)
        change[:shared] isa Bool || throw(ArgumentError("shared is true or false"))
        u["shared"] = change[:shared]
    end
    open(io -> JSON3.write(io, u), joinpath(_uploads_dir(ex), id * ".json"), "w")
    return u
end

function delete_upload!(ex::Explorer, user, id)
    u = _changeable_upload(ex, user, id)
    # (a run that read it keeps it: what made its results stays on the server)
    path = joinpath(_uploads_dir(ex), u["file"])
    using_it = [r for r in values(ex.runs) if any(c -> first(_split_choice(c)) == path, values(r.meta["inputs"]))]
    if !isempty(using_it)
        seen = sort!(["\"$(r.meta["label"])\"" for r in using_it if visible(ex, user, r.meta)])
        others = length(using_it) - length(seen)
        throw(ArgumentError("runs read this file: " * join(seen, ", ") *
                            (others == 0 ? "" : (isempty(seen) ? "" : " and ") * "$others of other people") *
                            ". It stays while they do: delete those runs first (their Scenario download keeps a copy of it)"))
    end
    lock(() -> delete!(ex.uploads, id), ex.lock)
    rm(joinpath(_uploads_dir(ex), u["file"]); force = true)
    rm(joinpath(_uploads_dir(ex), id * ".json"); force = true)
    return true
end

# the sheets a user may choose for each input: the model's, those of input_dirs,
# and those of the uploads they see (of the input's file), with their labels
function input_choices(ex::Explorer, user)
    notes = r"^(readme|info|notes?)\b"i
    out = Dict{String,Vector{Tuple{String,String}}}()
    labels = Dict{String,String}()
    mine = uploads_info(ex, user)
    for (k, cs) in ex.inputs
        v = ex.model.inputs[Symbol(k)]
        stem = lowercase(splitext(basename(v.path))[1])
        choices = copy(cs)
        for u in mine
            u["replaces"] == stem || continue
            f = joinpath(_uploads_dir(ex), u["file"])
            labels[f] = u["label"] * (u["owner"] == user ? "" : " (by $(u["owner"]))")
            for s in u["sheets"]
                occursin(notes, s) || push!(choices, (f, s))
            end
        end
        out[k] = choices
    end
    return out, labels
end

function inputs_info(ex::Explorer, user)
    choices, labels = input_choices(ex, user)
    label((f, s)) = haskey(labels, f) ? labels[f] * " › " * s : _choice_label((f, s))
    return Dict(k => [Dict("id" => _choice_id(c), "label" => label(c)) for c in cs] for (k, cs) in choices)
end
