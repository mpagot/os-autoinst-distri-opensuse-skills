#!/bin/bash

# ==============================================================================
# Integration Test: Multi-Tool Extension Installation & Discovery
# ==============================================================================
#
# This script tests that the OSADO AI Assistant extension can be properly
# installed and discovered by multiple AI coding tools:
#   - Gemini CLI (native extension install)
#   - Claude Code (skills in .claude/skills/)
#   - OpenCode (skills in .agents/skills/ and .config/opencode/skills/)
#   - OCX registry manifest validation
#   - OCX CLI install + add workflow
#
# It also tests the multi-harness install.sh mechanism.
#
# Requirements: Run inside the container ghcr.io/mpagot/osado-gemini-tester
#   which provides gemini, claude, and opencode on PATH.
#
# ==============================================================================

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

SRC_DIR="/src"
OSADO_DIR="/osado"

# Container image reference (overridable via env, defaults match Makefile)
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/mpagot/osado-gemini-tester}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Minimum required tool versions (major.minor only, for loose comparison)
REQUIRED_OPENCODE_VERSION="1.15"

# Expected skills (directory names)
EXPECTED_SKILLS=(
    "local-lint-test"
    "vr-planner"
    "test-catalog"
    "openqa-log-analyzer"
    "openqa-log-fetcher"
    "git-commit"
    "github-pr-create"
    "unit-test-wizard"
)

# Expected commands
EXPECTED_COMMANDS=(
    "osado/git_commit.toml"
    "osado/github_pr_create.toml"
)

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
log_skip() { echo -e "${YELLOW}[SKIP]${NC} $1"; SKIP=$((SKIP + 1)); }
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

# Helper: check a file exists
assert_file_exists() {
    local path="$1"
    local desc="$2"
    if [[ -f "$path" ]]; then
        log_pass "$desc: $path"
    else
        log_fail "$desc: $path (not found)"
    fi
}

# Helper: check a symlink exists and points to expected target
assert_symlink() {
    local path="$1"
    local expected_target="$2"
    local desc="$3"
    if [[ -L "$path" ]]; then
        local actual_target
        actual_target=$(readlink "$path")
        if [[ "$actual_target" == "$expected_target" ]]; then
            log_pass "$desc: $path -> $expected_target"
        else
            log_fail "$desc: $path -> $actual_target (expected $expected_target)"
        fi
    else
        log_fail "$desc: $path (not a symlink)"
    fi
}

# Helper: check command exists
has_command() {
    command -v "$1" &>/dev/null
}

# Helper: create a mock git that only handles clone (writes to given bin dir)
create_mock_git_clone() {
    local mock_dir="$1"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/git" <<'EOF'
#!/bin/bash
if [[ "$*" == *"clone"* ]]; then
    target="${@: -1}"
    mkdir -p "$target/.git"
    exit 0
fi
/usr/bin/git "$@"
EOF
    chmod +x "$mock_dir/git"
}

# Helper: reset OSADO dir to a clean git repo (isolates tests from each other)
reset_osado() {
    rm -rf "$OSADO_DIR"
    mkdir -p "$OSADO_DIR"
    git init "$OSADO_DIR" >/dev/null 2>&1
    git -C "$OSADO_DIR" config user.email "test@test.com"
    git -C "$OSADO_DIR" config user.name "Test"
    touch "$OSADO_DIR/.gitkeep"
    git -C "$OSADO_DIR" add . >/dev/null 2>&1
    git -C "$OSADO_DIR" commit -m "init" >/dev/null 2>&1
}

# =============================================================================
# PRE-FLIGHT: Verify container prerequisites
# =============================================================================
log_section "PRE-FLIGHT: Container Prerequisites"

# These tools MUST be available — fail hard if any is missing.
PREFLIGHT_FAIL=false

for tool in gemini claude opencode git jq curl; do
    if ! command -v "$tool" &>/dev/null; then
        echo -e "${RED}FATAL: '$tool' not found on PATH.${NC}" >&2
        echo "  This test must run inside ghcr.io/mpagot/osado-gemini-tester." >&2
        PREFLIGHT_FAIL=true
    fi
done

if [[ "$PREFLIGHT_FAIL" == "true" ]]; then
    echo -e "${RED}Pre-flight check failed. Aborting.${NC}" >&2
    exit 2
fi

# Print versions for traceability
log_info "gemini:   $(gemini --version 2>&1 | head -1)"
log_info "claude:   $(claude --version 2>&1 | head -1)"
log_info "opencode: $(opencode --version 2>&1 | head -1)"
log_info "git:      $(git --version 2>&1 | head -1)"
log_info "jq:       $(jq --version 2>&1 | head -1)"

