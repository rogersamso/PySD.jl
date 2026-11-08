# The explorer in a container: the model in /model, runs and settings in /data,
# configured by environment variables (see deploy/README.md).
using PySDExplorer

env(k, default = "") = get(ENV, k, default)
list(k) = filter(!isempty, strip.(split(env(k), ',')))

# the model: PYSD_MODEL (a path in /model), or the one translated model found there
function find_model(dir)
    found = String[]
    for (root, _, files) in walkdir(dir), f in files
        endswith(f, ".jl") && endswith(root, "_dsl") && f == replace(basename(root), r"_dsl$" => "") * ".jl" &&
            push!(found, joinpath(root, f))
    end
    length(found) == 1 || error("set PYSD_MODEL: $(isempty(found) ? "no translated model" : "$(length(found)) translated models") in $dir")
    return only(found)
end
model = isempty(env("PYSD_MODEL")) ? find_model("/model") : joinpath("/model", env("PYSD_MODEL"))

users = Symbol(env("PYSD_USERS", "header"))
serve(model; dir = "/data", host = "0.0.0.0", port = 8080, users,
      # behind Caddy in its own container: the header comes from there, and port 8080 isn't published
      allow_remote_proxy = users === :header,
      admins = list("PYSD_ADMINS"), title = env("PYSD_TITLE"),
      input_dirs = [joinpath("/model", d) for d in list("PYSD_INPUT_DIRS")],
      sensitivity = isempty(env("PYSD_SENSITIVITY")) ? nothing : joinpath("/model", env("PYSD_SENSITIVITY")),
      separator = env("PYSD_SEPARATOR", "-"))
