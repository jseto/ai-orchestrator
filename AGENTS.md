# AGENTS.md

Guidance for agents (and humans) working in this directory.

## tmux sessions

Use tmux to run long-lived or background work (dev servers, watchers, long
builds) so the work survives disconnects and can be re-attached later.

### Start a new session

```bash
# Named session (recommended)
tmux new -s <name>

# Detached session you can attach to later
tmux new -d -s <name>
```

### List sessions

```bash
tmux ls
```

### Attach to a session

```bash
tmux attach -t <name>
```

### Detach (from inside the session)

Press `Ctrl+b` then `d`. The session keeps running in the background.

### Send a command to a session without attaching

```bash
tmux send-keys -t <name> "npm run dev" Enter
```

### Capture output of a pane (useful for agents)

```bash
tmux capture-pane -t <name> -p | tail -50
```

### Kill a session

```bash
tmux kill-session -t <name>
```

### Conventions

- Use descriptive, kebab-case session names (e.g. `dev-server`, `tests-watch`).
- One concern per session; create a new session instead of overloading an
  existing one.
- Always prefer a named session over the default so it can be found later
  with `tmux ls`.
- When child panes are active, keep the main pane on the left and arrange child
  panes tiled on the right.
- If a session with the desired name already exists, attach to it or pick a
  new name; do not kill someone else's session without asking.

## treehouse (worktree pool)

`treehouse` (v2.3.0, at `~/.local/bin/treehouse`) maintains a pool of
reusable, pre-warmed git worktrees so multiple agents can work on the same
repo in parallel. Run it from *inside* a git repository; by default the pool
lives under `$HOME` (`--root .` or `root = "."` in `treehouse.toml` keeps it
in-project).

### Core commands

```bash
treehouse init              # create a default treehouse.toml (once per repo)
treehouse status            # list worktrees in the pool (name = number)
treehouse get               # acquire a free worktree and open a subshell in it
treehouse get --lease       # non-interactive: lease + print path to stdout
treehouse enter <name>      # open a subshell in an existing worktree (even in use)
treehouse return <path>     # kill lingering processes and give the worktree back
treehouse prune             # remove stale worktrees and opted-in orphans
treehouse destroy           # remove worktrees from the pool (safely by default)
```

- `get` acquires, fetches, and resets; `enter` only cd's in and leaves all pool
  state untouched — use it to attach to a worktree another agent is using.
- `return --force` cleans and resets without prompting.

### Base branch: always development

Every child starts from the latest `development` base. Do **not** switch a
pooled worktree directly to `development`: the main checkout commonly
already owns that branch, and Git forbids checking it out in two linked
worktrees. Instead, create a unique task branch from it:

```bash
git -C "$WT" switch -c task/<task-name> development
```

Worktrees are created **detached HEAD** at the inferred default
(`origin/HEAD` → checked-out branch → `init.defaultBranch`). The helper
uses `treehouse get --lease`, fetches `origin/development` when available,
then creates `task/<task-name>` from that ref (or local `development` when
there is no remote). This works with the installed treehouse CLI, whose
`get` does not expose a `--base` flag.

In repos whose dev branch is named differently (`main`, `master`, `dev`), use
that name instead — check with `git -C "$WT" remote show origin | grep HEAD`
if unsure. Set `DEV_BRANCH` when using the helpers with a repository whose
base branch has another name.

### Init scripts: not run by default

`treehouse init` only *writes* `treehouse.toml` — treehouse runs **no repo
scripts** on `get`/creation, and "pre-warmed" only means a *reused*
worktree keeps its old `node_modules`/build cache. A freshly created
worktree may have no dependencies installed.

**This machine has a `post_create` hook configured** in the user-level
`~/.config/treehouse/config.toml`, pointing at
`/home/jseto/programming-projects/ai-orchestrator/scripts/worktree-setup.sh`, which runs in each newly provisioned or reset
worktree right before `get` hands it over:

