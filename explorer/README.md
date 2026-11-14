# PySDExplorer

A web page to explore a PySD.jl model in the browser:

- **Browse** every name of the model by set (a translated model's views), with
  its title, unit and description; search names and descriptions.
- **Plot** any name; arrays by element, or their sum.  Each plot compares the
  runs you pick: their values, or their difference (absolute or %) from one run.
- **Run** the model with other parameter values (sliders when the model gives
  limits, boxes otherwise; arrays element by element) or other input sheets:
  versions of the model's Excel files found in `input_dirs`, or uploaded from
  the page (each user's own until shared).  Runs are kept on disk and listed
  next time.
- **Sensitivity**: analyses started from the page (each parameter changed in
  turn, around a run; elasticities of the results you pick at the end of the
  run), or a table from a file, as bar charts.
- **Code**: the model's files, each name's lines highlighted, names linked to
  their plots.
- **Export** a plot or the whole page as PNG or SVG (screen, slide or A4 size,
  with a caption of the runs and their changes), the plotted data as CSV, or
  one HTML file with the plots and runs that opens anywhere without a server.
  A run's results as CSV, and its scenario as Excel files: copies of the
  model's workbooks with the run's values in their cells.
- **Saved views**: the plots, runs and settings on screen, by name.

## Three ways to run it

| | who uses it | how | see |
|---|---|---|---|
| **On your computer** | you | `serve(model)` in Julia | below |
| **For several people, on a machine you run** | colleagues on your network or VPN | `serve(model; users = :password)` | [Several users](#several-users) |
| **On a server, with Docker** | colleagues anywhere, over HTTPS | Docker Compose with Caddy | [`deploy/README.md`](deploy/README.md) |

## On your computer

```julia
using Pkg
Pkg.activate("path/to/PySD.jl/explorer"); Pkg.instantiate()
using PySDExplorer
serve("path/to/model.jl"; dir = "explorer-data")
```

and open http://127.0.0.1:8080.  No login: you can do everything, the Admin
tab included.  The model is built once when the explorer starts (minutes for
a large model); every run after that takes about as long as `run_model`.
Start Julia with threads (`julia -t 4`) so the page answers while a run goes
on.

Options of `serve`:

| option | what it does |
|---|---|
| `dir` | where runs, analyses, saved views, settings and users are kept |
| `host`, `port` | where it listens; `127.0.0.1` (the default) is this computer only |
| `title` | the page's title (default: the model file's name) |
| `input_dirs` | folders of `.xlsx` files: their sheets can replace the model's input sheets in a run (files named like the model's own) |
| `sensitivity` | a TSV file of elasticities: a `parameter` column, optionally `value`, and a column per result |
| `separator` | splits set titles into a tree: `"ENERGY-DEMAND-Heat"` → ENERGY › DEMAND › Heat (`""`: none) |
| `users` | `:local` (the default): one person, no login. `:password`: several people, with the explorer's own logins. `:header`: several people, logged in by a proxy in front (see below) |
| `secure_cookies` | with `users = :password`: `true` (the default) sends the login cookie over HTTPS only |

## Several users

With `users = :password` the explorer asks for a user name and password, and:

- each user sees the base run, their own runs and analyses, and those others
  shared (a **Share** button); only the author, or an administrator, can
  rename, share or delete them; saved views are each user's own;
- runs and analyses wait in a queue for one of the simulation slots;
- administrators, in the **Admin** tab: add users (the explorer makes a
  password and shows it once), give someone a new password, make
  administrators, remove users; set the simulations at once, jobs per user,
  runs and analyses kept per user, parameters per analysis, whether users see
  the code; see everyone's jobs and disk use;
- everyone changes their own password from the menu with their name.

The first administrator is made from the command line (it asks for the
password; it never goes on the command line):

```sh
julia --project=path/to/PySD.jl/explorer path/to/PySD.jl/explorer/deploy/users.jl explorer-data set roger --admin
```

then:

```julia
serve("path/to/model.jl"; dir = "explorer-data", users = :password, host = "0.0.0.0")
```

**Passwords need HTTPS.**  Over plain `http://` they cross the network as
they are typed, and the explorer's cookie (`secure_cookies = true`) only
travels over HTTPS.  So:

- on a server open to the internet, put a web server with HTTPS in front
  (Caddy does it in a few lines, and gets its certificate itself): the
  Docker setup in [`deploy/`](deploy/README.md) does exactly that;
- on a network you trust (a VPN such as Tailscale, which encrypts its
  traffic), `secure_cookies = false` lets it work over `http://`.

The users live in `dir/users.json` (passwords as salted PBKDF2-SHA256
hashes, 600,000 rounds) and their sessions in `dir/sessions.json` (only the
tokens' hashes).  Five failed logins for a name, or twenty from an address,
in 15 minutes block more for 15 minutes; sessions end after 14 days without
use, 30 days in all, or when the password changes.

`users = :header` is for an organisation that already logs people in at its
web server (single sign-on): that proxy checks who they are and passes the
name in `X-PySD-User` (`user_header`); `admins` lists the administrators.
The explorer then trusts that header, so it listens on `127.0.0.1` only,
where nothing but the proxy can reach it.

## What it shows

The names, titles, units, descriptions and limits come from the model's
declarations, through `PySD.variables(model)`; set titles come from
`@equations title = "…" begin … end`.  A model translated by PySD has all of
them (Vensim's names, units, comments, limits and views).

## Safety

Anyone who can log in (or, with `users = :local`, open the page) can run the
model on the computer it's served from, within the Admin tab's limits.  The
server only accepts the model's own parameters and the listed input sheets;
users can't upload models.  A translated model is Julia code: serve only
models you trust.

## Runs on disk

`dir/runs/<id>.json` holds a run's name, author, date, changes and column names;
`<id>.f64` its values (Float64, time × column, column after column).  From
Python: `numpy.fromfile(f, dtype="<f8").reshape(ncolumns, ntimes).T`.
