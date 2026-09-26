# Design: retirement cost logging in the conversation log

## Summary

`scripts/sub-retire.sh` already kills the tmux session, force-returns the
worktree, removes scratch files, and best-effort cleans up branches — but the
conversation log knows nothing about a retirement. This change makes every
**successful** retirement append an `operation` entry to the weekly log via
the existing `scripts/conversation-log.sh append`, recording the task name,
the retirement, and the child's **total session cost**, read from the child's
own pi session records. The whole step is best-effort: a missing cost source
or a failing log prints a warning and leaves the retirement's exit status
untouched — the same contract as the branch cleanup from PR #2.

## Cost source: investigation

pi does not expose a cost-reporting CLI (`pi --help`: no usage/cost command;
`--export` writes an HTML transcript, `--mode json|rpc` format prompts, not
reports; `pi auth` only checks credentials). The authoritative record is the
**session JSONL** pi writes per session:

- Each entry of type `message` with an assistant turn carries
  `message.usage.cost.total` (plus per-component `input/output/cacheRead/
  cacheWrite` costs). The session's total cost is the sum of those totals.
- A child spawned by `sub-spawn.sh` runs with an **isolated per-task agent
  directory** (`PI_CODING_AGENT_DIR=<repo>/tmp/pi-sub/agent-dirs/<task>`,
  created by `prepare_child_agent_dir`), so its sessions are stored under
  `<agent-dir>/sessions/<cwd-slug>/<timestamp>_<uuid>.jsonl` — *only* that
  child's sessions, never the orchestrator's or another child's. Verified on
  a live spawn: the current child's own file is there and its summed cost
  matches the TUI's session cost.

**Chosen source**: sum of `message.usage.cost.total` over
`<repo>/tmp/pi-sub/agent-dirs/<task>/sessions/**/*.jsonl`, parsed with `jq`
(already a `need` of `sub-retire.sh`).

**Rejected alternatives:**

1. **tmux status-line cost for `pi-<task>`** — would have to be captured
   before `tmux kill-session`, and requires scraping wrapped pane text whose
   format/theme/width are pi-side details; it is display text, not data.
   Fragile by construction → dropped (the brief allows dropping it if the
   fragility is proven; capture-before-kill alone cannot make text parsing
   reliable).
2. **`~/.pi/agent/sessions/<cwd-slug>/*.jsonl` (the default agent dir)** —
   only used by non-isolated sessions (the orchestrator, manual runs). The
   treehouse pool *reuses* worktree paths (`~/.treehouse/<repo>/<n>/<repo>`),
   so one slug directory can mix sessions of several tasks over time → not
   attributable to this child; it can also contain the orchestrator's own
   sessions.
3. **pi CLI/JSON cost output** — no such surface exists (see above).

Because the source is a durable file, the sequencing constraint is easy to
satisfy: the cost is captured **before the tmux session is killed** and,
more importantly, **before the scratch cleanup deletes
`agent-dirs/<task>`** (the records live inside the scratch dir).

## Entities

- **`scripts/sub-retire.sh`** (modified)
  - new helper `session_cost <agent-dir>` → echoes the summed cost formatted
    as `0.1234`, or nothing when no session records exist / they cannot be
    parsed;
  - cost captured once, after the refusal checks pass and **before** the tmux
    kill + scratch removal (refused retirements never capture or log);
  - new helper `log_retirement <cost-label>`, called once at the end of a
    successful retirement: appends `retired <task> | session cost: <label>`
    with kind `operation` through `conversation-log.sh`; every failure mode
    (script missing, append failing) degrades to a `warn`.
  - cost label is `$0.1234` when readable, `unknown` otherwise (plus a
    warning at capture time).
- **`scripts/conversation-log.sh`** (unchanged): reused as-is through its
  public `append` interface.
- **`AGENTS.md`** (modified): helper-scripts table row + step 6 gain one line
  each about the retirement log entry and its session cost.
- **`specs/retire-cost-log/`** (new): this design + `retire-cost-log.feature`.
- **`tests/retire-cost-log.test.sh`** (new): self-contained sandbox in the
  `tests/sub-retire.test.sh` style — fake origin/checkout/worktree, stub
  `treehouse`/`tmux`/`gh`, session-record fixtures, one test per scenario,
  and an isolated `CONVERSATION_LOG_DIR` (test hygiene — never the real log).
- **`tests/sub-retire.test.sh`** (modified): its sandbox now exports an
  isolated `CONVERSATION_LOG_DIR` too — retirement logs on every success, so
  the pre-existing tests would otherwise write entries into the real log.

## Behaviour and data flow

```mermaid
flowchart TD
    A[sub-retire.sh task] --> B{dirty / unpublished?}
    B -- yes, no --force --> C[refuse, exit 1<br/>no capture, no log REQ-6]
    B -- no --> C2["session_cost agent-dirs/task/sessions<br/>jq sum of usage.cost.total"]
    C2 -- records found --> D["cost label $0.1234"]
    C2 -- none / unparseable --> W["warn, label unknown REQ-4"]
    D & W --> E[kill tmux session]
    E --> F["treehouse return + scratch removal<br/>(agent dir deleted REQ-3)"]
    F --> G[branch cleanup, best effort PR #2]
    G --> H["log_retirement label<br/>conversation-log.sh append operation<br/>'retired task | session cost: ...' REQ-1"]
    H -- append fails --> I["warn, continue REQ-5"]
    H -- ok --> J[info logged]
    I & J --> Z[exit 0 / original status]
```

