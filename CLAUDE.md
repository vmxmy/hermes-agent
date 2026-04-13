# Hermes Agent — Claude Code Reference

Quick-start guide for Claude Code sessions. For deep how-tos see [`AGENTS.md`](AGENTS.md) and [`CONTRIBUTING.md`](CONTRIBUTING.md).

---

## Project Overview

**Hermes Agent** (v0.8.0, Nous Research) is a self-improving AI agent platform written in Python 3.11+. It features:
- A registry-based tool system with self-registering tool files
- A closed learning loop (skill creation, memory, autonomous improvement)
- Multiple surfaces: interactive CLI, messaging gateway (Telegram/Discord/Slack/WhatsApp/Signal), ACP server (VS Code/Zed/JetBrains), and RL training environments

**Repo:** `https://github.com/NousResearch/hermes-agent`

---

## Development Environment

```bash
# ALWAYS activate the venv first — every Python command needs this
source venv/bin/activate

# Install all extras (first time or after pulling new dependencies)
uv pip install -e ".[all,dev]"

# User config (not in repo)
~/.hermes/config.yaml   # Settings (model, toolsets, display, compression, etc.)
~/.hermes/.env          # API keys and secrets
```

> **uv** is the package manager. Do not use `pip` directly unless `uv` is unavailable.

---

## Common Commands

```bash
# Run tests (default — fast, parallel, excludes integration/e2e)
python -m pytest tests/ -q -n auto --ignore=tests/integration --ignore=tests/e2e

# Run tests for a specific area
python -m pytest tests/tools/ -q
python -m pytest tests/gateway/ -q
python -m pytest tests/test_model_tools.py -q

# Interactive CLI
hermes

# Non-interactive single prompt
hermes chat -q "Your prompt here"

# Messaging gateway
hermes gateway start

# Diagnostics
hermes doctor
```

---

## Architecture

### File Dependency Chain

```
tools/registry.py          # No deps — imported by all tool files
      ↑
tools/*.py                 # Each calls registry.register() at import time
      ↑
model_tools.py             # Imports tools/registry + triggers tool discovery
      ↑
run_agent.py  cli.py  batch_runner.py  environments/
```

### Key Modules

| Path | Purpose |
|------|---------|
| `run_agent.py` | `AIAgent` class — core conversation loop, tool dispatch, session persistence |
| `cli.py` | `HermesCLI` — interactive TUI (prompt_toolkit + rich) |
| `model_tools.py` | Tool orchestration, `_discover_tools()`, `handle_function_call()` |
| `toolsets.py` | Toolset groupings; `_HERMES_CORE_TOOLS` list |
| `hermes_state.py` | `SessionDB` — SQLite session store with FTS5 full-text search |
| `hermes_constants.py` | `get_hermes_home()`, `display_hermes_home()`, global constants |
| `agent/prompt_builder.py` | System prompt assembly (identity, skills, context files, memory) |
| `agent/context_compressor.py` | Auto-summarization when approaching context limits |
| `agent/display.py` | `KawaiiSpinner`, tool progress formatting |
| `hermes_cli/main.py` | Entry point — all `hermes` subcommands |
| `hermes_cli/commands.py` | Central `COMMAND_REGISTRY` (`CommandDef` objects) — all slash commands |
| `hermes_cli/config.py` | `DEFAULT_CONFIG`, `OPTIONAL_ENV_VARS`, config migration |
| `tools/registry.py` | Central tool registry (schemas, handlers, availability, dispatch) |
| `tools/terminal_tool.py` | Terminal orchestration — local, Docker, SSH, Modal, Daytona, Singularity |
| `tools/approval.py` | Dangerous command detection + per-session approval flow |
| `gateway/run.py` | `GatewayRunner` — platform lifecycle, message routing, cron |
| `gateway/session.py` | `SessionStore` — conversation persistence for messaging |
| `gateway/platforms/` | Platform adapters (Telegram, Discord, Slack, WhatsApp, Signal, Matrix…) |

### Agent Loop (Synchronous)

