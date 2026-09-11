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

## Emergency Dependency Bump

The weekly bump quarantines an external action's release until it is at
least `VIBE_BUMP_QUARANTINE_HOURS` old (default 24h), so a compromised
upstream release is not pinned the moment it is published. An
actively-exploited CVE is the case where that wait costs more than it
buys, and `bump-deps.sh --quarantine-hours` is the documented way out.

Do not wait for the weekly schedule. Run the bump directly, with the
window narrowed only as far as the fix requires:

```bash
# Ship an urgent fix now, bypassing the 24h quarantine for this run only.
./bump-deps.sh --quarantine-hours 0
```

The flag overrides the window **for that run only** — it is a command-line
argument, not a committed setting. Never lower the default in
`bump-deps.sh` or in `.github/workflows/bump-deps.yml` to make an
emergency easier to repeat; the next run must quarantine normally.

Steps:

1. **Confirm the advisory is real and exploited** — a GitHub advisory, a
   CVE, or a maintainer's disclosure. Quarantine exists to defend against
   a malicious release, so skipping it on rumour inverts the protection.
2. **Run the bump** as above. `bump-deps.sh` runs `./quality.sh` as its
   audit gate; a failure there means the bump is bad — revert it rather
   than merging around it.
3. **Open a PR and say why the window was bypassed**, naming the advisory.
   The PR is the record that an override happened.
4. **Escalate if the bump cannot be made to pass**: open an issue, label
   it `security` and `needs-human`, and mention @stSoftwareAU — the same
   route a failed scan takes above.

If the urgent dependency is an internal `stSoftwareAU/*` action, no
override is needed: internal actions are never quarantined and bump on
the next run.
