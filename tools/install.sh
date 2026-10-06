#!/bin/bash

# ==============================================================================
# OSADO AI Assistant Installation & Management Script
# ==============================================================================
#
# Installs, updates, and manages OSADO AI skills for multiple AI coding tools.
#
# USAGE:
#   install.sh <harness> <action> [target_path]
#
# HARNESSES:
#   opencode      Install skills globally for OpenCode (~/.config/opencode/skills/)
#   gemini        Symlink into <target>/.gemini/ for Gemini CLI
#   claude        Symlink into <target>/.claude/skills/ for Claude Code
#   agents        Symlink into <target>/.agents/skills/ (cross-tool standard)
#   antigravity   Symlink into ~/.gemini/antigravity-cli/plugins/osado-ai-assistant/
#   all           Run all harnesses (global + symlink-based at target path)
#
# ACTIONS:
#   install    Install skills for the specified harness
#   update     Pull latest changes and refresh installation
#   uninstall  Remove installed skills
#   status     Show installation status and check for updates
#
# EXAMPLES:
#   install.sh opencode install
#   install.sh opencode update
#   install.sh opencode status
#   install.sh antigravity install
#   install.sh gemini install /path/to/os-autoinst-distri-opensuse
#   install.sh all install /path/to/os-autoinst-distri-opensuse
#
# NOTES:
#   - 'opencode' and 'antigravity' do not require a target path (global installs).
#   - All other harnesses require a target path pointing to an OSADO git repo.
#   - Symlink-based harnesses never overwrite existing regular files.
#   - The 'opencode' harness uses git clone; all others use symlinks.
#
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_URL="https://github.com/os-autoinst/osado-skills.git"
OPENCODE_INSTALL_DIR="${HOME}/.config/opencode/skills/osado-skills"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging ---
log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_success() { echo -e "${GREEN}OK:${NC} $1"; }
log_warn() { echo -e "${YELLOW}WARNING:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1"; }

# ==============================================================================
# Usage & Argument Parsing
# ==============================================================================

usage() {
    echo -e "${BOLD}OSADO AI Assistant - Skill Manager${NC}"
    echo ""
    echo "Usage: $0 <harness> <action> [target_path]"
    echo ""
    echo "Harnesses:"
    echo "  opencode      OpenCode (global install, no target path needed)"
    echo "  gemini        Gemini CLI (symlinks into <target>/.gemini/)"
    echo "  claude        Claude Code (symlinks into <target>/.claude/skills/)"
    echo "  agents        Cross-tool (symlinks into <target>/.agents/skills/)"
    echo "  antigravity   Antigravity CLI (native agy plugin, no target path needed)"
    echo "  all           All harnesses at once"
    echo ""
    echo "Actions:"
    echo "  install     Install skills"
    echo "  update      Pull latest and refresh"
    echo "  uninstall   Remove installed skills"
    echo "  status      Check installation and available updates"
    echo ""
    echo "Examples:"
    echo "  $0 opencode install"
    echo "  $0 opencode update"
    echo "  $0 opencode status"
    echo "  $0 gemini install ~/repos/os-autoinst-distri-opensuse"
    echo "  $0 all install ~/repos/os-autoinst-distri-opensuse"
    exit 1
}

HARNESS=""
ACTION=""
TARGET_PATH=""

if [[ "$#" -lt 2 ]]; then
    usage
fi

HARNESS="$1"
ACTION="$2"
TARGET_PATH="${3:-}"

# Validate harness
case "$HARNESS" in
    opencode|gemini|claude|agents|antigravity|all) ;;
    --help|-h|help) usage ;;
    *) log_error "Unknown harness: '$HARNESS'"; usage ;;
esac

# Validate action
case "$ACTION" in
    install|update|uninstall|status) ;;
    *) log_error "Unknown action: '$ACTION'"; usage ;;
esac

# Validate target path requirement
if [[ "$HARNESS" != "opencode" && "$HARNESS" != "antigravity" && -z "$TARGET_PATH" ]]; then
    if [[ "$HARNESS" == "all" ]]; then
        log_error "The 'all' harness requires a target path for gemini/claude/agents."
        log_error "Usage: $0 all <action> /path/to/osado-repo"
    else
        log_error "The '$HARNESS' harness requires a target path."
        log_error "Usage: $0 $HARNESS $ACTION /path/to/osado-repo"
    fi
    exit 1
fi

# Resolve and validate target path
TARGET_ABS_PATH=""
if [[ -n "$TARGET_PATH" ]]; then
    if [[ ! -d "$TARGET_PATH/.git" ]]; then
        log_error "The path '$TARGET_PATH' does not appear to be a git repository."
        exit 1
    fi
    TARGET_ABS_PATH="$(cd "$TARGET_PATH" && pwd)"
