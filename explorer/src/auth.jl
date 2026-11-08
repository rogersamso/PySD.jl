# Logins, with users = :password: the explorer keeps its users (passwords as
# PBKDF2-HMAC-SHA256 hashes) in dir/users.json, and their sessions (a random
# token in a cookie; only its SHA-256 kept) in dir/sessions.json.
#
# - a login takes the hash's time whether the user exists or not;
# - 5 failed logins for a name, or 20 from an address, in 15 minutes block
#   more for 15 minutes;
# - sessions end after 14 days without use, or 30 days in all, and when the
#   user's password changes or the user is removed;
# - cookies are HttpOnly, SameSite=Strict and (unless secure_cookies = false,
#   for trying it out without HTTPS) Secure; requests that change something
#   must carry the header X-PySD-Request, which other sites' pages can't send.

const ITERATIONS = 600_000
const MIN_PASSWORD = 10
const SESSION_IDLE = Day(14)
const SESSION_MAX = Day(30)
const FAIL_WINDOW = Minute(15)
const FAILS_PER_NAME = 5
const FAILS_PER_ADDRESS = 20
const COOKIE = "pysd_session"

struct NotLoggedIn <: Exception end

const RNG = Random.RandomDevice()      # the system's random source, for salts, tokens and passwords

function _pbkdf2(password::AbstractString, salt::Vector{UInt8}, iterations::Int)
    key = Vector{UInt8}(codeunits(password))
    length(key) > 64 && (key = SHA.sha256(key))
    k = vcat(key, zeros(UInt8, 64 - length(key)))
    inner = SHA.SHA256_CTX(); SHA.update!(inner, k .⊻ 0x36)
    outer = SHA.SHA256_CTX(); SHA.update!(outer, k .⊻ 0x5c)
    function mac(data)
        c = copy(inner); SHA.update!(c, data); h = SHA.digest!(c)
        c = copy(outer); SHA.update!(c, h); return SHA.digest!(c)
    end
    u = mac(vcat(salt, UInt8[0, 0, 0, 1]))
    t = copy(u)
    for _ in 2:iterations
        u = mac(u)
        t .⊻= u
    end
    return t
end

"""
    password_hash(password) -> String

`"pbkdf2-sha256\$iterations\$salt\$hash"` (salt and hash in base64).
"""
function password_hash(password::AbstractString; iterations = ITERATIONS)
    salt = rand(RNG, UInt8, 16)
    return join(("pbkdf2-sha256", iterations, base64encode(salt), base64encode(_pbkdf2(password, salt, iterations))), '$')
end

function password_matches(password::AbstractString, stored::AbstractString)
    parts = split(stored, '$')
    (length(parts) == 4 && parts[1] == "pbkdf2-sha256") || return false
    n = tryparse(Int, parts[2])
    n === nothing && return false
    return _same(_pbkdf2(password, base64decode(parts[3]), n), base64decode(parts[4]))
end

# equal, in a time that doesn't tell where they differ
_same(a, b) = length(a) == length(b) && reduce(|, a .⊻ b; init = 0x00) == 0x00

new_password() = String(rand(RNG, ['a':'z'; 'A':'Z'; '2':'9'], 16))     # (no 0/O, 1/l to confuse)

_token_key(token) = bytes2hex(SHA.sha256(token))
_valid_name(u) = occursin(r"^[\w.@-]{1,64}$", u) && u != "local"

# ---------------------------------------------------------------------------
# the files: users and sessions, read again when another process changed them

_users_file(dir) = joinpath(dir, "users.json")
_sessions_file(dir) = joinpath(dir, "sessions.json")

function _read_json_dict(f)
    isfile(f) || return Dict{String,Dict{String,Any}}()
    return Dict{String,Dict{String,Any}}(String(k) => _plain(v) for (k, v) in JSON3.read(read(f, String)))
end

function _write_atomic(f, x)
    tmp = f * ".tmp"
    open(tmp, "w") do io
        chmod(tmp, 0o600)
        JSON3.write(io, x)
    end
    mv(tmp, f; force = true)
end

"""
    load_users(dir) / save_users(dir, users)

The users of an explorer kept in `dir`: name => (hash, admin, created,
last_login).  For a script on the server (deploy/users.jl) as well.
"""
load_users(dir) = _read_json_dict(_users_file(dir))
save_users(dir, users) = _write_atomic(_users_file(dir), users)