- picks the JS package manager by lockfile (`pnpm-lock.yaml` →
  `pnpm install --frozen-lockfile`, `yarn.lock` → `yarn install --immutable`,
  bun lock → `bun install`, `package-lock.json` → `npm ci`, bare
  `package.json` → `npm install`), plus `flutter/dart pub get`,
  `cargo fetch`, and `go mod download` when their manifests exist;
- **skips the JS install when `node_modules` exists and the lockfile is not
  newer** — a warm cache from a reused worktree is left alone (that cache is
  the point of the pool); it refreshes only when the lockfile changed;
- logs `[worktree-setup] …` to stderr (stdout stays clean for
  `get --lease`); a failing step is reported but does **not** fail the
  `get`. The strict package-manager fallback is forced after a failed frozen
  install, so a partial `node_modules` directory cannot suppress the retry.

Things to know:

- Hooks are **user-level only** — hooks in a repo-level `treehouse.toml`
  are ignored on purpose (no executing checked-in shell from untrusted
  clones); treehouse warns on stderr if you declare them there.
- `pre_destroy` also exists (runs before `destroy`/`prune --yes` deletes a
  worktree) but is not configured.
- **Seed gitignored files** with a committed `.worktreeinclude` manifest
  (`.env*`, local config, …); selected ignored files are copied from the
  main checkout on every acquire.
- For repos needing different setup, still say so in the task brief — the
  hook is best-effort, and what it skips (e.g. a build step) is on the
  child to run.

### Using treehouse inside a tmux session

Interactive mode — the worktree subshell lives in a tmux pane so it survives
disconnects:

```bash
tmux new -s <name>          # session inside the repo
# inside the pane:
treehouse get               # acquire a worktree and drop into its subshell
# detach with Ctrl+b then d; the subshell keeps running
```

Agent/non-interactive mode — lease first, then drive everything through tmux:

```bash
# 1. Lease a worktree (prints only its absolute path to stdout)
WT=$(treehouse get --lease --lease-holder <agent-name>)

# 2. Run the long-lived work inside a named tmux session rooted there
tmux new -d -s <name> -c "$WT"
tmux send-keys -t <name> "npm run dev" Enter
tmux capture-pane -t <name> -p | tail -50   # check on it

# 3. When done, stop the work and return the worktree
tmux kill-session -t <name>
treehouse return --force "$WT"
```

### Conventions

- Give the tmux session a kebab-case name that hints at the worktree's task
  (e.g. `fix-auth`, `dep-bump`), not the default name.
- Always pair `get --lease` with a `return` (or `return --force`) when the
  work is finished; a leased worktree is never reused or pruned until then.
- Before disposing of a worktree (returned, force-returned, pruned, or
  destroyed), if it is dirty (uncommitted changes or untracked work), notify
  the user and get confirmation before discarding the changes.
- Set `TREEHOUSE_LEASE_HOLDER` (or pass `--lease-holder`) so leases are
  attributable when several agents share a pool.
- Use `treehouse status` (or `--json`) before acquiring to avoid grabbing a
  worktree another agent is already in.
- Never `treehouse destroy`/`prune` a worktree someone else is in without
  asking first — same rule as tmux sessions.

## pi sessions (orchestrated through tmux)

`pi` (v0.87.1, on PATH via nvm) is the AI coding assistant used here. A pi
session inside tmux survives disconnects, and tmux doubles as the control
channel: one **main pi session** (the orchestrator) opens and drives
**child pi sessions**, and the children report back to the main session.

This machine already has the pi-in-tmux key handling configured in
`~/.tmux.conf` (`extended-keys on` + `csi-u`, tmux 3.6), so `Shift+Enter`
(newline) vs `Enter` (submit) work inside panes.

### Open one pi session inside tmux

```bash
tmux new -d -s pi-main -c <repo>     # detached, inside the repo
tmux send-keys -t pi-main "pi -n main" Enter
tmux attach -t pi-main                # interact; detach with Ctrl+b d
```

Headless one-shots need no TUI — run and exit:

```bash
pi -p "<prompt>"                      # print mode: process prompt and exit
```

### Helper scripts (`scripts/`)

The orchestrator flow is scripted in `scripts/` (relative to this directory).
Prefer these over hand-rolled command sequences:

