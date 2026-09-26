# Design: model defaults in the child agent settings (prepare_child_agent_dir)

## Summary

`prepare_child_agent_dir()` (in `scripts/_sub-common.sh`) builds the child's
isolated Pi agent directory. It used to write a bare `{"packages":[]}` into
`settings.json`, so the child inherited **no** `defaultProvider` /
`defaultModel` / `enabledModels`. When the target repo ships no
project-level `.pi/settings.json`, pi has no configured default and falls
through to its built-in per-provider fallback map, landing on an arbitrary
model (e.g. `google/gemini-3.1-pro-preview`).

The fix inherits exactly those three keys from the global
`$HOME/.pi/agent/settings.json` with `jq`, drops null values, and merges the
result with `packages: []`. Every failure mode degrades to the old
behaviour — a packages-only file — instead of breaking child spawning:
missing/malformed/wrong-shaped global settings (`2>/dev/null || printf '{}'`
on the read), and a missing `jq` binary (`2>/dev/null || printf …` on the
merge/write, so the file is never left empty by the `>` truncation).

## Entities

- **`scripts/_sub-common.sh`** (modified) — `prepare_child_agent_dir`:
  - `local … model_cfg` added;
  - the bare `printf '{"packages":[]}'` is replaced by a two-step jq merge:
    1. `model_cfg=$(jq -c '{defaultProvider, defaultModel, enabledModels}
       | with_entries(select(.value != null))' "$HOME/.pi/agent/settings.json"
       2>/dev/null || printf '{}')` — read + drop nulls, `{}` on any failure;
    2. `jq -cn --argjson cfg "$model_cfg" '$cfg + {packages: []}' > settings.json
       2>/dev/null || printf '{"packages":[]}' > settings.json` — merge, with a
       fallback so a missing jq cannot leave an empty file.
  - The rest of the function (symlink loop for `auth.json`, `skills`, …) is
    untouched; model inheritance never affects the extension/package
    isolation.
- **`specs/child-model-defaults/`** (new): this design + the feature file.
- **`tests/sub-common.test.sh`** (new): behavioural suite for
  `prepare_child_agent_dir` covering [REQ-1]…[REQ-7]; honours
  `SUB_COMMON_UNDER_TEST` so the pre-change implementation can be exercised
  (RED) without touching the working tree.

## Behaviour and data flow

```mermaid
flowchart TD
    A[prepare_child_agent_dir dest] --> B["rm -rf + mkdir dest/extensions"]
    B --> C["jq read: defaultProvider/<br/>defaultModel/enabledModels,<br/>nulls dropped"]
    C -- "ok" --> D["jq merge: cfg + {packages: []}"]
    C -- "missing / malformed /<br/>wrong shape / no jq" --> C2["model_cfg = {}"]
    C2 --> D
    D -- "ok" --> E["dest/settings.json"]
    D -- "jq absent" --> F["fallback: {\"packages\": []}"]
    F --> E
    E --> G[symlink auth/skills/… , echo dest]
```

## Proposed changes (files/modules)

| File | Change |
|---|---|
| `scripts/_sub-common.sh` | inherit model defaults in `prepare_child_agent_dir`, two defensive fallbacks |
| `specs/child-model-defaults/*.feature` | atomic scenarios [REQ-1]…[REQ-8] |
| `specs/child-model-defaults/*-design.md` | this document |
| `tests/sub-common.test.sh` | behavioural suite, one test per scenario |

## Task list

- [x] Deduce atomic requirements from the brief → [REQ-1]…[REQ-8]
- [x] Write the feature file and this design doc
- [x] RED: run the new suite against the pre-change implementation
- [x] GREEN: full suite + shellcheck + `bash -n` pass on the change
- [x] Independent code audit (see note below) → rerun tests GREEN

## Strengths / Weaknesses

- **Strengths**: intent-preserving, purely additive; all failure modes
  converge on the old observable behaviour; package isolation unchanged and
  asserted (REQ-3); cheap (two jq invocations per spawn).
- **Weaknesses**: the `settings.json` write has two fallback sites (read and
  merge) that must stay in sync if the jq expression grows; `jq` becomes a
  soft runtime dependency of spawning (mitigated by REQ-7's fallback).

## Audit note (code-auditor, step 2)

Independent audit of the landed implementation against the feature file found
no major improvements to make — the function stays a shallow, single-purpose
builder with its failure policy visible at the call site, so no refactor plan
was needed (skill: stop at step 2 and note lesser ideas here):

- *Speculative*: fold the two jq steps into one `jq -cn` call with
  `--slurpfile`-style input, removing the `model_cfg` variable — rejected:
  it would obscure the read-vs-write fallback split that REQ-4…REQ-7 test
  independently.
- *Worth exploring*: moving the settings-merge into a named helper
  (`inherit_model_defaults <src> <dest>`) if a second caller ever appears —
  today there is exactly one caller, so it would only add indirection.

Tests re-run after the audit: all [REQ-1]…[REQ-8] GREEN.
