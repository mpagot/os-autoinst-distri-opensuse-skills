#!/bin/bash

# ==============================================================================
# OSADO AI Assistant - Installation Test Suite
# ==============================================================================
# Tests the multi-harness install mechanism (tools/install.sh) including:
#   - Gemini harness: symlinks into .gemini/ (skills + commands)
#   - Claude harness: symlinks into .claude/skills/
#   - Agents harness: symlinks into .agents/skills/ + AGENTS.md
#   - OpenCode harness: git clone to ~/.config/opencode/skills/osado-skills/
#   - Conflict protection and selective uninstallation
#   - Update simulation
#   - Status check
# ==============================================================================

set -e

# Setup paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_SCRIPT="$REPO_ROOT/tools/install.sh"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test environment
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_OSADO="$TEST_ROOT/fake_osado"

# Helper functions
log_test() { echo -e "${YELLOW}TEST:${NC} $1"; }
log_pass() { echo -e "${GREEN}PASS${NC}"; }
log_fail() { echo -e "${RED}FAIL:${NC} $1"; exit 1; }

setup_fake_osado() {
    rm -rf "$FAKE_OSADO"
    mkdir -p "$FAKE_OSADO/.git"
}

# Create a mock git that only handles clone (writes mock script to given dir)
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

assert_is_link() {
    local target="$1"
    local expected_source="$2"
    [[ -L "$target" ]] || log_fail "Path '$target' is not a symlink"
    local actual_source
    actual_source=$(readlink "$target")
    [[ "$actual_source" == "$expected_source" ]] || log_fail "Link '$target' points to '$actual_source', expected '$expected_source'"
}

assert_not_exists() {
    if [[ -e "$1" ]] || [[ -L "$1" ]]; then
        log_fail "Path '$1' should not exist"
    fi
}

assert_exists() {
    [[ -e "$1" ]] || log_fail "Path '$1' should exist"
}

assert_content() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(cat "$file")
    [[ "$actual" == "$expected" ]] || log_fail "File '$file' content mismatch. Got: '$actual', Expected: '$expected'"
}

# ------------------------------------------------------------------------------
# TEST 1: Gemini Install (Basic)
# Verifies gemini harness installs skills and commands into .gemini/
# ------------------------------------------------------------------------------
log_test "1: Gemini Install - basic symlinks"
setup_fake_osado
"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > /dev/null 2>&1

# Commands
assert_is_link "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml" \
    "$REPO_ROOT/commands/osado/github_pr_create.toml"

# Skills (check a few representative files)
assert_is_link "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
assert_is_link "$FAKE_OSADO/.gemini/skills/local-lint-test/scripts/test_compile.sh" \
    "$REPO_ROOT/skills/local-lint-test/scripts/test_compile.sh"
assert_is_link "$FAKE_OSADO/.gemini/skills/openqa-log-analyzer/SKILL.md" \
    "$REPO_ROOT/skills/openqa-log-analyzer/SKILL.md"

# Root GEMINI.md
assert_is_link "$FAKE_OSADO/GEMINI.md" "$REPO_ROOT/OSADO_AGENTS.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 2: Gemini Install - Conflict Protection
# Verifies that the script does not overwrite existing regular files.
# ------------------------------------------------------------------------------
log_test "2: Gemini Install - conflict protection"
setup_fake_osado
mkdir -p "$FAKE_OSADO/.gemini/commands/osado"
echo "USER_CONTENT" > "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml"

# Run install
"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > "$TEST_ROOT/install_output.log" 2>&1 || true

# Verify warning was issued
grep -q "Conflict" "$TEST_ROOT/install_output.log" || log_fail "No conflict warning found in output"

# Verify user file is untouched
[[ ! -L "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml" ]] || log_fail "User file was replaced by a link!"
assert_content "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml" "USER_CONTENT"

# Verify other files ARE linked
assert_is_link "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 3: Gemini Uninstall
# Verifies that uninstallation only removes links pointing to the toolset.
# ------------------------------------------------------------------------------
log_test "3: Gemini Uninstall - selective removal"
setup_fake_osado
"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > /dev/null 2>&1

# Create a user-owned file
echo "MY_SKILL" > "$FAKE_OSADO/.gemini/skills/my_skill.md"

