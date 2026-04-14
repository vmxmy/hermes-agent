#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# e2e-tenant-test.sh — End-to-end test: create tenant, configure channels,
# start container, verify readiness, smoke-test, and clean up.
#
# All steps are parameterized — no interactive input required.
# Safe for CI: trap ERR auto-teardowns a partial run to avoid leftover junk.
#
# Usage:
#   ./scripts/e2e-tenant-test.sh <NAME> [OPTIONS]
#
# Run `./scripts/e2e-tenant-test.sh --help` for the full option list.
#
# Exit codes:
#   0  — all phases passed
#   1  — one or more phases failed
#   2  — precheck (Phase 0) failed (hermesctl, docker, .env.shared missing …)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMESCTL="$DEPLOY_DIR/hermesctl"
ADD_TENANT="$DEPLOY_DIR/add-tenant.sh"
REMOVE_TENANT="$DEPLOY_DIR/remove-tenant.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
NAME=""
WAIT_SECONDS=120
SKIP_BUILD=false
TEARDOWN="archive"             # archive | purge | keep
LOG_FILE=""
DRY_RUN=false
VERBOSE=false
LLM_KEY_ENV="ANTHROPIC_API_KEY"

TELEGRAM_TOKEN=""
TELEGRAM_ALLOWED_USERS=""
TELEGRAM_HOME_CHANNEL=""
TELEGRAM_REQUIRE_MENTION="false"
TELEGRAM_WEBHOOK_URL=""
TELEGRAM_WEBHOOK_PORT=""
TELEGRAM_WEBHOOK_SECRET=""

WEIXIN_TOKEN=""
WEIXIN_ACCOUNT_ID=""
WEIXIN_BASE_URL=""
WEIXIN_ALLOWED_USERS=""
WEIXIN_HOME_CHANNEL=""
WEIXIN_DM_POLICY=""
WEIXIN_GROUP_POLICY=""

API_ENABLED=false
API_PORT=""
API_KEY=""
ALLOW_ALL_USERS=false

# ── Colors / output helpers ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

