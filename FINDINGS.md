# FINDINGS

Durable notes from provisioning this repo as a Mendix app driven by `mxcli`.
Append to this file as work continues — it is the context the next session
starts from.

## Environment / versions

| What | Value |
| --- | --- |
| Mendix version | `11.6.3` (project), MxBuild + runtime `11.6.3` cached |
| mxcli version | `nightly-20260805-4fda072f` (built 2026-08-05T15:39:37Z) |
| Platform | Linux 6.18.5 x86_64, Claude Code on the web (ephemeral container) |
| Project file | `App.mpr` at repo root |
| Database | local PostgreSQL 127.0.0.1:5432, db `app`, role `mendix` |
| Runtime log | `.mxcli/runtime.log` (gitignored) |

Caches live outside the repo in `/root/.mxcli/` (`mxbuild/11.6.3`,
`runtime/11.6.3`) — they do **not** survive container reaping, so a fresh
session re-downloads ~325 MB of runtime. That is what the SessionStart hook is
for (see finding 4).

---

## 1. `mxcli` was **not** pre-installed in this environment

**Expected:** the task description said mxcli "should be pre-installed by the
environment".
**Actual:** `command -v mxcli` → not found; nothing mxcli-shaped in
`/usr/local/bin`.

**Workaround applied** — downloaded the nightly prebuilt binary to `./mxcli`:

```bash
curl -fsSL -o ./mxcli \
  https://github.com/mendixlabs/mxcli/releases/download/nightly/mxcli-linux-amd64
chmod +x ./mxcli
```

**Verified:** `./mxcli --version` → `mxcli version nightly-20260805-4fda072f`.

Note the binary is 88 MB and is listed in the generated `.gitignore`, so it is
deliberately *not* committed — every fresh clone must re-fetch it.

## 2. `mxcli new` refuses to scaffold into a non-empty directory

**Command:** `./mxcli new App --version 11.6.3 --output-dir .`
**Error:** `Error: directory /home/user/mxcli-issuetracker already exists and is not empty`

The repo root was not empty — it already had `.git/`, `LICENSE`, `README.md`
from the initial commit. This is the normal state of any existing repo you want
to provision, so it blocks the documented "create the app at the repo root"
path. There is no `--force`/`--into-existing` flag (`mxcli new --help` lists
only `--output-dir`, `--skip-init`, `--version`). `mxcli init` was not an option
either — it needs an `.mpr` that does not exist yet.

**Workaround applied:** scaffold into an empty temp dir, then move the contents
into the repo root:

```bash
./mxcli new App --version 11.6.3 --output-dir /home/user/mxcli-new-tmp
# move everything except the linked ./mxcli binary into the repo root
```

**Verified:** no filename collisions with the pre-existing `LICENSE` /
`README.md` / `.git`, and `App.mpr` + `mprcontents/` landed intact
(`./mxcli -p App.mpr` reads the project fine — see finding 6).

**Suggested fix for mxcli:** allow scaffolding into a non-empty directory when
no `.mpr` is present, or at least ignore `.git`, `LICENSE`, `README*` and
similar when deciding "not empty". Provisioning an existing repo is a common
case.

## 3. Project name is derived from the output directory's basename

Because of the finding-2 workaround, the scaffolder stamped the *temp* directory
name into three generated files:

- `CLAUDE.md:1` — `# Mendix Project: mxcli-new-tmp`
- `AGENTS.md:1` — same heading
- `.devcontainer/devcontainer.json:2` — `"name": "mxcli-new-tmp"`

All cosmetic (nothing functional referenced the temp path — checked with
`grep -rl mxcli-new-tmp .`, which matched only those three files). Corrected to
`mxcli-issuetracker`; re-running `./mxcli init --tool claude` in the final
directory also regenerates `AGENTS.md`/`CLAUDE.md` with the right name, so the
`init` re-run is a clean way to repair this.

Worth knowing: the app name passed to `mxcli new` (`App`, which determines
`App.mpr`) and the display name in the docs/devcontainer are derived from
*different* sources — the argument vs. the directory basename.

## 4. The SessionStart self-bootstrap hook is a no-op on a fresh clone

`mxcli init --tool claude` writes this into `.claude/settings.json`:

```json
"command": "test -x ./mxcli && ./mxcli run --local --setup --ensure-db -p App.mpr || true"
```

