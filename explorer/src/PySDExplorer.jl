"""
    PySDExplorer

A web page to explore a PySD.jl model: its names by set (module), with their
units and descriptions; runs with other parameter values or input sheets,
kept on disk and compared; sensitivity analyses; the model's code; figures
and data exported.  On one computer (`users = :local`) or for several people
behind a reverse proxy that checks their passwords (`users = :header`).

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
using HTTP, JSON3, Dates, Sockets, Random
import SHA
using Base64: base64encode, base64decode

export serve, static_page

const ASSETS = joinpath(@__DIR__, "..", "assets")

mutable struct Run
    meta::Dict{String,Any}               # id, label, owner, shared, created, params, inputs, seconds, time, columns
    columns::Vector{String}
    index::Dict{String,Vector{Int}}      # name => its columns
    data::Matrix{Float64}                # time × column
end

"""
A job waiting for or using one of the simulation slots: a run or a
sensitivity analysis.  `work(job)` does it and returns the id of what it made.
"""
mutable struct Job
    id::String
    user::String
    kind::String                         # "run" or "analysis"
    label::String
    status::Symbol                       # :queued, :running, :done, :failed, :cancelled
    progress::Float64
    message::String
    result::Union{Nothing,String}
    created::DateTime
    started::Union{Nothing,DateTime}
    finished::Union{Nothing,DateTime}
    cancel::Threads.Atomic{Bool}
    work::Any
end

struct Auth
    mode::Symbol                         # :local (one user, an administrator), :header (a proxy's) or :password (the explorer's)
    header::String                       # the header the proxy writes the user's name in
    admins::Set{String}
end

mutable struct Explorer
    model::Model
    title::String
    vars::NamedTuple
    row::Dict{Symbol,Int}
    editable::Dict{Symbol,Any}           # parameter => its value in the model (Float64, or a Vector in Tables order)
    sizes::Dict{Symbol,Tuple}
    inputs::Dict{String,Vector{Tuple{String,String}}}   # input => (file, sheet) choices
    input_dirs::Vector{String}
    dir::String
    separator::String
    code::Vector{Pair{String,String}}    # file id => path: the model's code
    sources::Dict{Symbol,Vector{Tuple{String,Int}}}     # name => (file id, line) of its declaration and equations
    runs::Dict{String,Run}
    analyses::Dict{String,Dict{String,Any}}
    auth::Auth
    settings::Dict{String,Any}
    jobs::Vector{Job}
    cond::Threads.Condition              # jobs wait on it for a slot
    running::Int
    lock::ReentrantLock                  # runs, analyses, inputs
    cache::Dict{String,String}           # answers that don't change (the model, its code), as JSON
    users::Dict{String,Dict{String,Any}} # users = :password: name => hash, admin…
    sessions::Dict{String,Dict{String,Any}}
    failures::Dict{String,Vector{DateTime}}
    auth_mtime::Dict{String,Float64}
    secure_cookies::Bool
end

include("model.jl")
include("users.jl")
include("auth.jl")
include("runs.jl")
include("jobs.jl")
include("sensitivity.jl")
include("static.jl")
include("routes.jl")

"""
    serve(model; dir = "explorer-data", host = "127.0.0.1", port = 8080,
          title = "", input_dirs = String[], sensitivity = nothing,
          separator = "-", users = :local, admins = String[],
          user_header = "X-PySD-User")

Serve the explorer of `model` (a `Model`, or the path of the `.jl` file that
builds one) at `http://host:port`.

- `dir`: where runs, analyses, saved views and settings are kept.
- `input_dirs`: folders whose `.xlsx` sheets can replace the model's input
  sheets in a run (files named like the model's own).
- `sensitivity`: a TSV file of elasticities (a row per parameter, a column
  per result), shown as an analysis everyone can see.
- `separator`: splits set titles into a tree (`"ENERGY-DEMAND-Heat"` →
  ENERGY › DEMAND › Heat; `""` for none).
- `users = :local`: one person, this computer's, with everything allowed.
- `users = :password`: several people, who log in with the explorer's own
  users (`dir/users.json`); administrators create them, reset passwords and
  remove them in the Admin tab.  The first administrator is made with
  `deploy/users.jl` (or `PySDExplorer.set_password!(dir, name, pw; admin = true)`).
  Serve it over HTTPS (a proxy such as Caddy in front); `secure_cookies = false`
  only to try it out without.
- `users = :header`: several people; a reverse proxy in front (Caddy, nginx)
  checks their passwords and writes the user's name in `user_header`.  The
  explorer then listens on `127.0.0.1` only (the proxy's side), and `admins`
  are the names that see the administrators' tab.
"""
function serve(model; dir = "explorer-data", host = "127.0.0.1", port::Integer = 8080, users::Symbol = :local,
               allow_remote_proxy::Bool = false, kwargs...)
    users === :header && !allow_remote_proxy && !(host in ("127.0.0.1", "localhost", "::1")) &&
        throw(ArgumentError("with users = :header the explorer trusts the user's name the proxy sends: it must " *
                            "listen on 127.0.0.1, behind the proxy (allow_remote_proxy = true if the proxy is elsewhere)"))
    ex = explorer(model; dir, users, kwargs...)
    router = routes(ex)
    @info "PySD explorer: http://$host:$port ($(length(ex.vars.name)) names, $(length(ex.runs)) runs, users = $users, " *
          "$(ex.settings["max_parallel"]) simulations at once on $(Threads.nthreads()) threads)"
    return HTTP.serve(router, host, port; stream = false)
end

function explorer(model; dir = "explorer-data", title = "", input_dirs = String[], sensitivity = nothing,
                  separator = "-", users::Symbol = :local, admins = String[], user_header = "X-PySD-User",
                  secure_cookies::Bool = true)
    users in (:local, :header, :password) || throw(ArgumentError("users is :local, :password or :header, not $(repr(users))"))
    users === :password && !any(u -> u["admin"] === true, values(load_users(dir))) &&
        throw(ArgumentError("no administrator in $(abspath(dir))/users.json: make one first, e.g. " *
                            "julia deploy/users.jl $(abspath(dir)) set NAME --admin (it asks for the password)"))
    m = model isa Model ? model : _build(model)
    title = isempty(title) && !(model isa Model) ? splitext(basename(model))[1] : title
    for d in ("runs", "views", "analyses")
        mkpath(joinpath(dir, d))
    end
    vars = variables(m)
    row = Dict(n => i for (i, n) in enumerate(vars.name))
    base = Base.invokelatest(run_model, m)
    editable, sizes = _editable(m, vars, base)
    code, sources = _code(m, vars.name)
    ex = Explorer(m, title, vars, row, editable, sizes, _input_choices(m, input_dirs), String.(input_dirs), String(dir),
                  separator, code, sources, Dict{String,Run}(), Dict{String,Dict{String,Any}}(),
                  Auth(users, user_header, Set(String.(admins))), _load_settings(dir), Job[],
                  Threads.Condition(), 0, ReentrantLock(), Dict{String,String}(),
                  Dict{String,Dict{String,Any}}(), Dict{String,Dict{String,Any}}(), Dict{String,Vector{DateTime}}(),
                  Dict{String,Float64}(), secure_cookies)
    users === :password && lock(() -> _refresh_auth!(ex), ex.lock)
    _load_runs!(ex)
    _load_analyses!(ex)
    sensitivity === nothing || (ex.analyses["file"] = _sensitivity_file(sensitivity, row))
    isempty(ex.runs) && _save!(ex, base; label = "Base", owner = "", shared = true)
    return ex
end

end
