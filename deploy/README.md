# Hermes Agent — Multi-Tenant Deploy

Each tenant is an isolated Hermes gateway instance: its own bot tokens, its own `HERMES_HOME` (sessions, memories, cron, config), and its own Docker container.

## Directory layout

```
deploy/
├── docker-compose.yml          # Base file (project name only — no services)
├── hermesctl                   # Wrapper script — use this instead of docker compose
├── add-tenant.sh               # Scaffold a new tenant
├── remove-tenant.sh            # Stop + archive (or delete) a tenant
├── .env.shared                 # Shared LLM keys (gitignored — copy from .env.shared.example)
├── .env.shared.example         # Template for shared keys
└── tenants/
    ├── .env.template           # Template copied to each new tenant's .env
    ├── alice/
    │   ├── compose.yml         # Service fragment (auto-discovered by hermesctl)
    │   ├── .env                # Bot tokens + platform config for alice
    │   └── data/               # HERMES_HOME bind-mount (sessions, memories, config…)
    └── bob/
        ├── compose.yml
        ├── .env
        └── data/
```

## First-time setup

```bash
cd deploy/
cp .env.shared.example .env.shared
$EDITOR .env.shared          # add your LLM API key(s)
```

## Managing tenants

### Add a tenant

```bash
./add-tenant.sh alice
$EDITOR tenants/alice/.env   # fill in bot tokens
./hermesctl up -d alice
```

### Remove a tenant (archive — keeps data)

```bash
./remove-tenant.sh alice
# Data archived to tenants/.archive/alice-<timestamp>/
```

### Remove permanently

```bash
./remove-tenant.sh alice --purge   # prompts for name confirmation
```

### List tenants + status

```bash
./hermesctl ls
```

### Validate configuration

```bash
./hermesctl doctor   # checks ports, keys, UID, orphans, compose parse
```

## Common operations

```bash
./hermesctl up -d                  # start all tenants
./hermesctl up -d alice            # start one tenant
./hermesctl down                   # stop all tenants
./hermesctl ps                     # show container status
./hermesctl logs -f alice          # tail alice's logs
./hermesctl exec alice hermes doctor   # run hermes diagnostics inside container
./hermesctl config                 # preview merged compose (debug path issues)
./hermesctl restart alice          # restart one tenant
```

## Credential loading order

Later values win on conflict:

1. `.env.shared` — LLM keys, terminal defaults, shared tool keys
2. `tenants/<name>/.env` — bot tokens, platform config, optional per-tenant LLM key override

Move any key from `.env.shared` to a tenant's `.env` to make it tenant-specific.

## How `hermesctl` works

`hermesctl` is a thin bash wrapper that builds a `-f` flag list by globbing `tenants/*/compose.yml` and forwards everything to `docker compose`:

```bash
docker compose -f docker-compose.yml -f tenants/alice/compose.yml -f tenants/bob/compose.yml "$@"
```

Adding or removing tenants is a **filesystem operation only** — no YAML editing required. The running tenant set is always `ls tenants/*/compose.yml`.

### Why not use `docker compose` directly?

Bare `docker compose up` from this directory reads only `docker-compose.yml`, which has no services. Always use `./hermesctl`.

## Path resolution in tenant fragments

Compose resolves all relative paths against the **first `-f` file's directory** (`deploy/`), not the fragment's own directory. Tenant `compose.yml` files are therefore written with paths relative to `deploy/`:

```yaml
# tenants/alice/compose.yml
services:
  alice:
    build:
      context: ..              # deploy/../  =  repo root  (Dockerfile is here)
      dockerfile: Dockerfile
    volumes:
      - ./tenants/alice/data:/opt/data   # deploy/tenants/alice/data/
    env_file:
      - .env.shared                      # deploy/.env.shared
      - tenants/alice/.env               # deploy/tenants/alice/.env
```

This is intentional, not a bug. Use `./hermesctl config` to inspect the fully-resolved merged config.

## UID / volume ownership

The Hermes container runs as UID 10000 (`hermes` user). `add-tenant.sh` pre-sets `tenants/<name>/data/` ownership to 10000:10000. If that fails (not running as root), the container's entrypoint fixes it on first start via `gosu`.

To run as a different UID, set `HERMES_UID` in `.env.shared` or the tenant's `.env`:

```bash
HERMES_UID=1000   # match your host user UID
```

## API server port allocation

Each tenant that enables `API_SERVER_ENABLED=true` needs a unique `API_SERVER_PORT`. Pick ports manually in each tenant's `.env` (e.g. 8001, 8002…) and expose them in the tenant's `compose.yml` under `ports:`. Run `./hermesctl doctor` to detect conflicts before starting.
