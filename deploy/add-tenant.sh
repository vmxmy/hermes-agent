#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# add-tenant.sh — Scaffold a new hermes-agent tenant
#
# Usage: ./add-tenant.sh <tenant-name>
#
# Creates:
#   tenants/<name>/.env        (copy of .env.template)
#
# Then manually:
#   1. Edit tenants/<name>/.env to add bot tokens
#   2. Add the service block to docker-compose.yml (printed below)
#   3. docker compose up -d <name>
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
    echo "Usage: $0 <tenant-name>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure .env.shared exists
if [[ ! -f "$SCRIPT_DIR/.env.shared" ]]; then
    echo "Note: $SCRIPT_DIR/.env.shared not found."
    echo "      Run: cp $SCRIPT_DIR/.env.shared.example $SCRIPT_DIR/.env.shared"
    echo "      Then fill in your LLM API keys before starting containers."
    echo ""
fi
TENANT_DIR="$SCRIPT_DIR/tenants/$NAME"
ENV_FILE="$TENANT_DIR/.env"
TEMPLATE="$SCRIPT_DIR/tenants/.env.template"

if [[ -d "$TENANT_DIR" ]]; then
    echo "Error: tenant '$NAME' already exists at $TENANT_DIR" >&2
    exit 1
fi

mkdir -p "$TENANT_DIR/data"
cp "$TEMPLATE" "$ENV_FILE"

echo "✓ Created $ENV_FILE"
echo "✓ Created $TENANT_DIR/data/   (HERMES_HOME bind-mount target)"
echo ""
echo "Next steps:"
echo ""
echo "  1. Edit the .env file and fill in your bot tokens:"
echo "       \$EDITOR $ENV_FILE"
echo ""
echo "  2. Add this block to deploy/docker-compose.yml under 'services:':"
echo ""
echo "       $NAME:"
echo "         <<: *hermes-defaults"
echo "         container_name: hermes-$NAME"
echo "         volumes:"
echo "           - ./tenants/$NAME/data:/opt/data"
echo "         env_file:"
echo "           - .env.shared"
echo "           - tenants/$NAME/.env"
echo ""
echo "  3. Start the tenant:"
echo "       docker compose up -d $NAME"
echo ""
echo "  4. Tail logs:"
echo "       docker compose logs -f $NAME"
echo ""
echo "  Tenant data (sessions, memories, config) will be at:"
echo "       $TENANT_DIR/data/"
