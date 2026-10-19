# Installation

## Gemini CLI

Gemini supports extensions but can also rely on files on disk.

### Extension Installation (Recommended)

Install as a native Gemini CLI extension:
- Skills, commands, and context are discovered automatically.
- Supports updates

**Workspace-level is recommended** since the context and skills are OSADO-specific.

User-level (available across all projects):
```bash
gemini extensions install https://github.com/os-autoinst/osado-skills
```

Update can be done from within the running gemini-cli using `/extensions update osado-ai-assistant` or with:
```bash
gemini extensions update osado-ai-assistant
```

Uninstall:
```bash
gemini extensions uninstall osado-ai-assistant
```

### Script Installation

This method symlinks skills and commands into your OSADO clone's `.gemini/` directory using our install script:

```bash
# Clone this repository
git clone https://github.com/os-autoinst/osado-skills
cd osado-skills

# Install (symlinks into your OSADO clone)
./tools/install.sh gemini install /path/to/your/os-autoinst-distri-opensuse

# Alternative direct invocation (defaults to gemini install)
./tools/install.sh /path/to/your/os-autoinst-distri-opensuse
```

Update:
```bash
./tools/install.sh gemini update /path/to/your/os-autoinst-distri-opensuse
```

Uninstall:
```bash
./tools/install.sh gemini uninstall /path/to/your/os-autoinst-distri-opensuse
```

---

## OpenCode (OCX)

### Registry Installation (Recommended)