# Verify minimum opencode version (skills support requires >=1.15)
oc_version=$(opencode --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
if [[ "$(printf '%s\n' "$REQUIRED_OPENCODE_VERSION" "$oc_version" | sort -V | head -1)" == "$REQUIRED_OPENCODE_VERSION" ]]; then
    log_pass "opencode version $oc_version >= $REQUIRED_OPENCODE_VERSION"
else
    log_fail "opencode version $oc_version < $REQUIRED_OPENCODE_VERSION (skills support requires >= $REQUIRED_OPENCODE_VERSION)"
fi

# Verify /src is mounted (the source repo)
if [[ ! -d "$SRC_DIR/skills" ]]; then
    echo -e "${RED}FATAL: $SRC_DIR/skills not found. Is the source repo mounted at /src?${NC}" >&2
    exit 2
fi
log_pass "Source repo mounted at $SRC_DIR"

# Verify container image is up-to-date with remote registry
# LOCAL_IMAGE_DIGEST is set by the Makefile before launching the container.
if [[ -n "${LOCAL_IMAGE_DIGEST:-}" ]]; then
    log_info "Local image digest: $LOCAL_IMAGE_DIGEST"

    # Derive registry host and path from IMAGE_REPO
    # e.g. "ghcr.io/mpagot/osado-gemini-tester" -> host=ghcr.io path=mpagot/osado-gemini-tester
    registry_host="${IMAGE_REPO%%/*}"
    registry_path="${IMAGE_REPO#*/}"

    # Query registry for the remote digest
    # ghcr.io requires a bearer token even for public images.
    # || echo "" guards against set -e triggering when curl/jq fail on network errors.
    registry_token=$(curl -fsSL \
        "https://$registry_host/token?scope=repository:$registry_path:pull" 2>/dev/null \
        | jq -r '.token // empty' 2>/dev/null || echo "")

    if [[ -n "$registry_token" ]]; then
        remote_digest=$(curl -fsSL \
            -H "Authorization: Bearer $registry_token" \
            -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
            --head \
            "https://$registry_host/v2/$registry_path/manifests/$IMAGE_TAG" 2>/dev/null \
            | grep -i "docker-content-digest" | grep -oP 'sha256:[0-9a-f]+' || echo "")

        if [[ -n "$remote_digest" ]]; then
            log_info "Remote image digest: $remote_digest"
            if [[ "$LOCAL_IMAGE_DIGEST" == "$remote_digest" ]]; then
                log_pass "Container image is up-to-date with $IMAGE_REPO:$IMAGE_TAG"
            else
                log_fail "Container image STALE: local=$LOCAL_IMAGE_DIGEST remote=$remote_digest"
            fi
        else
            log_skip "Could not retrieve remote digest from $registry_host (network issue?)"
        fi
    else
        log_skip "Could not obtain registry token from $registry_host (network issue?)"
    fi
else
    log_skip "LOCAL_IMAGE_DIGEST not set (run via 'make test-integration' for digest verification)"
fi

# =============================================================================
# TEST 1: Source Repo Structure Validation
# =============================================================================
log_section "TEST 1: Source Repository Structure"

assert_file_exists "$SRC_DIR/gemini-extension.json" "Extension manifest exists"
assert_file_exists "$SRC_DIR/OSADO_AGENTS.md" "Context file exists"
assert_file_exists "$SRC_DIR/plugin.json" "Antigravity plugin manifest exists"
assert_file_exists "$SRC_DIR/.claude-plugin/plugin.json" "Claude Code plugin manifest exists"
assert_file_exists "$SRC_DIR/.claude-plugin/marketplace.json" "Claude Code marketplace manifest exists"
assert_file_exists "$SRC_DIR/ocx/registry.jsonc" "OCX registry manifest exists"

for skill in "${EXPECTED_SKILLS[@]}"; do
    assert_file_exists "$SRC_DIR/skills/$skill/SKILL.md" "Skill SKILL.md"
done

for cmd in "${EXPECTED_COMMANDS[@]}"; do
    assert_file_exists "$SRC_DIR/commands/$cmd" "Command file"
done

# Validate SKILL.md frontmatter has required fields
for skill in "${EXPECTED_SKILLS[@]}"; do
    skill_file="$SRC_DIR/skills/$skill/SKILL.md"
    if grep -q "^name:" "$skill_file" && grep -q "^description:" "$skill_file"; then
        log_pass "SKILL.md frontmatter valid: $skill"
    else
        log_fail "SKILL.md frontmatter missing name/description: $skill"
    fi
done

# Verify .opencode/skills symlink (only present in dev checkouts, gitignored)
if [[ -L "$SRC_DIR/.opencode/skills" ]]; then
    link_target=$(readlink "$SRC_DIR/.opencode/skills")
    if [[ "$link_target" == "../skills" ]]; then
        log_pass ".opencode/skills symlink -> ../skills"
    else
        log_fail ".opencode/skills symlink points to '$link_target', expected '../skills'"
    fi
else
    log_skip ".opencode/skills symlink not present (gitignored, dev-only setup)"
fi

# =============================================================================
# TEST 2: install.sh gemini (Gemini CLI paths)
# =============================================================================
log_section "TEST 2: install.sh gemini install"

reset_osado

# Run the installer
"$SRC_DIR/tools/install.sh" gemini install "$OSADO_DIR" 2>&1 || true

# Verify .gemini/skills/ symlinks
for skill in "${EXPECTED_SKILLS[@]}"; do
    assert_symlink "$OSADO_DIR/.gemini/skills/$skill/SKILL.md" \
        "$SRC_DIR/skills/$skill/SKILL.md" \
        "gemini install: .gemini/skills/$skill/SKILL.md"
done

# Verify .gemini/commands/ symlinks
for cmd in "${EXPECTED_COMMANDS[@]}"; do
    assert_symlink "$OSADO_DIR/.gemini/commands/$cmd" \
        "$SRC_DIR/commands/$cmd" \
        "gemini install: .gemini/commands/$cmd"
done

# Verify GEMINI.md at root
assert_symlink "$OSADO_DIR/GEMINI.md" \
    "$SRC_DIR/OSADO_AGENTS.md" \
    "gemini install: GEMINI.md -> OSADO_AGENTS.md"

# =============================================================================
# TEST 3: install.sh agents (Cross-tool paths)
# =============================================================================
log_section "TEST 3: install.sh agents install"

reset_osado

"$SRC_DIR/tools/install.sh" agents install "$OSADO_DIR" 2>&1 || true

# Verify .agents/skills/ symlinks (for OpenCode/Pi Agent)
for skill in "${EXPECTED_SKILLS[@]}"; do
    assert_symlink "$OSADO_DIR/.agents/skills/$skill/SKILL.md" \
        "$SRC_DIR/skills/$skill/SKILL.md" \
        "agents install: .agents/skills/$skill/SKILL.md"
done

# Verify AGENTS.md at root
assert_symlink "$OSADO_DIR/AGENTS.md" \
    "$SRC_DIR/OSADO_AGENTS.md" \
    "agents install: AGENTS.md -> OSADO_AGENTS.md"

# =============================================================================
# TEST 4: install.sh claude (Claude Code paths)
# =============================================================================
log_section "TEST 4: install.sh claude install"

reset_osado

"$SRC_DIR/tools/install.sh" claude install "$OSADO_DIR" 2>&1 || true

# Verify .claude/skills/ symlinks
for skill in "${EXPECTED_SKILLS[@]}"; do
    assert_symlink "$OSADO_DIR/.claude/skills/$skill/SKILL.md" \
        "$SRC_DIR/skills/$skill/SKILL.md" \
        "claude install: .claude/skills/$skill/SKILL.md"
done

# =============================================================================
# TEST 5: install.sh gemini uninstall
# =============================================================================
log_section "TEST 5: install.sh gemini uninstall"

reset_osado

# Install first (so there's something to uninstall)
"$SRC_DIR/tools/install.sh" gemini install "$OSADO_DIR" >/dev/null 2>&1 || true

# Now uninstall
"$SRC_DIR/tools/install.sh" gemini uninstall "$OSADO_DIR" 2>&1 || true

# Verify .gemini symlinks are removed
for skill in "${EXPECTED_SKILLS[@]}"; do
    if [[ -L "$OSADO_DIR/.gemini/skills/$skill/SKILL.md" ]]; then
        log_fail "gemini uninstall: .gemini/skills/$skill/SKILL.md still exists"
    else
        log_pass "gemini uninstall: .gemini/skills/$skill/SKILL.md removed"
    fi
done

# Verify GEMINI.md is removed
if [[ -L "$OSADO_DIR/GEMINI.md" ]]; then
    log_fail "gemini uninstall: GEMINI.md still exists"
else
    log_pass "gemini uninstall: GEMINI.md removed"
fi

# =============================================================================
# TEST 6: install.sh opencode (Global install simulation)
# =============================================================================
log_section "TEST 6: install.sh opencode install (mocked)"

FAKE_HOME=$(mktemp -d)
FAKE_OPENCODE_DIR="$FAKE_HOME/.config/opencode/skills/osado-skills"

# Create a mock git that simulates clone
MOCK_BIN="$FAKE_HOME/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/git" <<'EOF'
#!/bin/bash
if [[ "$*" == *"clone"* ]]; then
    target="${@: -1}"
    mkdir -p "$target/.git"
    echo "mock" > "$target/.git/HEAD"
    exit 0
fi
if [[ "$*" == *"remote"*"get-url"* ]]; then
    echo "https://github.com/mpagot/os-autoinst-distri-opensuse-gemini.git"
    exit 0
fi
if [[ "$*" == *"fetch"* ]]; then
    exit 0
fi
if [[ "$*" == *"rev-list"*"--count"* ]]; then
    echo "0"
    exit 0
fi
if [[ "$*" == *"log"*"--oneline"* ]]; then
    echo "abc1234 latest commit"
    exit 0
fi
/usr/bin/git "$@"
EOF
chmod +x "$MOCK_BIN/git"

# Test install
HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$SRC_DIR/tools/install.sh" opencode install >/dev/null 2>&1
if [[ -d "$FAKE_OPENCODE_DIR/.git" ]]; then
    log_pass "opencode install: created $FAKE_OPENCODE_DIR"
else
    log_fail "opencode install: $FAKE_OPENCODE_DIR not created"
fi

# Test status (already installed)
status_output=$(HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$SRC_DIR/tools/install.sh" opencode status 2>&1)
if echo "$status_output" | grep -q "Up to date\|Installed"; then
    log_pass "opencode status: shows installed state"
else
    log_fail "opencode status: unexpected output: $status_output"
fi

# Test uninstall
echo "y" | HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$SRC_DIR/tools/install.sh" opencode uninstall >/dev/null 2>&1
if [[ ! -d "$FAKE_OPENCODE_DIR" ]]; then
    log_pass "opencode uninstall: removed $FAKE_OPENCODE_DIR"
else
    log_fail "opencode uninstall: $FAKE_OPENCODE_DIR still exists"
fi

rm -rf "$FAKE_HOME"

# =============================================================================
# TEST 7: Gemini CLI Extension Discovery
# =============================================================================
log_section "TEST 7: Gemini CLI Extension Discovery"

reset_osado

# Link the extension for discovery testing
gemini extensions link "$SRC_DIR" --consent 2>&1 || true

# Check if skills are listed
skills_output=$(gemini skills list 2>&1 || echo "")
if [[ -n "$skills_output" ]]; then
    for skill in "${EXPECTED_SKILLS[@]}"; do
        if echo "$skills_output" | grep -q "$skill"; then
            log_pass "gemini skills list: $skill discovered"
        else
            log_fail "gemini skills list: $skill NOT discovered"
        fi
    done
else
    log_skip "gemini skills list returned empty (may need API key)"
fi

# Check extension directory
gemini_ext_dir="$HOME/.gemini/extensions/osado-ai-assistant"
if [[ -d "$gemini_ext_dir" ]] || [[ -L "$gemini_ext_dir" ]]; then
    log_pass "Extension linked in ~/.gemini/extensions/"
else
    log_fail "Extension directory not found (link may have failed)"
fi

# =============================================================================
# TEST 8: Claude Code Skill Discovery
# =============================================================================
log_section "TEST 8: Claude Code Compatibility"

reset_osado

# Install and verify symlinks
"$SRC_DIR/tools/install.sh" claude install "$OSADO_DIR" >/dev/null 2>&1

for skill in "${EXPECTED_SKILLS[@]}"; do
    if [[ -L "$OSADO_DIR/.claude/skills/$skill/SKILL.md" ]]; then
        log_pass "Claude Code: .claude/skills/$skill/SKILL.md linked"
    else
        log_fail "Claude Code: .claude/skills/$skill/SKILL.md not linked"
    fi
done

# Validate the plugin manifest against Claude Code's schema
validate_output=$(claude plugin validate "$SRC_DIR" 2>&1) && validate_rc=0 || validate_rc=$?
if [[ $validate_rc -eq 0 ]]; then
    log_pass "claude plugin validate: $SRC_DIR"
else
    log_fail "claude plugin validate failed (rc=$validate_rc): $validate_output"
fi

# =============================================================================
# TEST 9: OpenCode Skill Discovery
# =============================================================================
log_section "TEST 9: OpenCode Compatibility"

reset_osado

# Install and verify symlinks
"$SRC_DIR/tools/install.sh" agents install "$OSADO_DIR" >/dev/null 2>&1

for skill in "${EXPECTED_SKILLS[@]}"; do
    if [[ -L "$OSADO_DIR/.agents/skills/$skill/SKILL.md" ]]; then
        log_pass "OpenCode: .agents/skills/$skill/SKILL.md linked"
    else
        log_fail "OpenCode: .agents/skills/$skill/SKILL.md not linked"
    fi
done

if [[ -L "$OSADO_DIR/AGENTS.md" ]]; then
    log_pass "OpenCode: AGENTS.md at root"
else
    log_fail "OpenCode: AGENTS.md not at root"
fi

# =============================================================================
# TEST 10: Context File Content Validation
# =============================================================================
log_section "TEST 10: Context File Validation"

# OSADO_AGENTS.md should contain key OSADO project info and workflow instructions
if grep -q "os-autoinst" "$SRC_DIR/OSADO_AGENTS.md"; then
    log_pass "OSADO_AGENTS.md references os-autoinst"
else
    log_fail "OSADO_AGENTS.md missing os-autoinst reference"
fi

if grep -q "make" "$SRC_DIR/OSADO_AGENTS.md"; then
    log_pass "OSADO_AGENTS.md contains build commands"
else
    log_fail "OSADO_AGENTS.md missing build commands"
fi

if grep -q "PERL5LIB" "$SRC_DIR/OSADO_AGENTS.md"; then
    log_pass "OSADO_AGENTS.md contains PERL5LIB setup"
else
    log_fail "OSADO_AGENTS.md missing PERL5LIB setup"
fi

if grep -q "make tidy" "$SRC_DIR/OSADO_AGENTS.md"; then
    log_pass "OSADO_AGENTS.md contains formatting commands"
else
    log_fail "OSADO_AGENTS.md missing formatting commands"
fi

# =============================================================================
# TEST 11: gemini-extension.json Validation
# =============================================================================
log_section "TEST 11: Extension Manifest Validation"

manifest="$SRC_DIR/gemini-extension.json"

# Check required fields
for field in name version description contextFileName; do
    if jq -e ".$field" "$manifest" >/dev/null 2>&1; then
        log_pass "Manifest has required field: $field"
    else
        log_fail "Manifest missing required field: $field"
    fi
done

# Verify contextFileName points to existing file
context_file=$(jq -r '.contextFileName' "$manifest")
if [[ -f "$SRC_DIR/$context_file" ]]; then
    log_pass "contextFileName '$context_file' exists"
else
    log_fail "contextFileName '$context_file' does not exist"
fi

# Verify name is valid (kebab-case)
ext_name=$(jq -r '.name' "$manifest")
if [[ "$ext_name" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
    log_pass "Extension name is valid kebab-case: $ext_name"
else
    log_fail "Extension name is not valid kebab-case: $ext_name"
fi

# =============================================================================
# TEST 12: OCX Registry Manifest Validation
# =============================================================================
log_section "TEST 12: OCX Registry Manifest Validation"

ocx_manifest="$SRC_DIR/ocx/registry.jsonc"

if [[ -f "$ocx_manifest" ]]; then
    log_pass "OCX registry manifest exists"
else
    log_fail "OCX registry manifest not found at $ocx_manifest"
fi

# Validate JSON syntax (strip comments for jq)
# jsonc may have comments; use sed to strip them for validation
ocx_json=$(grep -v '^\s*//' "$ocx_manifest" 2>/dev/null)
if jq empty <<< "$ocx_json" 2>/dev/null; then
    log_pass "OCX registry manifest is valid JSON"
else
    log_fail "OCX registry manifest has invalid JSON syntax"
fi

# Check required top-level fields
for field in name version author components; do
    if jq -e ".$field" <<< "$ocx_json" >/dev/null 2>&1; then
        log_pass "OCX manifest has field: $field"
    else
        log_fail "OCX manifest missing field: $field"
    fi
done

# Verify schema reference
schema=$(jq -r '."$schema"' <<< "$ocx_json" 2>/dev/null)
if [[ "$schema" == *"ocx.kdco.dev"* ]]; then
    log_pass "OCX manifest references correct schema"
else
    log_fail "OCX manifest schema reference: '$schema'"
fi

# Verify each component has required fields and files exist
component_count=$(jq '.components | length' <<< "$ocx_json" 2>/dev/null)
if [[ "$component_count" -gt 0 ]]; then
    log_pass "OCX manifest has $component_count components"
else
    log_fail "OCX manifest has no components"
fi

# Check each component
for i in $(seq 0 $((component_count - 1))); do
    comp_name=$(jq -r ".components[$i].name" <<< "$ocx_json" 2>/dev/null)
    comp_type=$(jq -r ".components[$i].type" <<< "$ocx_json" 2>/dev/null)
    comp_desc=$(jq -r ".components[$i].description" <<< "$ocx_json" 2>/dev/null)

    # Validate component name format (lowercase alphanumeric + hyphens)
    if [[ "$comp_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
        log_pass "OCX component name valid: $comp_name"
    else
        log_fail "OCX component name invalid: '$comp_name' (must be lowercase + hyphens)"
    fi

    # Validate type is 'skill'
    if [[ "$comp_type" == "skill" ]]; then
        log_pass "OCX component type: $comp_name -> $comp_type"
    else
        log_fail "OCX component type: $comp_name -> '$comp_type' (expected 'skill')"
    fi

    # Validate description is non-empty
    if [[ -n "$comp_desc" && "$comp_desc" != "null" ]]; then
        log_pass "OCX component description: $comp_name has description"
    else
        log_fail "OCX component description: $comp_name is empty"
    fi

    # Validate all referenced files exist
    file_count=$(jq ".components[$i].files | length" <<< "$ocx_json" 2>/dev/null)
    files_ok=true
    for j in $(seq 0 $((file_count - 1))); do
        file_path=$(jq -r ".components[$i].files[$j]" <<< "$ocx_json" 2>/dev/null)
        if [[ ! -f "$SRC_DIR/$file_path" ]]; then
            log_fail "OCX component '$comp_name': file not found: $file_path"
            files_ok=false
        fi
    done
    if [[ "$files_ok" == "true" ]]; then
        log_pass "OCX component '$comp_name': all $file_count files exist"
    fi
done

# Verify every skill in EXPECTED_SKILLS has an OCX component
for skill in "${EXPECTED_SKILLS[@]}"; do
    if jq -e ".components[] | select(.name == \"$skill\")" <<< "$ocx_json" >/dev/null 2>&1; then
        log_pass "OCX registry includes skill: $skill"
    else
        log_fail "OCX registry missing skill: $skill"
    fi
done

# =============================================================================
# TEST 13: Claude Code Marketplace Install Cycle
# =============================================================================
log_section "TEST 13: Claude Code Marketplace Install Cycle"

marketplace_name="openqa-tools"
plugin_name="osado-ai-assistant"
plugin_ref="$plugin_name@$marketplace_name"

# Ensure a clean slate: best-effort cleanup if a previous run left state behind
claude plugin uninstall "$plugin_ref" >/dev/null 2>&1 || true
claude plugin marketplace remove "$marketplace_name" >/dev/null 2>&1 || true

# Add the local repo as a marketplace source
add_output=$(claude plugin marketplace add "$SRC_DIR" --scope user 2>&1) && add_rc=0 || add_rc=$?
if [[ $add_rc -eq 0 ]]; then
    log_pass "claude plugin marketplace add: $SRC_DIR"
else
    log_fail "claude plugin marketplace add failed (rc=$add_rc): $add_output"
fi

# The marketplace should now appear in the list under its declared name
if claude plugin marketplace list 2>&1 | grep -q "$marketplace_name"; then
    log_pass "claude plugin marketplace list contains '$marketplace_name'"
else
    log_fail "claude plugin marketplace list missing '$marketplace_name'"
fi

# Install the plugin from the freshly registered marketplace
install_output=$(claude plugin install "$plugin_ref" 2>&1) && install_rc=0 || install_rc=$?
if [[ $install_rc -eq 0 ]]; then
    log_pass "claude plugin install: $plugin_ref"
else
    log_fail "claude plugin install failed (rc=$install_rc): $install_output"
fi

# The plugin should now appear in the installed plugin list
if claude plugin list 2>&1 | grep -q "$plugin_name"; then
    log_pass "claude plugin list contains '$plugin_name'"
else
    log_fail "claude plugin list missing '$plugin_name'"
fi

# Uninstall the plugin before removing the marketplace
uninstall_output=$(claude plugin uninstall "$plugin_ref" 2>&1) && uninstall_rc=0 || uninstall_rc=$?
if [[ $uninstall_rc -eq 0 ]]; then
    log_pass "claude plugin uninstall: $plugin_ref"
else
    log_fail "claude plugin uninstall failed (rc=$uninstall_rc): $uninstall_output"
fi

# Cleanup: remove the marketplace regardless of prior outcomes
remove_output=$(claude plugin marketplace remove "$marketplace_name" 2>&1) && remove_rc=0 || remove_rc=$?
if [[ $remove_rc -eq 0 ]]; then
    log_pass "claude plugin marketplace remove: $marketplace_name"
else
    log_fail "claude plugin marketplace remove failed (rc=$remove_rc): $remove_output"
fi

# =============================================================================
# TEST 14: install.sh all (Multi-harness dispatch)
# =============================================================================
log_section "TEST 14: install.sh all install"

reset_osado

# Mock git for the opencode harness (can't actually clone in CI)
FAKE_HOME=$(mktemp -d)
MOCK_BIN="$FAKE_HOME/bin"
create_mock_git_clone "$MOCK_BIN"

HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$SRC_DIR/tools/install.sh" all install "$OSADO_DIR" >/dev/null 2>&1

# Verify gemini
if [[ -L "$OSADO_DIR/.gemini/skills/local-lint-test/SKILL.md" ]]; then
    log_pass "all install: gemini harness installed"
else
    log_fail "all install: gemini harness not installed"
fi

# Verify claude
if [[ -L "$OSADO_DIR/.claude/skills/local-lint-test/SKILL.md" ]]; then
    log_pass "all install: claude harness installed"
else
    log_fail "all install: claude harness not installed"
fi

# Verify agents
if [[ -L "$OSADO_DIR/.agents/skills/local-lint-test/SKILL.md" ]]; then
    log_pass "all install: agents harness installed"
else
    log_fail "all install: agents harness not installed"
fi

# Verify opencode (mocked)
if [[ -d "$FAKE_HOME/.config/opencode/skills/osado-skills/.git" ]]; then
    log_pass "all install: opencode harness installed (mocked clone)"
else
    log_fail "all install: opencode harness not installed"
fi

rm -rf "$FAKE_HOME"

# =============================================================================
# TEST 15: OCX CLI Install and Add Workflow
# =============================================================================
log_section "TEST 15: OCX CLI Install and Add Workflow"

# OCX is not pre-installed in the container — install it via the official script.
# This validates that our target audience can install OCX in the same environment.
OCX_INSTALL_OK=false

if has_command ocx; then
    log_pass "OCX CLI already available: $(ocx --version 2>&1 | head -1)"
    OCX_INSTALL_OK=true
else
    log_info "Installing OCX CLI via curl installer..."
    # nosemgrep: tools.curl-pipe-shell -- Not production code, only test code, only executed in a consumable container
    if curl -fsSL https://ocx.kdco.dev/install.sh 2>/dev/null | sh >/dev/null 2>&1; then
        # The installer typically places the binary in ~/.ocx/bin or ~/.local/bin
        for ocx_candidate in "$HOME/.ocx/bin" "$HOME/.local/bin" "/usr/local/bin"; do
            if [[ -x "$ocx_candidate/ocx" ]]; then
                export PATH="$ocx_candidate:$PATH"
                break
            fi
        done

        if has_command ocx; then
            log_pass "OCX CLI installed: $(ocx --version 2>&1 | head -1)"
            OCX_INSTALL_OK=true
        else
            log_fail "OCX CLI not in PATH after installation"
        fi
    else
        log_fail "OCX CLI installation script failed"
    fi
fi

if [[ "$OCX_INSTALL_OK" == "true" ]]; then
    # --- Subtest: ocx init creates configuration ---
    OCX_PROJECT=$(mktemp -d)

    ocx_init_output=$(cd "$OCX_PROJECT" && ocx init 2>&1) && ocx_init_rc=0 || ocx_init_rc=$?
    if [[ $ocx_init_rc -eq 0 ]]; then
        log_pass "ocx init succeeded in test project"
    else
        log_fail "ocx init failed (rc=$ocx_init_rc): $ocx_init_output"
    fi

    # Verify ocx init created the expected config file
    if [[ -f "$OCX_PROJECT/.opencode/ocx.jsonc" ]]; then
        log_pass "ocx init created .opencode/ocx.jsonc"
    else
        log_fail "ocx init did not create .opencode/ocx.jsonc"
    fi

    # --- Subtest: ocx add from our local registry ---
    # OCX supports --from for ephemeral registry sources.
    # Try file:// protocol first (local path), fall back gracefully.
    # The registry at /src/ocx/registry.jsonc lists files relative to /src/.
    OCX_ADD_OK=false
    REGISTRY_PATH="$SRC_DIR/ocx/registry.jsonc"

    # Determine the registry name from our manifest
    registry_name=$(grep -v '^\s*//' "$REGISTRY_PATH" | jq -r '.name // empty' 2>/dev/null)
    if [[ -n "$registry_name" ]]; then
        log_pass "OCX registry name resolved: '$registry_name'"
    else
        log_fail "Could not parse registry name from $REGISTRY_PATH"
    fi

    # Attempt to add a skill component from our registry
    # OCX add syntax: ocx add <registry-name>/<component> --from <url>
    # Try file:// URL first, then bare path
    add_output=""
    add_rc=1
    for registry_url in "file://$REGISTRY_PATH" "$REGISTRY_PATH"; do
        add_output=$(cd "$OCX_PROJECT" && ocx add osado-skills/local-lint-test --from "$registry_url" 2>&1) && add_rc=0 || add_rc=$?
        if [[ $add_rc -eq 0 ]]; then
            OCX_ADD_OK=true
            break
        fi
    done

    if [[ "$OCX_ADD_OK" == "true" ]]; then
        log_pass "ocx add local-lint-test: succeeded"

        # Verify the skill files were placed in .opencode/
        if [[ -f "$OCX_PROJECT/.opencode/skills/local-lint-test/SKILL.md" ]]; then
            log_pass "ocx add: SKILL.md placed in .opencode/skills/"
        elif [[ -f "$OCX_PROJECT/.opencode/local-lint-test/SKILL.md" ]]; then
            log_pass "ocx add: SKILL.md placed in .opencode/local-lint-test/"
        else
            # OCX might place files differently; check if any skill file landed
            skill_file=$(find "$OCX_PROJECT/.opencode" -name "SKILL.md" -path "*local-lint-test*" 2>/dev/null | head -1)
            if [[ -n "$skill_file" ]]; then
                log_pass "ocx add: SKILL.md found at $skill_file"
            else
                log_fail "ocx add: SKILL.md not found in .opencode/ after add"
            fi
        fi
    else
        # OCX may not support file:// or local paths — this is expected in some versions
        log_skip "ocx add --from local path not supported (output: ${add_output:0:200})"
    fi

    rm -rf "$OCX_PROJECT"
else
    log_skip "OCX CLI not available: skipping add workflow tests"
fi

# =============================================================================
# TEST 16: Antigravity CLI Compatibility
# =============================================================================
log_section "TEST 16: Antigravity CLI Compatibility"

# Validate plugin.json manifest at repo root
agy_manifest="$SRC_DIR/plugin.json"

assert_file_exists "$agy_manifest" "Antigravity plugin manifest (plugin.json) at repo root"

# Verify only allowed fields (additionalProperties: false in schema)
extra_fields=$(jq -r '[keys[] | select(. != "name" and . != "description")] | join(", ")' \
    "$agy_manifest" 2>/dev/null)
if [[ -z "$extra_fields" ]]; then
    log_pass "plugin.json has no extra fields (additionalProperties:false satisfied)"
else
    log_fail "plugin.json has disallowed fields: $extra_fields"
fi

# Verify required 'name' field and pattern
agy_name=$(jq -r '.name // empty' "$agy_manifest" 2>/dev/null)
if [[ -n "$agy_name" ]]; then
    log_pass "plugin.json has required 'name' field: $agy_name"
else
    log_fail "plugin.json missing required 'name' field"
fi

if [[ "$agy_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    log_pass "plugin.json name matches ^[a-zA-Z0-9-_]+\$: $agy_name"
else
    log_fail "plugin.json name '$agy_name' does not match ^[a-zA-Z0-9-_]+\$"
fi

# Verify name is in sync with gemini-extension.json
gemini_name=$(jq -r '.name' "$SRC_DIR/gemini-extension.json" 2>/dev/null)
if [[ "$agy_name" == "$gemini_name" ]]; then
    log_pass "plugin.json name in sync with gemini-extension.json: $agy_name"
else
    log_fail "name mismatch: plugin.json='$agy_name' vs gemini-extension.json='$gemini_name'"
fi

# Test install.sh antigravity harness: symlinks into staging dir
FAKE_HOME_AGY=$(mktemp -d)
AGY_PLUGIN_DIR="$FAKE_HOME_AGY/.gemini/antigravity-cli/plugins/osado-ai-assistant"

HOME="$FAKE_HOME_AGY" "$SRC_DIR/tools/install.sh" antigravity install >/dev/null 2>&1

assert_symlink "$AGY_PLUGIN_DIR/plugin.json" \
    "$SRC_DIR/plugin.json" \
    "antigravity install: plugin.json symlinked"

for skill in "${EXPECTED_SKILLS[@]}"; do
    assert_symlink "$AGY_PLUGIN_DIR/skills/$skill/SKILL.md" \
        "$SRC_DIR/skills/$skill/SKILL.md" \
        "antigravity install: skills/$skill/SKILL.md"
done

# Test uninstall removes symlinks
HOME="$FAKE_HOME_AGY" "$SRC_DIR/tools/install.sh" antigravity uninstall >/dev/null 2>&1

if [[ ! -L "$AGY_PLUGIN_DIR/plugin.json" ]]; then
    log_pass "antigravity uninstall: plugin.json removed"
else
    log_fail "antigravity uninstall: plugin.json still exists"
fi

if [[ ! -L "$AGY_PLUGIN_DIR/skills/local-lint-test/SKILL.md" ]]; then
    log_pass "antigravity uninstall: skills/ symlinks removed"
else
    log_fail "antigravity uninstall: skills/ symlinks still exist"
fi

rm -rf "$FAKE_HOME_AGY"

# Run agy plugin validate if agy is available in the container
if has_command agy; then
    log_info "agy: $(agy --version 2>&1 | head -1)"
    validate_output=$(agy plugin validate "$SRC_DIR" 2>&1) && validate_rc=0 || validate_rc=$?
    if [[ $validate_rc -eq 0 ]]; then
        log_pass "agy plugin validate: $SRC_DIR"
    else
        log_fail "agy plugin validate failed (rc=$validate_rc): $validate_output"
    fi
else
    log_skip "agy not on PATH — skipping agy plugin validate"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================"
echo -e "  ${GREEN}PASSED: $PASS${NC}"
echo -e "  ${RED}FAILED: $FAIL${NC}"
echo -e "  ${YELLOW}SKIPPED: $SKIP${NC}"
echo "  TOTAL:  $((PASS + FAIL + SKIP))"
echo "============================================"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Integration tests FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}Integration tests PASSED${NC}"
    exit 0
fi
