#!/usr/bin/env bash
# weixin-pair.sh — Drive the iLink/Weixin QR-login flow inside a running
# hermes container, persist the credentials to the tenant .env, and
# optionally restart the gateway so the adapter picks them up.
#
# Usage:
#   ./scripts/weixin-pair.sh <tenant> [--restart] [--wait-seconds N]
#
# Prerequisites:
#   - deploy/tenants/<tenant>/ exists
#   - Container hermes-<tenant> is running  (./hermesctl up -d <tenant>)
#   - docker is on PATH
#
# After pairing, the tenant .env is updated with:
#   WEIXIN_ACCOUNT_ID, WEIXIN_TOKEN, WEIXIN_BASE_URL
# and the container is restarted if --restart is given.

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_YELLOW='\033[0;33m'
C_CYAN='\033[0;36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'

ok()   { printf "${C_GREEN}[ OK ]${C_RESET} %s\n" "$*"; }
err()  { printf "${C_RED}[FAIL]${C_RESET} %s\n" "$*" >&2; }
info() { printf "${C_CYAN}[info]${C_RESET} %s\n" "$*"; }
step() { printf "\n${C_BOLD}==> %s${C_RESET}\n" "$*"; }

# ── Paths ──────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HERMESCTL="$DEPLOY_DIR/hermesctl"

# ── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -t, --tenant NAME     Tenant name (required; dir: deploy/tenants/<tenant>/)
  --restart             After pairing, recreate the container and verify
                        the Weixin adapter connects (waits for log marker)
  --wait-seconds N      Seconds to wait for adapter connect marker (default: 120)
  -h, --help            This help

Examples:
  $(basename "$0") --tenant poc --restart --wait-seconds 120
  $(basename "$0") -t poc --restart
  $(basename "$0") poc --restart   (positional fallback)

EOF
}

TENANT=""
DO_RESTART=false
WAIT_SECONDS=120

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)       usage; exit 0 ;;
        -t|--tenant)     TENANT="$2"; shift 2 ;;
        --restart)       DO_RESTART=true; shift ;;
        --wait-seconds)  WAIT_SECONDS="$2"; shift 2 ;;
        -*)              err "Unknown option: $1"; usage; exit 2 ;;
        *)               [[ -z "$TENANT" ]] && { TENANT="$1"; shift; } || { err "Unexpected argument: $1"; exit 2; } ;;
    esac
done

if [[ -z "$TENANT" ]]; then
    err "Tenant name is required."
    usage; exit 2
fi

TENANT_DIR="$DEPLOY_DIR/tenants/$TENANT"
ENV_FILE="$TENANT_DIR/.env"
CONTAINER="hermes-$TENANT"

# ── Precheck ───────────────────────────────────────────────────────────────────
step "Precheck"

if ! command -v docker &>/dev/null; then
    err "docker not found on PATH."; exit 1
fi

if [[ ! -d "$TENANT_DIR" ]]; then
    err "Tenant directory not found: $TENANT_DIR"
    err "Create it first with: ./add-tenant.sh $TENANT"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    err ".env not found: $ENV_FILE"
    exit 1
fi

RUNNING=$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)
if [[ "$RUNNING" != "true" ]]; then
    err "Container $CONTAINER is not running."
    err "Start it with: $HERMESCTL up -d $TENANT"
    exit 1
fi

ok "docker available"
ok "Tenant dir found: $TENANT_DIR"
ok "Container $CONTAINER is running"

# ── Idempotent env writer (same pattern as e2e-tenant-test.sh) ─────────────────
set_env() {
    local key="$1" value="$2"
    [[ -z "$value" ]] && return 0
    local esc_value
    esc_value=$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${esc_value}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    info "wrote $key"
}

# ── QR login flow ──────────────────────────────────────────────────────────────
step "Weixin QR-login (inside container $CONTAINER)"
info "Launching qr_login() — scan the QR code in WeChat when it appears."
info "The QR URL will also be printed as a fallback (open in a browser)."
echo ""

# Capture all output to a temp file while also streaming to the terminal.
# We need the raw text afterwards to parse the __CREDS_JSON__ sentinel.
EXEC_OUT=$(mktemp)

# -u: unbuffered Python stdout so the QR URL streams immediately
# Temporarily disable pipefail so we can capture PIPESTATUS after tee.
set +o pipefail
docker exec --user hermes "$CONTAINER" \
    /opt/hermes/.venv/bin/python -u -c '
