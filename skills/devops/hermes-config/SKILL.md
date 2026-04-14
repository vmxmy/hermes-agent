---
name: hermes-config
description: "Manage Hermes configuration — view, edit, validate, and migrate settings across config.yaml, .env, and skill-declared config. Knows the full field catalog, which surface each setting belongs to, and the `hermes config` CLI."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [configuration, config, settings, env, yaml, meta, devops]
    related_skills: [webhook-subscriptions, plan]
---

# Hermes Configuration

Authoritative reference and workflow for Hermes configuration. Use this skill whenever the user asks about what a config key does, where to put a new setting, why something "isn't taking effect", or how to validate / migrate their setup.

## When to Use

Activate when the user:

- Asks "how do I configure X?" / "where does X go — config.yaml or .env?"
- Wants to inspect / change / validate their current Hermes config
- Reports that a setting "doesn't work" (often: wrong surface, env vs yaml collision, or old config version)
- Needs to migrate config across Hermes versions
- Is setting up a new Hermes profile, docker tenant, or deployment and wants to know the full configuration surface

## Configuration Surfaces (three layers)

Hermes reads configuration from three distinct places, each with its own purpose. Knowing which surface a setting belongs to is the single most important thing about Hermes config.

| Surface | Path | Purpose | Precedence |
|---|---|---|---|
| **`config.yaml`** | `$HERMES_HOME/config.yaml` | Behavior, features, defaults | Primary source for non-secret settings. Loaded via `load_config()` — deep-merged onto `DEFAULT_CONFIG`. |
| **`.env`** | `$HERMES_HOME/.env` | Secrets, tokens, URLs, per-deployment toggles | Loaded into `os.environ`. Platform tokens and API keys **only** live here. |
| **Skill config** | `config.yaml → skills.config.<key>` | Settings declared by a skill's `metadata.hermes.config` frontmatter | Auto-injected into that skill's message as a `[Skill config: key=value]` prefix. |

`$HERMES_HOME` defaults to `~/.hermes/` but can be overridden per profile. Always resolve via `get_hermes_home()`, never hardcode `~/.hermes`.

### Priority rules (asymmetric, beware)

Not a simple "env wins" or "yaml wins" — it depends on the field:

- **Platform tokens** (`TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, …): env **overrides** `config.yaml` via `_apply_env_overrides()` in `gateway/config.py`.
- **Terminal settings** (`terminal.backend`, `terminal.timeout`, …): `config.yaml` **overrides** env. `gateway/run.py:73-136` writes `config.yaml` values back into `os.environ` at gateway startup.
- **LLM model choice**: `config.yaml` `model` is the default; CLI `--model` flag and runtime env override it.
- **API keys** (`ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, …): read directly from `os.environ` — **cannot be set in `config.yaml`**.

## Quick Reference — CLI Commands

```bash
hermes config show               # print effective merged config
hermes config edit               # open config.yaml in $EDITOR
hermes config set <key> <value>  # write one value into config.yaml
hermes config path               # print config.yaml path
hermes config env-path           # print .env file path
hermes config check              # check for missing / outdated config
hermes config migrate            # migrate old config to current schema version

hermes skills config             # interactive skill enable/disable selector
hermes doctor                    # overall health check (keys, versions, reachability)
```

For a new deployment: run `hermes config migrate` to scaffold defaults, then edit `$HERMES_HOME/.env` for secrets.

## config.yaml Field Catalog

All top-level keys in `DEFAULT_CONFIG` (see `hermes_cli/config.py:311-704`). Each section below lists the most commonly edited subfields; uncommon fields are marked `[advanced]`.

### `model` (string) + `providers` / `fallback_providers`

```yaml
model: anthropic/claude-opus-4.6   # primary model
providers:                          # custom provider dict (v12+, replaces custom_providers)
  my-openrouter:
    base_url: https://openrouter.ai/api/v1
    api_key_env: OPENROUTER_API_KEY
fallback_providers: []              # ordered fallback list on primary failure
credential_pool_strategies: {}      # [advanced] rotating credential pools
```

### `toolsets` (list)

