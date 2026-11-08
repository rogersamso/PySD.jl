# Putting the explorer on a server

This folder runs the explorer for several people on a server of your own
(Hetzner, a university machine, any Linux server with Docker): two containers,
started together with Docker Compose.

- **explorer**: Julia, PySD.jl and the explorer, with your model mounted
  read-only.  Runs, analyses, saved views and settings live in a Docker
  volume, so they survive restarts and updates.
- **caddy**: the web server people talk to.  It gets an HTTPS certificate
  (Let's Encrypt) for your address, asks each person for their user name and
  password, and passes only the name on to the explorer.

The explorer itself isn't reachable from outside: only Caddy talks to it.

## What you need

- A server with Docker.  For a large model: 4 cores and 8 GB of memory (the
  model, once built, takes about 2.5 GB; each simulation running at once adds
  a little).  On Hetzner, a CX33.
- An address that points at the server's IP.  A free DuckDNS name
  (https://www.duckdns.org) is enough: `myexplorer.duckdns.org`.
- Ports 80 and 443 open (Caddy needs 80 to get its certificate), and 22 for
  you (SSH).
- The model translated with PySD (`translate_to_julia(model, split_views=True)`),
  in one folder with its Excel files, as it was translated (the paths between
  them are relative).

## Set it up

1. Copy this repository to the server, and the model's folder (e.g.
   `/srv/model`).
2. In this folder (`explorer/deploy`):

   ```sh
   cp env.example .env
   vim .env                     # DOMAIN, MODEL_DIR, ADMINS, TITLE…
   cp users.caddy.example users.caddy
   ```

3. A password for each person: run this, type the password, and put the line
   it prints (after the user's name) in `users.caddy`:

   ```sh
   docker compose run --rm caddy caddy hash-password
   ```

   `users.caddy` then has lines like `ana $2a$14$…`.  Names are what people
   see as the author of shared runs; use letters, digits, `.`, `_` or `-`.
4. Start it:

   ```sh
   docker compose up -d --build
   docker compose logs -f explorer      # wait for "PySD explorer: http://…"
   ```

   The first build takes a while (Julia compiles PySD.jl).  Every start
   builds the model and runs it once before it answers: minutes for a large
   model.

Then open `https://DOMAIN`, log in, and the administrators (`ADMINS`) see an
**Admin** tab: how many simulations run at once, the limits per user, whether
users see the model's code, and everyone's jobs.

## Day to day

- **Add or remove a user**: edit `users.caddy`, then `docker compose restart caddy`.
  A removed user's runs stay (administrators see them, and can delete them).
- **Another model**: put it in `MODEL_DIR` (or change `MODEL_DIR`), then
  `docker compose restart explorer`.  Runs of the previous model don't belong
  with the new one: use another volume (`docker compose down`, change the
  volume's name in `docker-compose.yml`), or delete them in the Admin tab.
- **New input sheets** (other scenarios): put `.xlsx` files named like the
  model's own (`scen_w_high.xlsx` for `scen_w.xlsx`) in a folder listed in
  `INPUT_DIRS`; the Runs tab finds them, no restart needed.
- **Update** PySD.jl and the explorer: `git pull`, then `docker compose up -d --build`.
- **Back up**: the `explorer-data` volume (`docker run --rm -v deploy_explorer-data:/d -v $PWD:/b alpine tar czf /b/explorer-data.tgz -C /d .`).

## What people can do, and the limits

Each user sees the base run, their own runs and analyses, and those others
shared.  Only the author (and administrators) can rename, share or delete a
run.  A run or an analysis waits in a queue until one of the simulation slots
(Admin: "Simulations at once") is free.  Saved runs are limited per user
(about 14 MB each for a large model); sensitivity analyses keep only their
table, with their own limits (how many, how many parameters each).

## Safety

- The translated model is Julia code that runs on the server.  Only put
  models you trust in `MODEL_DIR`; users can't upload models.
- Caddy replaces any `X-PySD-User` a browser sends: the explorer trusts the
  name only because it comes from Caddy.  Don't publish port 8080.
- Keep the server updated (`unattended-upgrades` on Ubuntu or Debian), and
  allow SSH with keys only.
