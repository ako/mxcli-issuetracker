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

## 2. ~~`mxcli new` refuses to scaffold into a non-empty directory~~ — RETRACTED, my error

**Originally filed as an mxcli defect. It is not one.** Keeping the entry so the
next session does not re-derive the same wrong conclusion.

What happened: I read "create the app at the repo root" as "the app's *contents*
sit directly in the repo root", forced `--output-dir .`, and got

```
Error: directory /home/user/mxcli-issuetracker already exists and is not empty
```

I then built a temp-dir-and-move workaround around it. **The guard is correct**
— it stops you clobbering an existing project — and it was never in the way:
`mxcli new App --version 11.6.3` with **no** `--output-dir`, run from the repo
root, creates `./App/` and exits cleanly. That is also the layout you want,
because a repo may hold several apps side by side and each needs its own folder.

**Corrected layout** (see finding 12): the Mendix app lives in `App/`, shared
tooling stays at the repo root. No workaround, no `sed` fixes, no temp dir.

**Lesson for the next session:** if an mxcli command refuses something, check
whether the *default* behaviour already does what you want before working around
the guard.

## 3. ~~Project name is derived from the output directory's basename~~ — VOID

This only existed because of the finding-2 temp dir: `CLAUDE.md`, `AGENTS.md`
and `.devcontainer/devcontainer.json` were stamped with `mxcli-new-tmp`. With the
correct `mxcli new App` invocation the basename is `App` and the name is right,
so there is nothing here to report.

Still true and worth knowing: the app name argument (which determines
`App.mpr`) and the display name in the generated docs/devcontainer come from
**different** sources — the argument vs. the output directory's basename.

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

## 12. Multi-app layout: mxcli's generated tooling assumes a single app at the repo root

The repo is laid out for **one folder per app**, which is what `mxcli new <Name>`
produces by default and what a multi-app solution needs:

```
mxcli-issuetracker/
├── App/                 # the Mendix app: App.mpr, mprcontents/, javasource/, ...
│   └── App.mpr
├── .claude/             # shared: SessionStart hook, commands, lint rules
├── .devcontainer/       # shared
├── .ai-context/         # shared MDL skill docs
├── AGENTS.md CLAUDE.md  # shared agent entry docs
├── FINDINGS.md
└── mxcli                # shared binary (gitignored)
```

Three things had to be adjusted, because `mxcli init` generates tooling on the
assumption that exactly one `.mpr` sits directly in the repo root:

**a) `.gitignore` was root-anchored and silently stopped working.** mxcli emits
`/deployment/`, `/javasource/system/`, `/javasource/*/proxies/`,
`/mprcontents/mprjournal*`, `/.classpath`, `/*.launch`, etc. — all with a leading
`/`, so they only match at the repo root. Once the app moved to `App/`, **none of
those matched any more** and build artifacts inside `App/` would have been
committed. De-anchored them (dropped the leading `/`) so they match at any depth;
kept `/mxcli` anchored, since that one genuinely is a root-only file.
This is the sharpest of the three: it fails *silently* and in the direction of
committing junk.

**b) The SessionStart hook hardcoded `-p App.mpr`.** Rewrote
`.claude/bootstrap.sh` to discover apps (`for mpr in */*.mpr *.mpr`) and warm each
one, so adding a second app needs no edit to the hook. Each app gets its own
database, since mxcli derives the db name from the project name.

**c) `CLAUDE.md` / `AGENTS.md` hardcode `-p App.mpr` in 19 places each.**
Rewritten to `-p App/App.mpr`, plus a layout note at the top of each. **These two
files are regenerated by `mxcli init`, which will reset the paths back to
`-p App.mpr`** — the note says so, so a future session re-running `init` knows to
re-apply the prefix.

**Where the shared tooling lives, and why not inside `App/`:** Claude Code reads
project settings from `.claude/settings.json` at the session's working directory —
the repo root. A hook at `App/.claude/settings.json` would not fire, which would
defeat the whole self-bootstrap goal. Keeping `.claude/` at the root works
regardless, and is also the right home for it once there are several apps: one
hook warms them all.

**Suggested fixes for mxcli:**
- Emit `.gitignore` patterns un-anchored (or anchored to the app folder) so they
  survive the app not being at the repo root.
- Have `init` detect existing `.mpr` files anywhere in the tree and generate a
  hook that iterates them, rather than hardcoding one root-level path.