fi

# ==============================================================================
# OpenCode Harness (git clone-based, global install)
# ==============================================================================

opencode_install() {
    if [[ -d "$OPENCODE_INSTALL_DIR/.git" ]]; then
        local remote
        remote=$(git -C "$OPENCODE_INSTALL_DIR" remote get-url origin 2>/dev/null || echo "")
        if [[ "$remote" == "$REPO_URL" ]]; then
            log_info "Already installed at $OPENCODE_INSTALL_DIR"
            log_info "Run '$0 opencode update' to get the latest version."
            return 0
        else
            log_error "Directory $OPENCODE_INSTALL_DIR exists but points to a different repo."
            log_error "Remote: $remote"
            log_error "The OSADO skills repository moved to $REPO_URL"
            log_error "Run '$0 opencode uninstall', then '$0 opencode install' again."
            exit 1
        fi
    fi

    if [[ -d "$OPENCODE_INSTALL_DIR" ]]; then
        log_error "Directory $OPENCODE_INSTALL_DIR exists but is not a git repo."
        log_error "Remove it manually if you want to install."
        exit 1
    fi

    log_info "Installing OSADO skills for OpenCode..."
    mkdir -p "$(dirname "$OPENCODE_INSTALL_DIR")"
    git clone --depth 1 "$REPO_URL" "$OPENCODE_INSTALL_DIR"

    log_success "Skills installed to $OPENCODE_INSTALL_DIR"
    echo ""
    log_info "OpenCode will discover the skills on your next session."
    log_info "Run '$0 opencode status' to check for updates."
}

opencode_update() {
    if [[ ! -d "$OPENCODE_INSTALL_DIR/.git" ]]; then
        log_error "OSADO skills not installed. Run '$0 opencode install' first."
        exit 1
    fi

    log_info "Checking for updates..."
    git -C "$OPENCODE_INSTALL_DIR" fetch --quiet

    local behind
    behind=$(git -C "$OPENCODE_INSTALL_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")

    if [[ "$behind" -eq 0 ]]; then
        log_success "Already up to date."
        return 0
    fi

    echo ""
    log_info "New changes available ($behind commit(s)):"
    echo ""
    git -C "$OPENCODE_INSTALL_DIR" log --oneline HEAD..origin/main
    echo ""

    log_info "Pulling updates..."
    git -C "$OPENCODE_INSTALL_DIR" pull --ff-only --quiet

    log_success "Updated to latest. Restart OpenCode to pick up changes."
}