# Uninstall
"$INSTALL_SCRIPT" gemini uninstall "$FAKE_OSADO" > /dev/null 2>&1

# Verify toolset links are gone
assert_not_exists "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml"
assert_not_exists "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md"
assert_not_exists "$FAKE_OSADO/.gemini/skills/openqa-log-analyzer/SKILL.md"

# Verify user file is preserved
[[ -f "$FAKE_OSADO/.gemini/skills/my_skill.md" ]] || log_fail "User file was deleted during uninstall!"
log_pass

# ------------------------------------------------------------------------------
# TEST 4: Gemini Update (Mocked Git)
# Verifies that update triggers 'git pull' in the toolset repo.
# ------------------------------------------------------------------------------
log_test "4: Gemini Update - verify mocked git pull"
setup_fake_osado

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/git" <<EOF
#!/bin/bash
if [[ "\$*" == *"pull"* ]]; then
    echo "MOCK_GIT_PULL_CALLED"
    exit 0
fi
/usr/bin/git "\$@"
EOF

chmod +x "$MOCK_BIN/git"
PATH="$MOCK_BIN:$PATH" "$INSTALL_SCRIPT" gemini update "$FAKE_OSADO" > "$TEST_ROOT/update_output.log" 2>&1
grep -q "MOCK_GIT_PULL_CALLED" "$TEST_ROOT/update_output.log" || log_fail "Git pull was not called"
log_pass

# ------------------------------------------------------------------------------
# TEST 5: Recursive Linking
# Verifies recursive linking for skills with scripts/ and assets/.
# ------------------------------------------------------------------------------
log_test "5: Gemini Install - recursive linking (nested directories)"
setup_fake_osado
"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > /dev/null 2>&1

# openqa-log-analyzer has scripts/
assert_is_link "$FAKE_OSADO/.gemini/skills/openqa-log-analyzer/scripts/extract_log_section.pl" \
    "$REPO_ROOT/skills/openqa-log-analyzer/scripts/extract_log_section.pl"

# test-catalog has scripts/ and assets/
assert_is_link "$FAKE_OSADO/.gemini/skills/test-catalog/scripts/audit.sh" \
    "$REPO_ROOT/skills/test-catalog/scripts/audit.sh"
assert_is_link "$FAKE_OSADO/.gemini/skills/test-catalog/assets/template.md" \
    "$REPO_ROOT/skills/test-catalog/assets/template.md"

# vr-planner has multiple scripts
assert_is_link "$FAKE_OSADO/.gemini/skills/vr-planner/scripts/classify_changes.pl" \
    "$REPO_ROOT/skills/vr-planner/scripts/classify_changes.pl"
log_pass

# ------------------------------------------------------------------------------
# TEST 6: Coexistence with Pre-existing Files
# Verifies installation alongside existing user skills.
# ------------------------------------------------------------------------------
log_test "6: Gemini Install - coexistence with pre-existing .gemini"
setup_fake_osado
mkdir -p "$FAKE_OSADO/.gemini/skills"
echo "PRE_EXISTING" > "$FAKE_OSADO/.gemini/skills/user_skill.md"

"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > /dev/null 2>&1

assert_content "$FAKE_OSADO/.gemini/skills/user_skill.md" "PRE_EXISTING"
assert_is_link "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 7: Uninstall Protects User-Modified Files
# Verifies that user-replaced symlinks are NOT removed during uninstall.
# ------------------------------------------------------------------------------
log_test "7: Gemini Uninstall - protects user-modified files"
setup_fake_osado
"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > /dev/null 2>&1

# Replace a symlink with a regular file
rm "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md"
echo "USER_MODIFIED" > "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md"

# Replace a symlink with a different link
rm "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml"
ln -s "/tmp" "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml"

# Run uninstall
"$INSTALL_SCRIPT" gemini uninstall "$FAKE_OSADO" > /dev/null 2>&1

# Verify modified files are preserved
assert_content "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md" "USER_MODIFIED"
[[ -L "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml" ]] || log_fail "User symlink was deleted!"
[[ "$(readlink "$FAKE_OSADO/.gemini/commands/osado/github_pr_create.toml")" == "/tmp" ]] || log_fail "User symlink points to wrong place"