log()  { printf '%s[e2e]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
step() { printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }

vrun() {
    # Dry-run aware command executor
    if $DRY_RUN; then
        printf '%s[dry]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"
        return 0
    fi
    if $VERBOSE; then
        printf '%s[run]%s %s\n' "$C_CYAN" "$C_RESET" "$*"
    fi
    "$@"
}

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") <NAME> [OPTIONS]

Required:
  NAME                              Test tenant name (will be created + torn down)

Telegram:
  --telegram-token TOKEN            BotFather token
  --telegram-allowed-users CSV      Allowed user IDs (comma-separated)
  --telegram-home-channel ID        Home channel for cron delivery
  --telegram-require-mention BOOL   Default: false
  --telegram-webhook-url URL        Webhook mode (omit for long-polling)
  --telegram-webhook-port PORT
  --telegram-webhook-secret SECRET

Weixin:
  --weixin-token TOKEN
  --weixin-account-id ID
  --weixin-base-url URL
  --weixin-allowed-users CSV
  --weixin-home-channel ID
  --weixin-dm-policy STR            open|allowlist
  --weixin-group-policy STR         open|allowlist

API server:
  --api-enabled                     Enable REST API
  --api-port PORT                   Host-side port (must be unique per tenant)
  --api-key TOKEN                   Bearer token
  --allow-all-users                 GATEWAY_ALLOW_ALL_USERS=true (DANGEROUS)

Generic:
  --llm-key-env VAR                 Which LLM key to check in .env.shared (default: ANTHROPIC_API_KEY)
  --wait-seconds N                  Gateway-ready timeout (default: 120)
  --skip-build                      Don't rebuild the image
  --teardown MODE                   archive|purge|keep (default: archive)
  --log-file PATH                   Tee all output to this file
  --dry-run                         Print planned actions, do nothing
  --verbose                         Extra logging
  -h, --help                        This help

At least one channel (--telegram-token, --weixin-token, or --api-enabled) must be provided.

Example:
  ./scripts/e2e-tenant-test.sh testbot \\
      --telegram-token '1234:AAF...' \\
      --telegram-allowed-users '1234567' \\
      --teardown archive \\
      --wait-seconds 180
EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
    usage; exit 2
fi

# First positional argument = NAME (unless it's a flag)
if [[ "${1:0:1}" != "-" ]]; then
    NAME="$1"; shift
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --telegram-token)            TELEGRAM_TOKEN="$2"; shift 2 ;;
        --telegram-allowed-users)    TELEGRAM_ALLOWED_USERS="$2"; shift 2 ;;
        --telegram-home-channel)     TELEGRAM_HOME_CHANNEL="$2"; shift 2 ;;
        --telegram-require-mention)  TELEGRAM_REQUIRE_MENTION="$2"; shift 2 ;;
        --telegram-webhook-url)      TELEGRAM_WEBHOOK_URL="$2"; shift 2 ;;
        --telegram-webhook-port)     TELEGRAM_WEBHOOK_PORT="$2"; shift 2 ;;
        --telegram-webhook-secret)   TELEGRAM_WEBHOOK_SECRET="$2"; shift 2 ;;
        --weixin-token)              WEIXIN_TOKEN="$2"; shift 2 ;;
        --weixin-account-id)         WEIXIN_ACCOUNT_ID="$2"; shift 2 ;;
        --weixin-base-url)           WEIXIN_BASE_URL="$2"; shift 2 ;;
        --weixin-allowed-users)      WEIXIN_ALLOWED_USERS="$2"; shift 2 ;;
        --weixin-home-channel)       WEIXIN_HOME_CHANNEL="$2"; shift 2 ;;
        --weixin-dm-policy)          WEIXIN_DM_POLICY="$2"; shift 2 ;;
        --weixin-group-policy)       WEIXIN_GROUP_POLICY="$2"; shift 2 ;;
        --api-enabled)               API_ENABLED=true; shift ;;
        --api-port)                  API_PORT="$2"; API_ENABLED=true; shift 2 ;;
        --api-key)                   API_KEY="$2"; shift 2 ;;
        --allow-all-users)           ALLOW_ALL_USERS=true; shift ;;
        --llm-key-env)               LLM_KEY_ENV="$2"; shift 2 ;;
        --wait-seconds)              WAIT_SECONDS="$2"; shift 2 ;;
        --skip-build)                SKIP_BUILD=true; shift ;;
        --teardown)                  TEARDOWN="$2"; shift 2 ;;
        --log-file)                  LOG_FILE="$2"; shift 2 ;;
        --dry-run)                   DRY_RUN=true; shift ;;
        --verbose)                   VERBOSE=true; shift ;;
        *) err "Unknown option: $1"; usage; exit 2 ;;
    esac
done

# ── Argument validation ───────────────────────────────────────────────────────
if [[ -z "$NAME" ]]; then
    err "NAME is required (first positional argument)"; usage; exit 2
fi

if ! [[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    err "NAME must match [a-z0-9][a-z0-9-]+"; exit 2
fi

CHANNEL_COUNT=0
[[ -n "$TELEGRAM_TOKEN" ]] && ((CHANNEL_COUNT++)) || true
[[ -n "$WEIXIN_TOKEN" ]] && ((CHANNEL_COUNT++)) || true
$API_ENABLED && ((CHANNEL_COUNT++)) || true
if (( CHANNEL_COUNT == 0 )); then
    err "At least one channel must be provided: --telegram-token, --weixin-token, or --api-enabled"
    exit 2
fi

case "$TEARDOWN" in
    archive|purge|keep) ;;
    *) err "--teardown must be archive|purge|keep"; exit 2 ;;
esac

# ── Log file tee ──────────────────────────────────────────────────────────────
if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    # Redirect stdout+stderr to both console and log file
    exec > >(tee -a "$LOG_FILE") 2>&1
    log "Logging to $LOG_FILE"
fi

# ── Trap for auto-teardown on unexpected failure ──────────────────────────────
TEARDOWN_DONE=false
EXIT_STAGE="setup"