```yaml
toolsets:
  - hermes-cli                     # default bundle
  - web-research                   # optional toolsets — see `hermes toolsets list`
```

Toolsets gate tool availability and affect which skills activate.

### `agent` (dict) — runtime limits

```yaml
agent:
  max_turns: 90                    # max tool-call iterations per conversation
  gateway_timeout: 1800             # seconds before idle gateway session dies
  gateway_timeout_warning: 900     # warn user N seconds before timeout
  gateway_notify_interval: 600     # "still working" ping interval during long tasks
  restart_drain_timeout: 60        # graceful shutdown deadline
  tool_use_enforcement: auto       # auto | true | false | [model-substring-list]
  service_tier: ""                 # "" | standard | priority (Anthropic only)
```

### `terminal` (dict) — execution backend

```yaml
terminal:
  backend: local                   # local | ssh | docker | singularity | modal | daytona
  timeout: 180                     # per-command default timeout (seconds)
  persistent_shell: true           # reuse one shell across commands
  cwd: "."
  env_passthrough: []              # env vars to leak into non-skill commands

  # docker backend
  docker_image: ""                 # required if backend=docker
  docker_forward_env: []
  docker_env: {}
  docker_volumes: []
  docker_mount_cwd_to_workspace: false
  container_cpu: 1                 # cpu cores
  container_memory: 5120           # MB
  container_disk: 51200            # MB
  container_persistent: true

  # other backend-specific
  singularity_image: ""
  modal_image: ""
  modal_mode: auto
  daytona_image: ""
```

### `browser` (dict)

```yaml
browser:
  inactivity_timeout: 120          # seconds of idle before session closes
  command_timeout: 30
  record_sessions: false
  allow_private_urls: false        # allow localhost / 10.x / 192.168.x
  camofox:
    managed_persistence: false
```

### `compression` (dict) — context auto-summarization

```yaml
compression:
  enabled: true
  threshold: 0.50                  # compress when context usage > 50%
  target_ratio: 0.20               # compress down to 20% of window
  protect_last_n: 20               # never compress the last N messages
```

### `checkpoints` (dict) — filesystem snapshots

```yaml
checkpoints:
  enabled: true
  max_snapshots: 50
```

### `smart_model_routing` (dict)

```yaml
smart_model_routing:
  enabled: false
  max_simple_chars: 160
  max_simple_words: 28
  cheap_model:                     # route simple turns here
    provider: openrouter
    model: google/gemini-2.5-flash
```

### `auxiliary` (dict) — helper models for specific subtasks

```yaml
auxiliary:
  vision: { model, provider, api_key, base_url }
  web_extract: { ... }
  compression: { ... }
  session_search: { ... }
  skills_hub: { ... }
  approval: { ... }
  mcp: { ... }
  flush_memories: { ... }
```

Each subtask can point at a cheaper/faster model without changing the primary `model`.

### `delegation` (dict) — subagent models

```yaml
delegation:
  model: ""
  provider: ""
  base_url: ""
  api_key: ""
  max_iterations: 50
  reasoning_effort: ""             # "" | low | medium | high
```

### `display` (dict) — CLI rendering

```yaml
display:
  compact: false
  personality: kawaii              # kawaii | pirate | etc (see personalities)
  resume_display: full             # full | compact | off
  busy_input_mode: interrupt       # interrupt | queue
  bell_on_complete: false
  show_reasoning: false
  streaming: false
  inline_diffs: true
  show_cost: false
  skin: default                    # ui theme, consumed by skin_engine.py
  interim_assistant_messages: true
  tool_progress_command: false
  tool_preview_length: 0
  platforms:                       # per-platform display overrides
    telegram: { tool_progress: all }
    slack:    { tool_progress: off }
```

`display.tool_progress_overrides` is **deprecated** — use `display.platforms` instead.

### `privacy` (dict)

```yaml
privacy:
  redact_pii: false                # hash user IDs, strip phone numbers in logs
```

### `tts` / `stt` / `voice` (dicts)

