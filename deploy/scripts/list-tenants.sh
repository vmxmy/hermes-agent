#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# list-tenants.sh — Show all tenants, their container status, and configured platforms
# Called via: ./hermesctl ls
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Color helpers (only when stdout is a terminal) ────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; RESET=''
fi

# ── Header ────────────────────────────────────────────────────────────────────
printf "%-20s  %-12s  %s\n" "TENANT" "STATUS" "PLATFORMS"
printf "%-20s  %-12s  %s\n" "──────────────────" "──────────" "─────────"

shopt -s nullglob
tenants=("$SCRIPT_DIR/tenants"/*/compose.yml)

if [[ ${#tenants[@]} -eq 0 ]]; then
    echo "(no tenants configured — run ./add-tenant.sh <name> to create one)"
    exit 0
fi

# ── Per-tenant row ────────────────────────────────────────────────────────────
for fragment in "${tenants[@]}"; do
    dir="$(dirname "$fragment")"
    name="$(basename "$dir")"

    # Skip dotfile dirs (.archive, etc.)
    [[ "$name" == .* ]] && continue

    # Container status via docker inspect (exact match by container name).
    # Move || outside $() so docker's stdout blank-line on failure isn't captured.
    container="hermes-${name}"
    plain_status="$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)" \
        || plain_status="not created"

    # Apply color to a copy — keep plain_status for field-width padding
    case "$plain_status" in
        running)     colored_status="${GREEN}${plain_status}${RESET}" ;;
        exited|dead) colored_status="${RED}${plain_status}${RESET}" ;;
        *)           colored_status="${YELLOW}${plain_status}${RESET}" ;;
    esac

    # Pad the plain status to 12 chars, then append color prefix/suffix
    padded="$(printf '%-12s' "$plain_status")"
    if [[ -n "$RESET" ]]; then
        display_status="${GREEN/green/}${colored_status}${padded#"$plain_status"}"
        # Simpler: color the text, then append padding spaces separately
        pad_spaces="${padded#"$plain_status"}"   # the trailing spaces
        display_status="${colored_status}${pad_spaces}"
    else
        display_status="$padded"
    fi

    # Detect configured platforms from tenant .env
    env_file="$dir/.env"
    platforms=""
    if [[ -f "$env_file" ]]; then
        grep -q '^TELEGRAM_BOT_TOKEN='      "$env_file" 2>/dev/null && platforms+="telegram "
        grep -q '^DISCORD_BOT_TOKEN='       "$env_file" 2>/dev/null && platforms+="discord "
        grep -q '^SLACK_BOT_TOKEN='         "$env_file" 2>/dev/null && platforms+="slack "
        grep -q '^WHATSAPP_ENABLED=true'    "$env_file" 2>/dev/null && platforms+="whatsapp "
        grep -q '^WEIXIN_ACCOUNT_ID='        "$env_file" 2>/dev/null && platforms+="weixin "
        grep -q '^SIGNAL_HTTP_URL='         "$env_file" 2>/dev/null && platforms+="signal "
        grep -q '^MATRIX_ACCESS_TOKEN='     "$env_file" 2>/dev/null && platforms+="matrix "
        grep -q '^API_SERVER_ENABLED=true'  "$env_file" 2>/dev/null && platforms+="api "
    fi
    platforms="${platforms% }"
    [[ -z "$platforms" ]] && platforms="(none configured)"

    printf "%-20s  %s  %s\n" "$name" "$display_status" "$platforms"
done