auto_teardown() {
    local code=$?
    if $TEARDOWN_DONE; then return "$code"; fi
    if [[ "$TEARDOWN" == "keep" ]]; then
        warn "Exit at stage '$EXIT_STAGE' (code $code); --teardown keep — leaving tenant intact"
        return "$code"
    fi
    warn "Exit at stage '$EXIT_STAGE' (code $code); running emergency teardown"
    if [[ -d "$DEPLOY_DIR/tenants/$NAME" ]]; then
        # Emergency mode: always archive (safer than purge) regardless of --teardown
        ( cd "$DEPLOY_DIR" && "$REMOVE_TENANT" "$NAME" ) || true
    fi
    TEARDOWN_DONE=true
    return "$code"
}
trap auto_teardown EXIT

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 0 — Precheck
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-0-precheck"
step "Phase 0: Precheck"

if ! command -v docker >/dev/null 2>&1; then
    err "docker not found in PATH"; exit 2
fi
if ! docker info >/dev/null 2>&1; then
    err "docker daemon not responding (docker info failed)"; exit 2
fi
ok "docker is available"

for f in "$HERMESCTL" "$ADD_TENANT" "$REMOVE_TENANT"; do
    if [[ ! -x "$f" ]]; then
        err "$f not found or not executable"; exit 2
    fi
done
ok "hermesctl / add-tenant / remove-tenant are executable"

if [[ ! -f "$DEPLOY_DIR/.env.shared" ]]; then
    err ".env.shared missing — copy from .env.shared.example and fill in LLM keys"
    exit 2
fi

if ! grep -qE "^${LLM_KEY_ENV}=.+" "$DEPLOY_DIR/.env.shared"; then
    err ".env.shared does not contain ${LLM_KEY_ENV} — cannot test without an LLM key"
    exit 2
fi
ok ".env.shared has ${LLM_KEY_ENV}"

if [[ -d "$DEPLOY_DIR/tenants/$NAME" ]]; then
    err "tenants/$NAME already exists — pick a different NAME or remove it first"
    exit 2
fi

# Baseline doctor must be clean
cd "$DEPLOY_DIR"
if ! "$HERMESCTL" doctor >/dev/null 2>&1; then
    warn "Baseline doctor reported issues (continuing anyway — run ./hermesctl doctor to inspect)"
else
    ok "Baseline ./hermesctl doctor is clean"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Create tenant
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-1-create"
step "Phase 1: Create tenant"

cd "$DEPLOY_DIR"
vrun "$ADD_TENANT" "$NAME"

TENANT_DIR="$DEPLOY_DIR/tenants/$NAME"
ENV_FILE="$TENANT_DIR/.env"

if ! $DRY_RUN; then
    for f in "$TENANT_DIR/compose.yml" "$ENV_FILE" "$TENANT_DIR/data"; do
        if [[ ! -e "$f" ]]; then
            err "Expected $f after add-tenant.sh but not found"; exit 1
        fi
    done
fi
ok "tenants/$NAME/{compose.yml,.env,data/} created"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Write channel config into .env
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-2-configure"
step "Phase 2: Write channel config"

# Idempotent env writer — handles URLs / colons / ampersands safely
set_env() {
    local key="$1" value="$2"
    [[ -z "$value" ]] && return 0
    if $DRY_RUN; then
        printf '%s[dry]%s set_env %s=%s\n' "$C_YELLOW" "$C_RESET" "$key" "$value"
        return 0
    fi
    local esc_value
    esc_value=$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${esc_value}|" "$ENV_FILE"
        rm -f "${ENV_FILE}.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
    if $VERBOSE; then log "set $key"; fi
    return 0
}

# Telegram
if [[ -n "$TELEGRAM_TOKEN" ]]; then
    set_env TELEGRAM_BOT_TOKEN         "$TELEGRAM_TOKEN"
    set_env TELEGRAM_ALLOWED_USERS     "$TELEGRAM_ALLOWED_USERS"
    set_env TELEGRAM_HOME_CHANNEL      "$TELEGRAM_HOME_CHANNEL"
    set_env TELEGRAM_REQUIRE_MENTION   "$TELEGRAM_REQUIRE_MENTION"
    set_env TELEGRAM_WEBHOOK_URL       "$TELEGRAM_WEBHOOK_URL"
    set_env TELEGRAM_WEBHOOK_PORT      "$TELEGRAM_WEBHOOK_PORT"
    set_env TELEGRAM_WEBHOOK_SECRET    "$TELEGRAM_WEBHOOK_SECRET"
    ok "Telegram env vars written"