```yaml
tts:
  provider: edge                   # edge | elevenlabs | openai | mistral | neutts
  edge: {}
  elevenlabs: { voice_id, model }
  openai: { voice, model }
  mistral: { ... }

stt:
  enabled: true
  provider: local                  # local | openai | mistral
  local: {}

voice:
  record_key: ctrl+b
  max_recording_seconds: 120
  auto_tts: false
  silence_threshold: 200
  silence_duration: 3.0
```

### `memory` (dict) — persistent user memory

```yaml
memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
  provider: ""                     # plugin: mem0 | honcho | retaindb | ...
```

### `context` (dict) — context engine selection

```yaml
context:
  engine: compressor               # compressor | lcm (plugin)
```

### `skills` (dict)

```yaml
skills:
  external_dirs: []                # extra skill source directories
  config:                          # skill-declared settings, namespaced by key
    wiki:
      path: "~/wiki"
```

**Do not edit `skills.config.*` by hand** — skills declare their own keys via `metadata.hermes.config` frontmatter, and `hermes config migrate` scaffolds them.

### `discord` / `whatsapp` (dicts) — platform behavior (NOT tokens)

```yaml
discord:
  require_mention: true
  free_response_channels: ""       # comma-separated IDs where bot replies without mention
  allowed_channels: ""
  auto_thread: true
  reactions: true

whatsapp:
  reply_prefix: ""
```

**Tokens stay in `.env`**, behavior stays here.

### `approvals` (dict) + `command_allowlist` (list)

```yaml
approvals:
  mode: manual                     # manual | smart | off
  timeout: 60                      # seconds before auto-deny

command_allowlist:                 # commands that bypass approval
  - "^git status$"
  - "^ls "
```

### `quick_commands` / `personalities` (dicts)

```yaml
quick_commands:
  ship: "run tests, commit, push"

personalities:
  mascot:
    identity: "You are a cheerful cat developer."
```

### `security` (dict)

```yaml
security:
  redact_secrets: true             # mask API keys in tool output
  tirith_enabled: true             # static analysis pre-execution
  tirith_path: tirith
  tirith_timeout: 5
  tirith_fail_open: true
  website_blocklist:
    enabled: false
    domains: []
    shared_files: []
```

### `cron` / `logging` / `network` / `timezone`

```yaml
cron:
  wrap_response: true              # wrap cron output as assistant message

logging:
  level: INFO
  max_size_mb: 5
  backup_count: 3

network:
  force_ipv4: false

timezone: ""                       # IANA zone, e.g. Asia/Shanghai
```

### `file_read_max_chars` (int)

```yaml
file_read_max_chars: 100000        # max chars returned by read_file in one call
```

### `_config_version` (int) — do not edit manually

Managed by `migrate_config()`. Current schema: **17**. Bump triggers automatic migration on next load.

---

## .env Variable Catalog

See `OPTIONAL_ENV_VARS` in `hermes_cli/config.py:728-1433` for the authoritative list with prompts/URLs. Organized by category below.

### Provider (LLM API keys & base URLs)

| Variable | Provider |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic (Claude) |
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | OpenAI |
| `OPENROUTER_API_KEY` | OpenRouter (multi-model gateway) |
| `GOOGLE_API_KEY` / `GEMINI_API_KEY` / `GEMINI_BASE_URL` | Google AI Studio / Gemini |
| `NOUS_BASE_URL` | Nous Portal override |
| `GLM_API_KEY` / `ZAI_API_KEY` / `Z_AI_API_KEY` / `GLM_BASE_URL` | Z.AI / ZhipuAI GLM |
| `KIMI_API_KEY` / `KIMI_BASE_URL` | Moonshot Kimi |
| `MINIMAX_API_KEY` / `MINIMAX_BASE_URL` | MiniMax (intl) |
| `MINIMAX_CN_API_KEY` / `MINIMAX_CN_BASE_URL` | MiniMax (China) |
| `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` | DeepSeek |
| `DASHSCOPE_API_KEY` / `DASHSCOPE_BASE_URL` / `HERMES_QWEN_BASE_URL` | Alibaba Qwen |
| `OPENCODE_ZEN_API_KEY` / `OPENCODE_ZEN_BASE_URL` | OpenCode Zen (pay-as-you-go) |
| `OPENCODE_GO_API_KEY` / `OPENCODE_GO_BASE_URL` | OpenCode Go (subscription) |
| `HF_TOKEN` / `HF_BASE_URL` | HuggingFace Inference |
| `XIAOMI_API_KEY` / `XIAOMI_BASE_URL` | Xiaomi MiMo |