# Verify other toolset links ARE removed
assert_not_exists "$FAKE_OSADO/.gemini/skills/openqa-log-analyzer/SKILL.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 8: GEMINI.md Handling
# Verifies linking and protection of root context file.
# ------------------------------------------------------------------------------
log_test "8: Gemini Install - GEMINI.md linking and protection"
setup_fake_osado
"$INSTALL_SCRIPT" gemini install "$FAKE_OSADO" > /dev/null 2>&1

assert_is_link "$FAKE_OSADO/GEMINI.md" "$REPO_ROOT/OSADO_AGENTS.md"

# Replace with a real file
rm "$FAKE_OSADO/GEMINI.md"
echo "USER_GEMINI" > "$FAKE_OSADO/GEMINI.md"

# Run uninstall — should NOT remove user's regular file
"$INSTALL_SCRIPT" gemini uninstall "$FAKE_OSADO" > /dev/null 2>&1

assert_content "$FAKE_OSADO/GEMINI.md" "USER_GEMINI"
log_pass

# ------------------------------------------------------------------------------
# TEST 9: Claude Harness
# Verifies claude harness creates .claude/skills/ symlinks.
# ------------------------------------------------------------------------------
log_test "9: Claude Install - .claude/skills/ symlinks"
setup_fake_osado
"$INSTALL_SCRIPT" claude install "$FAKE_OSADO" > /dev/null 2>&1

assert_is_link "$FAKE_OSADO/.claude/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
assert_is_link "$FAKE_OSADO/.claude/skills/openqa-log-analyzer/SKILL.md" \
    "$REPO_ROOT/skills/openqa-log-analyzer/SKILL.md"
assert_is_link "$FAKE_OSADO/.claude/skills/openqa-log-analyzer/scripts/extract_log_section.pl" \
    "$REPO_ROOT/skills/openqa-log-analyzer/scripts/extract_log_section.pl"

# Claude harness should NOT create GEMINI.md or AGENTS.md
assert_not_exists "$FAKE_OSADO/GEMINI.md"
assert_not_exists "$FAKE_OSADO/AGENTS.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 10: Agents Harness
# Verifies agents harness creates .agents/skills/ symlinks + AGENTS.md.
# ------------------------------------------------------------------------------
log_test "10: Agents Install - .agents/skills/ and AGENTS.md"
setup_fake_osado
"$INSTALL_SCRIPT" agents install "$FAKE_OSADO" > /dev/null 2>&1

# .agents/skills/ should have the same skills
assert_is_link "$FAKE_OSADO/.agents/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
assert_is_link "$FAKE_OSADO/.agents/skills/openqa-log-analyzer/SKILL.md" \
    "$REPO_ROOT/skills/openqa-log-analyzer/SKILL.md"
assert_is_link "$FAKE_OSADO/.agents/skills/openqa-log-analyzer/scripts/extract_log_section.pl" \
    "$REPO_ROOT/skills/openqa-log-analyzer/scripts/extract_log_section.pl"

# AGENTS.md at root
assert_is_link "$FAKE_OSADO/AGENTS.md" "$REPO_ROOT/OSADO_AGENTS.md"

# Should NOT create .gemini/ or GEMINI.md
assert_not_exists "$FAKE_OSADO/GEMINI.md"
assert_not_exists "$FAKE_OSADO/.gemini"
log_pass

# ------------------------------------------------------------------------------
# TEST 11: Agents Uninstall
# Verifies agents harness uninstall removes .agents/ links and AGENTS.md.
# ------------------------------------------------------------------------------
log_test "11: Agents Uninstall - removes .agents/ links and AGENTS.md"

# .agents/ should exist from test 10
assert_exists "$FAKE_OSADO/AGENTS.md"
assert_exists "$FAKE_OSADO/.agents/skills/local-lint-test/SKILL.md"

"$INSTALL_SCRIPT" agents uninstall "$FAKE_OSADO" > /dev/null 2>&1

