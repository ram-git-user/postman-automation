> **Update log:** runners switched to self-hosted Windows; new-collection
> detection is now fully automatic (no manual `dependency-map.json` edit
> required); the dependency engine now handles downstream dependents as well
> as upstream prerequisites; regression is fully dynamic; and notifications
> support Microsoft Teams and/or email with reports attached. See
> [§7 Change log](#7-change-log-vs-previous-version) for the full mapping.

# Postman Automation Framework

A configuration-driven Newman/GitHub Actions framework for validating SOAP/REST
API collections exported from Postman. Built from `automate performance test
sample 35`, split into 4 independent collections (**Update User → Risk
Evaluate → Issuance OTP → Verify OTP**) that are orchestrated, tested,
versioned, and promoted automatically.

Adding API #5, #40, or #400 later requires **zero** changes to any workflow
or script — only:

```
1. Copy the exported collection into collections/
2. Add one line to dependency/dependency-map.json
```

---

## 1. Repository layout

```
postman-automation/
├── .github/workflows/
│   ├── pr-validation.yml          # feature/* -> develop
│   ├── develop-validation.yml     # full regression on develop
│   ├── production-validation.yml  # develop -> main, promote + tag
│   ├── rollback.yml               # manual emergency rollback
│   └── regression.yml             # nightly drift check on prod collections
├── collections/                   # source of truth, one file per API
│   ├── update-user.json
│   ├── risk-evaluate.json
│   ├── issuance-otp.json
│   ├── verify-otp.json
│   └── regression.json            # merged, for manual runs in Postman GUI only
├── collections-production/        # last known-good, auto-promoted, never hand-edited
├── dependency/
│   └── dependency-map.json        # the only file you touch to wire up new APIs
├── environment/
│   └── shared-environment.postman_environment.json
├── reports/                       # junit.xml, *.html, summary.json (gitignored)
└── scripts/                       # PowerShell (pwsh), OS-agnostic on GH runners
    ├── detect-changes.ps1
    ├── resolve-dependency.ps1
    ├── run-api.ps1
    ├── run-regression.ps1
    ├── notify.ps1
    └── rollback.ps1
```

## 2. How variable-passing works across separate collection files

The original collection stored `otp` as a **collection variable**, fine when
everything lives in one `.postman_collection.json`. Splitting into 4 files
means Issuance OTP and Verify OTP run as two separate `newman run` processes,
so the OTP now lives in the **shared environment file** instead:

- `Issuance OTP` test script: `pm.environment.set("otp", otp)`
- `scripts/run-api.ps1` calls `newman run ... --export-environment reports/env-after-<name>.json`, then copies that exported file back over the shared environment path before the next collection runs.
- `Verify OTP` reads `{{otp}}` from that same environment file.

`dependency/dependency-map.json` is what tells the pipeline *that* Verify OTP
needs Issuance OTP to run first — see below.

## 3. The dependency engine

```json
{
  "update-user": [],
  "risk-evaluate": [],
  "issuance-otp": [],
  "verify-otp": ["issuance-otp"]
}
```

`scripts/resolve-dependency.ps1` topologically sorts this map for whichever
collection(s) changed, so if you only touch `verify-otp.json`, the pipeline
runs `issuance-otp → verify-otp`, not the full suite, for the fast first pass.
`scripts/run-regression.ps1` sorts the *entire* map the same way to build the
full regression order — currently `update-user → risk-evaluate →
issuance-otp → verify-otp`.

Onboarding `login.json` tomorrow: add `"login": []` (or `"login":
["risk-evaluate"]` if it needs risk context first). Nothing else changes.

## 4. Pipeline behavior (mapped to your 3 requirements)

### Requirement 1 — versioning & rollback
- Every commit to `main` that passes full regression gets a moving tag
  `last-stable` (force-updated) **and** an immutable timestamped tag
  `stable-YYYYMMDD-HHMMSS`. Both live in normal Git history — no external
  artifact store needed for this scale.
- `collections-production/` is only ever updated by the CI bot, only after a
  100% pass, via `production-validation.yml`. It is the deployable artifact;
  `collections/` is the working/dev copy.
- If validation fails on `main`, `scripts/rollback.ps1` runs automatically:
  `git reset --hard last-stable` + `git push --force-with-lease`, so main is
  never left in a broken state. `rollback.yml` exposes the same script as a
  manual `workflow_dispatch` button for "it broke 2 hours after deploy."

### Requirement 2 — test changed API(s) first, then full suite, then alert
- `pr-validation.yml`: `detect-changes.ps1` diffs the PR against `develop` to
  find changed `collections/*.json` files → `resolve-dependency.ps1` builds
  the minimal ordered run (changed API + upstream deps) → runs that first for
  fast feedback → then runs `run-regression.ps1` for the full suite (because,
  as you noted, existing APIs may depend on what changed) → `notify.ps1` posts
  a Slack/Teams message naming exactly which collection failed, the Newman
  error, and links the uploaded HTML/JUnit report, on **any** failure.

### Requirement 3 — promote to production + notify on full pass
- `production-validation.yml` re-runs the full regression against `main`
  itself (never trust "it passed on develop" blindly — config/hosts can
  differ), and only then copies `collections/*.json` →
  `collections-production/*.json`, tags stable, and sends a "ready for
  production deployment" notification.

## 5. Local usage

```powershell
# one API
pwsh ./scripts/run-api.ps1 -CollectionName verify-otp

# everything, in dependency order
pwsh ./scripts/run-regression.ps1

# what changed vs develop, and what needs to run because of it
pwsh ./scripts/detect-changes.ps1 -BaseRef origin/develop -HeadRef HEAD
pwsh ./scripts/resolve-dependency.ps1 -ChangedCollections @("verify-otp")
```

Requires Node.js + `npm install -g newman newman-reporter-htmlextra`, and
PowerShell 7 (`pwsh`) — install via `winget install Microsoft.PowerShell` on
Windows or `brew install powershell` on macOS; GitHub's `ubuntu-latest`
runners ship it already.

Notifications (`scripts/notify.ps1`) support both channels, independently:

| Channel | Secrets to set | Behavior |
|---|---|---|
| Microsoft Teams | `NOTIFY_WEBHOOK_URL` (Teams incoming-webhook connector URL) | Posts a MessageCard with per-collection pass/fail facts and a "View full run" link. (A Slack webhook URL also works via the same secret - detected automatically by URL.) |
| Email | `SMTP_SERVER`, `SMTP_FROM`, `SMTP_TO` (required); `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_USE_SSL` (optional) | Sends a plain-text summary with the run's HTML + JUnit reports **attached directly** to the email, for troubleshooting without leaving the inbox. |

Neither is required to make the pipeline work — if nothing is configured,
`notify.ps1` prints the same summary to the job log instead of failing.

---

## 6. Is this the best approach? What most organizations actually do

This design is solid for **4–50 collections owned by one team** and mirrors
real practice reasonably well, but a few things are worth calling out
honestly:

**What you're already doing that matches industry norms:**
- GitFlow-lite (`feature/* → develop → main`) with CI gates at each stage —
  standard.
- Immutable Git tags as the version record for "what's actually in
  production" — this is exactly what most orgs do for config/API-test
  repos; you don't need a separate artifact registry (Nexus/Artifactory) at
  this scale.
- "Test changed thing fast, then full regression before merge" — this is the
  standard **test pyramid applied to a CI pipeline**: fast, targeted signal
  first, comprehensive signal before it's trusted.
- Auto-rollback via `git reset --hard` to a tag — common for config-only or
  test-suite repos where "rollback" means "point back at last-known-good,"
  not a blue/green infra rollback.

**Where most mature organizations go slightly further than what's above —
worth adopting as you scale past a handful of collections:**

1. **Branch protection + required status checks**, not just workflow logic.
   Even though `production-validation.yml` gates promotion, add branch
   protection rules on `main` requiring `develop-validation` and PR checks to
   pass before merge is *allowed*, not just before the bot promotes — belt
   and suspenders, and it stops someone with push rights from bypassing CI.

2. **A human approval gate before production promotion**, via [GitHub
   Environments](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment)
   with required reviewers on the `production` environment. Fully automatic
   promotion is fine for internal test-collections; if these SOAP endpoints
   sit in front of anything customer-facing, most orgs still want a named
   approver clicking "deploy" even when tests are green — auditability, not
   distrust of the tests.

3. **Secrets/host management via environment variables or a vault, not
   hardcoded IPs in the collection.** `192.168.10.35` baked into the JSON
   means every environment (dev/QA/staging/prod) needs a hand-edited copy of
   every collection. I already parameterized the host as `{{updateUserHost}}`
   etc. in the split collections — the next step most orgs take is one
   Postman **environment file per stage** (`dev.postman_environment.json`,
   `qa...`, `prod...`) selected via a workflow input, rather than editing
   collection bodies at all.

4. **Contract/schema validation, not just "did it 200 and avoid a SOAP
   Fault."** Current tests check status code and fault-absence. As this
   scales, add assertions on actual response fields (e.g., a schema check on
   the SOAP body, or `pm.expect(xml).to.match(...)` on key elements) so a
   silently-wrong response doesn't pass. Tools like Postman's built-in schema
   validation or a lightweight XML-schema check per response are common next
   steps.

5. **Retention and dashboards for historical trend data**, not just the last
   run's HTML report. Most orgs pipe `summary.json`/JUnit results into
   something queryable over time (a simple S3 bucket + static dashboard,
   Grafana, Postman's own Insights/Monitors, or even a GitHub Pages page
   generated from `reports/`) so you can see flakiness or latency creep
   across weeks, not just pass/fail on the last commit.

6. **Consider Postman Monitors for the *production* collection** in addition
   to CI-triggered runs. CI catches regressions from code changes; a
   scheduled monitor (I added a lightweight GitHub Actions cron
   equivalent — `regression.yml` — for exactly this) catches the case where
   the *downstream* SOAP service changes independently of your repo.

**Net assessment:** the architecture is right-sized and follows the same
change → fast-test → full-test → promote → tag → alert → rollback shape used
by most CI/CD setups for API test suites. The improvements above are the
things I'd prioritize in order (branch protection first, approval gate
second, environment-based host config third) as you go from 4 APIs to 40+ or
add anyone customer-facing behind these endpoints — none of them require
restructuring what's here.