"""
    set_password!(dir, name, password; admin = nothing) -> users

Create `name` with `password`, or give an existing user a new one; `admin`
true or false changes whether they are an administrator.  Their sessions end.
"""
function set_password!(dir, name, password; admin = nothing)
    _valid_name(name) || throw(ArgumentError("a user name is letters, digits, `.`, `_`, `-` or `@`"))
    length(password) >= MIN_PASSWORD || throw(ArgumentError("a password has at least $MIN_PASSWORD characters"))
    users = load_users(dir)
    u = get!(() -> Dict{String,Any}("admin" => false, "created" => Dates.format(now(), "yyyy-mm-dd HH:MM"),
                                    "last_login" => nothing), users, name)
    u["hash"] = password_hash(password)
    admin === nothing || (u["admin"] = admin)
    save_users(dir, users)
    _end_sessions!(dir, name)
    return users
end

function _end_sessions!(dir, name)
    f = _sessions_file(dir)
    s = _read_json_dict(f)
    filter!(kv -> last(kv)["user"] != name, s)
    _write_atomic(f, s)
end

# the explorer's copies of the files, fresh
function _refresh_auth!(ex::Explorer)
    for (key, f) in (("users", _users_file(ex.dir)), ("sessions", _sessions_file(ex.dir)))
        t = isfile(f) ? mtime(f) : 0.0
        t == get(ex.auth_mtime, key, -1.0) && continue
        if key == "users"
            ex.users = _read_json_dict(f)
        else
            ex.sessions = _read_json_dict(f)
        end
        ex.auth_mtime[key] = t
    end
end
_save_users!(ex) = (save_users(ex.dir, ex.users); ex.auth_mtime["users"] = mtime(_users_file(ex.dir)))
_save_sessions!(ex) = (_write_atomic(_sessions_file(ex.dir), ex.sessions); ex.auth_mtime["sessions"] = mtime(_sessions_file(ex.dir)))

# ---------------------------------------------------------------------------
# requests: the session's user, logging in and out

function _cookie(req, name)
    for part in split(HTTP.header(req, "Cookie", ""), ';')
        k, _, v = partition_eq(strip(part))
        k == name && return v
    end
    return nothing
end
partition_eq(s) = (i = findfirst('=', s); i === nothing ? (s, "", "") : (s[1:i-1], "=", s[i+1:end]))

# the address a request comes from: the proxy's X-Forwarded-For (Caddy sets it), else the connection's
_address(req) = (f = HTTP.header(req, "X-Forwarded-For", ""); isempty(f) ? "direct" : String(strip(first(split(f, ',')))))

function _session_user(ex::Explorer, req)
    token = _cookie(req, COOKIE)
    token === nothing && throw(NotLoggedIn())
    lock(ex.lock) do
        _refresh_auth!(ex)
        key = _token_key(token)
        s = get(ex.sessions, key, nothing)
        s === nothing && throw(NotLoggedIn())
        t = now()
        created, seen = DateTime(s["created"]), DateTime(s["seen"])
        if t - seen > SESSION_IDLE || t - created > SESSION_MAX || !haskey(ex.users, s["user"])
            delete!(ex.sessions, key); _save_sessions!(ex)
            throw(NotLoggedIn())
        end
        if t - seen > Minute(10)              # (not a write at every request)
            s["seen"] = string(t); _save_sessions!(ex)
        end
        return s["user"]
    end
end

function _blocked(ex, name, address)
    t = now()
    for k in ("name:" * name, "address:" * address)
        filter!(x -> t - x < FAIL_WINDOW, get!(ex.failures, k, DateTime[]))
    end
    return length(ex.failures["name:"*name]) >= FAILS_PER_NAME || length(ex.failures["address:"*address]) >= FAILS_PER_ADDRESS
end

const DUMMY_HASH = Ref("")