The guard `test -x ./mxcli` is doing exactly what it says — but `mxcli` is in
the generated `.gitignore`, so **after a fresh clone the binary does not exist
and the hook silently does nothing** (and `|| true` hides that). The next
session then has no MxBuild, no runtime, no Postgres and no database, which is
the precise situation the hook is meant to prevent.

**Workaround applied:** added `.claude/bootstrap.sh` (committed) that downloads
the nightly `mxcli` binary if it is missing, then runs the warm-loop setup, and
pointed the SessionStart hook at it. The download URL/version is kept in that
one script so it is easy to pin.

**Suggested fix for mxcli:** have `init` emit a bootstrap script (or make the
hook self-fetch the binary at the version that generated the project) rather
than a guard that no-ops precisely when bootstrapping is needed.

## 5. VS Code MDL extension cannot auto-install headless (expected, harmless)

`mxcli new` / `mxcli init` both print a boxed warning that
`.claude/vscode-mdl.vsix` could not be installed because `code` is not on PATH.
Expected in a headless cloud container; no action needed. Flagging only because
the box is visually alarming and reads like a failure. The `.vsix` is extracted
and available if someone wants it locally.

## 6. Warm-loop setup worked first try

`./mxcli run --local --setup --ensure-db -p App.mpr` completed cleanly:

- MxBuild 11.6.3 — already cached at `/root/.mxcli/mxbuild/11.6.3/modeler/mxbuild`
  (populated earlier by `mxcli new`, which downloads MxBuild as its step 1)
- Mendix runtime 11.6.3 — downloaded 325.5 MB from
  `https://cdn.mendix.com/runtime/mendix-11.6.3.tar.gz`, extracted to
  `/root/.mxcli/runtime/11.6.3`
- local PostgreSQL started, role `mendix` created, database `app` created

It also prints `WARNING: This is a vibe-coded PoC, alpha quality, use with
caution.` — accurate expectation-setting, not a problem.

## 7. Boot verified: HTTP 200 on the first try, ~19s cold

`./mxcli run --local -p App.mpr` (backgrounded) reached a serving state without
intervention:

```
Starting mxbuild --serve...
Building (first build is cold, ~10-15s)...
Bundling web client...
  Web client bundled in 9.513s
Runtime started; app serving at http://127.0.0.1:8080/
```

**Verified** by polling `curl` from launch until it answered:

| Check | Result |
| --- | --- |
| Time from launch to first `200` | ~19 s |
| `GET http://localhost:8080/` | `200 OK`, `Content-Type: text/html;charset=utf-8`, `Content-Length: 1706` |
| Body | the real Mendix web client `index.html` (async/arrow-function browser check, then client bootstrap) — not a placeholder |
| `GET /index.html` | `200` |
| `GET /xas/` | `401` — expected, the runtime data endpoint requires a session |

`.mxcli/runtime.log` ends with
`Core: Mendix Runtime successfully started, the application is now available.`
It is **not** warning-free, though — see finding 7a for what is in there.

### 7a. Runtime log warnings on a clean boot (all benign, one worth knowing)

`grep -icE "error|warn|exception|severe" .mxcli/runtime.log` → 8 lines across
two boots (the `--local` run and the `--hub` run). None of them indicate a
broken app:

- `WARNING - Core: MxAdmin user with username 'MxAdmin' does not exist!` — a
  blank scaffolded app ships no administrator user. Expected; you cannot log
  into the app until you create one.
- `WARNING - LicenseService: The runtime has been started using a trial
  license, the framework will be terminated when the maximum time is
  exceeded!` — expected for an unlicensed local runtime. **Worth knowing: a
  long-lived `mxcli run` will eventually self-terminate.** If a session finds
  the app dead after a long idle period, this is the likely cause, not a crash.
- `WARNING - Connector: Only content type 'application/json' is allowed (found
  'null').` — this was *my own* `curl http://localhost:8080/xas/` probe (no
  `Content-Type` header), not a spontaneous runtime problem. Timestamps line up
  exactly (18:19:29). Noting it so a future session doesn't chase it.

### 7b. Shutting the runtime down raises an unhandled exception

Stopping the backgrounded `--local` run logged:

```
ERROR - M2EE: An error occurred while executing action 'shutdown'.
com.mendix.m2ee.api.internal.AdminException: An unhandled exception occurred!
Caused by: java.lang.IllegalStateException: Shutdown in progress
```

