# PySDExplorer

A web page to explore a PySD.jl model in the browser:

- **Browse** every name of the model by set (a translated model's views), with
  its title, unit and description; search names and descriptions.
- **Plot** any name; arrays by element, or their sum.  Each plot compares the
  runs you pick: their values, or their difference (absolute or %) from one run.
- **Run** the model with other parameter values (sliders when the model gives
  limits, boxes otherwise; arrays element by element) or other input sheets.
  Runs are kept on disk and listed next time.
- **Sensitivity**: analyses started from the page (each parameter changed in
  turn, around a run; elasticities of the results you pick at the end of the
  run), or a table from a file, as bar charts.
- **Code**: the model's files, each name's lines highlighted, names linked to
  their plots.
- **Export** a plot or the whole page as PNG or SVG (screen, slide or A4 size,
  with a caption of the runs and their changes), the plotted data as CSV, or
  one HTML file with the plots and runs that opens anywhere without a server.
- **Saved views**: the plots, runs and settings on screen, by name.

## Start it

```julia
using Pkg
Pkg.activate("path/to/PySD.jl/explorer"); Pkg.instantiate()
using PySDExplorer
serve("path/to/model.jl"; dir = "explorer-data")
```

and open http://127.0.0.1:8080.  The model is built once when the explorer
starts (minutes for a large model); every run after that takes about as long
as `run_model`.  Start Julia with threads (`julia -t 4`) so the page answers
while a run goes on.

Options of `serve`:

| option | what it does |
|---|---|
| `dir` | where runs and saved views are kept (a `.json` and a `.f64` file per run) |
| `host`, `port` | where it listens; `127.0.0.1` (the default) is this computer only |
| `title` | the page's title (default: the model file's name) |
| `input_dirs` | folders of `.xlsx` files: their sheets can replace the model's input sheets in a run |
| `sensitivity` | a TSV file: a `parameter` column, optionally `value`, and a column per result |
| `separator` | splits set titles into a tree: `"ENERGY-DEMAND-Heat"` → ENERGY › DEMAND › Heat (`""`: none) |
| `users` | `:local` (the default): one person, this computer's, allowed everything. `:header`: several people, behind a proxy that checks their passwords (see below) |
| `admins` | with `users = :header`, the names that see the Admin tab |
| `user_header` | the header the proxy writes the user's name in (`X-PySD-User`) |

## Several users

With `users = :header`, a reverse proxy in front of the explorer (Caddy,
nginx) asks each person for their name and password and passes the name on
in `X-PySD-User`.  Then:

- each user sees the base run, their own runs and analyses, and those others
  shared (a **Share** button); only the author, or an administrator, can
  rename, share or delete them; saved views are each user's own;
- runs and analyses wait in a queue for one of the simulation slots;
- administrators set, in the **Admin** tab: simulations at once, jobs per user,
  runs and analyses kept per user, parameters per analysis, whether users see
  the code; and see everyone's jobs and disk use.

`deploy/` has all it takes to put it on a server with Docker: the image,
Caddy with HTTPS and a password per user, and the steps (`deploy/README.md`).

## What it shows

The names, titles, units, descriptions and limits come from the model's
declarations, through `PySD.variables(model)`; set titles come from
`@equations title = "…" begin … end`.  A model translated by PySD has all of
them (Vensim's names, units, comments, limits and views).

## Safety

Anyone who can open the page can run the model on your computer.  Keep the
default `host = "127.0.0.1"`, or serve it to others only behind a proxy that
checks passwords (`users = :header`; then the explorer only listens on
`127.0.0.1`, as it trusts the name the proxy sends), or on a VPN such as
Tailscale.  The server only accepts the model's own parameters and the listed
input sheets; the model itself is code, so serve only models you trust.

## Runs on disk

`dir/runs/<id>.json` holds a run's name, author, date, changes and column names;
`<id>.f64` its values (Float64, time × column, column after column).  From
Python: `numpy.fromfile(f, dtype="<f8").reshape(ncolumns, ntimes).T`.
