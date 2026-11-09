# Exploring a model in the browser

PySDExplorer, a package in the `explorer/` folder of this repository, shows a
model in a web page: its names by set (a translated model's views) with their
titles, units and descriptions; plots that compare runs; new runs with other
parameter values or input sheets; sensitivity analyses; the model's code; and
figures, data or a whole page to export.  It runs on your computer, or on a
server for several people.

| | who uses it | how |
|:---|:---|:---|
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
array, a box per element.  A lookup or a data series (a value for each x,
or each year; Vensim's `GET DIRECT LOOKUPS`, `GET DIRECT DATA`, tables) is a
table to edit: its values over the same x, typed one by one or a stretch
changed by a percentage ("from 2030, +20 %"), drawn against the model's; an
array of them, a table per element.  Names computed from others (`x = 2 *
y`) and the parameters that fix the structure of an operator (a delay's
order) have no control.  An Excel upload replaces only the values read from
Excel; what is written in the model changes with its controls.

A model whose data come from another model's results (`data(parents, …)`,
as a regional model reads the world's) needs those results to start: the
explorer doesn't choose a parent run yet.  Give the model a file of the
parent's results in its `inputs.jl`, `parents = (series_file("world.tab"),)`;
every run then uses that one parent run.

On the page: pick names from the tree of sets (or search them); each plot
compares the runs shown, in values or as the difference from one of them.
An array's plot has a row of checkboxes per dimension (all, none, or add
them up: *Σ add up* on the sectors gives one line per fuel), so any slice of
it is a couple of clicks.  Figures export as PNG or SVG, what is on screen
as CSV, the whole page as one HTML file, and each run's complete results as
CSV from the **Runs** tab (a row per name or element, a column per time).
The columns side by side (the tree of names, the two halves of a tab) widen
or narrow by dragging the line between them; a double-click puts them back.

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
|:---|---:|---:|
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

| file | what it holds |
|:---|:---|
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

## The API

Everything the page does goes through an HTTP API at `/api/…`, which
scripts can use as well: start runs and analyses, wait for them, read their
results.  Requests and answers are JSON, unless said otherwise.

### Logging in

- **On your computer** (`users = :local`): no login; every request is the
  local user's.
- **With the explorer's own logins** (`users = :password`): `POST
  /api/login` with `{"user": …, "password": …}` sets a session cookie that
  the next requests carry (a script keeps it, as a browser does).  Every
  request that changes something (`POST`, `PUT`, `PATCH`, `DELETE`) carries
  the header `X-PySD-Request: 1` too, or it is refused: another site's page
  can't send it.  A session ends after 14 days without use.
- **Behind a proxy that logs people in** (`users = :header`): the proxy sets
  the user in `X-PySD-User`.

A script has the same rights and limits as its user on the page: runs kept,
jobs waiting at once, and so on (`GET /api/me` says which).

Errors are `{"error": "…"}` with the status: 400 (a request that can't be
done, the message says why), 401 (log in first), 403 (not allowed), 404
(not found, or not yours to see).

### Runs

| request | what it does |
|:---|:---|
| `GET /api/model` | the model: its names (title, set, kind, unit, description, limits, dimensions and elements, the value in the model of each parameter, `table: true` for a table), its time and input sheets |
| `GET /api/inputs` | for each input sheet, the sheets that can replace it: `[{id, label}, …]`, the first the model's own |
| `GET /api/tables/{name}` | a table's `x` and `y` in the model, a list per element (`elements` their labels) |
| `POST /api/runs` | a run: `{"label": …, "params": {…}, "inputs": {…}}`; answers its job |
| `GET /api/runs` | the runs you see: id, label, owner, shared, created, params, inputs, seconds |
| `GET /api/runs/{id}/csv` | its results as CSV (text): a row per name or element, a column per time, after a line with its label and changes |
| `GET /api/series?name=…&runs=id1,id2` | a name's values in some runs: `time`, `elements`, and for each run a list per element |
| `PATCH /api/runs/{id}` | `{"label": …}` or `{"shared": true}` |
| `DELETE /api/runs/{id}` | deletes it |

In `params`, a number for a parameter (`"tax": 30`), a list for an array
(in the order of `GET /api/model`'s elements, the first dimension slowest),
and for a table a list of values per element, over the same `x` as `GET
/api/tables/{name}` (`[[…], […]]`; one list for a table without
dimensions).  In `inputs`, an input sheet's name and the `id` of the sheet
to use instead.

### Jobs

A run or an analysis waits for a simulation slot: `POST` answers its job,
`{id, kind, label, status, progress, position, message, result, …}`.

| request | what it does |
|:---|:---|
| `GET /api/jobs/{id}` | the job now: `status` is `queued` (its `position` in the queue), `running` (`progress` from 0 to 1), `done` (`result` is the run's or analysis' id), `failed` (`message` says why) or `cancelled` |
| `GET /api/jobs` | your jobs (all, for administrators) |
| `DELETE /api/jobs/{id}` | cancels it |

### Sensitivity, uploads, views

| request | what it does |
|:---|:---|
| `POST /api/analyses` | `{"label", "around" (a run's id, or "" for the model), "params": [names], "outputs": [names], "step": 0.01, "years": false}`; answers its job |
| `GET /api/analyses`, `GET /api/analyses/{id}` | the analyses you see; one with its table (`rows`: a parameter each, the elasticity of each output) |
| `PATCH`, `DELETE /api/analyses/{id}` | as for runs |
| `POST /api/uploads?replaces=scen_w&label=…` | an `.xlsx` file (the request's body, as bytes) to replace the model's `scen_w.xlsx` |
| `GET /api/uploads`, `PATCH`, `DELETE /api/uploads/{id}` | your uploads (and shared ones), the model's files; share, rename, delete |
| `GET`, `POST /api/views`, `DELETE /api/views/{name}` | your saved views |
| `GET /api/code`, `GET /api/code/{id}` | the model's files, one file's text (when users may see the code) |
| `POST /api/password` | `{"current": …, "new": …}` |
| `GET /api/admin`, `PUT /api/admin/settings`, `/api/admin/users…` | the Admin tab's, for administrators |

### An example

A run with a parameter and a table changed, its results as CSV, in Python:

```python
import requests, time

api = "https://myexplorer.duckdns.org/api/"
s = requests.Session()
s.headers["X-PySD-Request"] = "1"
s.post(api + "login", json={"user": "laia", "password": "…"}).raise_for_status()

t = s.get(api + "tables/p_power").json()                 # a table of the model
k = t["elements"].index("solar_pv")
y = t["y"]
y[k] = [v * 1.2 if x >= 2030 else v for x, v in zip(t["x"][k], y[k])]

job = s.post(api + "runs", json={"label": "Solar +20 % from 2030",
                                 "params": {"p_power": y, "tax": 30}}).json()
while job["status"] in ("queued", "running"):
    time.sleep(2)
    job = s.get(api + "jobs/" + job["id"]).json()
assert job["status"] == "done", job["message"]
open("solar.csv", "w").write(s.get(api + f"runs/{job['result']}/csv").text)
```

And in Julia:

```julia
using HTTP, JSON3
api = "https://myexplorer.duckdns.org/api/"
h = ["X-PySD-Request" => "1", "Content-Type" => "application/json"]
call(method, path, body = nothing) =
    JSON3.read(HTTP.request(method, api * path, h, body === nothing ? "" : JSON3.write(body)).body)

call("POST", "login", (; user = "laia", password = "…"))     # HTTP.jl keeps the cookie
job = call("POST", "runs", (; label = "Tax 30", params = (; tax = 30)))
while job.status in ("queued", "running")
    sleep(2)
    global job = call("GET", "jobs/" * job.id)
end
write("tax.csv", HTTP.get(api * "runs/$(job.result)/csv").body)
```

## Safety

Anyone who can log in can run the model on the server, within the
administrators' limits; users can't upload models, and the server only
accepts the model's own parameters and the listed input sheets.  Uploaded
files must replace one of the model's Excel files and open as `.xlsx`; a
file that would unpack to far more than its size (a "zip bomb") is refused.  A translated
model is Julia code: serve only models you trust.  Passwords are kept as
salted PBKDF2-SHA256 hashes; repeated failed logins are blocked for a while;
sessions end after 14 days without use.