fi

# Weixin
if [[ -n "$WEIXIN_TOKEN" ]]; then
    set_env WEIXIN_TOKEN               "$WEIXIN_TOKEN"
    set_env WEIXIN_ACCOUNT_ID          "$WEIXIN_ACCOUNT_ID"
    set_env WEIXIN_BASE_URL            "$WEIXIN_BASE_URL"
    set_env WEIXIN_ALLOWED_USERS       "$WEIXIN_ALLOWED_USERS"
    set_env WEIXIN_HOME_CHANNEL        "$WEIXIN_HOME_CHANNEL"
    set_env WEIXIN_DM_POLICY           "$WEIXIN_DM_POLICY"
    set_env WEIXIN_GROUP_POLICY        "$WEIXIN_GROUP_POLICY"
    ok "Weixin env vars written"
fi

# API server
if $API_ENABLED; then
    set_env API_SERVER_ENABLED         "true"
    [[ -n "$API_PORT" ]] && set_env API_SERVER_PORT  "$API_PORT"
    [[ -n "$API_KEY"  ]] && set_env API_SERVER_KEY   "$API_KEY"
    ok "API server env vars written"
fi

if $ALLOW_ALL_USERS; then
    set_env GATEWAY_ALLOW_ALL_USERS "true"
    warn "GATEWAY_ALLOW_ALL_USERS=true — anyone who knows the bot can send messages"
fi

# Verify the key we care about most (Telegram token) really landed
if [[ -n "$TELEGRAM_TOKEN" ]] && ! $DRY_RUN; then
    if ! grep -q "^TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}\$" "$ENV_FILE"; then
        err "TELEGRAM_BOT_TOKEN did not land in $ENV_FILE"; exit 1
    fi
fi
ok "Channel config verified in $ENV_FILE"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Pre-start validation
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-3-validate"
step "Phase 3: Pre-start validation"

cd "$DEPLOY_DIR"
if ! $DRY_RUN; then
    if ! "$HERMESCTL" doctor; then
        err "hermesctl doctor failed after config"; exit 1
    fi
    if ! "$HERMESCTL" config >/dev/null; then
        err "hermesctl config (merged compose) failed to parse"; exit 1
    fi
    if ! "$HERMESCTL" config --services 2>/dev/null | grep -qx "$NAME"; then
        err "Service '$NAME' not present in merged compose"; exit 1
    fi
fi
ok "doctor + config + service-list all green"

# Host port conflict check for API server
if $API_ENABLED && [[ -n "$API_PORT" ]] && ! $DRY_RUN; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${API_PORT}\$"; then
        err "Host port ${API_PORT} already in use"; exit 1
    fi
    ok "Host port ${API_PORT} is free"
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 4 — Start container
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-4-start"
step "Phase 4: Start container"

UP_FLAGS=(-d)
$SKIP_BUILD || UP_FLAGS+=(--build)

cd "$DEPLOY_DIR"
vrun "$HERMESCTL" up "${UP_FLAGS[@]}" "$NAME"

CONTAINER="hermes-$NAME"
if ! $DRY_RUN; then
    deadline=$(( $(date +%s) + 60 ))
    while (( $(date +%s) < deadline )); do
        st=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "")
        if [[ "$st" == "running" ]]; then
            ok "Container $CONTAINER is running"
            break
        fi
        sleep 1
    done
    st=$(docker inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo "")
    if [[ "$st" != "running" ]]; then
        err "Container $CONTAINER not running (status=$st)"
        docker logs --tail 100 "$CONTAINER" 2>&1 || true
        exit 1
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Gateway readiness (log markers)
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-5-ready"
step "Phase 5: Wait for gateway to be ready (up to ${WAIT_SECONDS}s)"

