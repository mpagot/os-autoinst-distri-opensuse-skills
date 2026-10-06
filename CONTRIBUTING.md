# Contributing

## Opening an issue

Use [GitHub Issues](https://github.com/os-autoinst/osado-skills/issues) for:
- Bug reports — include the harness version (`agy plugin list`, `gemini --version`, etc.), the exact command run, and the error output
- Skill improvement suggestions — describe the OSADO workflow you want help with
- Feature requests — explain the use case, not just the desired behavior

Label the issue: `bug`, `enhancement`, or `question`. If you are unsure, open it anyway.

## Creating a pull request

Keep PRs small and focused — one logical change per PR.

1. Fork the repository and create a branch from `main`.
2. Make your change. If it touches Bash or manifests, run `make test` locally before pushing.
3. Run `make test-integration` if you modified `tools/install.sh` or any skill.
4. Write a short, descriptive PR title (≤60 characters) in the imperative mood:
   - Good: `Add vr-planner support for YAML schedule files`
   - Avoid: `Fixed some stuff` or `Updates to the thing`
5. In the PR description, explain *why* the change is needed, not just what it does.
6. One commit per logical unit is preferred; squash fixups before requesting review.

Checklist before opening the PR:
- [ ] `make test` passes
- [ ] No new ShellCheck warnings
- [ ] SKILL.md frontmatter is valid (name + description present)

## Creating a release

Releases are tagged from `main` after a set of features is considered stable.

### Bump the version

The version must be kept in sync across two files:
- `gemini-extension.json` — `"version"` field
- `.claude-plugin/plugin.json` — `"version"` field

The `make claude-plugincheck` target verifies they match; it runs as part of `make test`.

### Steps

```bash
# 1. Update version in both manifests (e.g. 1.0.0 -> 1.1.0)
#    Edit gemini-extension.json and .claude-plugin/plugin.json

# 2. Verify everything passes
make test

# 3. Commit the version bump
git add gemini-extension.json .claude-plugin/plugin.json
git commit -m "Bump version to v1.1.0"
git push

# 4. Create the release (auto-generates notes from merged PR titles)
gh release create v1.1.0 \
  --repo os-autoinst/osado-skills \
  --title "v1.1.0" \
  --generate-notes
```

`--generate-notes` fills the release body from merged PR titles since the previous tag. Review and edit the draft in the GitHub UI before publishing if you want to add highlights.

### Version scheme

This project uses [Semantic Versioning](https://semver.org/):
- **PATCH** (`x.y.Z`) — bug fixes, documentation corrections, no new skills
- **MINOR** (`x.Y.0`) — new skills, new harness support, backwards-compatible additions
- **MAJOR** (`X.0.0`) — breaking changes to the install script, manifest schema changes, or removal of skills
