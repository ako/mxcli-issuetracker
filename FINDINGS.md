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