- Support a repo with N apps as a first-class layout: `init` at the root for
  shared tooling, `new <Name>` per app.

**Verified:** `bash .claude/bootstrap.sh` discovers and warms `App/App.mpr`, and
`./mxcli run --local -p App/App.mpr` boots to HTTP 200 (see the summary table).

## 13. A microflow datasource's argument parses but is never persisted (CE1571)

**The single most disruptive bug found.** A user task page receives one
parameter, `$Task: System.WorkflowUserTask`, so the natural way to show the
issue under handling is a microflow datasource taking the task:

```mdl
dataview dvIssue (datasource: microflow IssueTracker.SUB_Issue_FromTask(Task: $Task)) { ... }
```

Three forms were tried. Only one parses:

| Form | `mxcli check` |
| --- | --- |
| `microflow M.F($Task)` | parse error — `mismatched input ')' expecting '='` |
| `microflow M.F(Task: $Task)` | **passes** |
| `microflow M.F(Task = $Task)` | parse error — `expecting ':'` |

But the form that parses is **silently dropped on write**. `mx check` then fails:

```
[error] [CE1571] "No argument has been selected for parameter 'Task' and no
default is available. Please select an argument manually." at Data view 'dvIssue'
```

Verified by dumping the written page — the datasource has the microflow but no
argument mapping. The parameterless form (`datasource: microflow M.F`) fails the
same way, because Mendix does not auto-map page parameters into a microflow
datasource.

**Workaround used:** reach the issue with a **database datasource + XPath
constraint** back through the task's workflow, which does persist correctly:

```mdl
datagrid dgIssue (
  datasource: database from IssueTracker.Issue
    where [IssueTracker.Issue_Workflow = $Task/System.WorkflowUserTask_Workflow]
)
```

That is why `IssueTracker.Issue_Workflow` (Issue → System.Workflow) exists at
all: `ACT_Issue_StartWorkflow` sets it so task pages can navigate back.

**Suggested fix:** persist the parsed `(Param: $value)` mapping, and reject the
argumentless form at check time instead of letting it reach MxBuild.

## 14. A nested reverse association path into a custom module writes a *corrupt* .mpr

Worse than a build error — this one made the project **unloadable**:

```mdl
dataview dvWf (datasource: $Task/System.WorkflowUserTask_Workflow) {
  gallery galIssue (datasource: $currentObject/IssueTracker.Issue_Workflow) { ... }
}
```

`mx check` could not even parse the model afterwards:

```
ERROR: System.InvalidOperationException: An error occurred when trying to set the
'DestinationEntity' property of a Entity ref step in a Page with ID e2d2167e-…
 ---> System.ArgumentNullException: Value cannot be null. (Parameter 'value')
```

Not a validation error — a **load** failure. Studio Pro would not open the
project either. `mxcli` itself still read the file (it has its own reader), which
is what made recovery possible: `drop page` on the offending page restored a
loadable model.

**Isolated by bisection** — the trigger is specifically the *nested reverse*
step, from a System entity back into a custom module:

| Datasource | Result |
| --- | --- |
| `$Issue/IssueTracker.Comment_Issue` (same module, reverse) | ✅ 0 errors |
| `$Task/System.WorkflowUserTask_Workflow` (forward into System) | ✅ 0 errors |
| the two nested, System → custom module reverse | ❌ **.mpr unloadable** |

**Suggested fix:** resolve `DestinationEntity` for a reverse cross-module ref
step, or refuse to write the page. Emitting a structurally invalid unit is the
worst possible failure mode — it takes the whole project down, not one page.

**Lesson:** run `mx check` after every page batch, not at the end. And keep the
MDL in files under git — replaying `mdl/*.mdl` was the recovery plan.

## 15. `annotation` in a workflow body makes the model unloadable

The workflow skill documents a sticky-note annotation activity:

```mdl
annotation 'Escalation path per policy 4.2';
```

It passes `mxcli check` and executes, but the model then cannot be loaded:

```
ERROR: System.InvalidOperationException: Type Mendix.Modeler.Workflows.Model.Annotation
does not contain a constructor with a parameter of type Mendix.Modeler.Workflows.Model.Flow.
```

mxcli places the Annotation in the activity flow, where Mendix expects a Flow
element. Same severity as finding 14 — recovery was `create or replace workflow`
without the annotations, then re-running the phase that binds to it.