opencode_status() {
    if [[ ! -d "$OPENCODE_INSTALL_DIR/.git" ]]; then
        echo -e "${YELLOW}Not installed.${NC} Run '$0 opencode install' to set up."
        return 0
    fi

    local current_commit
    current_commit=$(git -C "$OPENCODE_INSTALL_DIR" log --oneline -1)
    echo -e "${BOLD}Installed:${NC} $OPENCODE_INSTALL_DIR"
    echo -e "${BOLD}Current:${NC}   $current_commit"

    log_info "Checking remote for updates..."
    git -C "$OPENCODE_INSTALL_DIR" fetch --quiet 2>/dev/null || {
        log_warn "Could not reach remote. Showing local status only."
        return 0
    }

    local behind
    behind=$(git -C "$OPENCODE_INSTALL_DIR" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")

    if [[ "$behind" -eq 0 ]]; then
        log_success "Up to date."
    else
        echo -e "${YELLOW}$behind update(s) available.${NC} Run '$0 opencode update' to apply."
    fi
}

opencode_uninstall() {
    if [[ ! -d "$OPENCODE_INSTALL_DIR" ]]; then
        log_info "Nothing to uninstall (directory does not exist)."
        return 0
    fi

    echo -e "${YELLOW}This will remove:${NC} $OPENCODE_INSTALL_DIR"
    echo -n "Continue? [y/N] "
    read -r confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "Cancelled."
        return 0
    fi

    rm -rf "$OPENCODE_INSTALL_DIR"
    log_success "OSADO skills removed from OpenCode."
}

# ==============================================================================
# Antigravity Harness (symlink-based, global install)
# Stages files into ~/.gemini/antigravity-cli/plugins/<name>/ — the directory
# Antigravity CLI auto-discovers on startup (no agy CLI required).
# ==============================================================================

ANTIGRAVITY_INSTALL_DIR="${HOME}/.gemini/antigravity-cli/plugins/osado-ai-assistant"

antigravity_install() {
    log_info "Installing OSADO skills for Antigravity CLI..."
    mkdir -p "$ANTIGRAVITY_INSTALL_DIR"

    # Link plugin.json at the plugin root (required manifest)
    local plugin_src="$REPO_ROOT/plugin.json"
    local plugin_dst="$ANTIGRAVITY_INSTALL_DIR/plugin.json"
    if [[ -e "$plugin_dst" ]] || [[ -L "$plugin_dst" ]]; then
        if [[ -L "$plugin_dst" && "$(readlink "$plugin_dst")" == "$plugin_src" ]]; then
            : # already correct
        elif [[ -L "$plugin_dst" ]]; then
            log_warn "Conflict: '$plugin_dst' symlinked elsewhere. Skipping."
        else
            log_warn "Conflict: '$plugin_dst' is a regular file. Skipping."
        fi
    else
        ln -s "$plugin_src" "$plugin_dst"
        echo "  Linked: plugin.json"
    fi

    # Recursively link skills/
    link_files "$REPO_ROOT" "skills" "$ANTIGRAVITY_INSTALL_DIR"

    log_success "Installation complete for antigravity."
}

antigravity_update() {
    log_info "Updating toolset repository..."
    git -C "$REPO_ROOT" pull --quiet

    log_info "Refreshing symlinks for antigravity..."
    antigravity_install
}

antigravity_uninstall() {
    log_info "Uninstalling antigravity from $ANTIGRAVITY_INSTALL_DIR..."

    # Unlink plugin.json if it points to this repo
    local plugin_dst="$ANTIGRAVITY_INSTALL_DIR/plugin.json"
    if [[ -L "$plugin_dst" && "$(readlink "$plugin_dst")" == "$REPO_ROOT/plugin.json" ]]; then
        unlink "$plugin_dst"
        echo "  Unlinked: plugin.json"
    fi

    # Unlink skills/
    unlink_files "$REPO_ROOT" "skills" "$ANTIGRAVITY_INSTALL_DIR"

    log_success "Uninstallation complete for antigravity."
}

antigravity_status() {
    echo -e "${BOLD}Harness:${NC}  antigravity"
    echo -e "${BOLD}Target:${NC}   $ANTIGRAVITY_INSTALL_DIR"

    if [[ ! -d "$ANTIGRAVITY_INSTALL_DIR" ]]; then
        echo -e "${YELLOW}Not installed.${NC} Run '$0 antigravity install' to set up."
        return 0
    fi

    local linked=0
    local missing=0

    # Check plugin.json
    local plugin_dst="$ANTIGRAVITY_INSTALL_DIR/plugin.json"
    if [[ -L "$plugin_dst" && "$(readlink "$plugin_dst")" == "$REPO_ROOT/plugin.json" ]]; then
        linked=$(( linked + 1 ))
    else
        missing=$(( missing + 1 ))
    fi

    # Check skills/
    while IFS= read -r -d '' file; do
        local rel="${file#"$REPO_ROOT"/}"
        local target_file="$ANTIGRAVITY_INSTALL_DIR/$rel"
        if [[ -L "$target_file" ]]; then
            local link_dest
            link_dest=$(readlink "$target_file")
            if [[ "$link_dest" == "$file" ]]; then
                linked=$(( linked + 1 ))
            fi
        else
            missing=$(( missing + 1 ))
        fi
    done < <(find "$REPO_ROOT/skills" -type f -print0)

    if [[ "$linked" -eq 0 && "$missing" -gt 0 ]]; then
        echo -e "${YELLOW}Not installed.${NC} Run '$0 antigravity install'"
    elif [[ "$missing" -gt 0 ]]; then
        echo -e "${YELLOW}Partially installed:${NC} $linked linked, $missing missing"
        log_info "Run '$0 antigravity install' to complete."
    else
        log_success "Fully installed ($linked files linked)."
    fi

    log_info "Checking repo for updates..."
    git -C "$REPO_ROOT" fetch --quiet 2>/dev/null || {
        log_warn "Could not reach remote."
        return 0
    }
    local behind
    behind=$(git -C "$REPO_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
    if [[ "$behind" -eq 0 ]]; then
        log_success "Source repo is up to date."
    else
        echo -e "${YELLOW}$behind update(s) available in source repo.${NC}"
        log_info "Run '$0 antigravity update' to apply."
    fi
}

# ==============================================================================
# Symlink Harness (shared by gemini, claude, agents)
# ==============================================================================

# Determine target directory and source directories based on harness
get_harness_config() {
    local harness="$1"
    local target_base="$2"

    case "$harness" in
        gemini)
            LINK_TARGET_DIR="$target_base/.gemini"
            LINK_SOURCES=("skills" "commands")
            LINK_CONTEXT_SRC="$REPO_ROOT/OSADO_AGENTS.md"
            LINK_CONTEXT_DST="$target_base/GEMINI.md"
            ;;
        claude)
            LINK_TARGET_DIR="$target_base/.claude"
            LINK_SOURCES=("skills")
            LINK_CONTEXT_SRC=""
            LINK_CONTEXT_DST=""
            ;;
        agents)
            LINK_TARGET_DIR="$target_base/.agents"
            LINK_SOURCES=("skills")
            LINK_CONTEXT_SRC="$REPO_ROOT/OSADO_AGENTS.md"
            LINK_CONTEXT_DST="$target_base/AGENTS.md"
            ;;
    esac
}