"""
    login!(ex, name, password, address) -> token

A new session for `name`, if the password is theirs.  Wrong or unknown, it
fails after the same time; too many failures block for a while.
"""
function login!(ex::Explorer, name, password, address)
    blocked = lock(() -> (_refresh_auth!(ex); _blocked(ex, name, address)), ex.lock)
    blocked && throw(Forbidden("too many failed logins: try again in 15 minutes"))
    stored = lock(() -> get(get(ex.users, name, Dict()), "hash", nothing), ex.lock)
    isempty(DUMMY_HASH[]) && (DUMMY_HASH[] = password_hash(new_password()))
    ok = password_matches(password, something(stored, DUMMY_HASH[])) && stored !== nothing
    return lock(ex.lock) do
        if !ok
            t = now()
            push!(ex.failures["name:"*name], t); push!(ex.failures["address:"*address], t)
            throw(Forbidden("wrong user name or password"))
        end
        token = bytes2hex(rand(RNG, UInt8, 32))
        t = string(now())
        ex.sessions[_token_key(token)] = Dict{String,Any}("user" => name, "created" => t, "seen" => t)
        _save_sessions!(ex)
        ex.users[name]["last_login"] = Dates.format(now(), "yyyy-mm-dd HH:MM")
        _save_users!(ex)
        delete!(ex.failures, "name:" * name)
        return token
    end
end

function logout!(ex::Explorer, req)
    token = _cookie(req, COOKIE)
    token === nothing && return
    lock(ex.lock) do
        delete!(ex.sessions, _token_key(token)) === nothing || _save_sessions!(ex)
    end
end

_session_cookie(ex, token; maxage = Dates.value(Second(SESSION_MAX))) =
    "$COOKIE=$token; Path=/; Max-Age=$maxage; HttpOnly; SameSite=Strict" * (ex.secure_cookies ? "; Secure" : "")

function change_password!(ex::Explorer, user, current, new)
    stored = lock(() -> (_refresh_auth!(ex); ex.users[user]["hash"]), ex.lock)
    password_matches(current, stored) || throw(Forbidden("the current password is wrong"))
    set_password!(ex.dir, user, new)              # ends all the user's sessions
    lock(() -> _refresh_auth!(ex), ex.lock)
end

# ---------------------------------------------------------------------------
# administrators: create, reset, admin or not, remove

function users_info(ex::Explorer)
    lock(ex.lock) do
        _refresh_auth!(ex)
        runs = Dict{String,Int}()
        foreach(r -> runs[r.meta["owner"]] = get(runs, r.meta["owner"], 0) + 1, values(ex.runs))
        return sort!([Dict("user" => n, "admin" => u["admin"] === true, "created" => get(u, "created", nothing),
                           "last_login" => get(u, "last_login", nothing), "runs" => get(runs, n, 0))
                      for (n, u) in ex.users]; by = u -> u["user"])
    end
end

function _admins_left(ex, without)
    count(((n, u),) -> n != without && u["admin"] === true, ex.users)
end

"""
    create_user!(ex, name; admin = false) -> password

A new user with a new password (given back once: it isn't kept).
"""
function create_user!(ex::Explorer, name; admin = false)
    lock(() -> (_refresh_auth!(ex); haskey(ex.users, name)), ex.lock) && throw(ArgumentError("`$name` exists already"))
    password = new_password()
    set_password!(ex.dir, name, password; admin)
    lock(() -> _refresh_auth!(ex), ex.lock)
    return password
end

function reset_password!(ex::Explorer, name)
    lock(() -> (_refresh_auth!(ex); haskey(ex.users, name)), ex.lock) || throw(KeyError(name))
    password = new_password()
    set_password!(ex.dir, name, password)
    lock(() -> _refresh_auth!(ex), ex.lock)
    return password
end

function set_admin!(ex::Explorer, name, admin::Bool)
    lock(ex.lock) do
        _refresh_auth!(ex)
        haskey(ex.users, name) || throw(KeyError(name))
        !admin && _admins_left(ex, name) == 0 && throw(ArgumentError("there must be an administrator left"))
        ex.users[name]["admin"] = admin
        _save_users!(ex)
    end
end

function remove_user!(ex::Explorer, name)
    lock(ex.lock) do
        _refresh_auth!(ex)
        haskey(ex.users, name) || throw(KeyError(name))
        ex.users[name]["admin"] === true && _admins_left(ex, name) == 0 &&
            throw(ArgumentError("there must be an administrator left"))
        delete!(ex.users, name)
        _save_users!(ex)
        filter!(kv -> last(kv)["user"] != name, ex.sessions)
        _save_sessions!(ex)
    end
end
