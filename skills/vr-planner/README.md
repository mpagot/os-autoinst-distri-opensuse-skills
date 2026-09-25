# vr-planner — Verification Run Planning Pipeline

A set of Perl scripts that analyze changes to an `os-autoinst-distri-opensuse`
(OSADO) checkout and produce a concrete testing plan: which unit tests to run,
which openQA jobs to clone, and what commands to copy-paste.

## Pipeline Data Flow

```
                         ┌─────────────────────────┐
                         │   classify_changes.pl    │  ← git diff / file list
                         │    (orchestrator)        │
                         └────┬───┬───┬───┬────────┘
                              │   │   │   │
              ┌───────────────┘   │   │   └──────────────────┐
              ▼                   ▼   ▼                      ▼
     ┌────────────────┐  ┌────────────────┐  ┌──────────────────────┐
     │find_test_      │  │find_unit_      │  │find_data_            │
     │schedule.pl     │  │test.pl         │  │consumers.pl          │
     │                │  │                │  │                      │
     │ tests/*.pm →   │  │ lib/*.pm →     │  │ data/* →             │
     │ schedule/*.yml │  │ t/*.t files    │  │ tests/*.pm, lib/*.pm │
     └───────┬────────┘  └────────────────┘  └──────────┬───────────┘
             │                                          │
             │   ┌──────────────────────┐               │
             │   │find_affected_        │               │
             │   │tests.pl              │               │
             │   │                      │               │
             │   │ lib/*.pm →           │               │
             │   │ tests/*.pm (callers) │               │
             │   └──────────┬───────────┘               │
             │              │                           │
             │   ┌──────────▼───────────┐               │
             │   │find_test_schedule.pl │◄──────────────┘
             │   │  (second pass)       │
             │   └──────────┬───────────┘
             │              │
             ▼              ▼
     ┌──────────────────────────────┐
     │      find_openqa_job.pl      │  ← NETWORK (requires --osd/--o3/--host)
     │                              │
     │  schedule/*.yml →            │
     │  openqa-clone-job commands   │
     └──────────────────────────────┘
```

## Script Input/Output Summary

| Script | Input | Output | Network |
|--------|-------|--------|---------|
| `classify_changes.pl` | git diff or file paths | Categorized file list + guidance per category | No |
| `find_test_schedule.pl` | `tests/*.pm` paths | YAML schedule file paths + loader references | No |
| `find_unit_test.pl` | `lib/*.pm` paths | Matching `t/*.t` files + `prove` commands | No |
| `find_affected_tests.pl` | `lib/*.pm` paths (+ optional commit) | Dependent `tests/*.pm` files (module-level and function-level) | No |
| `find_data_consumers.pl` | `data/*` paths | `tests/*.pm` and `lib/*.pm` that reference the data | No |
| `find_openqa_job.pl` | `schedule/*.yml` paths | `openqa-clone-job` commands + `isos POST` commands | **Yes** |

## Workflow Scenarios

### A. Changed a `lib/*.pm` file (richest pipeline)

This is the most complex case — a library change potentially affects many tests.

```
1.  classify_changes.pl --helpers            (commits in BASE...HEAD)
        │
        ├── find_unit_test.pl
        │       Input:  lib/sles4sap/ipaddr2.pm
        │       Output: t/22_ipaddr2.t  →  prove command to run locally
        │
        ├── find_affected_tests.pl --base BASE
        │       Input:  lib/sles4sap/ipaddr2.pm
        │       Output (two tiers):
        │         • VR-CONFIRMED TARGETS (function-level callers)
        │           Only tests that call the specific changed functions.
        │         • Conservative blast radius (module-level)
        │           All tests that import the module (may include false positives).
        │
        │       JSON key for downstream: "recommended_tests"
        │         → contains function-confirmed tests when available,
        │           falls back to full module-level list otherwise.
        │
        └── find_test_schedule.pl  (auto-chained for recommended_tests)
                Input:  tests/sles4sap/ipaddr2/deploy.pm
                Output: schedule/sles4sap/cloud-components/ipaddr2.yml
                        → ready for find_openqa_job.pl
```