### Tool (search, browser, voice, memory APIs)

| Variable | Tool |
|---|---|
| `EXA_API_KEY` | Exa search |
| `PARALLEL_API_KEY` | Parallel.ai search |
| `TAVILY_API_KEY` | Tavily search/crawl |
| `FIRECRAWL_API_KEY` / `FIRECRAWL_API_URL` / `FIRECRAWL_BROWSER_TTL` | Firecrawl |
| `FIRECRAWL_GATEWAY_URL` / `TOOL_GATEWAY_DOMAIN` / `TOOL_GATEWAY_SCHEME` / `TOOL_GATEWAY_USER_TOKEN` | Nous subscriber tool-gateway |
| `BROWSERBASE_API_KEY` / `BROWSERBASE_PROJECT_ID` | Browserbase cloud browser |
| `BROWSER_USE_API_KEY` | browser-use.com cloud browser |
| `CAMOFOX_URL` | Camofox anti-detection browser (local) |
| `FAL_KEY` | FAL image generation |
| `TINKER_API_KEY` | Tinker RL training |
| `WANDB_API_KEY` | Weights & Biases |
| `VOICE_TOOLS_OPENAI_KEY` | Whisper STT + OpenAI TTS |
| `ELEVENLABS_API_KEY` | ElevenLabs TTS |
| `MISTRAL_API_KEY` | Mistral Voxtral |
| `GITHUB_TOKEN` | GitHub API + Skills Hub |
| `HONCHO_API_KEY` / `HONCHO_BASE_URL` | Honcho memory |

### Messaging / Gateway platforms

