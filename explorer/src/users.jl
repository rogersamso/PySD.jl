# Users: who asks (from the proxy's header, or this computer's one user), what
# they may see and change, and the limits the administrators set.

struct Forbidden <: Exception
    msg::String
end

const DEFAULT_SETTINGS = Dict{String,Any}(
    "max_parallel" => 2,             # simulations at once, everyone's (each a run, or an analysis' runs one after the other)
    "max_jobs_per_user" => 1,        # a user's runs and analyses waiting or running
    "max_runs_per_user" => 30,       # runs kept (an analysis keeps no runs: only its table)
    "max_analyses_per_user" => 5,
    "max_params_per_analysis" => 100,
    "show_code" => true)             # the model's code, for users who aren't administrators

const SETTING_LIMITS = Dict("max_parallel" => (1, 64), "max_jobs_per_user" => (1, 100),
                            "max_runs_per_user" => (1, 10_000), "max_analyses_per_user" => (1, 1000),
                            "max_params_per_analysis" => (1, 100_000))

function _load_settings(dir)
    s = copy(DEFAULT_SETTINGS)
    f = joinpath(dir, "settings.json")
    if isfile(f)
        for (k, v) in JSON3.read(read(f, String))
            haskey(s, String(k)) && (s[String(k)] = v)
        end
    end
    return s
end

"""
    update_settings!(ex, new)

The administrators' settings, checked and saved; jobs waiting for a slot see
a new `max_parallel` at once.
"""
function update_settings!(ex::Explorer, new)
    s = copy(ex.settings)
    for (k, v) in pairs(new)
        k = String(k)
        haskey(s, k) || throw(ArgumentError("no setting `$k`"))
        if k == "show_code"
            v isa Bool || throw(ArgumentError("show_code is true or false"))
        else
            (lo, hi) = SETTING_LIMITS[k]
            (v isa Integer && lo <= v <= hi) || throw(ArgumentError("$k is a whole number from $lo to $hi"))
        end
        s[k] = v
    end
    lock(ex.cond) do
        ex.settings = s
        notify(ex.cond)
    end
    open(io -> JSON3.write(io, s), joinpath(ex.dir, "settings.json"), "w")
    return s
end

# the user asking: a name made of letters, digits, `.`, `_`, `-`, `@`
function user_of(ex::Explorer, req)
    ex.auth.mode === :local && return "local"
    u = strip(HTTP.header(req, ex.auth.header, ""))
    isempty(u) && throw(Forbidden("no user: the explorer is served for logged-in users only"))
    occursin(r"^[\w.@-]{1,64}$", u) || throw(Forbidden("not a user name the explorer accepts"))
    return String(u)
end

is_admin(ex::Explorer, user) = ex.auth.mode === :local || user in ex.auth.admins

# runs and analyses: the owner's, shared ones, and those of no one (the base run, the analysis from a file)
visible(ex::Explorer, user, meta) =
    is_admin(ex, user) || meta["owner"] == "" || meta["owner"] == user || get(meta, "shared", false) === true
may_change(ex::Explorer, user, meta) = is_admin(ex, user) || (meta["owner"] == user && user != "")

may_see_code(ex::Explorer, user) = is_admin(ex, user) || ex.settings["show_code"] === true

function me_info(ex::Explorer, user)
    s = ex.settings
    return Dict("user" => user, "admin" => is_admin(ex, user), "code" => !isempty(ex.code) && may_see_code(ex, user),
                "local" => ex.auth.mode === :local,
                "limits" => Dict(k => s[k] for k in ("max_runs_per_user", "max_analyses_per_user",
                                                     "max_params_per_analysis", "max_jobs_per_user")),
                "runs" => count(r -> r.meta["owner"] == user, values(ex.runs)),
                "analyses" => count(a -> a["owner"] == user, values(ex.analyses)))
end

function admin_info(ex::Explorer)
    users = Dict{String,Dict{String,Any}}()
    entry(u) = get!(() -> Dict{String,Any}("user" => u, "runs" => 0, "shared" => 0, "analyses" => 0, "mb" => 0.0), users, u)
    for r in values(ex.runs)
        e = entry(r.meta["owner"])
        e["runs"] += 1
        e["shared"] += get(r.meta, "shared", false) === true
        e["mb"] += sizeof(r.data) / 2^20
    end
    for a in values(ex.analyses)
        entry(a["owner"])["analyses"] += 1
    end
    for e in values(users)
        e["mb"] = round(e["mb"]; digits = 1)
    end
    return Dict("settings" => ex.settings, "threads" => Threads.nthreads(), "running" => ex.running,
                "jobs" => jobs_info(ex, "", true),
                "users" => sort!(collect(values(users)); by = e -> e["user"]))
end
