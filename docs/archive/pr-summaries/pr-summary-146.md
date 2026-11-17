# Fix Node punycode deprecation warning in Pages deploy (Issue #146)

## Summary

The GitHub Pages deploy workflow logged a Node `[DEP0040]` deprecation warning
(`The 'punycode' module is deprecated`) and intermittently failed with
`Error: Deployment failed, try again later.`

The `punycode` deprecation is emitted by Node from **inside** the
GitHub-provided `actions/deploy-pages` action. That action is an external
dependency (`actions/*`, not `stSoftwareAU/*`) and is already pinned to the
latest release (`v5.0.0` — SHA `cd2ce8fcbc39b97be8ca5fce6e763baed58fa128`), so
the warning cannot be patched at the action's source from this repo. Instead we
silence it at the Node runtime with `NODE_OPTIONS: --no-deprecation` on the
deploy job, which is the supported way to suppress third-party deprecation
noise.

We also add the canonical `environment: github-pages` declaration that GitHub
recommends for `actions/deploy-pages`. This is the supported configuration for
Pages deployments and surfaces the published page URL, making deploys more
observable — a robustness improvement for the transient
"Deployment failed, try again later" symptom.

No repository source code changed — this is a CI workflow configuration fix.

Closes #146.

## Changes

- `.github/workflows/deploy.yml`
  - Add job-level `env: NODE_OPTIONS: --no-deprecation` to suppress the
    punycode `DEP0040` warning from the pinned GitHub actions.
  - Add job-level `environment: github-pages` (with the deployment `page_url`)
    per GitHub's supported Pages deploy configuration.
- `tests/test-deploy-deprecation-fix.sh` — new test.

```mermaid
flowchart LR
    A[push to docs/**] --> B[deploy job]
    B --> C{NODE_OPTIONS=--no-deprecation}
    C --> D[Setup Pages]
    D --> E[Upload artifact]
    E --> F[Deploy to GitHub Pages]
    F --> G[environment: github-pages<br/>url = page_url]
```

## Evidence

This is a CI/workflow-only change with no web UI to screenshot. Verification is
via the new test plus YAML validation:

- New test `tests/test-deploy-deprecation-fix.sh` parses `deploy.yml` with a
  real YAML parser and asserts on the parsed structure (not raw text):
  - `jobs.deploy.env.NODE_OPTIONS` requests `--no-deprecation`.
  - `jobs.deploy.environment.name` is `github-pages`.
  - `jobs.deploy.environment.url` references
    `steps.deployment.outputs.page_url`.
- The pre-existing `tests/test-deploy-workflow-pinned.sh` still passes, so SHA
  pinning and version comments remain intact.

## Test Plan

- Added `tests/test-deploy-deprecation-fix.sh` (5 assertions, all pass).
- Confirmed it fails against the unfixed workflow (3 failing assertions) and
  passes after the fix — a genuine regression test.
- Ran `./quality.sh`: the two remaining failures
  (`test-gitleaks-workflow`, `test-version-consistency`) are pre-existing on a
  clean checkout and unrelated to this change (verified by stashing the change
  and re-running both — they fail without it).