# Cross-tool files should be removed
assert_not_exists "$FAKE_OSADO/.agents/skills/local-lint-test/SKILL.md"
assert_not_exists "$FAKE_OSADO/AGENTS.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 12: OpenCode Install (Mocked Git Clone)
# Verifies opencode harness calls git clone to the correct directory.
# ------------------------------------------------------------------------------
log_test "12: OpenCode Install - git clone to global dir"

FAKE_HOME="$TEST_ROOT/fakehome"
FAKE_OPENCODE_DIR="$FAKE_HOME/.config/opencode/skills/osado-skills"
mkdir -p "$FAKE_HOME"

MOCK_BIN="$TEST_ROOT/bin_oc"
create_mock_git_clone "$MOCK_BIN"

HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$INSTALL_SCRIPT" opencode install > "$TEST_ROOT/oc_install.log" 2>&1

# Verify the clone target directory was created
[[ -d "$FAKE_OPENCODE_DIR/.git" ]] || log_fail "OpenCode install dir not created at $FAKE_OPENCODE_DIR"
log_pass

# ------------------------------------------------------------------------------
# TEST 13: OpenCode Install - Already Installed Detection
# Verifies opencode harness detects existing installation.
# ------------------------------------------------------------------------------
log_test "13: OpenCode Install - already installed detection"

# Set up a fake existing install with the correct remote
mkdir -p "$FAKE_OPENCODE_DIR/.git"
cat > "$MOCK_BIN/git" <<'EOF'
#!/bin/bash
if [[ "$*" == *"remote"*"get-url"* ]]; then
    echo "https://github.com/os-autoinst/osado-skills.git"
    exit 0
fi
/usr/bin/git "$@"
EOF
chmod +x "$MOCK_BIN/git"

HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$INSTALL_SCRIPT" opencode install > "$TEST_ROOT/oc_reinstall.log" 2>&1
grep -q "Already installed" "$TEST_ROOT/oc_reinstall.log" || log_fail "Should detect already installed"
log_pass

# ------------------------------------------------------------------------------
# TEST 14: OpenCode Status - Not Installed
# Verifies opencode status shows not-installed message.
# ------------------------------------------------------------------------------
log_test "14: OpenCode Status - not installed"

rm -rf "$FAKE_OPENCODE_DIR"
HOME="$FAKE_HOME" "$INSTALL_SCRIPT" opencode status > "$TEST_ROOT/oc_status.log" 2>&1
grep -q "Not installed" "$TEST_ROOT/oc_status.log" || log_fail "Should show not-installed message"
log_pass

# ------------------------------------------------------------------------------
# TEST 15: OpenCode Uninstall - Confirm Prompt (Simulated 'n')
# Verifies opencode uninstall aborts on 'n' input.
# ------------------------------------------------------------------------------
log_test "15: OpenCode Uninstall - cancel on 'n'"

mkdir -p "$FAKE_OPENCODE_DIR/.git"
echo "n" | HOME="$FAKE_HOME" "$INSTALL_SCRIPT" opencode uninstall > "$TEST_ROOT/oc_uninstall_n.log" 2>&1
grep -q "Cancelled" "$TEST_ROOT/oc_uninstall_n.log" || log_fail "Should show cancelled message"
[[ -d "$FAKE_OPENCODE_DIR" ]] || log_fail "Directory should still exist after cancel"
log_pass

# ------------------------------------------------------------------------------
# TEST 16: OpenCode Uninstall - Confirm Prompt (Simulated 'y')
# Verifies opencode uninstall removes directory on 'y' input.
# ------------------------------------------------------------------------------
log_test "16: OpenCode Uninstall - confirm with 'y'"

[[ -d "$FAKE_OPENCODE_DIR" ]] || mkdir -p "$FAKE_OPENCODE_DIR/.git"
echo "y" | HOME="$FAKE_HOME" "$INSTALL_SCRIPT" opencode uninstall > "$TEST_ROOT/oc_uninstall_y.log" 2>&1
[[ ! -d "$FAKE_OPENCODE_DIR" ]] || log_fail "Directory should be removed after confirm"
log_pass

# ------------------------------------------------------------------------------
# TEST 17: All Harness (Dispatches to all)
# Verifies 'all' harness runs opencode + gemini + claude + agents.
# ------------------------------------------------------------------------------
log_test "17: All Harness - dispatches to all"
setup_fake_osado
rm -rf "$FAKE_OPENCODE_DIR"

