# Vendored library updates

The updater currently manages oUF in Vaarattu Unit Frames. Other bundled libraries remain manually maintained until their upstream source, shipped files, and local modifications have been audited.

`.github/vendor-libraries.json` records the upstream repository, stable tag, exact commit, destination, included file patterns, and SHA-256 hashes of shipped files. Hashes normalize CRLF to LF so Windows checkouts work without line-ending-only changes.

## Local checks

Requires Python 3.11+ and Git. Lua 5.1 is required for the optional syntax check; there are no Python package dependencies.

```sh
python -B -m unittest discover -s tests -p 'test_update_libraries.py'
python -B scripts/update_libraries.py --luac luac5.1
python -B scripts/update_libraries.py --update --luac luac5.1
```

Omitting `--luac` still verifies hashes and XML/TOC file references, but does not check Lua syntax. The updater selects the highest stable `major.minor.patch` tag, optionally prefixed with `v`, and skips prereleases. Major-version updates also require manual PR review.

Local modifications, missing tracked files, moved current tags, and collisions with unmanaged files stop the update. Resolve local patches explicitly before retrying; do not regenerate hashes simply to silence a mismatch. The script validates every candidate before writing library files. It never executes upstream Lua.

## GitHub automation

`Refresh addon libraries` runs monthly on the seventh at 04:23 UTC and can also be started manually from Actions. Changes are proposed on the single `codex/library-updates` branch. No changes means no new PR. Updates never auto-merge or install into WoW.

The refresh job checks Lua syntax and XML/TOC references before creating a PR, then explicitly dispatches `Library checks` on the PR branch. This dispatch is needed because PRs created with `GITHUB_TOKEN` do not automatically trigger the usual PR workflow.

Before enabling the schedule, merge the workflows into `main` and enable **Settings → Actions → General → Workflow permissions → Allow GitHub Actions to create and approve pull requests**. The repository's default workflow permissions can remain read-only; only the refresh workflow requests write permissions. No personal access token is needed.

Review upstream changes and test target switching, aura displays, health/absorb bars, power bars, and relevant indicators in WoW before merging an oUF update. GitHub checks cannot reproduce WoW rendering, combat restrictions, or secret-value behavior.

Dependabot separately proposes monthly updates to the pinned GitHub Actions.

## Adding another library

First identify its authoritative repository and stable tag, compare the existing copy against upstream, and account for any local patches. Add the audited file selection and hashes to the manifest. Extend the workflow path filters and refresh `add-paths` list to include its destination. The current validator requires `LICENSE.txt`; adapt license validation explicitly if the next upstream uses a different license filename. Do not register addon-owned code such as `oUF_Elements` as an upstream library.
