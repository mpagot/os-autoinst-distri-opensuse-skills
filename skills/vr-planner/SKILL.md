---
name: vr-planner
description: Plans how to verify the changes committed on an os-autoinst-distri-opensuse (OSADO) branch. Use this skill when the user asks "how do I test my change", "what verification run (VR) should I do", "which openQA job should I clone", or "what's affected by my edit". Determines affected test modules, YAML schedules, and openqa-clone-job commands, plus the unit tests that also cover the committed files.
compatibility: Requires Perl (with JSON::PP), git, and jq. Phase 3 additionally requires openqa-cli (openQA-client package).
---

<instructions>
You help an OSADO developer figure out how to verify their changes to `os-autoinst-distri-opensuse`.
Use the Perl helpers in `scripts/` to do the work. Never duplicate their logic in shell or in your own reasoning.

Script paths below are relative to this skill's installed directory.

## Pipeline overview

```
classify_changes.pl                 (orchestrator — call first)
  ├── tests/    → find_test_schedule.pl
  ├── lib/      → find_unit_test.pl + find_affected_tests.pl
  ├── data/     → find_data_consumers.pl
  └── schedule/ → find_openqa_job.pl  (NETWORK — confirm host first)
```

All scripts accept `--repo /path/to/osado`, `--json`, `--verbose`, and `--help`.

## Process

### Phase 1 — Classify and produce the testing plan

1. **Identify the OSADO repo path.** If the user did not state it, ask them.
   Verify it exists and contains both `lib/` and `tests/`. Most of the time
   it should be the current folder.
2. **Precondition: only committed changes can be planned.** An openQA VR
   fetches the code from `CASEDIR=<fork>.git#<branch>`, so it only runs what
   is committed and pushed. `classify_changes.pl` always plans the commits on
   the current branch (`git diff BASE...HEAD`); staged, unstaged and
   untracked changes are ignored. BASE defaults to the closest local
   `master` ref (upstream remote, `origin/master` or `master`); pass
   `--base REF` only if the user asks for a different one. If the user has
   nothing committed yet, tell them to commit (and push) first.
3. **Run the orchestrator with context-efficient JSON output:**
   ```bash
   perl scripts/classify_changes.pl \
     --repo /path/to/osado --json
   ```
   This only classifies files; it does NOT run any helper and does NOT
   contact openQA. Read `base`, `warnings`, `categories.<name>.files` and
   `vr_needed` from the JSON output.
4. **Run only the helpers the change set needs**, each with `--json` and
   only the files of its category (skip empty categories):
   * `tests` → `find_test_schedule.pl`
   * `lib`   → `find_unit_test.pl` and `find_affected_tests.pl --base <base>`
     (the `base` from step 3; enables function-level analysis)
   * `data`  → `find_data_consumers.pl`
   * `t`     → no helper; the file itself is the `prove` target
   * `schedule` → no helper; the files are already Phase 3 input
5. **Summarise the plan to the user and proactively prompt for the host.**
   Start with the `warnings` (uncommitted changes, unpushed commits, branch
   not pushed): they mean the VR would not run what the user has locally.
   Then report per category:
   * file count and whether VR is needed,
   * the concrete next action (unit-test command, affected tests, data
     consumers, or schedule files to clone from).
   * **Proactive Prompt**: If Verification Runs (VRs) are required, immediately ask the user to confirm their target openQA host (`--osd` for SLE or `--o3` for Tumbleweed/Leap) so we can proceed to Phase 3 without an empty wait turn.

### Phase 2 — Targeted deep-dive (only when the user asks)

If the user wants more detail on one category, call the matching helper
directly with the specific files. Examples:

* "Which unit tests cover lib/foo.pm?" →
  `perl scripts/find_unit_test.pl --repo REPO --verbose lib/foo.pm`
* "What's affected by my lib change?" →
  `perl scripts/find_affected_tests.pl --repo REPO --verbose lib/foo.pm`
  Add `--base BASE` to also get function-level analysis of the committed
  changes (which subs changed, who calls them).
* "Where is tests/X/Y.pm scheduled?" →
  `perl scripts/find_test_schedule.pl --repo REPO --verbose tests/X/Y.pm`
* "Who consumes data/foo/bar.yaml?" →
  `perl scripts/find_data_consumers.pl --repo REPO --verbose data/foo/bar.yaml`

### Phase 3 — Find a clonable openQA job (network call gated)

Before querying openQA, always confirm the host with the user (usually `--osd` or `--o3`, prompted proactively in Phase 1).
Do not guess. The canonical options are:
* `--osd` → `http://openqa.suse.de` (SLE, SLE Micro, SLES4SAP)
* `--o3`  → `http://openqa.opensuse.org` (Tumbleweed, Leap)
* `--host URL` → custom worker (e.g. dedicated cloud workers)

Apply a **Hybrid Discovery Strategy** depending on how the test is scheduled:

