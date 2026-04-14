#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# doctor.sh — Validate multi-tenant Hermes deploy configuration
# Called via: ./hermesctl doctor
#
# Checks (all read-only, no changes made):
#   1. .env.shared exists and has at least one LLM key
#   2. Each tenant has both compose.yml and .env
#   3. No duplicate API_SERVER_PORT / TELEGRAM_WEBHOOK_PORT across tenants
#   4. Data directory UID matches expected HERMES_UID (10000)
#   5. Orphan data dirs (data/ without compose.yml)
#   6. Merged compose parses cleanly (hermesctl config)
#
# Exit code: 0 = all checks passed, 1 = one or more issues found
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_UID=10000

errors=0
warnings=0

err()  { echo "  [ERROR] $*"; (( errors++  )) || true; }
warn() { echo "  [WARN]  $*"; (( warnings++ )) || true; }
ok()   { echo "  [OK]    $*"; }

# ── 1. .env.shared ────────────────────────────────────────────────────────────
echo "==> Checking .env.shared"
if [[ ! -f "$DEPLOY_DIR/.env.shared" ]]; then
    err ".env.shared not found — copy from .env.shared.example and fill in LLM keys"
else
    # At least one LLM key must be set (not commented, not empty)
    has_key=false
    for key in ANTHROPIC_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY OPENAI_API_KEY; do
        if grep -qE "^${key}=.+" "$DEPLOY_DIR/.env.shared" 2>/dev/null; then
            has_key=true
            break
        fi
    done
    if ! $has_key; then
        err ".env.shared exists but no LLM API key found (ANTHROPIC_API_KEY, OPENROUTER_API_KEY, …)"
    else
        ok ".env.shared looks good"
    fi
fi

# ── 2. Per-tenant integrity ───────────────────────────────────────────────────
echo "==> Checking tenant directories"
shopt -s nullglob

tenant_count=0
for dir in "$DEPLOY_DIR/tenants"/*/; do
    name="$(basename "$dir")"
    [[ "$name" == .* ]] && continue  # skip .archive, etc.

    tenant_count=$(( tenant_count + 1 ))

    has_compose=false
    has_env=false
    [[ -f "$dir/compose.yml" ]] && has_compose=true
    [[ -f "$dir/.env" ]]        && has_env=true

    if ! $has_compose && ! $has_env; then
        warn "tenants/${name}/ has neither compose.yml nor .env — leftover directory?"
    elif ! $has_compose; then
        err  "tenants/${name}/ missing compose.yml (orphan .env)"
    elif ! $has_env; then
        err  "tenants/${name}/ missing .env (run: cp tenants/.env.template tenants/${name}/.env)"
    else
        ok "tenants/${name}/ — compose.yml + .env present"
    fi
done

# Orphan data dirs: data/ exists but no compose.yml
for data_dir in "$DEPLOY_DIR/tenants"/*/data/; do
    [[ -d "$data_dir" ]] || continue
    name="$(basename "$(dirname "$data_dir")")"
    [[ "$name" == .* ]] && continue
    if [[ ! -f "$DEPLOY_DIR/tenants/$name/compose.yml" ]]; then
        warn "tenants/${name}/data/ exists without compose.yml — orphan from incomplete remove?"
    fi
done

if [[ $tenant_count -eq 0 ]]; then
    warn "No tenants found. Run ./add-tenant.sh <name> to create one."
fi

# ── 3. Port conflict detection ────────────────────────────────────────────────
echo "==> Checking for port conflicts"
declare -A port_owners
errors_before_ports=$errors

check_port() {
    local port="$1"
    local source="$2"
    if [[ -z "$port" || "$port" == "0" ]]; then return; fi
    if [[ -v "port_owners[$port]" ]]; then
        err "Port $port conflict: $source and ${port_owners[$port]}"
    else
        port_owners[$port]="$source"
    fi
}

for env_file in "$DEPLOY_DIR/tenants"/*/.env; do
    [[ -f "$env_file" ]] || continue
    name="$(basename "$(dirname "$env_file")")"
    [[ "$name" == .* ]] && continue

    api_port="$(grep -E '^API_SERVER_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || true)"
    wh_port="$(grep -E '^TELEGRAM_WEBHOOK_PORT=' "$env_file" 2>/dev/null | cut -d= -f2 || true)"

    check_port "$api_port" "tenants/${name}/.env API_SERVER_PORT"
    check_port "$wh_port"  "tenants/${name}/.env TELEGRAM_WEBHOOK_PORT"
done

# Also check ports: entries in compose fragments
for fragment in "$DEPLOY_DIR/tenants"/*/compose.yml; do
    [[ -f "$fragment" ]] || continue
    name="$(basename "$(dirname "$fragment")")"
    [[ "$name" == .* ]] && continue
    while IFS= read -r port_entry; do
        # Strip host port from "host:container" or bare "port"
        host_port="$(echo "$port_entry" | cut -d: -f1 | tr -d ' "-')"
        check_port "$host_port" "tenants/${name}/compose.yml ports:"
    done < <(grep -E '^\s+-\s+"?[0-9]+' "$fragment" 2>/dev/null || true)
done

if [[ $errors -eq $errors_before_ports ]]; then
    ok "No port conflicts detected"
fi

# ── 4. Data directory UID ─────────────────────────────────────────────────────
echo "==> Checking data directory ownership"
current_uid="$(id -u)"
for data_dir in "$DEPLOY_DIR/tenants"/*/data/; do
    [[ -d "$data_dir" ]] || continue
    name="$(basename "$(dirname "$data_dir")")"
    [[ "$name" == .* ]] && continue

    dir_uid="$(stat -c '%u' "$data_dir" 2>/dev/null || stat -f '%u' "$data_dir" 2>/dev/null || echo "unknown")"
    if [[ "$dir_uid" == "unknown" ]]; then
        warn "tenants/${name}/data/ — could not stat UID"
    elif [[ "$dir_uid" != "$EXPECTED_UID" && "$dir_uid" != "$current_uid" ]]; then
        warn "tenants/${name}/data/ owned by UID $dir_uid (expected $EXPECTED_UID or current user $current_uid) — may cause permission errors unless HERMES_UID is set"
    else
        ok "tenants/${name}/data/ UID=$dir_uid"
    fi
done

# ── 5. Merged compose validates ───────────────────────────────────────────────
echo "==> Validating merged compose config"
cd "$DEPLOY_DIR"
# .env.shared is required: false in fragments so this check works even without
# the secrets file — but skip it if .env.shared is absent (caught in check #1).
if [[ ! -f "$DEPLOY_DIR/.env.shared" ]]; then
    warn "Skipping compose parse check — .env.shared missing (see check #1)"
elif ./hermesctl config > /dev/null 2>&1; then
    ok "hermesctl config parses cleanly"
else
    err "hermesctl config failed — run './hermesctl config' to see parse errors"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
if [[ $errors -gt 0 ]]; then
    echo "doctor: $errors error(s), $warnings warning(s) — fix errors before starting containers"
    exit 1
elif [[ $warnings -gt 0 ]]; then
    echo "doctor: 0 errors, $warnings warning(s) — review warnings above"
    exit 0
else
    echo "doctor: all checks passed"
    exit 0
fi
