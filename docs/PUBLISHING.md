# Publishing Workflow

pm-blog is a single repo (`promptmetrics/pm-blog`), not a private/public dual-mirror
setup. Releases are simple: commit to `main`, bump the version coherently, tag, and
publish a GitHub release.

## Standard release flow

1. **Pre-release sanity check** (run locally before tagging):

   ```bash
   python3 -m pytest tests/                        # all 187 tests pass
   python3 scripts/lint_prose.py --root .          # zero prose-hygiene violations
   claude plugin validate .                        # marketplace manifest valid
   ```

2. **Version + CHANGELOG**:
   - Bump the version coherently across every surface `tests/test_version_coherence.py`
     checks: `pyproject.toml`, `.claude-plugin/plugin.json`, `CITATION.cff` (also update
     `date-released`), and every sub-skill `SKILL.md` with `version:` frontmatter.
   - Move the `## [Unreleased]` block in `CHANGELOG.md` to `## [X.Y.Z] - YYYY-MM-DD` and
     start a fresh empty Unreleased.

3. **Tag and release**:

   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z: <one-line summary>"
   git push origin main
   git push origin vX.Y.Z
   gh release create vX.Y.Z \
     --repo promptmetrics/pm-blog \
     --title "vX.Y.Z" \
     --notes-file <(awk '/^## \[X.Y.Z\]/,/^## \[/' CHANGELOG.md | head -n -1)
   ```

## Remote configuration

A single `origin` remote pointing at `promptmetrics/pm-blog` is all that's needed.
An `upstream` remote pointing at `AgriciDaniel/claude-blog` (the fork point) can
optionally be added to pull in upstream fixes:

```bash
git remote add upstream https://github.com/AgriciDaniel/claude-blog.git
```

## What does NOT get committed

Some artifacts are intentionally local-only:

- `audit-results.md` (per-audit session evidence, already in `.gitignore`)
- `.env*` and `BRAND.md` / `VOICE.md` / `DISCOURSE.md` at the repo root (user- and
  writer-specific context; see the multi-writer sync design in
  `docs/superpowers/specs/2026-07-20-pm-blog-fork-design.md`)

The `.gitignore` already excludes these.