```python
# Inside AIAgent.run_conversation()
while api_call_count < max_iterations and iteration_budget.remaining > 0:
    response = client.chat.completions.create(model=model, messages=messages, tools=tool_schemas)
    if response.tool_calls:
        for tool_call in response.tool_calls:
            result = handle_function_call(tool_call.name, tool_call.args, task_id)
            messages.append(tool_result_message(result))
        api_call_count += 1
    else:
        return response.content  # Final text response
```

Messages follow the OpenAI format. Reasoning content is stored in `assistant_msg["reasoning"]`.

### Config System

Two separate config loaders exist:

| Loader | Used by |
|--------|---------|
| `load_cli_config()` in `cli.py` | Interactive CLI |
| `load_config()` in `hermes_cli/config.py` | `hermes tools`, `hermes setup`, migration |
| Direct YAML load | Gateway (`gateway/run.py`) |

### Session Storage

- **SQLite DB**: `~/.hermes/state.db` via `hermes_state.py` (FTS5 full-text search, session titles)
- **JSON logs**: `~/.hermes/sessions/<session_id>.json`
- System prompts and prefill messages are **ephemeral** — injected at API call time, never persisted

---

## How to Add Things

### New Tool (3 steps)

**1. Create `tools/your_tool.py`:**
```python
import json
from tools.registry import registry

def your_tool(param: str, task_id: str = None) -> str:
    return json.dumps({"result": "..."})  # MUST return a JSON string

registry.register(
    name="your_tool",
    toolset="your_toolset",
    schema={"type": "function", "function": {"name": "your_tool", "description": "...", "parameters": {...}}},
    handler=lambda args, **kw: your_tool(param=args.get("param", ""), task_id=kw.get("task_id")),
    check_fn=lambda: True,  # Return False if requirements are missing
)
```

**2. Add import** to the `_modules` list in `model_tools.py`.

**3. Add to `toolsets.py`** — either `_HERMES_CORE_TOOLS` or a new toolset entry.

See `AGENTS.md` for the full pattern including `check_fn`, `requires_env`, and dynamic cross-tool references.

### New Skill

```
skills/
└── <category>/
    └── <skill-name>/
        ├── SKILL.md         # Required — frontmatter + instructions
        └── scripts/         # Optional — helper scripts
```

`SKILL.md` frontmatter fields: `name`, `description`, `version`, `author`, `platforms`, `required_environment_variables`, `metadata.hermes.tags`, `metadata.hermes.fallback_for_toolsets`, `metadata.hermes.requires_toolsets`. See `AGENTS.md` for the full format.

Bundled skills go in `skills/` (universal). Optional official skills go in `optional-skills/` (discoverable but not active by default).

### New Slash Command (4 steps)

1. Add `CommandDef` to `COMMAND_REGISTRY` in `hermes_cli/commands.py`
2. Add handler branch in `HermesCLI.process_command()` in `cli.py`
3. If gateway-available, add handler in `gateway/run.py`
4. For persistent settings, use `save_config_value()` in `cli.py`

Adding an alias only requires updating the `aliases` tuple on the `CommandDef` — all consumers update automatically.

### New Config Option

1. Add to `DEFAULT_CONFIG` in `hermes_cli/config.py`
2. Bump `_config_version` (currently `5`) to trigger migration for existing users
3. For env vars, add to `OPTIONAL_ENV_VARS` with `description`, `prompt`, `url`, `password`, `category`

---

## Critical Rules

### Profiles / HERMES_HOME

