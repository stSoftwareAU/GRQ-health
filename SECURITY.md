# Security Policy

This document is the escalation path for GRQ Health Monitoring System. It
names who is alerted when a security signal appears, and the route that
signal takes to a human — whether the signal is a failing CI scan, a new
advisory, or a report from outside the project (issue #205).

Maintainers: **@stSoftwareAU** — the organisation that owns this
repository. Every route below ends with them.

## Scope and Supported Versions

Only the tip of the default branch (`Develop`) is supported. The
repository publishes a rolling dashboard rather than tagged releases, so
there is no back-porting: a fix lands on `Develop` and is deployed by
`.github/workflows/deploy.yml`. Reports against an older commit are
accepted, but the fix will only ever be applied to `Develop`.

In scope: `run.sh`, `bump-deps.sh`, `helpers/`, the dashboard under
`docs/`, and the workflows in `.github/workflows/`. Out of scope: the
hosts being monitored, and the contents of the logs they publish — the
README's [Security Considerations](README.md#security-considerations)
section covers what must never be written into a log.

## Reporting a Vulnerability

Report privately, never in a public issue: open a draft advisory through
GitHub's private vulnerability reporting on the
[Security tab](https://github.com/stSoftwareAU/GRQ-health/security/advisories/new).
That route notifies @stSoftwareAU directly and keeps the report
confidential until a fix is published.

Expect an acknowledgement within **5 business days**. If none arrives,
escalate by opening a public issue that describes the *absence of a
response* only — never the vulnerability itself — and label it
`needs-human`.

## Triaging a Failed Security Scan

Two scans gate every pull request, and both fail the PR when they find
something:

- **Gitleaks** (`.github/workflows/gitleaks.yml`) — secret scanning across
  the PR's commit range.
- **Semgrep** (`.github/workflows/semgrep.yml`) — SAST on the PR head, plus
  a daily authenticated scan of the default branch at 07:00 UTC.

Neither sets `continue-on-error`, so a finding is always a red check
rather than a warning buried in a log.

```mermaid
flowchart TD
    A[Gitleaks or Semgrep fails] --> B[PR author triages<br/>within 2 business days]
    B --> C{Real finding?}
    C -- no --> D[Fix or narrowly scope the rule,<br/>record why in the PR]
    C -- yes, code not yet merged --> E[Fix on the PR branch<br/>before merge]
    C -- yes, secret was committed --> F[Rotate the credential first,<br/>then open a private advisory]
    F --> G[Label the tracking issue<br/>security + needs-human]
    E --> G
    G --> H[@stSoftwareAU]
```

Responsibilities:

1. **The PR author triages first**, within **2 business days** of the red
   check. A failing scan is never merged around and never ignored.
2. **A committed secret is an incident, not a lint failure.** Rotate the
   credential before anything else — assume a public repository means the
   value is already disclosed — then report it through the private
   advisory route above.
3. **If the author cannot triage it**, or the finding reaches beyond this
   repository, open an issue, label it `security` and `needs-human`, and
   mention @stSoftwareAU. That label pair is the signal that a human
   maintainer must pick the issue up.
4. **A daily Semgrep run on `Develop`** can fail with no PR attached; that
   failure is @stSoftwareAU's to triage, on the same 2-business-day clock.

## Dependency Advisories

Third-party GitHub Actions are pinned to commit SHAs and refreshed weekly
by `.github/workflows/bump-deps.yml`, which runs `./bump-deps.sh` and
opens a PR. `.github/workflows/dependency-review.yml` blocks a PR that
introduces a dependency carrying a known advisory. An advisory that
neither catches is reported through the private route above.