Because the project repositories are sibling directories, the scripts are not
inside each project's worktree. In a main session, set this once and use the
absolute directory:

```bash
SCRIPTS=/home/jseto/programming-projects/ai-orchestrator/scripts
```

| Script | Does |
|---|---|
| `sub-spawn.sh <task> <repo> [brief-file]` | Lease worktree (holder = task), base on `development`, write brief, boot `pi -n <task> "<kickoff>"` in tmux `pi-<task>` (kickoff passed as pi's initial message, so it cannot strand in the composer) with an isolated agent directory that excludes only notify/Telegram extensions and the pi-telegram package while retaining other resources, open a live viewer window in the invoking tmux session (skippable with `SUB_SPAWN_NO_VIEWER=1`), print all handles |
| `sub-status.sh <task> [repo] [lines]` | Lease + git state + pane tail + report tail for one subsession |
| `sub-changes.sh <task> [repo]` | Read-only: status, commits not on `development`, diff stats |
| `sub-send.sh <task> "message"` | Send a literal follow-up instruction to an existing child pi session and confirm it was submitted (re-types/retries `Enter` via `tmux_send_line`) |
| `sub-report.sh <task> "message"` | Push a `[task] message` notice into `$MAIN_SESSION` (used by children) |
| `sub-land.sh <task> [repo] [--patch]` | Read-only: what would be lost, commits to publish, push + `gh pr create` commands; `--patch` exports the work to `tmp/pi-sub/reports/<task>.patch` |
| `sub-retire.sh <task> [repo] [--force] [--keep-files]` | Kill `pi-<task>`, `treehouse return --force`, and delete the task's scratch brief/report/patch; **refuses** when uncommitted or unpublished work would be destroyed (overridable with `--force`; `--keep-files` retains the scratch docs) |
| `sub-clean.sh [repo] [--yes]` | Sweep scratch docs for tasks with no lease and no running tmux session (dry-run unless `--yes`) |
| `worktree-setup.sh` | treehouse `post_create` hook: installs dependencies in each new worktree (lockfile-aware; see *Init scripts* below) |

Details:

- Worktrees are looked up by **lease holder = task name** (`sub-spawn.sh`
  passes `--lease-holder <task>`); don't lease manually with another holder
  if you want the scripts to find the worktree.
- Scratch exchange files live in the **main checkout**: `tmp/pi-sub/tasks/<task>.md`
  and `tmp/pi-sub/reports/<task>.md`. They are outside any worktree, so they
  survive `return --force`, and they are **gitignored** via the global excludes
  file (`~/.config/git/ignore`) so they are never committed. `sub-retire.sh`
  deletes them when the task is retired (use `--keep-files` to keep them);
  `sub-clean.sh` sweeps leftovers from crashed sessions.
- Overrides: `DEV_BRANCH` (default `development`), `MAIN_SESSION` (default
  `pi-main`), `SCRATCH_DIR` (default `tmp/pi-sub`), `PI_BIN`, `PI_BOOT_DELAY`
  (default `3`).
- `sub-spawn.sh` always creates a unique `task/<name>` branch from the
  development base; it never commits directly to the shared `development`
  branch. If setup fails after leasing, it cleans up the lease.
- All scripts are safe to run from anywhere; they resolve the repo
  themselves and print `ERROR:` lines to stderr on misuse.

### Delegation mandate — the main session is the middle man

The main session is a **relay between the human and the children, not a
worker**. Its only jobs are: resolve names, transfer the user's queries and
tasks to the proper child (spawn one when none fits), relay the child's
answers back verbatim, run the mechanics of the pattern (spawn / publish /
land / retire, branch cleanup), and talk to you. It must not pick up a task
— or a question — itself, and it must not reason things out itself; the sole
exception is the last row of the routing table below.

**The atomic-specs flow must be done EXCLUSIVELY by the children.** You launch a child with the user's input and delegate to it the FULL flow: from atomic specs (Gherkin/design), TDD implementation (tests passing), to a code audit (code-auditor). The child goes back to you ONLY when it needs the user's input or when it has completed the full task through to opening a PR. Your job is ONLY to manage child task assignments and handle child feedback (whether a question for the user or a finished task report).

Routing rule for every incoming message:

| Message is… | Main session does |
|---|---|
| New work (*"fix/implement/refactor …"*) | **Delegate**: spawn a child (or route to the live one). Never starts coding itself. |
| Query about work or the world (*"state of …"*, *"changes in …"*, *"why …"*, *"what does … mean"*) | **Relay**: pass it to the proper child — the live one for that task, or spawn a research child — and report the child's answer back. Local retrieval of raw artifacts (`treehouse status`, `capture-pane`, `tmp/pi-sub/reports/`, `git log\|diff`) is allowed **only** to route or to quote verbatim; interpretation and reasoning belong to the child. |
| Housekeeping (*land*, *retire*, *merge on request*, *branch cleanup*, *"wrap up alpha"*) | Run steps 5-6 itself — the mechanics of being the middle man, not new reasoning. |
| Modify the main session's own behaviour (*"from now on …"*, *"always …"*, edits to this `AGENTS.md`) | **The sole exception**: reason and act by itself, without delegating. |

Hard rules:

- **Always delegate the reasoning to the children**: requirement
  interpretation, root-cause analysis, design and trade-off decisions, and
  investigative *why / what does this mean* work are child work — spawn (or
  route to) a child even when the question starts from read-only inspection.
  The main session only routes, quotes existing artifacts, and reports; it
  must not reason things out itself.
- If the answer or outcome requires **any** `edit`/`write`/mutating command
  in a repo, that is new work → delegate. Doing it in the main session is a
  bug, not a shortcut: it pollutes the orchestrator's context and skips the
  worktree isolation this pattern exists for.
- Exceptions the main session may do itself: read-only inspection needed to
  route or answer (issue tracker, `git status/log/diff`, files under
  `tmp/pi-sub/tasks/` `tmp/pi-sub/reports/`), spawning/publishing/retiring
  children, small direct edits to the orchestration docs themselves
  (e.g. a line or two in this `AGENTS.md`), and **updating `AGENTS.md` directly every time the user modifies the main session's behaviour**.
- When in doubt whether a message is a question or a task: **relay it** —
  questions go to the proper child and its answer comes back verbatim, tasks
  get a spawned or live working child. Only an explicit request to change
  the main session's own behaviour short-circuits the relay.

### Orchestrator pattern: main session controls the children

Conventions: the main session lives in tmux session `pi-main`; every child
gets its own tmux session named `pi-<task>` (kebab-case), rooted at the
child's leased treehouse worktree. A child pi process must be started with
that worktree as its working directory, never from the main checkout or the
parent repository. The main pi session runs all commands below with its own
bash tool; it is the **only writer** of child prompts. Humans may attach to watch, but should not type into a child pane
while the orchestrator is driving it. **The main session's tmux pane/window must be positioned at the exact left half (50% width) of the screen, while the right half of the screen is reserved for children tmux sessions.** Arranged via `main-vertical` layout and `main-pane-width 50%`.

> **Name the orchestrator `pi-main` — child notices are addressed to it.**
> Children push reports with `sub-report.sh`, which defaults to
> `MAIN_SESSION=pi-main`. The helper sends to the active pane using the exact
> tmux target `=pi-main:`; `=pi-main` alone works for `has-session` but is not a
> valid pane target for `send-keys`. If the main session has a different name
> (e.g. tmux auto-named it `3`), export `MAIN_SESSION=<current>` before
> spawning children or rename it (`tmux rename-session -t <current> pi-main`,
> which does not detach anyone). When `MAIN_SESSION` was not explicitly set,
> `sub-spawn.sh` also prefers the invoking session when its pane is running
> `pi`, avoiding a stale default `pi-main` shell. At startup, verify with
> `tmux display-message -p '#S'`; polling `sub-status.sh` and reading the
> durable report remain the fallback if a live notice cannot be delivered.

**1. Spawn a child session with a task:**

```bash
"$SCRIPTS/sub-spawn.sh" fix-auth <repo> [brief-file]
```

That one call leases a worktree (holder `fix-auth`), bases it on
`development`, writes the brief to `tmp/pi-sub/tasks/fix-auth.md`, boots
`pi -n fix-auth` in tmux session `pi-fix-auth` **with the tmux session rooted
at the leased worktree**, using an isolated agent directory that excludes
only notify/Telegram extensions and the pi-telegram package while retaining
other resources, kicks the child off with the brief/report paths, and prints
task, worktree, branch, session, brief, and report handles. The child pi
process therefore starts with the worktree as its current directory, not the
main checkout. The kickoff is passed to pi as its **initial message
argument** (`pi -n <task> "<kickoff>"`), not typed into the composer, so a
keystroke lost while pi initializes can never leave the child sitting idle
with an unsent prompt. (The raw commands behind it: `treehouse get
--lease --lease-holder <task>`, fetch `origin/development`, create
`task/<task>` from the development ref, `tmux new -d -c <worktree>`, then
`tmux_send_line` to launch `pi` with the kickoff.)

**2. Hand follow-up work to the child** — `sub-spawn.sh` already sends the
kickoff; for later instructions use the helper:

```bash
"$SCRIPTS/sub-send.sh" fix-auth "Read the updated brief and continue the implementation"
```

For long or multiline task descriptions, do not fight shell/tmux quoting:
write the task into a file and tell the child to read it.

**Every prompt must be confirmed as submitted — never leave one parked in the
composer.** A bare `tmux send-keys -l '…'` + `Enter` races the child's TUI:
when the Enter lands while pi is mid-redraw (slow extension init, model
switch) it is dropped and the text sits unsent in the input box — the child
looks alive but never works. `sub-send.sh` and the spawn path go through the
shared `tmux_send_line` helper
([scripts/_sub-common.sh](file://scripts/_sub-common.sh)), which re-types the
text when it did not appear and retries `Enter` while the pane stays frozen,
so the instruction actually lands. When driving a child with raw
`tmux send-keys` (or any other way), apply the same rule yourself: send the
text first, send a separate `Enter` keystroke, then **verify** it was
submitted (the pane shows the child working, or `sub-status.sh` shows
progress) and press `Enter` again if the prompt is still sitting in the input
buffer.

**3. Monitor a child:**

```bash
"$SCRIPTS/sub-status.sh" fix-auth <repo>  # lease + git + pane + report
"$SCRIPTS/sub-changes.sh" fix-auth <repo> # just the diffs/commits
# fallback: tmux capture-pane -t pi-fix-auth -p | tail -40
```

**4. Reporting — children report to the main session** with two channels:

- *Durable report*: the child writes its findings to
  `tmp/pi-sub/reports/<task>.md` as it works (the main session reads files at
  leisure).
- *Push notice*: when done (or blocked), the child runs from its own shell:

```bash
"$SCRIPTS/sub-report.sh" fix-auth "DONE: migration done, 2 tests failing -> tmp/pi-sub/reports/fix-auth.md"
```

which injects `[fix-auth] DONE: …` into the main session's input (raw
equivalent: `tmux send-keys -t pi-main -l '…'` + `Enter`). The main session
also polls `sub-status.sh <task>` for children that do not push. Treat the
report file as the source of truth and the push as a notification.

**Relay child completions immediately**: as soon as a `DONE:` / `BLOCKED:`
notice arrives (or a poll shows a child finished — PR opened, tests green),
report it to the user in the very next reply, unprompted: task, PR link, test
status. Never sit on a finished-child report waiting for the user to ask
"what's ready?".

**5. Child pushes branch and creates the PR — never merge into `development`.**
The child session itself pushes its branch (`git push -u origin task/<name>`) and opens a pull request against `development` using `gh pr create` as the final step of its work, including the PR link in its report and `DONE` notice. Never run `git merge` / `git cherry-pick` into `development` from the main checkout.
Do **not** retire the child yet when the PR is open: the child stays alive until the PR is merged (step 6), so it can address review feedback, rebase against new `development`, or answer questions about the work.

**6. Retire a child** — only once its PR is **merged** (or the user explicitly
abandons it). Keep the child's tmux session and worktree lease alive between
step 5 and the merge; retiring earlier strands review follow-ups. Before
disposing of or retiring any child, check whether its worktree has
uncommitted, unpublished, or otherwise potentially lost changes. Notify the
user if any such changes exist, and require the user's confirmation before
force-discarding them.

**Uncommitted changes are handled by instructing the child, not by force.**
When a child returns (or is about to be retired) with uncommitted or
unpublished changes in its worktree, the main session must not discard them
and must not just ask the user what to do: send the child a follow-up
instruction itself (`sub-send.sh <task> "..."`) telling it to commit, push,
and open/complete its PR, then re-check. Only when the child genuinely
cannot finish (or the user explicitly abandons the work) fall back to asking
the user about `--force`.

```bash
"$SCRIPTS/sub-retire.sh" fix-auth <repo>         # refuses lost work
"$SCRIPTS/sub-retire.sh" fix-auth <repo> --force  # after the PR is merged, or discard
```

It kills tmux session `pi-fix-auth` and returns the worktree. Manual
equivalent: `tmux kill-session -t pi-fix-auth; treehouse return --force "$WT"`
(resets the worktree!).

### Prompt template: spawn a subsession

**Minimal trigger — this is enough:**

```text
fix issue #42 in project alpha
```

Given only that, the main session fills in the rest itself:

1. **Locate the repo** — resolve `project alpha` to its checkout (e.g.
   `~/programming-projects/project-alpha`); it is the cwd only if you are
   already in it, otherwise pass it explicitly.
2. **Fetch the requirements** — read the issue
   (`gh issue view 42 -R <owner/project-alpha>`, or the tracker/TUI of
   choice) and turn it into the requirements paragraph; if the issue cannot
   be read, ask instead of guessing.
3. **Infer the task name** from issue + repo (see Naming below), e.g.
   `alpha-42-fix-utf8-login`.
4. Write the brief to `tmp/pi-sub/tasks/<task>.md`, run
   `$SCRIPTS/sub-spawn.sh <task> <repo>` and report back: task name,
   worktree path, branch, tmux session name.

The task name and requirements are therefore **optional in your message**:
include them only to override what the main session would infer. Names in
any message are resolved as described in *Referring to a subsession* below.
Full form (when you want to control the details):

```text
Start a new subsession for this task: <one-paragraph
description of the requirements>.
(Optionally name it <task-name>; omit that and I will derive a kebab-case
name from the task.)

Steps:
1. Pick a kebab-case task name (see Naming in AGENTS.md).
2. Write the full requirements to tmp/pi-sub/tasks/<task-name>.md, including the
   instruction to write the final report to tmp/pi-sub/reports/<task-name>.md.
3. Run: "$SCRIPTS/sub-spawn.sh" <task-name> <repo>
   (leases the worktree holder <task-name>, bases it on development, boots
   pi in tmux session pi-<task-name>, kicks the child off with the brief).
4. Read its output and tell me the task name, worktree path, branch, and
   tmux session name.
```

Short form when the main session already knows these conventions:

```text
Spawn a subsession for: <one-paragraph description>.
Infer a kebab-case task name, write the brief to tmp/pi-sub/tasks/<name>.md, run
"$SCRIPTS/sub-spawn.sh" <name> <repo>, and report back the task name, worktree
path, branch, and session name.
```

Include more than the minimal trigger only when something must be explicit:
the **requirements** if they aren't in a readable issue, the **repo** if it
is ambiguous, the **report path** if it should differ from the default
(`tmp/pi-sub/reports/<task-name>.md`), or a **task name** when it must match an
external identifier.

### Referring to a subsession

Any mention of a project/task name — *"what is the state of alpha"*, *"give
me the changes in alpha"*, *"fix issue #42 in alpha"* — resolves to that
project's subsession(s) before anything else. The main session maps the name
to the artifacts this pattern maintains:

| Artifact | Location |
|---|---|
| Child process/pane | tmux session `pi-<task>` |
| Worktree + branch | the `treehouse` lease whose holder = task name |
| Requirements | `tmp/pi-sub/tasks/<task>.md` |
| Report (source of truth) | `tmp/pi-sub/reports/<task>.md` |

Then it classifies the intent:

- **Query about state** — *"state/status/progress of alpha"*:
  `"$SCRIPTS/sub-status.sh" <task> <repo>` (lease + pane + report in one shot). No
  spawning.
- **Request for artifacts** — *"changes/diffs/results in alpha"*:
  `"$SCRIPTS/sub-changes.sh" <task> <repo>` (status, commits vs `development`, diff
  stats), or read the report file. No spawning.
- **Imperative to do new work** — *"fix issue #42 in alpha"*: run
  `"$SCRIPTS/sub-spawn.sh"` — **unless** a live subsession for that task
  already exists (spawn refuses to double-book anyway), in which case route
  the new instruction to the existing child instead.
- **Ambiguous name** — several live subsessions in the project, or no
  matching subsession but the name looks like a query: list what exists
  (`tmux ls`, `treehouse status`) and ask, don't guess.

`alpha` here is shorthand: it matches the project/repo name **or** a task
name (so *state of fix-utf8-login* and *state of alpha* can point at the same
subsession). With no match at all, say so and offer to start one.

### Naming

Whatever names the session (you or the main session), the task name is the
one identifier the whole pattern keys on: it becomes the tmux session
(`pi-<task>`), the lease label, and the file names (`tmp/pi-sub/tasks/…`,
`tmp/pi-sub/reports/…`). When inferring it from context:

- Make it kebab-case and say *what* the task does, not how
  (`fix-auth-refresh` ✅, `task-1` ❌).
- Keep it short (2-4 words); it is used verbatim in shell commands.
- Reuse an external identifier verbatim when one exists
  (`riak-1234-fix-login` for ticket RIAK-1234).
- Make it unique among live sessions — check `tmux ls` and
  `treehouse status` first; if it collides, disambiguate (`fix-auth-2`)
  rather than reusing the name.

### Conventions

- Prefer the `scripts/sub-*.sh` helpers over raw tmux/treehouse/git command
  sequences; they encode every rule below (and refuse double-booking,
  lost-work retirements, and wrong-base branches for you).
- `pi-main` for the orchestrator, `pi-<task>` for each child; one concern per
  session, same rule as every other tmux session. **Verify the orchestrator is
  actually named `pi-main`** (`tmux display-message -p '#S'`) or set
  `MAIN_SESSION` to its real name — children address notices to `pi-main` by
  default, and a misnamed orchestrator silently misses them.
- Children never talk to each other — all coordination goes through the main
  session (star topology); the main session is the only orchestrator.
- The main session delegates all implementation work (see *Delegation
  mandate*); if it is editing repo files or running mutating commands to
  "just fix it", it is violating the pattern.
- **Keep children alive until their work is fully merged**: opening the PR
  (step 5) does **not** end the child — do not kill its session or return its
  worktree then. It stays up (tmux session + treehouse lease) so it can handle
  review feedback, rebases, and follow-up instructions; retire it (step 6)
  only after the PR is merged, or once the user explicitly abandons the work.
- **PR before you return**: `return --force` resets the worktree — always
  push the child's branch and open a PR (step 5) before retiring the child, or
  the local commits are lost. The pushed branch is the durable copy; merging
  the PR is the human's job, never the orchestrator's.
- Long tasks go in files (`tmp/pi-sub/tasks/<task>.md`), reports go in files
  (`tmp/pi-sub/reports/<task>.md`); keep `send-keys` payloads to single lines.
  These scratch files are gitignored and deleted on retire (`sub-clean.sh`
  sweeps leftovers), so treat the report as transient — copy anything durable
  into the PR description or an issue before retiring.
- Check `tmux ls` and `treehouse status` before spawning to avoid double
  booking a name or a worktree — or let `sub-spawn.sh` check for you.
- Alternatives to tmux orchestration when you don't need visible panes:
  `pi -p` for one-shot tasks, the subagent extension (in-process delegation,
  `~/.pi/agent/extensions/subagent`), and `pi --mode rpc` for a programmatic
  JSONL control channel.