## 16. `jump to <Task>` writes a comment instead of a target (CE6680 + CE0495)

The documented loop construct does not build. `jump to Triage;` round-trips as:

```mdl
jump to Triage comment 'Triage';
```

— the target ends up as the activity's *comment*, the `Target` property is left
unset, and the Jump activity is *named* after its target, colliding with the
user task of that name:

```
[error] [CE6680] "The 'Target' property is required." at Jump 'Triage'
[error] [CE0495] "Duplicate name 'Triage'." at User task 'Triage the issue', Jump 'Triage'
```

This also kills interrupting timer boundary events, because
`CE6665 "Interrupting timer boundary event must end with a jump or end activity"`
demands a jump that cannot be written.

**Workaround used:** the NeedsInfo and Reopen loops are implemented in the
outcome-handler microflows (`ACT_Task_WorkBlock`, `ACT_Task_VerifyReopen`), which
clear `Issue_Workflow` and call `ACT_Issue_StartWorkflow` to begin a fresh
instance. Same user-visible behaviour — the issue goes back round — without an
unbuildable Jump.

## 17. `decision '<expression>'` yields CE0117; and the context variable is renamed

`write-workflows.md` documents an expression-form decision:

```mdl
decision '$workflowContext/Priority = IssueTracker.IssuePriority.Critical'
  outcomes true -> { … } false -> { … };
```

It parses and executes, but builds as `CE0117 "Error(s) in expression."` The
`mxcli syntax workflow.decision` registry shows a *different* shape
(`DECISION ['<caption>'] OUTCOMES '<outcome>' { … }`), so the grammar accepts one
form while the writer/registry expect another.

Related, and useful: `DESCRIBE WORKFLOW` reveals that mxcli **renames the context
parameter**. Declaring `parameter $Context: IssueTracker.Issue` stores
`parameter $WorkflowContext: …` and call mappings become `'$WorkflowContext'`.
The literal `'$workflowContext'` in a `call microflow … with (…)` mapping *does*
build correctly — only the decision expression fails.

**Workaround used:** dropped the decision node; the critical-priority escalation
now happens inside `SUB_Issue_SetTriaged`, which is arguably where that policy
belongs anyway.

## 18. A token in an XPath constraint loses its quotes as soon as `and` is added

Mendix requires tokens quoted in XPath: `'[%CurrentUser%]'`. mxcli gets this
right for a lone condition and **wrong** the moment the constraint is compound.
Dumped from the written .mpr:

| MDL constraint | Written XPath | Build |
| --- | --- | --- |
| `where DueDate < [%CurrentDateTime%]` | `[DueDate < '[%CurrentDateTime%]']` | ✅ |
| `where Issue_Assignee = [%CurrentUser%]` | `[… = '[%CurrentUser%]']` | ✅ |
| `where DueDate < [%CurrentDateTime%] and Status != …` | `[DueDate < [%CurrentDateTime%] and Status != 'Closed']` | ❌ CE0161 |
| `where Issue_Assignee = [%CurrentUser%] and Status != …` | `[… = [%CurrentUser%] and Status != 'Closed']` | ❌ CE0161 |

Note the enum is converted correctly (`Status != 'Closed'`) in both cases — only
the token quoting breaks.

**Workaround used:** write the quotes yourself in the MDL. `where DueDate <
'[%CurrentDateTime%]' and …` passes them through verbatim and builds. Both
dashboard datasources do this, with a comment saying why.

**Also found here:** a negative numeric literal inside an XPath constraint is
**truncated**. `addDays([%CurrentDateTime%], -7)` was written as
`addDays('[%CurrentDateTime%]', -)` — the `7` silently vanished. And a microflow
*variable* is written unquoted (`ResolvedOn > $ResolvedSince`), which is also
CE0161. Both were avoided by choosing a metric that needs neither.

**How these were pinned down:** `mx check` names only one erroring activity per
document, and its text does not say which retrieve. `mx check -j <file>` emits
JSON with `document-name` per error, which narrowed it to the two datasource
microflows; then eight one-constraint probe microflows plus `mxcli bson dump`
gave the exact written XPath. Worth knowing — the JSON mode is much more useful
than the console output.

## 19. Page widgets cannot bind an attribute through an association into System

`Issue_Assignee/Name` (Issue → System.User) is accepted by `mxcli check` and then
fails the build:

