# Exploring a model in the browser

PySDExplorer, a package in the `explorer/` folder of this repository, shows a
model in a web page: its names by set (a translated model's views) with their
titles, units and descriptions; plots that compare runs; new runs with other
parameter values or input sheets; sensitivity analyses; the model's code; and
figures, data or a whole page to export.  It runs on your computer, or on a
server for several people.

| | who uses it | how |
|---|---|---|
| [On your computer](@ref) | you | `serve(model)` |
| [For several people](@ref) | colleagues on your network or VPN | `serve(model; users = :password)` |
| [On a server, with Docker](@ref) | colleagues anywhere, over HTTPS | Docker Compose, with Caddy in front |

## On your computer

```julia
using Pkg
Pkg.activate("path/to/PySD.jl/explorer"); Pkg.instantiate()
using PySDExplorer
serve("path/to/model.jl"; dir = "explorer-data")
```

Open `http://127.0.0.1:8080`.  The model is built once when the explorer
starts (minutes for a large model) and runs in about the time of
[`run_model`](@ref) after that.  Start Julia with threads (`julia -t 4`) so
the page answers while a run goes on.  `dir` keeps the runs, analyses and
saved views from one session to the next.

What the page shows comes from the model's declarations, through
[`variables`](@ref): `title`, `unit`, `description` and `limits` of each name
(the sliders' ranges), and `@equations title = "…"` for each set.  A model
translated by PySD has all of them.

Every parameter can change in a run: a number or an array written in the
model (Vensim's `x = 3`, `x[region] = 1, 2, 3`) as well as one read from an
Excel file.  A number gets a slider when it has limits, a box otherwise; an
array, a box per element.  Names computed from others (`x = 2 * y`), the
parameters that fix the structure of an operator (a delay's order), and
lookups and data series (they change with the input sheets) have no control.
An Excel upload replaces only the values read from Excel; numbers written in
the model change with their controls.

A model whose data come from another model's results (`data(parents, …)`,
as a regional model reads the world's) needs those results to start: the
explorer doesn't choose a parent run yet.  Give the model a file of the
parent's results in its `inputs.jl`, `parents = (series_file("world.tab"),)`;
every run then uses that one parent run.

Other options: `input_dirs` (folders whose `.xlsx` sheets, named like the
model's own files, can replace its input sheets in a run; users can also
upload their own versions of those files from the page), `sensitivity` (a
table of elasticities from a file), `title`, `separator` (how set titles
split into a tree), `host` and `port`.

## For several people

```sh
# the first administrator: it asks for the password
julia --project=path/to/PySD.jl/explorer path/to/PySD.jl/explorer/deploy/users.jl explorer-data set roger --admin
```

```julia
serve("path/to/model.jl"; dir = "explorer-data", users = :password, host = "0.0.0.0")
```

Everyone logs in.  Each user sees the base run, their own runs and analyses,
and those others shared; only the author, or an administrator, can change
them.  Runs and analyses wait in a queue for one of the simulation slots.
Administrators manage the users (add, new password, administrator or not,
remove) and the limits (simulations at once, runs and analyses per user,
parameters per analysis, whether users see the code) in the **Admin** tab.

### Limits

The same for every user; administrators have none.  A change in the Admin
tab applies at once and is kept in `dir/settings.json` (only the settings
changed; the others keep their default, from `DEFAULT_SETTINGS` in
`explorer/src/users.jl`).

| Admin tab | default | from–to |
|---|---|---|
| Simulations at once (everyone's) | 2 | 1–64 |
| A user's runs and analyses waiting or running | 1 | 1–100 |
| Runs kept per user | 30 | 1–10,000 |
| Analyses kept per user (they keep only their table) | 5 | 1–1,000 |
| Parameters in an analysis | 100 | 1–100,000 |
| Uploaded files per user (0: no uploads) | 10 | 0–1,000 |
| Largest upload | 20 MB | 1–200 MB |
| Users see the model's code | yes | |

There is no quota of disk space as such: a run of a large model takes about
15 MB, so the runs limit bounds it.

### The data folder

Everything the explorer writes is in `dir` (in Docker, the `explorer-data`
volume, mounted at `/data`):

| | |
|---|---|
| `users.json` | users, administrators, password hashes |
| `sessions.json` | logins (hashes of their tokens) |
| `settings.json` | the Admin tab's limits, once changed |
| `runs/` | a run each: `<id>.json` (who, label, parameters, sheets) and `<id>.f64` (its values) |
| `analyses/` | a sensitivity analysis each, its table |
| `inputs/` | uploaded Excel files, and a `.json` each (who, which file it replaces, its sheets) |
| `views/<user>/` | each user's saved views |

Copy this folder to back everything up.

Passwords need HTTPS: over plain `http://` they cross the network as typed,
and the login cookie only travels over HTTPS.  On a network you trust (a VPN
such as Tailscale), `secure_cookies = false` lets it work over `http://`;
anywhere else, put a web server with HTTPS in front, as the Docker setup
below does.

## On a server, with Docker

`explorer/deploy/` has a Docker image for any translated model, and a Docker
Compose file that puts Caddy in front: it gets an HTTPS certificate for your
address and renews it.  On a Linux server with Docker (for a large model, 4
cores and 8 GB of memory), and an address that points at it (a free DuckDNS
name is enough):

```sh
cd PySD.jl/explorer/deploy
cp env.example .env && vim .env     # the address, the model's folder, a title
docker compose build
docker compose run --rm explorer julia /app/users.jl /data set roger --admin
docker compose up -d
```

`explorer/deploy/README.md` has the details: what the server needs, adding
users, another model, updates, backups and safety.

## How it's made

A Julia server (HTTP.jl, in `explorer/src/`) and a page of plain HTML, CSS
and JavaScript (`explorer/assets/`, no framework), with Plotly.js for the
plots, kept in `assets/vendor/`: the page loads nothing from other sites.
The page asks the server for everything at `/api/…` (the model, runs,
series, jobs, analyses, uploads, users).

## Safety

Anyone who can log in can run the model on the server, within the
administrators' limits; users can't upload models, and the server only
accepts the model's own parameters and the listed input sheets.  Uploaded
files must replace one of the model's Excel files and open as `.xlsx`; a
file that would unpack to far more than its size (a "zip bomb") is refused.  A translated
model is Julia code: serve only models you trust.  Passwords are kept as
salted PBKDF2-SHA256 hashes; repeated failed logins are blocked for a while;
sessions end after 14 days without use.