| Variable(s) | Platform |
|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`, `TELEGRAM_HOME_CHANNEL`, `TELEGRAM_REQUIRE_MENTION`, `TELEGRAM_REPLY_TO_MODE`, `TELEGRAM_WEBHOOK_URL/PORT/SECRET` | Telegram |
| `DISCORD_BOT_TOKEN`, `DISCORD_ALLOWED_USERS`, `DISCORD_HOME_CHANNEL`, `DISCORD_REPLY_TO_MODE` | Discord |
| `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`, `SLACK_HOME_CHANNEL` | Slack (socket mode needs both tokens) |
| `MATTERMOST_URL`, `MATTERMOST_TOKEN`, `MATTERMOST_ALLOWED_USERS`, `MATTERMOST_HOME_CHANNEL`, `MATTERMOST_REQUIRE_MENTION`, `MATTERMOST_FREE_RESPONSE_CHANNELS`, `MATTERMOST_REPLY_MODE` | Mattermost |
| `MATRIX_HOMESERVER`, `MATRIX_ACCESS_TOKEN`, `MATRIX_USER_ID`, `MATRIX_ALLOWED_USERS`, `MATRIX_REQUIRE_MENTION`, `MATRIX_FREE_RESPONSE_ROOMS`, `MATRIX_AUTO_THREAD`, `MATRIX_DEVICE_ID`, `MATRIX_RECOVERY_KEY` | Matrix (E2EE supported) |
| `BLUEBUBBLES_SERVER_URL`, `BLUEBUBBLES_PASSWORD`, `BLUEBUBBLES_ALLOWED_USERS` | iMessage via BlueBubbles |
| `SIGNAL_HTTP_URL`, `SIGNAL_ACCOUNT`, `SIGNAL_HOME_CHANNEL` | Signal via signal-cli REST |
| `DINGTALK_*`, `FEISHU_*`, `WECOM_*`, `WEIXIN_*` | Chinese messaging platforms |
| `WHATSAPP_MODE`, `WHATSAPP_ENABLED` | WhatsApp (Baileys bridge) |
| `GATEWAY_ALLOW_ALL_USERS` | Cross-platform: allow all users (dangerous) |

### API server (OpenAI-compatible REST)

| Variable | Purpose |
|---|---|
| `API_SERVER_ENABLED` | Enable REST endpoint |
| `API_SERVER_KEY` | Bearer token for clients |
| `API_SERVER_PORT` | Listen port (**must be unique per tenant**) |
| `API_SERVER_HOST` | Bind address (default 0.0.0.0) |
| `API_SERVER_MODEL_NAME` | Model name reported to clients |
| `API_SERVER_CORS_ORIGINS` | CORS origins |

### Webhook adapter

`WEBHOOK_ENABLED`, `WEBHOOK_PORT`, `WEBHOOK_SECRET` — generic webhook → Hermes input bridge.

### Settings / passthrough

| Variable | Purpose |
|---|---|
| `MESSAGING_CWD` | Per-message working directory |
| `SUDO_PASSWORD` | sudo password (terminal tool) |
| `HERMES_MAX_ITERATIONS` | Max tool-call iterations per turn |
| `HERMES_PREFILL_MESSAGES_FILE` | Few-shot prefill file |
| `HERMES_EPHEMERAL_SYSTEM_PROMPT` | Ephemeral system prompt override |
| `HERMES_UID` / `HERMES_GID` | Docker user remapping (entrypoint) |
| `HERMES_HOME` | Profile root override |
| `TERMINAL_ENV`, `TERMINAL_SSH_KEY`, `TERMINAL_SSH_PORT` | Terminal backend passthrough |
| `HERMES_TOOL_PROGRESS`, `HERMES_TOOL_PROGRESS_MODE` | **Deprecated** — use `display.platforms` |

---

## Decision Guide: config.yaml or .env?

When the user wants to set something new, ask:

1. **Is it a secret / token / API key?** → `.env`
2. **Is it a per-deployment override (host, port, URL)?** → `.env`
3. **Is it a user-allowlist / room-allowlist?** → `.env` (all `*_ALLOWED_USERS` / `*_ALLOWED_CHANNELS` are env-only)
4. **Is it behavior / defaults / features / UI?** → `config.yaml`
5. **Is it nested (dict / list / complex structure)?** → `config.yaml` (env vars can only be flat strings)
6. **Is it declared by a skill's frontmatter?** → `config.yaml → skills.config.<key>`, but let `hermes config migrate` scaffold it

### Settings that **only** exist in `config.yaml`

No env override path exists for these — must be set in yaml:

- `providers.*` (structured provider routing)
- `smart_model_routing.cheap_model`
- `auxiliary.*` (all 8 helper-model configs)
- `delegation.*`
- `compression.*`, `checkpoints.*`, `memory.*`
- `terminal.docker_{volumes,env}`, `terminal.container_{cpu,memory,disk,persistent}`
- `approvals.*`, `command_allowlist`, `quick_commands`, `personalities`
- `security.website_blocklist`, `security.tirith_*`
- `display.*`
- `discord.{require_mention,free_response_channels,allowed_channels,auto_thread,reactions}`
- `skills.external_dirs`, `skills.config.*`
- `cron.*`, `logging.*`, `network.*`, `timezone`

### Settings that **only** exist in `.env`

- All API keys / tokens
- All provider base URL overrides (`*_BASE_URL`)
- All `*_ALLOWED_USERS` allowlists
- BlueBubbles password, Matrix device_id / recovery_key
- Entire `API_SERVER_*` block
- Entire `WEBHOOK_*` block
- `SUDO_PASSWORD`, `MESSAGING_CWD`

## Procedures

### View current config

```bash
hermes config show                    # effective merged config
hermes config check                   # check for missing / outdated fields
hermes config path                    # where is config.yaml?
hermes config env-path                # where is .env?
```

To see platform tokens without leaking them: `hermes config show` redacts secrets by default (`security.redact_secrets`).

### Modify a setting

```bash
# Simple scalar
hermes config set terminal.backend docker

# Nested / complex — edit the file
hermes config edit