Key decisions:

1. **One source, no fallback** — a second (weaker) source would create
   double-counting and attribution questions; when the chosen source is
   absent the label is `unknown` and a warning explains why (REQ-4).
2. **Log only on the success path** — the capture happens after the refusal
   checks, the append at the very end; a refused or crashed retirement never
   writes an entry (REQ-6).
3. **Non-fatal everywhere** — the append runs in an `if`; both its missing
   script and its failure branch end in `warn` + `return 0`, so under `set
   -euo pipefail` the retirement still finishes with its original status
   (REQ-5), independent of the branch-cleanup guards.
4. **Entry format** — `retired <task> | session cost: $0.1234` with kind
   `operation`; task name, retirement and total cost are all present (REQ-1),
   and the cost is summed from *this* task's records only (REQ-2).
5. **Attribution boundary** — only `scratch_root/<task>/agent-dirs/<task>/
   sessions/**` is read; the orchestrator's `~/.pi/agent/sessions` is never
   touched, so unrelated sessions cannot leak into the total (REQ-2).

## Files / modules changed

| File | Change |
|---|---|
| `scripts/sub-retire.sh` | `session_cost()`, `log_retirement()`, capture + append in the success path |
| `AGENTS.md` | helper-scripts row + step 6: retirement log entry with session cost |
| `specs/retire-cost-log/retire-cost-log.feature` | new — requirements |
| `specs/retire-cost-log/retire-cost-log-design.md` | new — this doc |
| `tests/retire-cost-log.test.sh` | new — self-contained sandbox + one test per scenario |
| `tests/sub-retire.test.sh` | `setup()` exports an isolated `CONVERSATION_LOG_DIR` (hygiene) |

`conversation-log.sh`, `_sub-common.sh`, `sub-spawn.sh`, `sub-clean.sh` are
**not** touched.

## Test plan (1 test per scenario)

| REQ | Test (all in `tests/retire-cost-log.test.sh`) |
|---|---|
| REQ-1 | retire with known records → log file gains an `operation` entry naming `retired <task>` and `session cost: $0.1500` |
| REQ-2 | own records `$0.1` + another task's `$5.0` in the sandbox → entry shows `$0.1000` only |
| REQ-3 | retire → `agent-dirs/<task>` is gone **and** the entry still carries the known cost |
| REQ-4 | no agent dir → exit 0, stderr `WARNING: …no readable session cost…`, entry ends `session cost: unknown` |
| REQ-5 | `CONVERSATION_LOG_DIR` pointing under a regular file → exit 0, `WARNING: could not append…`, retirement still completes |
| REQ-6 | dirty worktree → exit 1 and **no** file in the (sandboxed) log dir |
| REQ-7 | `grep` AGENTS.md for `session cost` + `conversation log` |
| REQ-8 | `shellcheck scripts/sub-retire.sh` (skip when shellcheck absent) |

Test hygiene: `setup()` exports `CONVERSATION_LOG_DIR="$SB/logs"` for **every**
test, so no run can write into the real `logs/conversations/`; the tmux/treehouse
stubs mean no live session is ever touched.

## Strengths / Weaknesses

- **Strengths**: one durable, attributable data source (per-task agent dir)
  instead of pane scraping; one capture + one append, both gated on the
  success path; the non-fatal contract mirrors the branch cleanup, so the two
  post-retirement steps stay independent; tests reuse the existing sandbox
  with only fixtures added.
- **Weaknesses**: cost granularity is 4 decimals (a sub-$0.0001 session logs
  as `$0.0000`); sessions resumed outside the isolated agent dir (manual
  `pi -c` in the worktree with the default agent dir) are not counted — by
  design, since they are not attributable; a corrupt session file makes the
  whole total `unknown` rather than summing the readable files (fail-safe
  toward "unknown", never toward a wrong number).

## Code audit note (independent review, post-implementation)

Audited `scripts/sub-retire.sh` against `retire-cost-log.feature` as read
from disk (the design doc and tests were deliberately excluded from the
audit input), using the `codebase-design` vocabulary. **No major improvements
detected** — stopped at step 2 of the audit procedure. Both new modules sit
at the right seam (after the refusal checks, strictly on the success path),
hide their degradation rules behind a one-parameter interface
(`session_cost <agent-dir>`, `log_retirement <label>`), and are verified
tests-cross-the-CLI-seam style. Less valuable improvements, recorded for
later:

1. The `sub-retire.sh` header comment still described only kill/return/
   cleanup — **fixed in this change** (found by the audit; doc accuracy only).
2. The agent-dir path (`scratch_root/agent-dirs/<task>`) is constructed twice
   (cost capture + scratch cleanup); a single `AGENT_DIR=` variable would
   centralise it — a rename-level change, skipped to minimise churn on a
   merged script.
3. `session_cost` reads `sessions/*.jsonl` and `sessions/*/*.jsonl`; pi
   currently nests exactly one slug level. Deeper nesting would silently
   yield `unknown` — fail-safe (never a wrong total), but worth knowing.
4. `log_retirement` receives the cost label but reads `$TASK` from script
   scope; fully parametric would be marginally cleaner, but with one call
   site inside one script that is a hypothetical seam.
5. The success `info` line for the log entry prints *after*
   `retired task '<task>'` — reading order is "retired …, then logged …",
   which matches the log's placement as the final step (cosmetic).