import asyncio, json, sys, os
# Ensure stdout is unbuffered at the fd level too
sys.stdout.reconfigure(line_buffering=True)

from gateway.platforms.weixin import qr_login
result = asyncio.run(qr_login("/opt/data"))
if not result:
    print("__QR_FAILED__", flush=True)
    sys.exit(2)
# Machine-readable sentinel on its own line
print("__CREDS_JSON__" + json.dumps(result), flush=True)
' 2>&1 | tee "$EXEC_OUT"
EXEC_EXIT="${PIPESTATUS[0]}"
set -o pipefail

echo ""

# ── Parse credentials ──────────────────────────────────────────────────────────
CREDS_LINE=$(grep '^__CREDS_JSON__' "$EXEC_OUT" || true)
rm -f "$EXEC_OUT"

if [[ -z "$CREDS_LINE" ]]; then
    err "QR login did not complete — no credential sentinel found."
    err "Possible reasons:"
    err "  - User did not scan / confirm in time (timeout ~8 min)"
    err "  - qr_login() returned None (server-side error)"
    err "  - Container exited mid-flow (exit code: $EXEC_EXIT)"
    exit 1
fi

JSON_PAYLOAD="${CREDS_LINE#__CREDS_JSON__}"

# Parse with python (available on the host via the project venv, or use jq if present)
parse_field() {
    local field="$1"
    if command -v python3 &>/dev/null; then
        python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$field',''))" "$JSON_PAYLOAD"
    elif command -v jq &>/dev/null; then
        printf '%s' "$JSON_PAYLOAD" | jq -r ".$field // empty"
    else
        # Bare sed fallback — works for simple alphanumeric values
        printf '%s' "$JSON_PAYLOAD" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
    fi
}

ACCOUNT_ID=$(parse_field account_id)
TOKEN=$(parse_field token)
BASE_URL=$(parse_field base_url)
USER_ID=$(parse_field user_id)

if [[ -z "$ACCOUNT_ID" || -z "$TOKEN" ]]; then
    err "Failed to parse account_id or token from: $JSON_PAYLOAD"
    exit 1
fi

ok "QR login successful — account_id=$ACCOUNT_ID"
[[ -n "$USER_ID" ]]  && info "user_id=$USER_ID"
[[ -n "$BASE_URL" ]] && info "base_url=$BASE_URL"

# ── Write creds to host-side .env ──────────────────────────────────────────────
step "Writing credentials to $ENV_FILE"

set_env "WEIXIN_ACCOUNT_ID" "$ACCOUNT_ID"
set_env "WEIXIN_TOKEN"      "$TOKEN"
[[ -n "$BASE_URL" ]] && set_env "WEIXIN_BASE_URL" "$BASE_URL"

# Hint if WEIXIN_ALLOWED_USERS is not yet set
if ! grep -q '^WEIXIN_ALLOWED_USERS=' "$ENV_FILE" 2>/dev/null; then
    info "Tip: add  WEIXIN_ALLOWED_USERS=<phone_or_id>  to $ENV_FILE to restrict access."
fi

ok "Credentials written"

# ── Optional restart + verify ──────────────────────────────────────────────────
if ! $DO_RESTART; then
    echo ""
    printf "${C_YELLOW}Next step:${C_RESET} recreate the gateway to reload env_file and activate Weixin:\n"
    printf "  %s up -d --force-recreate %s\n" "$HERMESCTL" "$TENANT"
    exit 0
fi

# Repair any root-owned weixin state from pre-fix runs (idempotent, safe)
docker exec "$CONTAINER" sh -c 'chown -R hermes:hermes /opt/data/weixin 2>/dev/null || true'

step "Recreating container $CONTAINER (force-recreate to reload env_file)"
"$HERMESCTL" up -d --force-recreate "$TENANT"
ok "Container recreated"

step "Waiting up to ${WAIT_SECONDS}s for Weixin adapter to connect"
MARKER="[weixin] Connected account="
DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))

while (( $(date +%s) < DEADLINE )); do
    if docker logs --tail 5000 "$CONTAINER" 2>&1 | grep -qF "$MARKER"; then
        echo ""
        ok "Weixin connected — adapter log marker seen."
        exit 0
    fi
    sleep 3
done

echo ""
err "Timed out after ${WAIT_SECONDS}s — '[weixin] Connected account=' not seen."
echo ""
printf "${C_YELLOW}--- Last 200 log lines from $CONTAINER ---${C_RESET}\n"
docker logs --tail 200 "$CONTAINER" 2>&1 || true
exit 1