# Mock git for opencode clone
create_mock_git_clone "$MOCK_BIN"

HOME="$FAKE_HOME" PATH="$MOCK_BIN:$PATH" "$INSTALL_SCRIPT" all install "$FAKE_OSADO" > "$TEST_ROOT/all_output.log" 2>&1

# Verify gemini
assert_is_link "$FAKE_OSADO/.gemini/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
# Verify claude
assert_is_link "$FAKE_OSADO/.claude/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
# Verify agents
assert_is_link "$FAKE_OSADO/.agents/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
# Verify opencode (mocked clone)
[[ -d "$FAKE_OPENCODE_DIR/.git" ]] || log_fail "OpenCode install dir not created by 'all'"
log_pass

# ------------------------------------------------------------------------------
# TEST 18: Error Handling - Missing Target Path
# Verifies proper error when target path is missing for symlink harnesses.
# ------------------------------------------------------------------------------
log_test "18: Error - missing target path for gemini"
"$INSTALL_SCRIPT" gemini install > "$TEST_ROOT/err_output.log" 2>&1 && \
    log_fail "Should have exited with error" || true
grep -q "requires a target path" "$TEST_ROOT/err_output.log" || log_fail "Should show target path error"
log_pass

# ------------------------------------------------------------------------------
# TEST 19: Error Handling - Invalid Harness
# Verifies proper error for unknown harness names.
# ------------------------------------------------------------------------------
log_test "19: Error - invalid harness name"
"$INSTALL_SCRIPT" foobar install "$FAKE_OSADO" > "$TEST_ROOT/err_harness.log" 2>&1 && \
    log_fail "Should have exited with error" || true
grep -q "Unknown harness" "$TEST_ROOT/err_harness.log" || log_fail "Should show unknown harness error"
log_pass

# ------------------------------------------------------------------------------
# TEST 20: Error Handling - Invalid Action
# Verifies proper error for unknown action names.
# ------------------------------------------------------------------------------
log_test "20: Error - invalid action name"
"$INSTALL_SCRIPT" gemini foobar "$FAKE_OSADO" > "$TEST_ROOT/err_action.log" 2>&1 && \
    log_fail "Should have exited with error" || true
grep -q "Unknown action" "$TEST_ROOT/err_action.log" || log_fail "Should show unknown action error"
log_pass

# ------------------------------------------------------------------------------
# TEST 21: Antigravity Install (Basic)
# Verifies antigravity harness symlinks plugin.json and skills/ into the
# global plugin staging directory.
# ------------------------------------------------------------------------------
log_test "21: Antigravity Install - plugin.json and skills/ symlinked"

FAKE_HOME_AGY="$TEST_ROOT/fakehome_agy"
mkdir -p "$FAKE_HOME_AGY"
AGY_PLUGIN_DIR="$FAKE_HOME_AGY/.gemini/antigravity-cli/plugins/osado-ai-assistant"

HOME="$FAKE_HOME_AGY" "$INSTALL_SCRIPT" antigravity install > /dev/null 2>&1

assert_is_link "$AGY_PLUGIN_DIR/plugin.json" "$REPO_ROOT/plugin.json"
assert_is_link "$AGY_PLUGIN_DIR/skills/local-lint-test/SKILL.md" \
    "$REPO_ROOT/skills/local-lint-test/SKILL.md"
assert_is_link "$AGY_PLUGIN_DIR/skills/openqa-log-analyzer/SKILL.md" \
    "$REPO_ROOT/skills/openqa-log-analyzer/SKILL.md"
log_pass

# ------------------------------------------------------------------------------
# TEST 22: Antigravity Install - Recursive linking (nested directories)
# Verifies skills with scripts/ subdirs are recursively linked.
# ------------------------------------------------------------------------------
log_test "22: Antigravity Install - recursive linking (scripts/ subdir)"

assert_is_link "$AGY_PLUGIN_DIR/skills/openqa-log-analyzer/scripts/extract_log_section.pl" \
    "$REPO_ROOT/skills/openqa-log-analyzer/scripts/extract_log_section.pl"