#### Tier 1 — YAML Scheduled Tests (Fast Path)
If the test is mapped to a YAML schedule, pass those schedule paths to `find_openqa_job.pl`:
```bash
perl scripts/find_openqa_job.pl --osd --repo REPO schedule/A/B.yml
```
If starting from test files (`tests/*.pm`), resolve them to YAML schedules first:
```bash
perl scripts/find_test_schedule.pl --repo REPO --json tests/X/Y.pm \
| jq -r '.results[].matches[] | select(.type=="yaml_schedule") | .file' \
| xargs perl scripts/find_openqa_job.pl --osd --repo REPO
```

#### Tier 2 — Programmatically Loaded Tests (Slow Fallback)
If a test file is loaded programmatically (e.g., via `main_common.pm` or `load_testdir()`)
and has no YAML schedule, use the `--modules` fallback of the **same** helper. Do NOT
hand-craft a raw `openqa-cli` call.
Explain to the user that this lookup can take minutes for rarely-run modules, then run:
```bash
perl scripts/find_openqa_job.pl --osd --repo REPO --modules tests/publiccloud/download_repos.pm
```
The `--modules` value may be a `tests/*.pm` path or a bare openQA module name. The output
lists recent passing jobs and copy-paste-ready `openqa-clone-job` commands.

## Rules

* Do NOT modify any OSADO source code. This skill only analyses and reports.
* Do NOT plan uncommitted changes (do not pass file lists to
  `classify_changes.pl`, it refuses them). A VR can only run committed and
  pushed code.
* Do NOT run `openqa-cli` or `find_openqa_job.pl` without first confirming
  the openQA host with the user.
* Do NOT re-implement the helpers' logic in shell, grep, or file exploration
  tools (ReadFile, SearchText, FindFiles). Always call the Perl scripts.
* When a Phase 1 helper already resolved test modules to schedule
  files, pass those schedule paths directly to `find_openqa_job.pl`. Do NOT
  explore schedule directories with file tools to verify or supplement the
  output.
* When `find_affected_tests.pl` output includes a section labelled
  **"VR-CONFIRMED TARGETS function-level callers"**, use ONLY those test
  files for schedule and job lookups. The "Module-level candidates"
  (conservative blast radius) section may contain false positives:
  tests that import the changed library but do not call the modified functions.
  Never pass module-level candidates to `find_test_schedule.pl` or
  `find_openqa_job.pl` when function-level data is available.
* Resolve `--repo` to an absolute path before passing it. The scripts also
  accept relative paths but absolute paths make the output easier to read.
* **Database Safety Rule**: Only use the `find_openqa_job.pl --modules` fallback
  for tests identified as programmatic loaders (no YAML schedule). Never
  craft a `modules=` query by hand.
* **Cross-Skill Synergy**: If local unit tests are recommended, suggest using the `local-lint-test` skill to execute them efficiently.

## Known limitations to surface to the user when relevant

* **Schedule fan-out cap.** `find_openqa_job.pl` refuses to query when a
  change touches more than 25 schedule files (e.g. `lib/virt_autotest/common.pm`,
  `lib/hacluster.pm`). Report the cap and ask the user to pick 1–3
  schedules manually.
* **Dynamic/runtime loaders.** publiccloud and parts of kernel/LTP load tests
  via `lib/main_*.pm` with runtime conditions that `find_test_schedule.pl`
  cannot resolve statically. When `find_test_schedule.pl` reports a
  `loadtest` match inside a `lib/main_*.pm` file, fall back to
  `find_openqa_job.pl --modules <test>` to locate passing runs.
* **Private workers.** Hosts like `vh012.qa2.suse.asia` or
  `openqaworker15.qe.prg2.suse.org` are VPN-only and not auto-detected;
  the user must pass them with `--host`.
* **Function-level analysis** in `find_affected_tests.pl` requires
  `--base BASE`. Without it, only module-level blast radius is shown.
  VR-CONFIRMED TARGETS may still include a test calling a same-named
  method of another class. Callers marked `[entry point, not followed]`
  were not traced further; if no VR-CONFIRMED TARGETS remain, use
  `recommended_tests` (it falls back to the module-level list).
* Changes scoped to `t/`, `.github/`, `Makefile`, `variables.md`, or pure
  comment/lint fixes typically do NOT require a VR.

## Output expectations

Keep the user-facing summary short:

1. One line per category (count + VR needed).
2. The exact `prove` command for each touched `t/` file or `lib/` module
   that has a unit test (recommend using `local-lint-test` to run them).
3. The schedule file(s) the user should clone from. Every clone command
   must set `BUILD='<user>_VR' TEST='<user>_VR' _GROUP=0` next to
   `CASEDIR`; add them if a command lacks them. If the test is programmatic, explain that we will use `find_openqa_job.pl --modules` to find baseline jobs.
4. A proactive request for the openQA host to proceed with job discovery.
</instructions>
