# OSADO AI Assistant

AI-powered developer productivity skills for the
[os-autoinst-distri-opensuse](https://github.com/os-autoinst/os-autoinst-distri-opensuse)
(OSADO) project. Provides modular **Skills** and **Commands** that act as an
on-demand pair programmer aware of OSADO architecture and workflows.

## See It in Action

A few examples of what the assistant can do during a typical OSADO session.

### 🔍 Plan what to test after a code change

```
You: I changed lib/sles4sap/azure_cli.pm -- what do I need to test?

AI:  Your change touches 1 library file. Here's the verification plan:
     - Unit test: prove -l -Ios-autoinst/ t/sles4sap/azure_cli.t
     - Affected tests: tests/sles4sap/hana_install.pm, tests/sles4sap/azure_deploy.pm
     - Schedules: schedule/sles4sap/hana_node.yaml
     To get a clonable openQA job, confirm the target instance (osd or o3).
```

### 🩺 Understand openQA log files

```
You: I have the autoinst-log.txt from a failed job. The hana_install module
     timed out -- was it a real failure or infrastructure lag?

AI:  Running health check on autoinst-log.txt... 1 timeout detected in hana_install.
     Running lag detection... backend loop count: 243,891 (threshold: 100,000).
     Verdict: infrastructure stress on the worker host. The SUT likely had no issue.
     Recommend: re-run the job on a different worker.
```

### ✅ Run the right checks before pushing

```
You: I edited lib/sles4sap/azure_cli.pm and schedule/sles4sap/hana_node.yaml
     -- what should I run locally?

AI:  Analysing 2 changed files...

     TIER 1 (instant):
       perl -c lib/sles4sap/azure_cli.pm ... PASS
       yamllint schedule/sles4sap/hana_node.yaml ... PASS

     TIER 2 (before commit):
       prove -lv -Ios-autoinst/ t/sles4sap/azure_cli.t ... 12 tests passed
       make tidy ... no changes needed

     All local checks passed. Ready to push.
```

### 📝 Generate Perldoc headers for the test catalog

```
You: Add a documentation header to tests/sles4sap/qesap_ansible.pm

AI:  Reading file... identified 3 openQA variables (ANSIBLE_PLAYBOOK, PUBLIC_CLOUD_PROVIDER,
     QESAP_DEPLOYMENT_DIR) and 2 library dependencies (lib/sles4sap/qesapdeployment.pm,
     lib/publiccloud/utils.pm).
     Header generated from template. Running audit... PASS.
     Metadata check... OK. POD whitespace... OK.
```

### 🧪 Scaffold or review a unit test

```
You: I added a new function az_disk_create to lib/sles4sap/azure_cli.pm.
     Generate a unit test for it.

AI:  Scanning az_disk_create... 3 mandatory args (resource_group, name, size_gb),
     1 optional (sku). Generating test skeleton with @calls capture pattern,
     dies_ok for mandatory args, and separate subtest for the optional arg.
     Written to t/21_sles4sap_azure_cli.t (appended 3 new subtests).
     Run: prove -lv -Ios-autoinst/ t/21_sles4sap_azure_cli.t
```

### 🚀 Commit and open a PR in one shot

```
You: /github_pr_create

AI:  Inspecting staged changes... 2 files modified (lib/sles4sap/azure_cli.pm, t/sles4sap/azure_cli.t).
     Proposed commit message:
       "Add retry logic to azure_cli resource group creation"
     Written to commit_message.txt -- please review and confirm.

You: Looks good, go ahead.

AI:  Committed. Pushing to origin/add-retry-azure-cli...
     Creating PR against os-autoinst/os-autoinst-distri-opensuse...
     PR #18742 created: https://github.com/os-autoinst/os-autoinst-distri-opensuse/pull/18742
```

For a complete list of use cases and detailed explanations, see
[Use Cases and Workflows](docs/USE_CASES.md).

## Skills Included

| Skill | Description |
|-------|-------------|
| `local-lint-test` | Answers: *"What's the fastest local command to validate my edit right now?"* |
| `unit-test-wizard` | Write and review unit tests for OSADO Perl library modules |
| `test-catalog` | Add/audit Perldoc documentation headers on test modules |
| `vr-planner` | Answers: *"What remote openQA jobs should I clone to verify my change?"* |
| `git-commit` | Write OSADO-compliant commit messages for staged changes |
| `github-pr-create` | End-to-end workflow: commit, push, and create PR upstream |
| `openqa-log-analyzer` | Parse and extract sections from `autoinst-log.txt` |
| `openqa-log-fetcher` | Fetch, cache, and inspect logs, test artifacts, and job metadata from openQA instances |

## Dependencies

- `gh` (GitHub CLI) for PR operations.
- `jq` for JSON processing.
- `perl` for compilation checks.
- `uv` / `uvx` (or `openqa-log-local`) for fetching openQA logs with `openqa-log-fetcher`.

## Installation

See the [installation](INSTALL.md) document.


## Contributing

### Development Setup

```bash
# Clone and link for local development
git clone https://github.com/mpagot/os-autoinst-distri-opensuse-gemini
cd os-autoinst-distri-opensuse-gemini
gemini extensions link .
```

For OpenCode skill testing within this repo, create a local symlink:

```bash
mkdir -p .opencode && ln -s ../skills .opencode/skills
```

Changes to skills, commands, and context files are picked up on the next
Gemini CLI session.

### References

- [Agent Skills specification](https://agentskills.io/specification)
- [OpenCode Skills docs](https://opencode.ai/docs/skills/)
- [OCX Extension Manager](https://github.com/kdcokenny/ocx)
- [Gemini CLI Skills](https://geminicli.com/docs/cli/skills/)
- [Gemini CLI Custom Commands](https://geminicli.com/docs/cli/custom-commands/)
- [Gemini CLI Extensions](https://geminicli.com/docs/extensions/)
- [Claude Code Plugin Marketplaces](https://code.claude.com/docs/en/plugin-marketplaces)

### Testing

```bash
# Run all local tests (installer + lint)
make test

# Run integration tests (requires podman or docker)
make test-integration

# Or with docker instead of podman
make test-integration CONTAINER_RT=docker

# Use a custom container image
IMAGE_REPO=my-registry.io/my-tester IMAGE_TAG=v2 make test-integration
```

Integration tests run inside `ghcr.io/mpagot/osado-gemini-tester:latest` which
ships with `gemini`, `claude`, and `opencode` pre-installed. The Makefile
automatically pulls the latest image and verifies the digest against the remote
registry before running.

To run the integration test script directly (bypassing the pull + digest check):

```bash
podman run --rm -v "$(pwd):/src:ro" \
  ghcr.io/mpagot/osado-gemini-tester:latest /src/t/test_integration.sh
```

Both `IMAGE_REPO` and `IMAGE_TAG` can be overridden via environment variables
(the test script uses sensible defaults if unset).

## License

Licensed under the same terms as OSADO (GPL-2.0-or-later).