```
[error] [CE1613] "The selected attribute 'IssueTracker.Issue.Issue_Assignee/Name'
no longer exists." at Columns (7/12) of data grid 2 'dgIssues'
```

Same-module paths are fine — `Issue_Project/Code` and
`$currentObject/IssueTracker.Comment_Issue` both build. Neither alternative path
form even parses: `IssueTracker.Issue_Assignee/Name` (module-qualified) and
`Issue_Assignee/System.User/Name` (via target) are both rejected by the grammar.

**Workaround used:** denormalised `Issue.AssigneeName`, `Issue.ReporterName` and
`Comment.AuthorName` string attributes, populated by `SUB_CurrentUserName` (which
resolves the user with the documented `where id = '[%CurrentUser%]'` lookup). The
associations remain for logic and XPath, where they work fine.

**Two neighbouring quirks in the same area:**

* **Comboboxes want the opposite convention.** `Association: Issue_Assignee`
  resolves to the wrong module (`System.Issue_Assignee` → CE1613); the
  **module-qualified** `Association: IssueTracker.Issue_Assignee` builds. So
  column attribute paths must be bare and combobox associations must be
  qualified — inverted rules for the same association.
* **Auto system members are lowercase in page bindings.** An attribute declared
  `CreatedDate: autocreateddate` is bound in a page as `createdDate` /
  `changedDate`. Binding `CreatedDate` fails CE1613. Microflows, by contrast, use
  the declared `CreatedDate` and work.

## 20. Entity access rules cannot be completed in MDL for most real entities (CE0066)

Mendix requires every member of an entity to appear in each access rule. mxcli's
`GRANT` validator does not recognise two kinds of member that Mendix counts:

```
Error: entity IssueTracker.Issue has no member(s) changedDate, createdDate;
       grant only names members of the entity or of an entity it inherits from
Error: entity IssueTracker.Label has no member(s) Issue_Label; …
```

* the system members from `autocreateddate` / `autochangeddate` — this rules out
  `Issue`, `Comment` and `Project`
* the **non-owning side of an `owner both` reference set** — `Issue_Label` is a
  member of `Label` as far as Mendix is concerned, but not as far as GRANT is

`read *` does not cover them either: it is expanded to an explicit member list at
grant time, and the system members are simply absent from it. A *partial* rule is
worse than none — it fails the build:

```
[error] [CE0066] "Entity access is out of date. Please update security by clicking
the 'Update security' button in the domain model editor."
  at Domain model of module 'IssueTracker'
```

Granting nothing builds cleanly, so entity rules are declared for
`DashboardStats` only (no auto members, no associations). Module roles, **page**
access and **microflow** access are unaffected and fully modelled — 36 grants.

**Suggested fix:** teach the GRANT validator about system members and both-owner
reference sets; ideally let `read *` / `write *` mean "all members including
system ones" so a rule stays complete when the domain model changes.

## 21. Reserved words: what actually bites, and what does not

Verified in this build (`nightly-20260805`):

| Where | Reserved | Symptom / fix |
| --- | --- | --- |
| Enumeration **value** | `New` | Caught at check time as MDL010. Renamed to `Reported 'New'` — the *caption* can still read "New" |
| GRANT **member list** | `Title`, `Description`, `Body` | Hard parse error: `mismatched input 'Title' expecting {IDENTIFIER, QUOTED_IDENTIFIER}`. Fix by quoting: `write ("Title", "Description", …)` |

The grant-member case is the surprising one — these are ordinary attribute names,
and nothing warns you that a member list is parsed where they are keywords.

**Correction to a widely-repeated claim.** `create-page.md` warns that
`column Status (attribute: Status)` "fails silently" and that the attribute value
must be quoted. That is **only about the reserved word used as the column
*widget name*** — the attribute *value* is fine unquoted. Probed directly:

```mdl
column cUnquotedTitle  (attribute: Title,  caption: 'unquoted Title')
column cUnquotedStatus (attribute: Status, caption: 'unquoted Status')
```

round-trips as `column "Title" (Attribute: Title, …)` / `column "Status"
(Attribute: Status, …)` — stored correctly, and the page builds and renders. So
the rule is: **use a `col`-prefixed widget name** (which is good practice anyway)
and the attribute value needs no quoting. This project quotes them regardless,
which is harmless.

I initially misdiagnosed an empty Title column as this reserved-word problem and
"fixed" it by quoting. The real cause was finding 23.