- **NEVER hardcode `~/.hermes`** — use `get_hermes_home()` from `hermes_constants` for all path construction
- **Use `display_hermes_home()`** (also from `hermes_constants`) for user-facing print/log messages
- Hardcoding breaks profiles (each profile has its own `HERMES_HOME`; this caused 5 bugs in PR #3575)
- Tests that mock `Path.home()` must also set `os.environ["HERMES_HOME"]` — see `tests/hermes_cli/test_profiles.py`

```python
# CORRECT
from hermes_constants import get_hermes_home, display_hermes_home
config_path = get_hermes_home() / "config.yaml"
print(f"Saved to {display_hermes_home()}/config.yaml")

# WRONG — breaks profiles
config_path = Path.home() / ".hermes" / "config.yaml"
```

### Prompt Caching

- **NEVER break prompt caching** mid-conversation: don't alter past context, don't change toolsets, don't rebuild system prompts
- The ONLY legitimate context change is during context compression
- Cache-breaking dramatically increases API costs

### Display / Terminal

- **DO NOT use `simple_term_menu`** for interactive menus — use `curses` (stdlib); `simple_term_menu` has rendering bugs in tmux/iTerm2
- **DO NOT use `\033[K`** (ANSI erase-to-EOL) in spinner/display code — it leaks as `?[K` under `prompt_toolkit`. Space-pad instead: `f"\r{line}{' ' * pad}"`

### Tools

- **All tool handlers MUST return a JSON string** — the registry wraps errors but expects strings
- **No cross-tool references in schema descriptions** — don't mention tools from other toolsets by name; add cross-references dynamically in `model_tools.py` (see `browser_navigate`/`execute_code` post-processing blocks as the pattern)
- **Path references in schemas**: use `display_hermes_home()` so they are profile-aware
- **State files**: store under `get_hermes_home()`, never `Path.home() / ".hermes"`
- **Agent-level tools** (todo, memory): intercepted by `run_agent.py` before `handle_function_call()` — see `todo_tool.py`

### Cross-Platform

- `termios` and `fcntl` are Unix-only — always catch both `ImportError` and `NotImplementedError`
- Use `pathlib.Path` instead of string path concatenation
- Use `shlex.quote()` when interpolating any user input into shell commands
- Use `os.path.realpath()` before path-based access control checks (symlink bypass prevention)
- File encoding: Windows may use `cp1252` — handle `UnicodeDecodeError` with `encoding="latin-1"` fallback

### Tests

- Tests must **never** write to `~/.hermes/` — `_isolate_hermes_home` autouse fixture in `tests/conftest.py` redirects `HERMES_HOME` to a temp dir; respect this pattern
- Profile tests: use the fixture from `tests/hermes_cli/test_profiles.py` that mocks both `Path.home()` and `HERMES_HOME`

### Process Globals

- `_last_resolved_tool_names` in `model_tools.py` is a process-global — `_run_single_child()` in `delegate_tool.py` saves/restores it around subagent runs; be aware if you read it elsewhere

---

## Commit Conventions

[Conventional Commits](https://www.conventionalcommits.org/) format: `<type>(<scope>): <description>`

| Type | Use for |
|------|---------|
| `fix` | Bug fixes |
| `feat` | New features |
| `docs` | Documentation |
| `test` | Tests |
| `refactor` | Code restructuring (no behavior change) |
| `chore` | Build, CI, dependency updates |

Common scopes: `cli`, `gateway`, `tools`, `skills`, `agent`, `install`, `security`, `terminal`

Branch naming: `fix/description`, `feat/description`, `docs/description`, `test/description`, `refactor/description`

---

## Security

Security-sensitive areas (see `CONTRIBUTING.md` for full details):

| Layer | File |
|-------|------|
| Dangerous command detection + approval | `tools/approval.py` |
| Shell injection prevention (sudo) | `tools/terminal_tool.py` |
| Write deny-list + symlink protection | `tools/file_tools.py` |
| Cron prompt injection scanner | `tools/cronjob_tools.py` |
| Skills security scanner | `tools/skills_guard.py` |
| Code execution sandbox (strips API keys) | `tools/code_execution_tool.py` |

---

## References

- **`AGENTS.md`** — AIAgent class API, detailed tool/skill/command/skin/profile how-tos, full list of pitfalls
- **`CONTRIBUTING.md`** — PR process, skill-vs-tool decision guide, security checklist, cross-platform rules
- **`hermes_cli/commands.py`** — `COMMAND_REGISTRY` (all slash commands in one place)
- **`hermes_cli/config.py`** — `DEFAULT_CONFIG`, `OPTIONAL_ENV_VARS`, `_config_version`
- **`toolsets.py`** — `_HERMES_CORE_TOOLS` and all toolset definitions
- **`tools/registry.py`** — Central registry API (`register()`, `get_tool_definitions()`, dispatch)