If using [OCX](https://github.com/kdcokenny/ocx), skills can be installed directly from this registry.

> **Note for OpenCode V1:** OCX 2.0.15 is the frozen client for OpenCode V1 (OCX 3+ targets OpenCode V2). If using Bun or npm, invoke as `bunx ocx@2.0.15` or install via:
> ```bash
> bun add --global ocx@2.0.15
> # or:
> npm install --global ocx@2.0.15
> ```

One-time: init and add the OSADO registry:
```bash
# Project-level (inside the os-autoinst-distri-opensuse clone):
cd /path/to/os-autoinst-distri-opensuse
ocx init
ocx registry add https://os-autoinst.github.io/osado-skills/ocx --name osado

# Or globally (for all workspaces):
ocx init -g
ocx registry add https://os-autoinst.github.io/osado-skills/ocx --name osado -g
```

Install a specific skill:
```bash
ocx add osado/local-lint-test
# (or globally: ocx add -g osado/local-lint-test)
```

Install all skills at once:
```bash
ocx add osado/{git-commit,github-pr-create,local-lint-test,openqa-log-analyzer,openqa-log-fetcher,test-catalog,unit-test-wizard,vr-planner}
# (or globally: ocx add -g osado/{git-commit,github-pr-create,local-lint-test,openqa-log-analyzer,openqa-log-fetcher,test-catalog,unit-test-wizard,vr-planner})
```

Update:
```bash
ocx update osado/local-lint-test
# or update all components:
ocx update --all
# (or globally: ocx update -g --all)
```

### Script Installation

Use this method if you cannot or do not want to install OCX. You can use our installation script to install skills globally. OpenCode auto-discovers these global skills on your next session:

```bash
# Clone this repository (if not already done)
git clone https://github.com/os-autoinst/osado-skills
cd osado-skills

# Install globally to ~/.config/opencode/skills/osado-skills/
./tools/install.sh opencode install
```

Update:
```bash
./tools/install.sh opencode update
```

Check status:
```bash
./tools/install.sh opencode status
```

Uninstall:
```bash
./tools/install.sh opencode uninstall
```

---

## Claude Code

### Native Plugin Installation (Recommended)

Install as a native Claude Code plugin via the marketplace system.

Subscribe to the marketplace (one-time):
```bash
claude plugin marketplace add os-autoinst/osado-skills
```

Then in a Claude Code session, install the plugin:
```
/plugin install osado-ai-assistant@openqa-tools
```
Skills become available as `osado-ai-assistant:local-lint-test`, `osado-ai-assistant:vr-planner`, etc.

**Note:** Claude Code plugins don't inject per-turn project context like Gemini CLI extensions do. For full OSADO guidelines in every interaction, add this to your project's `CLAUDE.md`:
```markdown
@OSADO_AGENTS.md
```

### Manual Installation

If you prefer not to use the native plugin, you can install the skills manually into the workspace's `.claude/skills/` directory.

#### Method A: Using the Installer Script

```bash
# Clone this repository (if not already done)
git clone https://github.com/os-autoinst/osado-skills
cd osado-skills

# Install (symlinks into <osado-path>/.claude/skills/)
./tools/install.sh claude install /path/to/your/os-autoinst-distri-opensuse
```

#### Method B: Manual File Copying

From your OSADO clone root, copy the skills directly:
```bash
mkdir -p .claude/skills
cp -r /path/to/osado-skills/skills/* .claude/skills/
```

To ensure Claude Code also has access to the core guidelines context in every session, copy the agent context to your repository root:
```bash
cp /path/to/osado-skills/OSADO_AGENTS.md ./AGENTS.md
```
And add `@AGENTS.md` to your `CLAUDE.md` file.

---

## Antigravity CLI

### Native Plugin Installation (Recommended)

Install as a native Antigravity CLI plugin directly from the remote repository:

```bash
agy plugin install https://github.com/os-autoinst/osado-skills.git
```

Or from a local clone:

```bash
git clone https://github.com/os-autoinst/osado-skills
agy plugin install /path/to/osado-skills
```

Verify the installation:

```bash
agy plugin list
```

Update by reinstalling:

```bash
agy plugin uninstall osado-ai-assistant
agy plugin install https://github.com/os-autoinst/osado-skills.git
```

### Script Installation

Use the installer script to symlink directly into the Antigravity plugin staging
directory (`~/.gemini/antigravity-cli/plugins/osado-ai-assistant/`). No `agy` command needed — Antigravity auto-discovers the directory on startup.

```bash
# Clone this repository (if not already done)
git clone https://github.com/os-autoinst/osado-skills
cd osado-skills

# Install (symlinks into ~/.gemini/antigravity-cli/plugins/osado-ai-assistant/)
./tools/install.sh antigravity install
```

Update:
```bash
./tools/install.sh antigravity update
```

Check status:
```bash
./tools/install.sh antigravity status
```

Uninstall:
```bash
./tools/install.sh antigravity uninstall
```

---

## Other AI Coding Tools (Universal Setup)

The skills in this repository follow the [Agent Skills open standard](https://agentskills.io) (`SKILL.md` format) and are compatible with 36+ AI coding tools.

### Manual Overlay / Agent Skills Standard

These tools discover skills in a local `.agents/skills/` directory.

#### Method A: Using the Installer Script (Recommended)

You can use our installer script to automatically configure standard Agent Skills directories or establish multi-tool harnesses:

```bash
# Clone this repository (if not already done)
git clone https://github.com/os-autoinst/osado-skills
cd osado-skills

# Standard Agent Skills installation (symlinks into <osado-path>/.agents/skills/)
./tools/install.sh agents install /path/to/your/os-autoinst-distri-opensuse

# Portable multi-tool option (links all standard directories and copies context files)
./tools/install.sh --portable /path/to/your/os-autoinst-distri-opensuse

# Multi-harness (All target tools configured at once)
./tools/install.sh all install /path/to/your/os-autoinst-distri-opensuse
```

#### Method B: Manual File Copying

From your OSADO clone root, copy or symlink the skills directory:
```bash
mkdir -p .agents/skills
cp -r /path/to/osado-skills/skills/* .agents/skills/

# Also place the AGENTS.md context file at your repo root:
cp /path/to/osado-skills/OSADO_AGENTS.md ./AGENTS.md
```

### GitHub Copilot

Copilot reads `AGENTS.md` at the repository root for project context but does not support the skills/scripts mechanism:

```bash
cp /path/to/osado-skills/OSADO_AGENTS.md ./AGENTS.md
```
