---
name: openqa-log-fetcher
description: >
  Fetches, caches, and inspects logs, test artifacts, and job metadata from openQA
  instances. Activate when the user asks to "get logs", "download openQA log",
  "fetch autoinst-log.txt", "retrieve job artifacts", "check test variables",
  "inspect openQA job settings", or provides an openQA job URL or job ID to analyze.
compatibility: Requires uvx (via uv) and jq.
---

<instructions>
You help an OSADO developer fetch openQA test logs, inspect job configurations,
and extract artifacts directly from openQA instances.

Where `openqa-log-analyzer` requires local log files to exist on disk before
analyzing them, this skill bridges the gap by downloading and caching logs
and metadata locally.

## Prerequisites

Before executing commands, perform pre-flight checks:

1. **Check for `openqa-log-local` in PATH**:
   ```bash
   command -v openqa-log-local >/dev/null 2>&1
   ```
   If available directly in PATH, run `openqa-log-local` directly instead of prefixing with `uvx`.

2. **Check for `uvx`**:
   If `openqa-log-local` is not found directly in PATH, check for `uvx`:
   ```bash
   command -v uvx >/dev/null 2>&1 || which uvx >/dev/null 2>&1
   ```
   If available, run commands via `uvx openqa-log-local`.

3. **If neither is found**:
   Inform the user that neither `openqa-log-local` nor `uvx` is installed or available in PATH.

## Target Resolution

Users may supply a full URL or a host and job ID:

- **URL format**: `https://<host>/tests/<job_id>` (e.g. `https://openqa.suse.de/tests/24569155`)
  - `<host>`: `openqa.suse.de`
  - `<job_id>`: `24569155`
- **Default host**: If only a job ID is supplied and the host is omitted, confirm or default to `openqa.suse.de` for SUSE internal jobs or `openqa.opensuse.org` for openSUSE jobs.

## Workflow

Follow this step-by-step workflow:

### Step 1 — Check Available Logs and Cache Job Details

Query the list of files without downloading the entire asset payload. This call automatically queries the openQA API and initializes the local metadata cache:

```bash
uvx openqa-log-local --host <host> get-log-list --job-id <job_id>
# Or filter by piping to grep:
uvx openqa-log-local --host <host> get-log-list --job-id <job_id> | grep supportconfig
```

### Step 2 — Inspect Job Metadata and Settings

On cache miss or initialization, a consolidated JSON file is created locally at:
`.cache/<host>/<job_id>.json`

This file contains two top-level keys:
- `job_details`: Full openQA job specification, including test settings, worker ID, machine architecture, start/end timestamps, and final test result.
- `log_files`: Array of all asset and log filenames published by the test run.

Use `jq` to inspect metadata directly without remote round-trips:

#### Check Job Status and Architecture
```bash
jq '{state: .job_details.state, result: .job_details.result, arch: .job_details.settings.ARCH, machine: .job_details.settings.MACHINE}' .cache/<host>/<job_id>.json
```

#### Check Test Variables and Configuration
```bash
# View all test variables:
jq '.job_details.settings' .cache/<host>/<job_id>.json

# Query specific settings (e.g., cloud provider, test suite, exclusions):
jq -r '.job_details.settings.PUBLIC_CLOUD_PROVIDER // "N/A"' .cache/<host>/<job_id>.json
jq -r '.job_details.settings.PUBLIC_CLOUD_SUPPORTCONFIG_EXCLUDE // "not set"' .cache/<host>/<job_id>.json
```

#### Check Available Log Files
Prefer using `get-log-list` piped to `grep` to verify available files or check for specific artifacts:
```bash
uvx openqa-log-local --host <host> get-log-list --job-id <job_id> | grep supportconfig
```
*(Prefer `get-log-list` over extracting `.log_files` from `.cache/<host>/<job_id>.json`)*

### Step 3 — Download and Retrieve Target Logs

Fetch specific log files on demand. The command prints the path to the local cached file, downloading it transparently if not already present:

```bash
# Main os-autoinst execution log:
uvx openqa-log-local --host <host> get-log-filename --job-id <job_id> --filename autoinst-log.txt

# Serial console I/O:
uvx openqa-log-local --host <host> get-log-filename --job-id <job_id> --filename serial_terminal.txt

# Specific diagnostic / test log:
uvx openqa-log-local --host <host> get-log-filename --job-id <job_id> --filename destroy-scc_supportconfig.txt
```

Cached files are stored in the workspace directory under:
`.cache/<host>/<job_id>/<filename>`

### Step 4 — Handoff to Analysis Tools

Once target logs are retrieved, pass the cached file paths to downstream analysis skills or scripts.

For example, to analyze failures and timing with `openqa-log-analyzer`:
```bash
perl <path-to-skill>/scripts/analyze_log_health.pl --json .cache/<host>/<job_id>/autoinst-log.txt
perl <path-to-skill>/scripts/detect_lag.pl --json .cache/<host>/<job_id>/autoinst-log.txt
perl <path-to-skill>/scripts/measure_cmd_time.pl --json --duration ">30" .cache/<host>/<job_id>/autoinst-log.txt
```

## Rules

- Do NOT download video files, raw disk images (`.qcow2`, `.raw`), or full ISOs unless explicitly requested by the user. Prefer text logs (`autoinst-log.txt`, `serial_terminal.txt`, `.txt`).
- Always perform pre-flight checks (`openqa-log-local` in PATH, then `uvx`) before attempting execution.
- Leverage `.cache/<host>/<job_id>.json` for configuration inspection rather than downloading `vars.json` separately.
- Respect existing local cache files; `get-log-filename` will avoid unnecessary network requests when the file is already cached.
</instructions>