assert_is_link "$AGY_PLUGIN_DIR/skills/test-catalog/scripts/audit.sh" \
    "$REPO_ROOT/skills/test-catalog/scripts/audit.sh"
log_pass

# ------------------------------------------------------------------------------
# TEST 23: Antigravity Install - Conflict protection
# Verifies that a pre-existing regular file is not overwritten.
# ------------------------------------------------------------------------------
log_test "23: Antigravity Install - conflict protection"

FAKE_HOME_AGY2="$TEST_ROOT/fakehome_agy2"
mkdir -p "$FAKE_HOME_AGY2/.gemini/antigravity-cli/plugins/osado-ai-assistant/skills/local-lint-test"
echo "USER_CONTENT" > \
    "$FAKE_HOME_AGY2/.gemini/antigravity-cli/plugins/osado-ai-assistant/skills/local-lint-test/SKILL.md"

HOME="$FAKE_HOME_AGY2" "$INSTALL_SCRIPT" antigravity install > "$TEST_ROOT/agy_conflict.log" 2>&1 || true

grep -q "Conflict" "$TEST_ROOT/agy_conflict.log" || log_fail "No conflict warning found"
assert_content \
    "$FAKE_HOME_AGY2/.gemini/antigravity-cli/plugins/osado-ai-assistant/skills/local-lint-test/SKILL.md" \
    "USER_CONTENT"
log_pass

# ------------------------------------------------------------------------------
# TEST 24: Antigravity Uninstall
# Verifies symlinks are removed and user files are preserved.
# ------------------------------------------------------------------------------
log_test "24: Antigravity Uninstall - selective removal"

echo "MY_FILE" > "$AGY_PLUGIN_DIR/skills/my_custom.md"

HOME="$FAKE_HOME_AGY" "$INSTALL_SCRIPT" antigravity uninstall > /dev/null 2>&1

assert_not_exists "$AGY_PLUGIN_DIR/plugin.json"
assert_not_exists "$AGY_PLUGIN_DIR/skills/local-lint-test/SKILL.md"
[[ -f "$AGY_PLUGIN_DIR/skills/my_custom.md" ]] || log_fail "User file was deleted during uninstall!"
log_pass

# ------------------------------------------------------------------------------
# TEST 25: Antigravity Status - fully installed
# Verifies status reports installed when all symlinks are in place.
# ------------------------------------------------------------------------------
log_test "25: Antigravity Status - fully installed"

HOME="$FAKE_HOME_AGY" "$INSTALL_SCRIPT" antigravity install > /dev/null 2>&1
HOME="$FAKE_HOME_AGY" "$INSTALL_SCRIPT" antigravity status > "$TEST_ROOT/agy_status.log" 2>&1

grep -qi "Fully installed" "$TEST_ROOT/agy_status.log" || log_fail "Should show fully installed"
log_pass

# ------------------------------------------------------------------------------
# TEST 26: Antigravity Status - not installed
# Verifies status reports not-installed when directory is absent.
# ------------------------------------------------------------------------------
log_test "26: Antigravity Status - not installed"

FAKE_HOME_AGY3="$TEST_ROOT/fakehome_agy3"
mkdir -p "$FAKE_HOME_AGY3"

HOME="$FAKE_HOME_AGY3" "$INSTALL_SCRIPT" antigravity status > "$TEST_ROOT/agy_status_not.log" 2>&1
grep -qi "Not installed" "$TEST_ROOT/agy_status_not.log" || log_fail "Should show not-installed"
log_pass

# ------------------------------------------------------------------------------
# TEST 27: Antigravity - no target path required
# Verifies antigravity harness does not error when no target path is given.
# ------------------------------------------------------------------------------
log_test "27: Antigravity Install - no target path required"

FAKE_HOME_AGY4="$TEST_ROOT/fakehome_agy4"
mkdir -p "$FAKE_HOME_AGY4"
HOME="$FAKE_HOME_AGY4" "$INSTALL_SCRIPT" antigravity install > /dev/null 2>&1
[[ -d "$FAKE_HOME_AGY4/.gemini/antigravity-cli/plugins/osado-ai-assistant" ]] || \
    log_fail "Plugin dir not created without target path"
log_pass

echo -e "\n${GREEN}All tests passed successfully!${NC}"
