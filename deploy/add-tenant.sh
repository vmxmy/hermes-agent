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
TENANT_DIR="$SCRIPT_DIR/tenants/$NAME"
ENV_FILE="$TENANT_DIR/.env"
TEMPLATE="$SCRIPT_DIR/tenants/.env.template"

if [[ -d "$TENANT_DIR" ]]; then
    echo "Error: tenant '$NAME' already exists at $TENANT_DIR" >&2
    exit 1
fi

mkdir -p "$TENANT_DIR"
cp "$TEMPLATE" "$ENV_FILE"

echo "✓ Created $ENV_FILE"
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
echo "           - ${NAME}_data:/opt/data"
echo "         env_file:"
echo "           - .env.shared"
echo "           - tenants/$NAME/.env"
echo ""
echo "     And under 'volumes:':"
echo ""
echo "       ${NAME}_data:"
echo ""
echo "  3. Start the tenant:"
echo "       docker compose up -d $NAME"
echo ""
echo "  4. Tail logs:"
echo "       docker compose logs -f $NAME"