## 22. `Size` on a datagrid column is a relative weight, not a pixel width

The page skill documents `ColumnWidth: manual` + `Size: <integer (px)>`. It does
not behave like pixels. With five columns configured
`Size: 60 / (autofill) / 100 / 110 / 80` in a 734px-wide grid, the rendered
header widths were:

| Column | Configured | Rendered |
| --- | --- | --- |
| `#` | `manual, Size: 60` | **113px** |
| `Title` | autofill (no Size) | **20px** — collapsed |
| `Priority` | `manual, Size: 100` | **189px** |
| `Due` | `manual, Size: 110` | **207px** |
| actions | `manual, Size: 80` | **151px** |

The manual widths came out at ~1.88× their configured value — i.e. `Size` was
distributed as a **weight** across the available width — and the one autofill
column was squeezed to nothing. The visible symptom was a data grid with no
Title column at all, which is what sent me chasing reserved words (finding 22).

**Workaround used:** treat `Size` as a weight and give the wrapping text columns a
dominant one — `caption: 'Title', WrapText: true, ColumnWidth: manual, Size: 320`
— rather than leaving any column on autofill next to manual siblings.

**Measured with** `getBoundingClientRect().width` on each `[role="columnheader"]`
in a headless Chromium against the running app. This is not visible from `mx
check` or `describe page`; the model was correct all along.

**Also here:** `caption: ''` on a column does not render an empty header — it
falls back to the **widget name**, so the action columns showed `COLMINEACT` /
`COLESCACT` as headers. Use `caption: ' '` (a single space).

## 24. With security off, `[%CurrentUser%]` is a throwaway anonymous account

Not an mxcli bug, but it bit the demo data and would bite anyone building this way.

The project's security level is left as generated, so every visit is served as a
**fresh anonymous `System.User`**. Two consequences:

* `SUB_CurrentUserName` returns something like
  `Anonymous_29f9b7f8-2075-4042-a925-77…`, which is what the assignee column
  showed until the seed was changed to write real display names.
* Anonymous accounts are **session-scoped**. When the session that seeded the
  data goes away, the rows it wrote survive but every `Issue_Assignee` reference
  pointing at that account is **nulled**. Verified in Postgres: after a restart,
  `issuetracker$issue_assignee` was NULL on all 12 rows and the dashboard's
  Unassigned KPI jumped from 6 to 11 while "My queue" went empty.

**Handled in `ACT_DemoData_Seed`:** when data already exists it no longer just
returns — it re-points any issue that has an `AssigneeName` but a null
`Issue_Assignee` at whoever is looking now. Verified: `named_but_unlinked = 0`
after a restart, and the KPI is back to 6.

**Also worth knowing:** seeding issues does not start workflows. Creating an
`Issue` row is not the same as putting it under workflow control —
`ACT_Issue_StartWorkflow` has to be called explicitly, which is why the seed now
starts instances for the three freshly-reported issues. Before that, the workflow
monitor and every task page were empty even though the workflow was correctly
modelled, which reads like a broken workflow when it is just missing data.

## 23. Things that worked first try (worth knowing, to keep the list above in perspective)

Not everything fought back. These all built with 0 errors on the first attempt:

* the whole domain model — 5 entities, 3 enumerations, 6 associations, indexes,
  `autonumber default 1`, cascade delete, `owner both` reference set
* `call workflow M.WF (Context = $Issue)` **inside a microflow** — this is how a
  workflow gets started, and it is not in the `mxcli syntax microflow` topic list
  at all (only under `workflow.call-workflow`, described as a sub-workflow call).
  Found by probing; builds cleanly.
* `set task outcome $Task 'Accept'` for completing a user task from a page button
* user tasks with named outcome branches, `boundary event` aside
* `create or modify page` genuinely preserving IDs — the stub-then-fill pattern
  for circular page ↔ microflow references worked exactly as documented
* `alter entity … add event handler on before commit … raise error` — binding
  validation without touching Studio Pro
* `validation feedback $Obj/Attr message '…'`
* MDL lint catching real bugs *before* the build: MDL047 (`= empty` on an
  association), MDL044 (`count()` in an expression), MDL010 (reserved enum value),
  MPR010 (dataview not in a layoutgrid). This is the best part of the toolchain.

---

## Verification summary