# Secret / API key — goes in .env, NOT config.yaml
$EDITOR "$(hermes doctor --show-paths | grep 'env file')"
# or directly:
$EDITOR "$HERMES_HOME/.env"
```

After editing, restart the gateway or CLI so changes take effect.

### Validate

```bash
hermes doctor                         # overall health check
hermes config show                    # fails loudly on schema errors
```

`validate_config_structure()` checks against `_KNOWN_ROOT_KEYS` and reports unknown top-level keys as warnings. Note: `_KNOWN_ROOT_KEYS` is narrower than `DEFAULT_CONFIG` — harmless "unknown key" warnings are expected for newer fields.

### Migrate across versions

```bash
hermes config migrate                 # scaffolds new fields, renames old ones, bumps _config_version
```

Run this after upgrading Hermes. Safe — it deep-merges and preserves user values.

### Reset to defaults

```bash
mv "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.bak"
hermes config migrate                 # regenerate defaults for the current schema version
```

## Secrets Handling

**Never put secrets in `config.yaml`.** It is meant to be committable / reviewable. Secrets belong in `$HERMES_HOME/.env`, which is gitignored by default.

- API keys → `.env`
- Bot tokens → `.env`
- SSH keys / passwords → `.env` or referenced by path
- `sudo` password → `SUDO_PASSWORD` env only

For deployments with multiple tenants (e.g. `deploy/docker-compose.yml`), use per-tenant `.env` files and never commit them.

## Pitfalls

1. **"My Telegram token isn't working"** — Check `.env`, not `config.yaml`. Tokens are env-only. `config.yaml → discord.require_mention` etc. are behavior flags, not credentials.

2. **"I set `display.tool_progress_overrides` and it doesn't work"** — Deprecated. Use `display.platforms.<platform>.tool_progress` instead.

3. **"`HERMES_TOOL_PROGRESS` env var ignored"** — Also deprecated. Migrated automatically to `display.tool_progress` on config version bump. Check `_config_version` and run `hermes config migrate`.

4. **"Unknown key warning for a key I just added"** — `_KNOWN_ROOT_KEYS` in `hermes_cli/config.py:1564` is the validator's narrower allowlist. If you added a legitimate new key, add it there too.

5. **"My `config.yaml` change didn't take effect for terminal settings"** — It should. Terminal settings in `config.yaml` write back into `os.environ` at gateway startup (`gateway/run.py:73-136`), overriding anything from `.env`. If they didn't, your `config.yaml` may have a syntax error — run `hermes config show` to surface it.

6. **"`${ENV_VAR}` in config.yaml not expanded"** — `load_config()` only expands `${VAR}` references at load time. If the env var is set *after* load, it won't re-resolve. Set env vars before starting Hermes.

7. **"Profile isolation broken"** — `HERMES_HOME` must be set per profile. Never hardcode `~/.hermes` in any helper script; use `get_hermes_home()`.

8. **Settings collisions across surfaces** — A few keys exist on both surfaces with nuanced priority (see "Priority rules" above). When in doubt, `hermes config show` and compare against `hermes config check`.

## Verification

After any change:

```bash
hermes config show | head -50         # sanity-check structure
hermes doctor                          # cross-layer validation
# If running gateway: restart it
systemctl --user restart hermes-gateway  # or kill+restart the process
```

For a gateway deployment, tail logs after restart to confirm the new config took effect:

```bash
hermes gateway start 2>&1 | grep -Ei 'config|loaded|provider'
```

---

## Authoritative References

When unsure, go to the source:

- **`hermes_cli/config.py:311-703`** — `DEFAULT_CONFIG` (complete field catalog + defaults; `_config_version: 17` at line 703)
- **`hermes_cli/config.py:728`** — `OPTIONAL_ENV_VARS` (env var catalog with prompts/URLs)
- **`hermes_cli/config.py:1564`** — `_KNOWN_ROOT_KEYS` (validator allowlist)
- **`hermes_cli/config.py:1735`** — `migrate_config()` (version migration logic)
- **`gateway/config.py:431`** — `load_gateway_config()`; `_apply_env_overrides()` at line 742
- **`gateway/run.py:104-127`** — terminal env-var writeback logic (config.yaml values → `TERMINAL_*` env vars)
- **`docker/entrypoint.sh`** — bootstraps config.yaml + .env from examples on first container start
- **`website/docs/developer-guide/creating-skills.md`** — authoritative SKILL.md spec
