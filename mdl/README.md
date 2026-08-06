# MDL sources

The Issue Tracker's model as executable MDL. `App/App.mpr` is the build output of
these scripts — treat these files as the source of truth and re-run them rather
than hand-editing the `.mpr`.

## Replay order

MDL executes statement by statement and resolves every reference **immediately**,
so the order matters. Run them from the repo root:

```bash
for f in mdl/0*.mdl; do ./mxcli exec "$f" -p App/App.mpr; done
```

| # | File | Contains | Why here |
| --- | --- | --- | --- |
| 01 | `01-domain-model.mdl` | module, 3 enumerations, 5 entities, 6 associations, indexes | nothing depends on anything else |
| 02 | `02-page-stubs.mdl` | minimal versions of the 6 pages that microflows and the workflow bind to | breaks the page ↔ microflow reference cycle |
| 03 | `03-logic-core.mdl` | datasources, helpers, workflow-step helpers, lifecycle actions, validation | needs the stubs (01 + 02); does **not** touch the workflow |
| 04 | `04-workflow.mdl` | `WF_IssueHandling` | needs the task pages (02) and the step helpers (03) |
| 05 | `05-logic-workflow.mdl` | `ACT_Issue_StartWorkflow`, `ACT_Issue_Save`, the 6 task-outcome handlers, the demo seed | all reference the workflow document, so must follow 04 |
| 06 | `06-pages.mdl` | the real pages, filling the stubs with `CREATE OR MODIFY` | needs every microflow to exist |
| 07 | `07-task-pages.mdl` | the 3 workflow task pages, filling their stubs | needs the task-outcome handlers (05) |
| 08 | `08-navigation-security.mdl` | module roles, grants, navigation, before-commit event handler | needs every page and microflow |

## Two rules that are easy to break

**Fill a stub with `CREATE OR MODIFY`, never `CREATE OR REPLACE`.** `OR REPLACE`
drops the document and creates a new one with a fresh ID, so every microflow and
workflow binding pointing at the stub silently becomes dangling. `OR MODIFY`
preserves the ID.

**Re-run `mx check` after each phase, not at the end.** Some mxcli writes produce
a structurally invalid `.mpr` that Mendix cannot even load (see FINDINGS findings
14 and 15). Catching that against one phase is a `drop page`; catching it at the
end means bisecting.

```bash
/root/.mxcli/mxbuild/11.6.3/modeler/mx check App/App.mpr
/root/.mxcli/mxbuild/11.6.3/modeler/mx check App/App.mpr -j /tmp/check.json  # per-error locations
```

The JSON form is considerably more useful — the console output names the erroring
activity but not the document it lives in.

## Replaying into a project that already has the module

`08-navigation-security.mdl` starts by dropping its two module roles, because
`create module role` has no `OR REPLACE` form. On a fresh module those drops fail
harmlessly (exec stops on error, so comment them out for a first run into a clean
module — or run 08 twice). Everything else uses `CREATE OR REPLACE` /
`CREATE OR MODIFY` and is safe to re-run.