# Recursively symlink files from source to target
link_files() {
    local src_dir="$1"
    local rel_path="$2"
    local target_base_dir="$3"

    local source_full="$src_dir/$rel_path"
    local target_full="$target_base_dir/$rel_path"

    mkdir -p "$target_full"

    for item in "$source_full"/*; do
        [[ -e "$item" ]] || continue
        local name
        name=$(basename "$item")
        local target_item="$target_full/$name"

        if [[ -d "$item" ]]; then
            link_files "$src_dir" "$rel_path/$name" "$target_base_dir"
        else
            if [[ -e "$target_item" ]] || [[ -L "$target_item" ]]; then
                if [[ -L "$target_item" ]]; then
                    local existing_link
                    existing_link=$(readlink "$target_item")
                    if [[ "$existing_link" == "$item" ]]; then
                        continue
                    else
                        log_warn "Conflict: '$target_item' symlinked elsewhere. Skipping."
                    fi
                else
                    log_warn "Conflict: '$target_item' is a regular file. Skipping."
                fi
            else
                ln -s "$item" "$target_item"
                echo "  Linked: $rel_path/$name"
            fi
        fi
    done
}

# Recursively remove symlinks pointing to this repo
unlink_files() {
    local src_dir="$1"
    local rel_path="$2"
    local target_base_dir="$3"

    local source_full="$src_dir/$rel_path"
    local target_full="$target_base_dir/$rel_path"

    [[ -d "$source_full" ]] || return 0

    for item in "$source_full"/*; do
        [[ -e "$item" ]] || continue
        local name
        name=$(basename "$item")
        local target_item="$target_full/$name"

        if [[ -d "$item" ]]; then
            unlink_files "$src_dir" "$rel_path/$name" "$target_base_dir"
        else
            if [[ -L "$target_item" ]]; then
                local existing_link
                existing_link=$(readlink "$target_item")
                if [[ "$existing_link" == "$item" ]]; then
                    unlink "$target_item"
                    echo "  Unlinked: $rel_path/$name"
                fi
            fi
        fi
    done
}

symlink_install() {
    local harness="$1"
    local target_base="$2"

    get_harness_config "$harness" "$target_base"

    log_info "Installing for $harness at $target_base..."

    for src in "${LINK_SOURCES[@]}"; do
        if [[ -d "$REPO_ROOT/$src" ]]; then
            link_files "$REPO_ROOT" "$src" "$LINK_TARGET_DIR"
        fi
    done

    # Link context file if configured
    if [[ -n "$LINK_CONTEXT_SRC" && -f "$LINK_CONTEXT_SRC" ]]; then
        if [[ ! -e "$LINK_CONTEXT_DST" ]]; then
            ln -s "$LINK_CONTEXT_SRC" "$LINK_CONTEXT_DST"
            log_success "Linked context: $(basename "$LINK_CONTEXT_DST")"
        else
            log_info "$(basename "$LINK_CONTEXT_DST") already exists. Skipping."
        fi
    fi

    log_success "Installation complete for $harness."
}

symlink_update() {
    local harness="$1"
    local target_base="$2"

    log_info "Updating toolset repository..."
    git -C "$REPO_ROOT" pull --quiet

    log_info "Refreshing symlinks for $harness..."
    symlink_install "$harness" "$target_base"
}

symlink_uninstall() {
    local harness="$1"
    local target_base="$2"

    get_harness_config "$harness" "$target_base"

    log_info "Uninstalling $harness from $target_base..."

    for src in "${LINK_SOURCES[@]}"; do
        if [[ -d "$REPO_ROOT/$src" ]]; then
            unlink_files "$REPO_ROOT" "$src" "$LINK_TARGET_DIR"
        fi
    done

    # Unlink context file
    if [[ -n "$LINK_CONTEXT_DST" && -L "$LINK_CONTEXT_DST" ]]; then
        local link_target
        link_target=$(readlink "$LINK_CONTEXT_DST")
        if [[ "$link_target" == "$LINK_CONTEXT_SRC" ]]; then
            unlink "$LINK_CONTEXT_DST"
            log_success "Unlinked context: $(basename "$LINK_CONTEXT_DST")"
        fi
    fi

    log_success "Uninstallation complete for $harness."
}

symlink_status() {
    local harness="$1"
    local target_base="$2"

    get_harness_config "$harness" "$target_base"

    echo -e "${BOLD}Harness:${NC}  $harness"
    echo -e "${BOLD}Target:${NC}   $LINK_TARGET_DIR"

    local linked=0
    local missing=0

    for src in "${LINK_SOURCES[@]}"; do
        [[ -d "$REPO_ROOT/$src" ]] || continue
        while IFS= read -r -d '' file; do
            local rel="${file#"$REPO_ROOT"/}"
            local target_file="$LINK_TARGET_DIR/$rel"
            if [[ -L "$target_file" ]]; then
                local link_dest
                link_dest=$(readlink "$target_file")
                if [[ "$link_dest" == "$file" ]]; then
                    ((linked++))
                fi
            else
                ((missing++))
            fi
        done < <(find "$REPO_ROOT/$src" -type f -print0)
    done

    if [[ "$linked" -eq 0 && "$missing" -gt 0 ]]; then
        echo -e "${YELLOW}Not installed.${NC} Run '$0 $harness install $target_base'"
    elif [[ "$missing" -gt 0 ]]; then
        echo -e "${YELLOW}Partially installed:${NC} $linked linked, $missing missing"
        log_info "Run '$0 $harness install $target_base' to complete."
    else
        log_success "Fully installed ($linked files linked)."
    fi

    # Check if this repo is up to date
    log_info "Checking repo for updates..."
    git -C "$REPO_ROOT" fetch --quiet 2>/dev/null || {
        log_warn "Could not reach remote."
        return 0
    }
    local behind
    behind=$(git -C "$REPO_ROOT" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
    if [[ "$behind" -eq 0 ]]; then
        log_success "Source repo is up to date."
    else
        echo -e "${YELLOW}$behind update(s) available in source repo.${NC}"
        log_info "Run '$0 $harness update $target_base' to apply."
    fi
}

# ==============================================================================
# Dispatch
# ==============================================================================

case "$HARNESS" in
    opencode)
        case "$ACTION" in
            install)   opencode_install ;;
            update)    opencode_update ;;
            uninstall) opencode_uninstall ;;
            status)    opencode_status ;;
        esac
        ;;
    antigravity)
        case "$ACTION" in
            install)   antigravity_install ;;
            update)    antigravity_update ;;
            uninstall) antigravity_uninstall ;;
            status)    antigravity_status ;;
        esac
        ;;
    gemini|claude|agents)
        case "$ACTION" in
            install)   symlink_install "$HARNESS" "$TARGET_ABS_PATH" ;;
            update)    symlink_update "$HARNESS" "$TARGET_ABS_PATH" ;;
            uninstall) symlink_uninstall "$HARNESS" "$TARGET_ABS_PATH" ;;
            status)    symlink_status "$HARNESS" "$TARGET_ABS_PATH" ;;
        esac
        ;;
    all)
        log_info "Running all harnesses..."
        echo ""

        # OpenCode (global, no path needed)
        echo -e "${BOLD}--- opencode ---${NC}"
        case "$ACTION" in
            install)   opencode_install ;;
            update)    opencode_update ;;
            uninstall) opencode_uninstall ;;
            status)    opencode_status ;;
        esac
        echo ""

        # Antigravity (global, no path needed)
        echo -e "${BOLD}--- antigravity ---${NC}"
        case "$ACTION" in
            install)   antigravity_install ;;
            update)    antigravity_update ;;
            uninstall) antigravity_uninstall ;;
            status)    antigravity_status ;;
        esac
        echo ""

        # Symlink-based harnesses (need path)
        for h in gemini claude agents; do
            echo -e "${BOLD}--- $h ---${NC}"
            case "$ACTION" in
                install)   symlink_install "$h" "$TARGET_ABS_PATH" ;;
                update)    symlink_update "$h" "$TARGET_ABS_PATH" ;;
                uninstall) symlink_uninstall "$h" "$TARGET_ABS_PATH" ;;
                status)    symlink_status "$h" "$TARGET_ABS_PATH" ;;
            esac
            echo ""
        done
        ;;
esac
