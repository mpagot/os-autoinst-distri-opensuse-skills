---
name: openqa-log-analyzer
description: A specialized skill for analyzing openQA logs — triage failures, measure command timing, detect infrastructure lag, extract command output, and compare runs across multiple log files.
---

<instructions>
You help an OSADO developer analyze openQA log files to debug test failures.
Use the Perl helpers in `scripts/` to do the work. Never duplicate their logic
in shell, grep, or your own reasoning.

Script paths below are relative to this skill's installed directory.

## Log file types

openQA jobs produce several log files. This skill operates on two:

| Log file | Content | Used by |
|----------|---------|---------|
| `autoinst-log.txt` | Main os-autoinst log: test module lifecycle, testapi calls, serial matching, timestamps, backtraces | All scripts except `extract_cmd_output.pl` |
| `serial_terminal.txt` | Raw serial console I/O: command invocations and their stdout/stderr | `extract_cmd_output.pl` only |

**The user provides local log files.** This skill does not download, fetch,
or retrieve logs from any openQA instance. (If logs are not yet downloaded,
use the `openqa-log-fetcher` skill to fetch and cache them locally first.)
When the user provides a directory, most scripts auto-append `autoinst-log.txt`.
For `extract_cmd_output.pl`, the user must point to the `serial_terminal.txt`
file explicitly.

## Tools & Scripts

| Script | Input | Purpose |
|--------|-------|---------|
| `extract_log_section.pl` | `autoinst-log.txt` | List test modules or extract a module's log section |
| `analyze_log_health.pl` | `autoinst-log.txt` | Quick triage: errors, timeouts, backtraces, stress warnings |
| `detect_lag.pl` | `autoinst-log.txt` | Correlate backend loop counts with timeouts |
| `measure_cmd_time.pl` | `autoinst-log.txt` | Per-command execution timing with filtering |
| `extract_cmd_output.pl` | `serial_terminal.txt` | Extract command stdout/stderr by regex |
| `compare_modules_time.pl` | Multiple `autoinst-log.txt` | Side-by-side module wall/cmd/overhead comparison |

All scripts accept `--help`, `--json`, `--verbose`, and `--color`.

## Workflow

When asked to analyze a failure or log file, follow this pipeline:

### Step 1 — Locate log files

Confirm the path to the log directory or files. If the user provides a
directory, check for both `autoinst-log.txt` and `serial_terminal.txt`.

### Step 2 — Quick triage

Run the health check to surface all critical issues at once:
```bash
perl scripts/analyze_log_health.pl --json <autoinst-log.txt>
```
This answers: *"What went wrong?"* — errors, timeouts, hook failures,
backtraces, backend stress warnings.

### Step 3 — Infrastructure check

If timeouts were detected, check whether they were caused by host stress:
```bash
perl scripts/detect_lag.pl --json <autoinst-log.txt>
```
This answers: *"Was this a real failure or a flaky host?"* High loop counts
(>100K) indicate infrastructure stress rather than SUT failure.

### Step 4 — List modules

See the sequence of test modules that ran:
```bash
perl scripts/extract_log_section.pl --json <autoinst-log.txt>
```

### Step 5 — Extract module log

Focus on a specific module's log section:
```bash
perl scripts/extract_log_section.pl <autoinst-log.txt> <module_name>
```
This creates `<module_name>.log` in the current directory.

### Step 6 — Command timing analysis

Identify slow commands or filter by duration/API:
```bash
perl scripts/measure_cmd_time.pl --json <autoinst-log.txt>
perl scripts/measure_cmd_time.pl --json --duration ">5" <autoinst-log.txt>
perl scripts/measure_cmd_time.pl --json <autoinst-log.txt> zypper
```
This answers: *"Which command was slow?"*

### Step 7 — Command output extraction (if needed)

When you need to see what a specific command actually printed:
```bash
perl scripts/extract_cmd_output.pl --json <serial_terminal.txt> "az vm create"
```
This answers: *"What did the command output?"*

### Step 8 — Compare runs (if needed)

When comparing a failing run against a passing one:
```bash
perl scripts/compare_modules_time.pl --json <pass_log.txt> <fail_log.txt>
```
This answers: *"Which module regressed?"* or *"Where is the overhead?"*

## Common flags

| Flag | Behavior |
|------|----------|
| `--json` | Structured JSON output (for programmatic analysis) |
| `--color` | ANSI-colored terminal output (for human reading) |
| `--verbose` | Extra progress/debug messages on stderr |
| `--help` | Show full usage with examples |
| `--duration EXPR` | Duration filter (`measure_cmd_time.pl` only). Supports `>`, `>=`, `<`, `<=`, `==`, `!=` with `&&` and `||` connectives. Example: `">1 && <=30"` |
| `--loop-threshold N` | Loop count threshold (`analyze_log_health.pl` only, default: 100000) |

`--json` and `--color` are mutually exclusive. Default is plain text (no color).

## Rules

* Do NOT download, fetch, or attempt to retrieve log files from any openQA
  instance or remote server. The user is responsible for obtaining logs and
  making them available locally. If the user has not provided a log file path,
  ask them where the logs are.
* Do NOT re-implement the helpers' logic in shell, grep, awk, or file
  exploration tools. Always call the Perl scripts.
* Always prefer `--json` when processing results programmatically. Use the
  JSON output to extract specific fields rather than parsing tabular text.
* Do NOT modify any log files. This skill only reads and reports.
* When `analyze_log_health.pl` already identified the failing module, pass
  that module name directly to `extract_log_section.pl` rather than listing
  all modules first.
* When analyzing a timeout, always run `detect_lag.pl` to rule out
  infrastructure issues before investigating the test logic.
</instructions>
