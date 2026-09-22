# deploy_license

HTTP API service for provisioning Dorian DDoS Firewall installations on remote
servers. It generates a machine-bound license, uploads the product tarball and
license tarball over SSH, then runs `deploy.sh` on the target host. GeoIP is
downloaded separately by the target from `192.142.44.204` (not SCP'd). The
script brings up the `angelos`, `athens`, and `sparta` systemd services.

Built with Node.js / Express 5 and MySQL.

> See [`WORKFLOW.md`](./WORKFLOW.md) for the end-to-end procedure of
> provisioning a new server (covers both `odysseus` ingestion and the
> `/create_server` call).

---

## Features

- Generates RSA-signed licenses bound to a remote host's `machine_id` via the
  bundled `mklicense` binary. Four license tiers are supported — `trial`,
  `l4`, `l7`, `unified` — each with its own feature bitmask and duration.
- Uploads artifacts to the target server with `sshpass` + `scp` and runs
  `bin/deploy.sh` remotely with one of three modes:
  - `all` — Dorian tarball + license + GeoIP, plus Python venv and systemd units.
  - `license_only` — unpack `license.tar.gz` only (no venv, no systemd).
  - `version_only` — Dorian tarball only, plus venv and systemd units.
- Tracks servers, product versions, and an audit history in MySQL
  (`license`, `versions`, `history` tables).
- Structured JSON logging under `/var/dorian/logs` (process logs, daily JSONL,
  per-deploy session files).
- Swagger UI for interactive API exploration at `/docs`.

---

## Requirements

- Node.js (Express 5 requires Node 18+)
- MySQL 5.7+ / MariaDB
- `sshpass`, `ssh`, `scp`, `tar` available in `PATH` (the API uses them to
  talk to target servers)
- On target servers: `bash`, `tar`, `python3` with `venv`, `systemd`, and
  `sudo` (or root) for `--all` / `--version-only` deploys

The native helpers in `bin/` (`mklicense`, `machine_id`, `parse_license`) are
prebuilt for Linux x86_64 and committed to the repository. Their sources
(`*.c`) are alongside them if rebuilds are required.

---

## Installation

```bash
git clone <repo-url> deploy_license
cd deploy_license
npm install
```

Initialize the database schema:

```bash
mysql -u root -p < schema.sql
```

This creates the `lic` database with three tables:

- `license` — one row per provisioned server (uuid, ip, ssh creds, machine_id,
  license blob, expiry, etc.)
- `versions` — Dorian product tarballs available for deployment
  (`uuid`, `version`, `full_name`, `path`)
- `history` — append-only audit log keyed by license `uuid`

---

## Configuration

Copy `.env.example` to `.env` and fill in the values:

```bash
cp .env.example .env
```

| Variable      | Default     | Description                                  |
| ------------- | ----------- | -------------------------------------------- |
| `PORT`        | `9090`      | HTTP listen port                             |
| `DB_HOST`     | `127.0.0.1` | MySQL host                                   |
| `DB_PORT`     | `3306`      | MySQL port                                   |
| `DB_USER`     | `root`      | MySQL user                                   |
| `DB_PASSWORD` | (empty)     | MySQL password                               |
| `DB_NAME`     | `lic`       | MySQL database                               |
| `LOG_DIR`     | `/var/dorian/logs` | Directory for JSONL + per-session log files |
| `GEODB_DOWNLOAD_URL` | `http://192.142.44.204/geodb/dbip-full-2026-02.mmdb.tar.gz` | URL edge hosts use to download GeoIP |

Before deploying, also seed the `versions` table with at least one row whose
`path` points to a readable `dorian-ddos-firewall-*.tar.gz` on the API host,
and place the GeoIP archive at `bin/geodb/dbip-full-2026-02.mmdb.tar.gz`
(served on `192.142.44.204` for targets to download separately during deploy).

---

## Running

```bash
npm start
```

The server listens on `PORT` (default `9090`). On startup it emits a JSON log
line (also written under `/var/dorian/logs`), for example:

```json
{"ts":"…","level":"info","component":"license-server","event":"listening","msg":"deploy_license API listening","port":9090}
```

Swagger UI is served at `http://<host>:<port>/docs` and a basic liveness
check at `http://<host>:<port>/health`.

---

## Logging

All Dorian control-plane and deploy components write under **`/var/dorian/logs`**.
Log lines are **one JSON object per line** with common fields such as `ts`,
`level`, `component`, `event`, `req_id`, and `msg`.

Create the directory once on the control plane (and on edge hosts if you want
remote `deploy.sh` logs to land there):

```bash
mkdir -p /var/dorian/logs
```

Override the license-server directory with `LOG_DIR` in `.env` if needed
(default is `/var/dorian/logs`). Remote `deploy.sh` uses `DEPLOY_LOG_DIR`
(default `/var/dorian/logs`).

### Log files

| File / pattern | Component | Contents |
| -------------- | --------- | -------- |
| `/var/dorian/logs/backend.log` | Panel Go API | HTTP requests (`http_request`), error responses, deploy_license client calls, other API events |
| `/var/dorian/logs/license-server.log` | `deploy_license` process | stdout/stderr of `node server.js` (JSON lines) |
| `/var/dorian/logs/deploy_license-YYYY-MM-DD.jsonl` | `deploy_license` | Daily structured events (SSH/SCP steps, GeoIP background, successes/failures) |
| `/var/dorian/logs/<ip>__<token>.log` | `deploy_license` | Per-deploy session trail for one host + deployment token |
| `/var/dorian/logs/deploy-<run_id>.log` | Target `bin/deploy.sh` | Phase timings on the edge (`extract_*`, venv, systemd); `run_id` matches request id when passed via `DEPLOY_RUN_ID` |

Frontend failed API calls also print JSON lines in the browser DevTools console
(`"component":"frontend"`). Error toasts and the create/upgrade dialogs can
show expandable technical details (`script_error`, `stderr`, `req_id`, …).

### Correlating a failed deploy

1. Note `req_id` from the UI error details, response header `X-Request-Id`, or
   the API error JSON field `req_id`.
2. Search control-plane logs:

```bash
grep '"req_id":"<REQ_ID>"' /var/dorian/logs/backend.log
grep '"req_id":"<REQ_ID>"' /var/dorian/logs/license-server.log
grep '"req_id":"<REQ_ID>"' /var/dorian/logs/deploy_license-*.jsonl
```

3. Open the matching session file if present:

```bash
ls /var/dorian/logs/<ip>__*.log
```

4. On the edge host, check the remote deploy script log:

```bash
ls /var/dorian/logs/deploy-*.log
```

Useful filters:

```bash
grep '"level":"error"' /var/dorian/logs/backend.log /var/dorian/logs/license-server.log
grep '"event":"http_request"' /var/dorian/logs/backend.log | tail
```

---

## API

Full schemas live in `openapi.yaml` (and at `/docs`). Quick reference:

### `GET /get_versions`

Returns Dorian product versions from the `versions` table, newest first.

```json
{
  "versions": [
    {
      "uuid": "…",
      "version": "0.1.7",
      "os": "ubuntu-22.04",
      "full_name": "dorian-ddos-firewall-0.1.7-ubuntu-22.04-payload-<sha256>.tar.gz",
      "path": "/opt/dorian/uploads/dorian-ddos-firewall-0.1.7-ubuntu-22.04-payload-<sha256>.tar.gz",
      "updated": "2026-05-13T00:00:00.000Z"
    }
  ]
}
```

### `POST /create_server`

Generates (or resolves an existing) license, uploads artifacts, and runs
`deploy.sh` on the target.

Request body:

```json
{
  "name": "edge-01",
  "ip": "10.0.0.10",
  "user": "root",
  "pass": "…",
  "ssh_port": 22,
  "license_type": "trial",
  "token": "…",
  "deploy_mode": "all"
}
```

- `license_type`: one of `trial`, `l4`, `l7`, `unified` (case-insensitive).
  Each tier maps to a specific feature bitmask and duration:

  | `license_type` | feature | duration  | reuse via `license_string`? |
  | -------------- | ------- | --------- | --------------------------- |
  | `trial`        | 7       | 3 days    | no (always generates)       |
  | `l4`           | 1       | 365 days  | yes (optional)              |
  | `l7`           | 2       | 365 days  | yes (optional)              |
  | `unified`      | 3       | 365 days  | yes (optional)              |

- `license_string` (optional): only accepted when `license_type` is `l4`,
  `l7`, or `unified`. When provided, the API reuses an existing row in the
  `license` table whose `license` column matches, instead of generating a
  new license. Returns `404` if no row matches.
- `deploy_mode` (optional): `all` (default), `license_only`, or
  `version_only`.

### `POST /upgrade_version`

Uploads a selected Dorian tarball and runs `deploy.sh --version-only` on the
target (no license regeneration).

```json
{
  "name": "edge-01",
  "ip": "10.0.0.10",
  "user": "root",
  "pass": "…",
  "ssh_port": 22,
  "token": "…",
  "version_uuid": "<row uuid from /get_versions>"
}
```

### `GET /health`

Returns `{"status":"ok"}`.

### `GET /docs`

Swagger UI rendered from `openapi.yaml`.

---

## Project layout

```
deploy_license/
├── server.js                 Express app: routes, validation, SSH/SCP orchestration
├── openapi.yaml              OpenAPI 3.0 spec (rendered at /docs)
├── schema.sql                MySQL schema (license, versions, history)
├── package.json
├── .env.example              Environment variable template
├── bin/
│   ├── deploy.sh             Runs on the target server; extracts artifacts + systemd
│   ├── generate_license.sh   Wraps machine_id lookup + key gen + mklicense
│   ├── get_remote_machine_id.sh
│   ├── gen_server_keys.sh    Generates RSA keypair per license run
│   ├── mklicense / mklicense.c
│   ├── machine_id / machine_id.c
│   ├── parse_license / parse_license.c
│   ├── geodb/                Holds dbip-full-*.mmdb.tar.gz (gitignored)
│   ├── licenses/             Generated licenses keyed by machine_id/timestamp
│   └── secrets/              Server-level keypair (do not commit)

# Runtime logs (not in the repo; default on disk)
/var/dorian/logs/
├── backend.log
├── license-server.log
├── deploy_license-YYYY-MM-DD.jsonl
├── <ip>__<token>.log
└── deploy-<run_id>.log
```

---

## How a `create_server` request flows

1. Validate payload (AJV against the schema in `server.js`).
2. Fetch the latest row from `versions`; resolve the local Dorian tarball.
3. Resolve the license:
   - If `license_string` is **not** provided (any `license_type`): call
     `bin/generate_license.sh` to SSH to the target, read its `machine_id`,
     generate an RSA keypair, and run `mklicense` with the feature/duration
     that match the chosen `license_type`. Insert a new row in `license`.
   - If `license_string` **is** provided (`l4` / `l7` / `unified` only):
     look up an existing license row by `license = ?` and reuse the stored
     signed `license.lic` + public key; update connection fields on that
     row. Returns `404` if no match.
4. Build `license.tar.gz` containing the license artifacts.
5. `scp` the Dorian tarball, `license.tar.gz`, and `deploy.sh` into
   `/tmp/dorian_deploy_<token>/` on the target (GeoIP is **not** SCP'd; the
   target downloads it from `GEODB_DOWNLOAD_URL` / `192.142.44.204` in a
   background step when needed).
6. Run `bash deploy.sh --<mode>` remotely (with `GEODB_DEFER=1` on the hot
   path so create stays under gateway timeouts). On success the staging
   directory is removed; GeoIP may still be installing in the background.
7. Persist / update the row in `license` and append a row to `history`.

---

## Notes & gotchas

- `bin/deploy.sh` requires root (or `sudo`) on the target for venv creation
  under `/usr/local/share/dorian` and for installing systemd units.
- `sshpass` is used because target servers are provisioned with password
  authentication. SSH passwords are never written to disk by the API; they
  are passed via process arguments and redacted in logs.
- License files are stored under `bin/licenses/<machine_id>/<UTC timestamp>/`
  along with an `info.txt` describing the run.
- `.env`, `node_modules/`, and `bin/geodb/*` are gitignored. Runtime logs live
  under `/var/dorian/logs` (not the old in-repo `logs/` directory).
- GeoIP is served over HTTP from this host at
  `http://192.142.44.204/geodb/dbip-full-2026-02.mmdb.tar.gz` (nginx alias to
  `bin/geodb/dbip-full-2026-02.mmdb.tar.gz`).