wait_for_log_marker() {
    local marker="$1" timeout="$2"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if "$HERMESCTL" logs --tail 5000 "$NAME" 2>&1 | grep -qF "$marker"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

if ! $DRY_RUN; then
    # Per-platform markers
    if [[ -n "$TELEGRAM_TOKEN" ]]; then
        if wait_for_log_marker "Connected to Telegram" "$WAIT_SECONDS"; then
            ok "Telegram: 'Connected to Telegram' seen in logs"
        else
            err "Timeout waiting for 'Connected to Telegram' — dumping last 2000 log lines:"
            "$HERMESCTL" logs --tail 2000 "$NAME" 2>&1 || true
            exit 1
        fi
    fi

    # Gateway-wide ready marker: "Gateway running with N platform(s)" appears just
    # before the final "Press Ctrl+C to stop" logger line, both at INFO level (visible
    # with gateway run -v). Avoids matching the banner box which also contains
    # "Press Ctrl+C to stop" and is printed before platforms even connect.
    if wait_for_log_marker "Gateway running with" "$WAIT_SECONDS"; then
        ok "Gateway fully ready ('Gateway running with' seen)"
    else
        err "Timeout waiting for gateway to fully start — dumping last 2000 log lines:"
        "$HERMESCTL" logs --tail 2000 "$NAME" 2>&1 || true
        exit 1
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 6 — Channel smoke tests
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-6-smoke"
step "Phase 6: Channel smoke tests"

smoke_telegram() {
    local token="$1"
    local me_json
    if ! me_json=$(curl -sfS --max-time 10 "https://api.telegram.org/bot${token}/getMe"); then
        err "Telegram getMe HTTP failed"; return 1
    fi
    if ! grep -q '"ok":true' <<<"$me_json"; then
        err "Telegram getMe returned not-ok: $me_json"; return 1
    fi
    local bot_name
    bot_name=$(grep -oE '"username":"[^"]+"' <<<"$me_json" | head -1 | cut -d'"' -f4)
    ok "Telegram getMe ok — bot @${bot_name:-?}"

    local wh_json
    wh_json=$(curl -sfS --max-time 10 "https://api.telegram.org/bot${token}/getWebhookInfo" || echo '{}')
    local wh_url
    wh_url=$(grep -oE '"url":"[^"]*"' <<<"$wh_json" | head -1 | cut -d'"' -f4)
    if [[ -n "$TELEGRAM_WEBHOOK_URL" ]]; then
        if [[ "$wh_url" == "$TELEGRAM_WEBHOOK_URL" ]]; then
            ok "Telegram webhook URL = $wh_url"
        else
            warn "Telegram webhook URL mismatch: expected '$TELEGRAM_WEBHOOK_URL', got '$wh_url'"
        fi
    else
        if [[ -z "$wh_url" ]]; then
            ok "Telegram polling mode confirmed (webhook URL empty)"
        else
            warn "Long-polling expected but webhook URL is set: $wh_url"
        fi
    fi
    return 0
}

smoke_api() {
    local port="$1" key="$2"
    local base="http://localhost:${port}"
    local hdr=(-H "Authorization: Bearer ${key}")
    if ! curl -sfS --max-time 10 "${hdr[@]}" "${base}/v1/models" >/dev/null; then
        err "API /v1/models failed"; return 1
    fi
    ok "API /v1/models returned 200"
    local resp
    if ! resp=$(curl -sfS --max-time 30 -X POST "${hdr[@]}" \
        -H "Content-Type: application/json" \
        -d '{"model":"default","messages":[{"role":"user","content":"ping"}]}' \
        "${base}/v1/chat/completions"); then
        err "API /v1/chat/completions failed"; return 1
    fi
    if grep -q '"content"' <<<"$resp"; then
        ok "API /v1/chat/completions returned content"
    else
        warn "API /v1/chat/completions response missing content field: $resp"
    fi
    return 0
}

if ! $DRY_RUN; then
    if [[ -n "$TELEGRAM_TOKEN" ]]; then
        smoke_telegram "$TELEGRAM_TOKEN" || exit 1
    fi
    if [[ -n "$WEIXIN_TOKEN" ]]; then
        warn "Weixin smoke test skipped (no standard health endpoint) — env vars verified in Phase 8"
    fi
    if $API_ENABLED && [[ -n "$API_PORT" && -n "$API_KEY" ]]; then
        smoke_api "$API_PORT" "$API_KEY" || exit 1
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 7 — In-container health
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-7-health"
step "Phase 7: In-container health"

if ! $DRY_RUN; then
    if "$HERMESCTL" exec -T "$NAME" /opt/hermes/.venv/bin/hermes doctor >/tmp/.hermes-doctor-$$.log 2>&1; then
        ok "hermes doctor (inside container) passed"
    else
        err "hermes doctor (inside container) failed:"
        cat /tmp/.hermes-doctor-$$.log || true
        rm -f /tmp/.hermes-doctor-$$.log
        exit 1
    fi
    rm -f /tmp/.hermes-doctor-$$.log

    if "$HERMESCTL" exec -T "$NAME" sh -c 'echo probe > /opt/data/.e2e_write_probe && cat /opt/data/.e2e_write_probe && rm -f /opt/data/.e2e_write_probe' >/dev/null 2>&1; then
        ok "HERMES_HOME (/opt/data) is writable inside container"
    else
        err "HERMES_HOME not writable — bind-mount or UID issue"
        exit 1
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 8 — Allowlist / auth injection
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-8-auth"
step "Phase 8: Verify allowlist / auth env injection"

check_env_in_container() {
    local key="$1" expected="$2"
    [[ -z "$expected" ]] && return 0
    local actual
    actual=$("$HERMESCTL" exec -T "$NAME" printenv "$key" 2>/dev/null || true)
    if [[ "$actual" == "$expected" ]]; then
        ok "$key correctly set inside container"
        return 0
    fi
    err "$key inside container: expected '$expected', got '$actual'"
    return 1
}

if ! $DRY_RUN; then
    AUTH_OK=true
    [[ -n "$TELEGRAM_ALLOWED_USERS" ]] && { check_env_in_container TELEGRAM_ALLOWED_USERS "$TELEGRAM_ALLOWED_USERS" || AUTH_OK=false; }
    [[ -n "$WEIXIN_ALLOWED_USERS"   ]] && { check_env_in_container WEIXIN_ALLOWED_USERS   "$WEIXIN_ALLOWED_USERS"   || AUTH_OK=false; }
    if $ALLOW_ALL_USERS; then
        check_env_in_container GATEWAY_ALLOW_ALL_USERS "true" || AUTH_OK=false
    fi
    $AUTH_OK || exit 1
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 9 — Teardown
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-9-teardown"
step "Phase 9: Teardown ($TEARDOWN)"

cd "$DEPLOY_DIR"
case "$TEARDOWN" in
    archive)
        vrun "$REMOVE_TENANT" "$NAME"
        ok "Tenant archived to tenants/.archive/"
        ;;
    purge)
        # remove-tenant.sh --purge asks for typed confirmation of the name
        if $DRY_RUN; then
            printf '%s[dry]%s %s %s --purge (with stdin=%s)\n' "$C_YELLOW" "$C_RESET" "$REMOVE_TENANT" "$NAME" "$NAME"
        else
            printf '%s\n' "$NAME" | "$REMOVE_TENANT" "$NAME" --purge
        fi
        ok "Tenant purged"
        ;;
    keep)
        warn "--teardown keep — tenant left intact. Clean up manually:"
        warn "  cd $DEPLOY_DIR && ./remove-tenant.sh $NAME [--purge]"
        ;;
esac
TEARDOWN_DONE=true

# Final baseline check
if ! $DRY_RUN && [[ "$TEARDOWN" != "keep" ]]; then
    if "$HERMESCTL" doctor >/dev/null 2>&1; then
        ok "Final ./hermesctl doctor clean"
    else
        warn "Final doctor reported issues (inspect with ./hermesctl doctor)"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 10 — Summary
# ═════════════════════════════════════════════════════════════════════════════
EXIT_STAGE="phase-10-summary"
step "Phase 10: Summary"

printf '\n%s✓ e2e-tenant-test PASSED%s  tenant=%s  channels=' "$C_GREEN" "$C_RESET" "$NAME"
parts=()
[[ -n "$TELEGRAM_TOKEN" ]] && parts+=("telegram")
[[ -n "$WEIXIN_TOKEN"   ]] && parts+=("weixin")
$API_ENABLED            && parts+=("api")
printf '%s\n' "$(IFS=,; echo "${parts[*]}")"

exit 0
