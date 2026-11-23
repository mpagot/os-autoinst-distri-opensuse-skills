# openQA Tests for openSUSE - Agent Guidelines

This repository contains the openQA test distribution for openSUSE (`os-autoinst-distri-opensuse`). It is primarily written in Perl.

## 1. Build, Lint, and Test

### Setup
Before running tests, ensure dependencies are installed:
```bash
make prepare
```
This clones `os-autoinst` and installs CPAN dependencies.

**Important Environment Variable:**
To run perl scripts or check compilation manually, set `PERL5LIB`:
```bash
export PERL5LIB=".:lib:os-autoinst:os-autoinst/lib:$PERL5LIB"
```

### Running Tests
*   **Run all unit tests:**
    ```bash
    make unit-test
    ```
*   **Run a single unit test file:**
    ```bash
    prove -l -Ios-autoinst/ t/03_utils_systemd.t
    ```
*   **Check compilation of all `.pm` files:**
    ```bash
    make test-compile
    ```
*   **Check compilation of modified files (faster):**
    ```bash
    make test-compile-changed
    ```
    Alternatively, use the helper script: `.gemini/skills/local-lint-test/scripts/test_compile.sh <file>`
*   **Run static analysis (YAML, metadata, etc.):**
    ```bash
    make test-static
    ```

### Linting and Formatting
*   **Format code (PerlTidy):**
    ```bash
    make tidy       # Formats changed files
    make tidy-full  # Formats all files
    ```
    *Always run `make tidy` before committing.*
*   **Lint code (PerlCritic):**
    ```bash
    make perlcritic
    ```
*   **Check code style:**
    ```bash
    make test-code-style
    ```

## 2. Code Style & Conventions

### General Perl
*   **Strictness:** Always use `use strict;` and `use warnings;`.
*   **Formatting:** Follow the `.perltidyrc` configuration (line length 160, no spaces before semicolons, etc.).
*   **Naming:** Use `snake_case` for subroutines and variables.
*   **Imports:** Explicitly import functions.
    ```perl
    use utils qw(fully_patch_system zypper_call);
    ```

### openQA Specifics
*   **Sleep:** **NEVER** use `sleep()`. Use synchronization primitives like `wait_serial`, `wait_screen_change`, or `assert_screen`.
*   **Tumbleweed First:** Assume openSUSE Tumbleweed is the default target. Use conditions for older products, not the other way around. Avoid `is_tumbleweed()`.
*   **Soft Failures:** usage of `record_soft_failure` **MUST** include a bug reference (e.g., `bsc#12345`, `poo#6789`).
*   **Screen Assertions:** Prefer multi-tag `assert_screen` with `match_has_tag` over `check_screen`.
    ```perl
    assert_screen([qw(yast2_console-finished yast2_missing_package)]);
    if (match_has_tag('yast2_missing_package')) { ... }
    ```
*   **Exec:** Use `grep -E` and `grep -F` instead of deprecated `egrep` and `fgrep`.

### Project Structure
*   `lib/`: Helper modules (e.g., `utils.pm`).
*   `tests/`: Integration/functional test modules.
*   `t/`: Unit tests for libraries.
*   `schedule/`: YAML schedule definitions.
*   `products/`: Product definitions.

### New Files
*   Use `SPDX-License-Identifier` for licensing.
*   Do not add copyright years to file headers.
*   Use `my ($self) = @_;` for method parameter parsing.

### Commit Messages
*   Subject MUST start with a `<scope>:` prefix naming the affected area (kernel style), e.g. `lib/utils: Fix deep issue in a library`.
*   Subject line <= 72 chars including the scope, NO trailing dot.
*   Empty line between subject and body.
*   Explain "why" the change is needed, then "what" it does.
*   **Do NOT use conventional commit types** (e.g., `feat(scope):` or `(feat)`); the scope names the affected area, not a commit type.
*   Add one `Assisted-by: <model>` trailer per LLM model involved; never add `Signed-off-by:` or `Co-authored-by:`.

## 3. Workflow for Agents
1.  **Understand:** Read related code in `lib/` or `tests/`. Search for existing patterns using `grep`.
2.  **Edit:** Apply changes.
3.  **Format:** Run `make tidy`.
4.  **Verify:**
    *   Run `make test-compile-changed` to catch syntax errors immediately.
    *   If editing a library with unit tests, run the specific test with `prove`.
    *   If no unit tests exist, consider adding one in `t/`.

## 4. Commit and Pull Request Workflow

### Commit
Use the `git-commit` skill (or `/git_commit` in Gemini CLI) to inspect the
staged changes and write the commit message:
*   Message must NOT follow conventional commit format.
*   Subject: `<scope>: <description>`, no trailing dot, <= 72 chars.
*   Body: Explain "why" and then "what".
*   Add one `Assisted-by: <model>` trailer per LLM model involved; no
    `Signed-off-by:` or `Co-authored-by:` trailers.
*   Keep commits atomic; do not bundle unrelated changes.
*   Get user approval for the message.

### Create the pull request
Use the `github-pr-create` skill (or `/github_pr_create` in Gemini CLI), which:
1.  Requires a non-default branch with at least one commit beyond `master`.
2.  Pushes with `git push --set-upstream origin <branch>`.
3.  Reads every commit on the branch and `.github/PULL_REQUEST_TEMPLATE.md`,
    summarizes the commits into the PR title and body, asks for a ticket
    reference, and creates the PR against the upstream repository. Verification
    run results are added later to the description or a dedicated comment;
    planning and running VRs is the `vr-planner` skill's job.
