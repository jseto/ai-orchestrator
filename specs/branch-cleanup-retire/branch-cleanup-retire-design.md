# Design: branch cleanup on subsession retirement

## Summary

`scripts/sub-retire.sh` currently kills the tmux session, force-returns the
worktree, and removes scratch files — but never touches branch refs, so merged
local and remote `task/<task>` branches accumulate forever. This change adds a
best-effort, post-retirement cleanup step to `sub-retire.sh`, documents it in
`AGENTS.md` step 6, and flips the GitHub repo setting
`delete_branch_on_merge` to `true`.

## Entities

- **`scripts/sub-retire.sh`** (modified)
  - captures the worktree's current branch (`BRANCH`) *before*
    `treehouse return --force` detaches the worktree HEAD;
  - new flag `--no-branch-cleanup` (default: cleanup ON);
  - new function `cleanup_branches <branch>`, called once, only after the
    retirement (tmux kill + treehouse return + scratch removal) has succeeded;
  - new helper `pr_state <branch>` → `merged | open | none | unknown`
    (wraps `gh pr list --state <merged|open> --head <branch>`; any `gh`
    failure degrades to `unknown`, never an error).
- **`AGENTS.md`** (modified): step 6 gains two lines describing the automatic
  cleanup, when it is skipped, and the opt-out flag.
- **`specs/branch-cleanup-retire/`** (new): `branch-cleanup-retire.feature`
  (the requirements) and this design doc.
- **`tests/sub-retire.test.sh`** (new): self-contained bash test harness —
  sandboxes a fake `origin` (bare repo), a main checkout, a linked task
  worktree, and stub `treehouse` / `tmux` / `gh` binaries on `PATH`.
  Includes the shellcheck check for `sub-retire.sh`.
- **GitHub repo setting**: `PATCH repos/jseto/ai-orchestrator
  -f delete_branch_on_merge=true` (run once; verified with a GET).

`_sub-common.sh`, `sub-land.sh`, `sub-spawn.sh`, `sub-clean.sh` are **not**
touched.

## Behaviour and data flow

```mermaid
flowchart TD
    A[sub-retire.sh task] --> B{dirty / unpublished?}
    B -- yes, no --force --> C[refuse, exit 1<br/>branches untouched REQ-8]
    B -- no --> D[kill tmux session]
    D --> E[treehouse return --force<br/>worktree HEAD detached]
    E --> F[remove scratch files]
    F --> G{--no-branch-cleanup?}
    G -- yes --> Z[done REQ-7]
    G -- no --> H[cleanup_branches BRANCH<br/>best-effort REQ-6]
    H --> I{local branch merged<br/>into DEV_BRANCH?}
    I -- yes --> I2["git branch -d<br/>(never -D) REQ-1"]
    I -- no --> I3[warn + keep REQ-2]
    H --> J{remote ref exists?}
    J -- no --> Z
    J -- yes --> K{pr_state?}
    K -- merged --> L["git push --delete origin<br/>REQ-3"]
    K -- open --> M[note + keep REQ-4]
    K -- none / unknown --> N{merged into<br/>origin/DEV_BRANCH?}
    N -- yes --> L2["git push --delete origin REQ-5"]
    N -- no --> O[note + keep REQ-4]
    L & L2 --> P{push failed?}
    P -- yes --> Q[warn, exit stays 0 REQ-6]
    P -- no --> R[info deleted]
```

Key decisions:

1. **Ordering** — cleanup runs strictly after the retirement steps, so a
   refused retirement (`exit 1`) can never delete a branch (REQ-8).
2. **`branch -d`, never `-D`** — the local deletion is gated on an explicit
   `git merge-base --is-ancestor <branch> <DEV_BRANCH>` check, and executed
   with `git branch -d` as a second line of defence (REQ-1/REQ-2).
   `treehouse return --force` detaches the worktree HEAD, so the branch is
   no longer checked out and `-d` can succeed; if it still fails, a warning
   is printed and the script continues.