---

## 7. Change log vs. previous version

| # | Change | Where | Detail |
|---|---|---|---|
| P1 | Self-hosted Windows runner | all `.github/workflows/*.yml` | `runs-on: [self-hosted, Windows]`, `shell: powershell` (Windows PowerShell 5.1, no extra `pwsh` install needed). Every step also checks `Get-Command node` / `Get-Command newman` and only installs Newman globally if it isn't already on the runner — self-hosted runners persist state between jobs, so this avoids a redundant `npm install -g` on every run. A "clean workspace" step clears `reports/` first for the same reason (ephemeral GitHub-hosted runners don't need this; self-hosted ones do). |
| P2 | Automatic detection of new collections | `scripts/sync-dependency-map.ps1` (new) | Scans `collections/*.json` on disk and auto-adds any file missing from `dependency/dependency-map.json` with an empty dependency list, then rewrites the map. Called at the start of every workflow (`run-regression.ps1` also calls it internally). On `develop`/`main` the auto-registration is committed back to the repo so the map stays an accurate record; on PRs it's applied in-memory for that run only (no push to someone else's branch). **Net effect: dropping a new `collections/<name>.json` file and opening a PR is now sufficient by itself — the dependency-map edit described in the original design is now optional, not required.** |
| P3 | Dependency engine now handles both directions | `scripts/resolve-dependency.ps1` (rewritten) | Previously only resolved *upstream* prerequisites (e.g. verify-otp needs issuance-otp first). Now also walks the **reverse** map to pull in *downstream dependents* — if `issuance-otp` changes, `verify-otp` is automatically included in the fast-feedback run too, since it consumes issuance-otp's output. Circular dependencies are detected and fail fast with a clear error instead of infinite-looping. |
| P4 | Dynamic regression | `scripts/run-regression.ps1` | Already built from a topological sort of `dependency-map.json` rather than a hardcoded list; now also calls `sync-dependency-map.ps1` first, so a collection added straight to `collections/` with zero other changes is picked up and executed on the very next regression run, in the correct order, with no script edits. |
| P5 | Production promotion | `production-validation.yml` | Unchanged in intent, hardened in mechanics: still copies `collections/*.json` → `collections-production/*.json` and commits only on success; now also commits the auto-synced `dependency-map.json` in the same commit so production and its dependency graph move together. |
| P6 | HTML/JUnit reports | `scripts/run-api.ps1` (unchanged) + `scripts/notify.ps1` (rewrite) | Reports were already generated (`newman-reporter-htmlextra` + JUnit XML per collection); what changed is `notify.ps1` now actively surfaces them — every email notification has the run's `.html` and `*junit.xml` files attached directly, and the Teams card links straight to the uploaded artifact for the run. |
| P7 | Notifications | `scripts/notify.ps1` (rewrite) | Added Microsoft Teams `MessageCard` formatting (facts table, one row per collection with its status/error) and SMTP email as a fully independent second channel, per the table in §6. Slack webhooks still work unchanged via URL auto-detection. |
| P8 | Automatic rollback | `production-validation.yml` (unchanged logic) + `rollback.yml` (unchanged logic) | This was already implemented: `production-validation.yml` calls `scripts/rollback.ps1` automatically on any failure, resetting `main` (and therefore `collections-production/`) to the `last-stable` tag and force-pushing with `--force-with-lease`; `rollback.yml` exposes the identical script as a manual `workflow_dispatch` button for after-the-fact incidents. No functional change was needed here — confirmed this satisfies "restore the last working production version" and left it as-is. |

**Runner prerequisites for your self-hosted Windows box(es):** Node.js LTS
installed once and on `PATH` (the workflow throws a clear error if it isn't),
Git, and network access to wherever your Postman targets and
Teams/SMTP endpoints live. Newman itself installs automatically on first use
and is left in place for subsequent runs.