| Step | Command | Result |
| --- | --- | --- |
| mxcli available | `./mxcli --version` | ✅ `nightly-20260805-4fda072f` (downloaded; not pre-installed — finding 1) |
| App created | `mxcli new App --version 11.6.3` | ✅ at `App/App.mpr` — one folder per app (findings 2, 12) |
| Claude tooling | `./mxcli init --tool claude` | ✅ hook + commands + lint rules present |
| Prereqs up | `./mxcli run --local --setup --ensure-db -p App/App.mpr` | ✅ MxBuild + runtime cached, Postgres up, db `app` created |
| Bootstrap hook | `bash .claude/bootstrap.sh` | ✅ idempotent; discovers `App/App.mpr` via `*/*.mpr`; download URLs return HTTP 206 for linux-amd64 / linux-arm64 / darwin-arm64 |
| Local boot | `./mxcli run --local -p App/App.mpr` | ✅ HTTP **200** at `http://localhost:8080/` (~19 s root layout, ~38 s re-verified after the move) |
| Hub preview | `./mxcli run --hub https://hub.mxcli.org -p App.mpr` | ✅ tunnel up; preview URL 302s to GitHub OAuth (finding 8) — verified pre-move |
| Lint | `./mxcli lint -p App.mpr` (pre-move) | ⚠️ exit 0, but 106 issues of which 102 are un-actionable `System.*` (finding 9) |
| Runtime log | `grep -icE "error|warn|exception" .mxcli/runtime.log` | ⚠️ 8 lines — all benign or self-inflicted (findings 7a, 7b) |
| Build stability | `git status --porcelain` after 2 builds | ✅ clean — but the *first* build rewrote 51 scaffolded files (finding 11) |
| Ignore rules under `App/` | `git check-ignore` on 6 generated artifacts | ✅ all ignored after de-anchoring `.gitignore` (finding 12a) |

## 25. Half-dark theming: my own bug, and why Atlas makes it easy to hit

**Reported by the user from a real browser**, not caught by any check: with the OS
in dark mode the app rendered dark KPI tiles and card headers around **white grid
rows with pale, near-unreadable text**.

Cause was mine. `_issuetracker.scss` carried a `@media (prefers-color-scheme: dark)`
block that repainted the `it-` tokens. Two things make that wrong in Atlas:

* **Atlas's dark theme is opt-in by class, not by media query.** The generated
  `theme/web/_theme-dark.scss` is scoped to `:root.theme-dark`. Nothing in Atlas
  listens to `prefers-color-scheme`, so the media query moved *only* my surfaces
  and left every Atlas widget in light mode.
* **Atlas widgets and the pluggable DataGrid2 ship light-only surfaces.** Grid rows
  stay white however dark the page shell gets.

`.ai-context/skills/atlas-design.md` warns about exactly this — *"A half-dark
result (your chrome dark, Atlas widgets light) is worse than a consistent light
app"* — and I wrote the media query anyway.

**Fixed by committing to light-only:** the dark token block is gone, replaced by a
comment explaining what going dark would actually require (root class + every
Atlas widget surface overridden unconditionally, including popovers and modals
which render at `<body>` outside any app-scoped class).

**Verified** by driving the app twice in headless Chromium with
`newContext({ colorScheme })` and reading computed styles:

| `colorScheme` | page bg | card bg | text | row-text contrast |
| --- | --- | --- | --- | --- |
| `dark` | `rgb(245,246,248)` | `rgb(255,255,255)` | `rgb(28,32,36)` | **16.39:1** |
| `light` | `rgb(245,246,248)` | `rgb(255,255,255)` | `rgb(28,32,36)` | **16.39:1** |

Identical in both, and far above WCAG AA's 4.5:1 for body text. No JS console
errors in either pass.

**Lesson worth carrying:** a screenshot taken in the default (light) color scheme
proves nothing about the dark case. `colorScheme: 'dark'` is one Playwright option
and it would have caught this before the user did.

## 26. A nullable DateTime in a dynamic-class expression takes the whole grid down

**Reported by the user as "the app stopped".** It had not — the server was serving
HTTP 200 the whole time. The *Issues board* was throwing a client-side error, which
Mendix surfaces as a dead-looking page.

The runtime log had it exactly:

```
ERROR - Client: An error occurred while evaluating value of
IssueTracker.Issue_Overview.dgIssues:
Operator < not supported in expression <(, Thu Aug 06 2026 05:29:49 …)
```