3. **Remote deletion gate** — delete only when (a) `gh pr list --state merged
   --head <branch>` is non-empty, or (b) there is no *open* PR for the branch
   and `origin/<branch>` is an ancestor of `origin/<DEV_BRANCH>`. An open PR
   always keeps the branch (REQ-3/REQ-4/REQ-5). `gh` missing/failing yields
   `unknown`, which falls through to the merge-base gate.
4. **Non-fatal everywhere** — every deletion is inside an `if`/`||` guard
   under `set -euo pipefail`; failures print `warn` and execution continues
   to the final `retired task` line with exit 0 (REQ-6).
5. **Branch captured early** — `BRANCH=$(git -C "$WT" branch --show-current)`
   is read once, before `treehouse return`, and reused by the safety check
   and the cleanup. Cleanup only acts on `task/*` branches and never on
   `$DEV_BRANCH`.

## Files / modules changed

| File | Change |
|---|---|
| `scripts/sub-retire.sh` | `--no-branch-cleanup` flag, `BRANCH` capture, `pr_state()`, `cleanup_branches()` |
| `AGENTS.md` | step 6: document automatic cleanup, skip conditions, flag |
| `specs/branch-cleanup-retire/*.feature` | new — requirements |
| `specs/branch-cleanup-retire/branch-cleanup-retire-design.md` | new — this doc |
| `tests/sub-retire.test.sh` | new — behavioural tests + shellcheck check |
| GitHub repo setting | `delete_branch_on_merge` false → true |

## Test plan (1 test per scenario)

| REQ | Test |
|---|---|
| REQ-1 | merged local branch deleted after retire |
| REQ-2 | unmerged local branch kept + warning |
| REQ-3 | gh reports merged PR → remote branch deleted (even when the tip is not an ancestor — squash merge) |
| REQ-4 | gh reports open PR → remote kept + note |
| REQ-5 | no PR + merged into `origin/development` → remote deleted |
| REQ-6 | stale remote-tracking ref + gh error → script exits 0 |
| REQ-7 | `--no-branch-cleanup` → both branches kept |
| REQ-8 | dirty worktree → refuse, exit 1, branches kept |
| REQ-9 | AGENTS.md mentions cleanup + `--no-branch-cleanup` |
| REQ-10 | `shellcheck scripts/sub-retire.sh` (skip when shellcheck absent) |
| REQ-11 | verified by `gh api …/delete_branch_on_merge` GET (network; not in sandbox suite) |

## Strengths / Weaknesses

- **Strengths**: single choke point (retire) instead of scattered docs; every
  gate is an independent `if`, so partial failures degrade to warnings;
  tests sandbox everything with stubs — no real tmux/treehouse/GitHub needed.
- **Weaknesses**: `gh pr list` needs network/credentials at retire time (falls
  back to the local `origin/*` merge-base check when unavailable); a
  `git branch -d` failure when another worktree still holds the branch only
  warns (correct under the non-fatal constraint, but the ref lingers).

## Code audit note (independent review, post-implementation)

Audited `scripts/sub-retire.sh` against `branch-cleanup-retire.feature` and
the `codebase-design` vocabulary — no major improvements detected, so no
refactor was made. The less valuable improvements, recorded for later:

1. `remote_merged` is a near-trivial wrapper around two git invocations;
   inlined it would not change the interface — kept as-is for locality
   inside `cleanup_branches`.
2. Moving `cleanup_branches` to `_sub-common.sh` would only pay off with a
   second caller (e.g. `sub-clean.sh`); one call site = hypothetical seam.
3. `[ -n "$out" ] && [ "$out" != "[]" ]` in `pr_state` is mildly redundant
   (`gh --json` prints `[]` when empty) but guards a bare-empty output too.
4. When `git branch -d` fails because another worktree still holds the
   branch, only a warning is printed; the ref lingers by design (the
   non-fatal constraint outranks tidiness).

Strengths confirmed by the audit: `cleanup_branches(branch)` is a deep
module (one-parameter interface hiding all gating/degradation rules);
`pr_state` folds gh absence/failure into its result type; tests cross the
same CLI seam callers use, with stub adapters only at the PATH seam.