**Key JSON contract:** `find_affected_tests.pl --json` emits a
`recommended_tests` array. The orchestrator reads this to feed
`find_test_schedule.pl` automatically, closing the pipeline without
manual intervention.

### B. Changed a `tests/*.pm` file

```
1.  classify_changes.pl --helpers
        │
        └── find_test_schedule.pl
                Input:  tests/ha/barrier_init.pm
                Output: schedule/ha/bv/basic_cluster_node.yaml
                        (or: lib/main_ha.pm:42 — programmatic loader)
```

For YAML schedule results, pass directly to `find_openqa_job.pl`.
For programmatic loaders, the user must browse the openQA web UI.

### C. Changed a `data/*` file

```
1.  classify_changes.pl --helpers
        │
        └── find_data_consumers.pl
                Input:  data/sles4sap/qe_sap_deployment/qesap_aws.yaml
                Output: tests/sles4sap/qesap_terraform.pm:45
                        (matched via layered search)
```

The output test files then follow the same path as scenario B:
feed into `find_test_schedule.pl` → `find_openqa_job.pl`.

### D. Changed a `schedule/*.yml` file

No intermediate resolution needed — pass directly to `find_openqa_job.pl`.
The orchestrator prints the ready-to-run command (it does not execute it
because a host must be confirmed first).

## JSON Piping Between Scripts

All scripts support `--json` for machine-readable output. The key fields
that enable piping:

| Producer | JSON path | Consumer |
|----------|-----------|----------|
| `find_affected_tests.pl` | `.recommended_tests[]` | `find_test_schedule.pl` |
| `find_test_schedule.pl` | `.results[].matches[] \| select(.type=="yaml_schedule") \| .file` | `find_openqa_job.pl` |
| `find_openqa_job.pl` | `.recommendations[].clone_command` | User (copy-paste) |

Example full pipe (lib/ change → clone command):

```bash
perl find_affected_tests.pl --repo REPO --json --base BASE lib/foo.pm \
  | jq -r '.recommended_tests[]' \
  | xargs perl find_test_schedule.pl --repo REPO --json \
  | jq -r '.results[].matches[] | select(.type=="yaml_schedule") | .file' \
  | sort -u \
  | xargs perl find_openqa_job.pl --osd --repo REPO
```

## Design Decisions

### Why `find_openqa_job.pl` only accepts schedule paths

Test files can map to multiple schedules or to programmatic loaders that
cannot be resolved statically. Requiring pre-resolved schedule paths keeps
the network-calling script simple and avoids ambiguity about which job to
clone.

### Two-tier output in `find_affected_tests.pl`

Without `--base`, only module-level dependency walking is possible
(any test that imports the changed module). With `--base`, the script
parses the diff hunks of the committed changes (BASE...HEAD), maps changed
lines to function boundaries, then traces
callers of those functions through the codebase. The function-level tier
eliminates false positives from tests that import the module but never call
the modified code paths.

Callers are matched per package: a call qualified with another package
(`upload_system_log::upload_supportconfig_log`) is ignored, and a bare call
only counts in files that import the changed package; `->method` calls
always count. The upward walk stops at entry-point subs (`run`,
`post_fail_hook`, `new`, `load_*`, ...): following them would reach nearly
every test in the repository.

### Layered search in `find_data_consumers.pl`

~43% of `data_url()` calls in OSADO use variables in the path, so a single
grep for the full filename misses nearly half of references. The script
tries progressively broader search terms (full path → directory prefix →
bare filename → parent directory) and stops at the first layer that
produces results.

### Stage-3 filtering in `find_openqa_job.pl`

Before querying the openQA API for passing jobs, the script filters out:
- **VR-clone TEST names** (contain `@`) — one-off developer clones that
  will never have a passing production counterpart.
- **`:investigate:` variants** — auto-retry jobs that are never scheduled
  directly.
- **Duplicate TEST+group_id pairs** across multiple schedule inputs — avoids
  redundant API calls that each cost 2–75 seconds.

## Common Flags

All scripts share these flags (see individual `--help` for details):

- `--repo DIR` — OSADO repository root (default: `.`)
- `--json` — Structured JSON output (via `JSON::PP`)
- `--verbose` — Diagnostic info to stderr
- `--help` — Full usage documentation