The process did exit and port 8080 was released cleanly (verified: `curl`
`Failed to connect`, no listener), so this is cosmetic — but it looks like mxcli
issues an admin `shutdown` action *while* the JVM shutdown hook is already
running, so the two race. Harmless here; would be noise in any CI log that
starts and stops the app. Reproduced on the first stop; not retried.

## 8. Hub preview works; the public URL is behind GitHub OAuth (so `curl` sees 302, not 200)

`MXCLI_HUB_KEY` **was** set on this environment, so
`./mxcli run --hub https://hub.mxcli.org -p App.mpr` worked:

```
Registering with hub https://hub.mxcli.org...
client: Connecting to wss://hub.mxcli.org:443 via http://127.0.0.1:45461
Tunnel: exposing local :8080 at https://app-claude-mendix-app-mxcli-setup-b0o6qv.mxcli.org (via proxy)
Preview available at https://app-claude-mendix-app-mxcli-setup-b0o6qv.mxcli.org
client: Connected (Latency 154.111263ms)
```

**Preview URL:** `https://app-claude-mendix-app-mxcli-setup-b0o6qv.mxcli.org`
(derived from the git branch name — `app-<branch>` — so it changes with the
branch).

**Verified:**

- `curl https://app-claude-...mxcli.org/` → **`302`** redirecting to
  `https://hub.mxcli.org/auth/github/login?return=…`. The hub gates previews
  behind a GitHub login, so an unauthenticated HTTP client will never see 200.
  Not a bug — just don't script a `200` assertion against the preview URL. A
  human opening it in a browser logs in with GitHub and gets the app.
- `curl http://localhost:8080/` → still `200` while the tunnel is up, so
  `--hub` does not change local serving (it implies `--local`).
- Round-trip latency through the tunnel was ~9.6 s for the first request
  (cold proxy + OAuth redirect); the tunnel itself reported 154 ms.

**Note on ports:** `--hub` implies `--local` and also binds `:8080`, so an
already-running `mxcli run --local` must be stopped first or the second run
collides. Nothing in the output warns about this in advance.

## 9. `mxcli lint` on a *blank* app reports 106 issues, ~96% of them un-actionable

`./mxcli lint -p App.mpr` on the freshly scaffolded project: **106 issues
(0 errors, 44 warnings, 62 info)**, exit code 0.

Breakdown by rule:

| Rule | Count | Notes |
| --- | --- | --- |
| `QUAL002` (no documentation) | 50 | almost all on `System.*` entities |
| `SEC001` (no access rules) | 38 | all on `System.*` entities |
| `CONV001` (boolean naming) | 8 | `System.*`, e.g. `BackgroundJob.Successful` → "should be `IsSuccessful`" |
| `DESIGN001` | 4 | |
| `MPR003`, `SEC006`, `QUAL004`, `CUSTOM002`, `CONV003`, `CONV008` | 1 each | |

**102 of the issue locations are in the built-in `System` module**, which a
developer cannot edit. Highlights of the noise:

- `⚠ Module 'System' has 38 persistent entities (max 15). Consider splitting
  into smaller modules. [MPR003]` → *"Split module 'System' into smaller
  modules"*. Not possible; `System` is Mendix-owned.
- `⚠ Persistent entity 'System.WorkflowGroup' has no access rules [SEC001]`
  (×38) with a `GRANT <Role> ON System.… ` suggestion.
- `ℹ Boolean attribute 'BackgroundJob.Successful' should start with Is, Has,
  Can…` — renaming a platform attribute is not an option.

Only **4 findings are about the developer's own code**, and all four are the
scaffolded template content, which is exactly what you'd want a linter to say:

- `MyFirstModule.User` module role maps to 2 user roles (`CONV008`)
- page `Home_Web` has no recognized suffix (`CONV003`)
- microflow `MyFirstLogic` lacks a standard prefix (`CUSTOM002`)
- microflow `MyFirstLogic` is never called (`QUAL004`)

**Suggested fix for mxcli:** exclude platform modules (`System`, and arguably
`Administration`/`Atlas_*`) from lint by default, or add a
`--skip-platform-modules` / `--modules <list>` filter. As it stands, the signal
is buried at a 25:1 ratio on an empty project, which trains you to ignore the
output. Verified by re-running lint and counting `at System.` occurrences
(102/106).

## 10. Misc / small stuff

