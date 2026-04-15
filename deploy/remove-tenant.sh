#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# remove-tenant.sh — Stop and archive (or delete) a hermes-agent tenant
#
# Usage:
#   ./remove-tenant.sh -t <name>           # stop container + archive data
#   ./remove-tenant.sh -t <name> --purge   # stop container + permanently delete
#   ./remove-tenant.sh <name> [--purge]    (positional fallback)
#
# Default (archive): moves tenants/<name>/ to tenants/.archive/<name>-<ts>/
# --purge: requires typing the tenant name to confirm, then rm -rf
#
# Sessions, memories, and cron jobs live in tenants/<name>/data/.
# Default archive mode preserves this data. --purge destroys it permanently.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ─────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -t, --tenant NAME   Tenant name to remove (required)
  --purge             Permanently delete all data (default: archive)
  -h, --help          Show this help

Examples:
  $(basename "$0") --tenant poc
  $(basename "$0") -t poc --purge
  $(basename "$0") poc --purge
EOF
}

NAME=""
MODE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tenant) NAME="$2"; shift 2 ;;
        --purge)     MODE="--purge"; shift ;;
        -h|--help)   usage; exit 0 ;;
        --)          shift; break ;;
        -*) echo "Error: unknown option '$1'" >&2; usage >&2; exit 2 ;;
        *)  [[ -z "$NAME" ]] && { NAME="$1"; shift; } || { echo "Error: unexpected argument '$1'" >&2; exit 2; } ;;
    esac
done

if [[ -z "$NAME" ]]; then
    echo "Error: --tenant is required" >&2
    usage >&2
    exit 1
fi

# ── Verify tenant exists ──────────────────────────────────────────────────────
TENANT_DIR="$SCRIPT_DIR/tenants/$NAME"
if [[ ! -d "$TENANT_DIR" ]]; then
    echo "Error: tenant '$NAME' not found at $TENANT_DIR" >&2
    exit 1
fi

# ── Stop and remove container ─────────────────────────────────────────────────
echo "Stopping and removing container hermes-${NAME}..."
# -f = no confirmation prompt (we do our own below)
# -s = stop the container first (atomic: avoids restart: unless-stopped racing)
# -v = remove anonymous volumes
cd "$SCRIPT_DIR"
./hermesctl rm -fsv "$NAME" 2>/dev/null || {
    # Container may not exist yet (tenant was never started) — that's fine
    echo "  (container hermes-${NAME} was not running)"
}

# ── Archive or purge ──────────────────────────────────────────────────────────
if [[ "$MODE" == "--purge" ]]; then
    echo ""
    echo "WARNING: This will permanently delete all data for tenant '${NAME}'."
    echo "         Sessions, memories, cron jobs, and config will be lost."
    echo ""
    read -r -p "Type the tenant name to confirm deletion: " CONFIRM
    if [[ "$CONFIRM" != "$NAME" ]]; then
        echo "Confirmation did not match. Aborting." >&2
        exit 1
    fi
    # data/ is owned by UID 10000 (container's hermes user) so a plain rm -rf
    # will fail with "Permission denied" on the host.  Wipe it via an Alpine
    # container running as root first, then remove the rest with rm -rf.
    if [[ -d "$TENANT_DIR/data" ]] && command -v docker &>/dev/null; then
        docker run --rm -v "$TENANT_DIR:/w" alpine sh -c 'rm -rf /w/data' 2>/dev/null || true
    fi
    rm -rf "$TENANT_DIR"
    echo "✓ Permanently deleted $TENANT_DIR"
else
    ARCHIVE_DIR="$SCRIPT_DIR/tenants/.archive"
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    DEST="$ARCHIVE_DIR/${NAME}-${TIMESTAMP}"
    mkdir -p "$ARCHIVE_DIR"
    mv "$TENANT_DIR" "$DEST"
    echo "✓ Archived to $DEST"
    echo ""
    echo "  Data is preserved. To restore:"
    echo "    mv $DEST $TENANT_DIR"
    echo "    ./hermesctl up -d ${NAME}"
    echo ""
    echo "  To permanently delete the archive:"
    echo "    rm -rf $DEST"
fi