The culprit was my own `DynamicCellClass` on the Due column:

```mdl
DynamicCellClass: 'if $currentObject/DueDate < [%CurrentDateTime%] then ''it-cell-overdue'' else '''''
```

`DueDate` is nullable, and 6 of the 12 seeded issues have none. Feeding empty into
`<` raises "Operator < not supported" — note the rendered expression `<(, <date>)`
with an empty left operand — and it fires per row, so the grid never renders.

**Fixed with a nested guard rather than `and`,** so the comparison is unreachable
when the value is empty and nothing depends on short-circuit evaluation:

```mdl
DynamicCellClass: 'if $currentObject/DueDate = empty then '''' else if $currentObject/DueDate < [%CurrentDateTime%] then ''it-cell-overdue'' else '''''
```

The other four dynamic-class expressions compare **enumerations**, which are never
empty, so they were never at risk.

**Why my verification missed it.** The earlier driver only reliably reached the
dashboard — its Issues-link click silently did nothing, and I read the absence of a
`board rows:` line as noise instead of as a page never visited. Neither `mxcli
check` nor `mx check` can catch this: the expression is valid MDL and a valid
Mendix expression; it only fails on data.

**Verification now covers it**, and this is the shape worth keeping:

* navigate by **URL** to every page (`/p/dashboard`, `/p/issues`, `/p/projects`,
  `/p/labels`, `/p/workflows`, plus detail via the board), never by clicking links
  that may silently fail
* assert per page: grid rows rendered, **0** `pageerror`/console errors, **0**
  error dialogs in the DOM
* diff the **runtime log** against a line-count baseline taken before boot and
  fail on any new `ERROR - Client:` line — the server-side record of client
  failures, which is what actually found this
* run it all under `colorScheme: 'dark'` so finding 25 cannot regress

Result after the fix: `dashboard 14 rows · issues 13 · projects 4 · labels 7 ·
workflows 8 · detail ok` — all with 0 JS errors, 0 alerts, and **0 new
`ERROR - Client` lines** in the runtime log.

**Lesson:** "the app renders" is not the same as "every page renders", and demo
data with nulls in it is what exposes the difference. Seed nullable fields as
empty on purpose — 6 of these 12 issues having no due date is what caught this.

---

## Issue Tracker build — what shipped

| Layer | Contents |
| --- | --- |
| Domain model | `Issue`, `Comment`, `Project`, `Label` (persistent) + `DashboardStats` (non-persistent); 3 enumerations; 7 associations incl. a cascade delete and an `owner both` reference set; 2 indexes |
| Logic | 21 microflows — 2 datasources, 6 task-outcome handlers, 4 workflow-step helpers, 5 lifecycle actions, 1 before-commit validation, 1 demo seed, 2 helpers |
| Workflow | `WF_IssueHandling` over `Issue`: Triage → Work → Verify, branching outcomes, loops via handler-driven restart |
| Pages | 12 — dashboard, issue board, issue detail, issue form, comment pop-up, 3 workflow task pages, workflow monitor, project + label admin |
| Security | 2 module roles mapped to the app's user roles, 36 grants (pages + microflows + DashboardStats) |
| Theme | `theme/web/_issuetracker.scss` — KPI tiles, dense grid tuning, status/priority cell tints, light + dark tokens; `--brand-primary` retuned |
| Reproducibility | 8 numbered scripts in `mdl/`, replayable in order |

**End-to-end verification** (headless Chromium against the running app):

| Check | Result |
| --- | --- |
| `mx check` | ✅ **0 errors** |
| App boots | ✅ HTTP 200 at `localhost:8080` |
| Dashboard renders | ✅ 8 KPI tiles, 3 grids, 0 JS console errors |
| KPI arithmetic | ✅ Open 11, Critical 2, Overdue 3, In progress 2, Unassigned 5, Awaiting verification 1, Closed 1, Reopened 1 — each cross-checked against SQL |
| Demo seed | ✅ 3 projects, 6 labels, 12 issues, 4 comments |
| Workflow instances | ✅ 3 started, each on an open `Triage the issue` task (verified in `system$workflowusertask`) |
| Issue detail | ✅ description, resolution, activity feed, fact list, labels all bound |
| Assignee re-pointing | ✅ `named_but_unlinked = 0` after restart (finding 24) |

Committed and pushed to `claude/mendix-app-mxcli-setup-b0o6qv`.
