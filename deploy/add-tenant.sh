#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# add-tenant.sh — Scaffold a new hermes-agent tenant
#
# Usage: ./add-tenant.sh <tenant-name>
#
# Creates:
#   tenants/<name>/compose.yml   (service fragment, auto-discovered by hermesctl)
#   tenants/<name>/.env          (copy of tenants/.env.template)
#   tenants/<name>/data/         (HERMES_HOME bind-mount target)
#
# Then:
#   1. Edit tenants/<name>/.env to add bot tokens
#   2. ./hermesctl up -d <name>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument validation ───────────────────────────────────────────────────────
NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    echo "Usage: $0 <tenant-name>" >&2
    exit 1
fi

# Names become container names and directory names — keep them safe
if ! [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "Error: tenant name must match [a-z0-9][a-z0-9-]+ (lowercase, digits, hyphens only)" >&2
    exit 1
fi

# Reserved names (directories with special meaning under tenants/)
for reserved in archive scripts; do
    if [[ "$NAME" == "$reserved" ]]; then
        echo "Error: '$NAME' is a reserved name" >&2
        exit 1
    fi
done

# ── Ensure shared env exists ──────────────────────────────────────────────────
if [[ ! -f "$SCRIPT_DIR/.env.shared" ]]; then
    echo "Note: $SCRIPT_DIR/.env.shared not found."
    echo "      Run: cp $SCRIPT_DIR/.env.shared.example $SCRIPT_DIR/.env.shared"
    echo "      Then fill in your LLM API keys before starting containers."
    echo ""
fi

# ── Create tenant directory ───────────────────────────────────────────────────
TENANT_DIR="$SCRIPT_DIR/tenants/$NAME"
if [[ -d "$TENANT_DIR" ]]; then
    echo "Error: tenant '$NAME' already exists at $TENANT_DIR" >&2
    exit 1
fi

mkdir -p "$TENANT_DIR/data"

# Pre-set UID so bind-mount permissions work without root-on-first-start.
# The entrypoint will also fix this via gosu on first startup.
chown 10000:10000 "$TENANT_DIR/data" 2>/dev/null || true

# ── Write .env from template ──────────────────────────────────────────────────
cp "$SCRIPT_DIR/tenants/.env.template" "$TENANT_DIR/.env"

# ── Write compose fragment ────────────────────────────────────────────────────
# Paths are relative to deploy/ (the project directory anchored by the base
# docker-compose.yml, which is always the first -f flag in hermesctl).
cat > "$TENANT_DIR/compose.yml" << EOF
# Tenant: ${NAME}
# Paths are relative to deploy/ (the project directory set by the base compose file).
# See deploy/README.md for details on path resolution.
services:
  ${NAME}:
    build:
      context: ..
      dockerfile: Dockerfile
    restart: unless-stopped
    command: gateway run -v
    container_name: hermes-${NAME}
    volumes:
      - ./tenants/${NAME}/data:/opt/data
    env_file:
      - path: .env.shared
        required: false      # gitignored secret — doctor.sh validates its presence
      - tenants/${NAME}/.env
EOF

# ── Done ──────────────────────────────────────────────────────────────────────
echo "✓ Created tenants/${NAME}/compose.yml"
echo "✓ Created tenants/${NAME}/.env  (from .env.template)"
echo "✓ Created tenants/${NAME}/data/ (HERMES_HOME bind-mount target)"
echo ""
echo "Next steps:"
echo ""
echo "  1. Fill in bot tokens:"
echo "       \$EDITOR $TENANT_DIR/.env"
echo ""
echo "  2. Start the tenant:"
echo "       ./hermesctl up -d ${NAME}"
echo ""
echo "  3. Tail logs:"
echo "       ./hermesctl logs -f ${NAME}"
echo ""
echo "  4. Validate config (optional, checks for port conflicts etc.):"
echo "       ./hermesctl doctor"
echo ""
echo "  Tenant data (sessions, memories, config) will be written to:"
echo "       $TENANT_DIR/data/"