- `mxcli new` runs `mxcli init` as its step 3, so the `mxcli init --tool claude`
  in the documented flow is a **no-op re-run** on a fresh `new`. It is
  idempotent and harmless (it re-emits `AGENTS.md`, updates `.devcontainer/`,
  re-adds the SessionStart hook, regenerates 42 widget docs), and it is a
  genuinely useful repair step after the finding-2/3 workaround.
- `mxcli init` commits a 205 KB `.claude/vscode-mdl.vsix` blob into the repo —
  it is *not* in the generated `.gitignore`. Left in place here (it is part of
  `.claude/`), but it is a regenerable build artifact and is probably ignore
  material.
- `.gitignore` correctly excludes the 88 MB `mxcli` binary, `.mxcli/`,
  `.claude/settings.local.json`, and `mprcontents/mprjournal*`.
- `theme-cache/web/theme.compiled.css` (~29 k lines) **is** committed — also a
  build artifact, also not ignored. Left as generated.
- Version caches (`/root/.mxcli/mxbuild/11.6.3`, `/root/.mxcli/runtime/11.6.3`)
  live outside the repo and do not survive container reaping. Expect a fresh
  session to re-download the 325 MB runtime via the SessionStart hook.
- All output is prefixed with `WARNING: This is a vibe-coded PoC, alpha quality,
  use with caution.` — noted so nobody mistakes it for a per-command warning.

## 11. The first build rewrites 51 scaffolded source files (dirties git)

Right after `mxcli new`, the first `mxbuild` run (triggered by
`mxcli run --local`) **modified 51 files that `mxcli new` had just created**:

- 49 × `javascriptsource/{datawidgets,nanoflowcommons,webactions}/actions/*.js`
- 2 × `javasource/feedbackmodule/actions/{ValidateEmail,XSS_Sanitizer}.java`

The change is a regeneration of the action stubs — the build prepends the
`// This file was generated by Mendix Studio Pro.` banner and reflows the
generated wrapper code that `mxcli new` had emitted without it. So the
scaffolder and the builder disagree about the canonical form of these files, and
the builder wins on first contact.

**Why it matters:** if you commit straight after `mxcli new` (the documented
order), your very first `mxcli run` leaves 51 unexplained modifications in
`git status`. That looks like the app was edited when nothing was, and it will
show up as churn in the first real diff.

**Verified stable after the first build:** the second build (the `--hub` run)
produced byte-identical files — `git status --porcelain` is empty with the
runtime up and both builds' output on disk. So this is a one-time
normalization, not per-build churn. Committed in the post-build state here, so
the next session starts from a clean tree.

**Suggested fix for mxcli:** have `new` emit the same stub form `mxbuild`
generates (or run one throwaway build as part of `new`) so a freshly scaffolded
project is already build-stable.

---

## Verification summary

| Step | Command | Result |
| --- | --- | --- |
| mxcli available | `./mxcli --version` | ✅ `nightly-20260805-4fda072f` (downloaded; not pre-installed — finding 1) |
| App created | `mxcli new App --version 11.6.3` | ✅ via temp-dir workaround (finding 2) |
| Claude tooling | `./mxcli init --tool claude` | ✅ hook + commands + lint rules present |
| Prereqs up | `./mxcli run --local --setup --ensure-db -p App.mpr` | ✅ MxBuild + runtime cached, Postgres up, db `app` created |
| Bootstrap hook | `bash .claude/bootstrap.sh` | ✅ idempotent; download URLs return HTTP 206 for linux-amd64 / linux-arm64 / darwin-arm64 |
| Local boot | `./mxcli run --local -p App.mpr` | ✅ HTTP **200** at `http://localhost:8080/` in ~19 s |
| Hub preview | `./mxcli run --hub https://hub.mxcli.org -p App.mpr` | ✅ tunnel up; preview URL 302s to GitHub OAuth (finding 8) |
| Lint | `./mxcli lint -p App.mpr` | ⚠️ exit 0, but 106 issues of which 102 are un-actionable `System.*` (finding 9) |
| Runtime log | `grep -icE "error|warn|exception" .mxcli/runtime.log` | ⚠️ 8 lines — all benign or self-inflicted (findings 7a, 7b) |
| Build stability | `git status --porcelain` after 2 builds | ✅ clean — but the *first* build rewrote 51 scaffolded files (finding 11) |

Committed and pushed to `claude/mendix-app-mxcli-setup-b0o6qv`.
