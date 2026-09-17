# FeatureRunner POC — Stage 1

Base: `e0ccc83720a42a600a53b61c5f8d3e518bebe1db`
Branch: `poc/feature-runner`
Origin: `https://github.com/JarFrank/symphony`
Upstream: `https://github.com/openai/symphony`

The reference checkout `/home/jarek/symphony` is not modified. This is an opt-in,
standalone deterministic core, not a production scheduler extension. No Codex,
Linear, GitHub, publishing, application-code generation or subprocess executor
is connected. `orchestrator.ex`, `AgentRunner` and existing workflow parsing are
unchanged. Stage 1 stops at fake ReadyForHuman; it does not assert real tests or
PR readiness.

## Entry point

Use `iex -S mix` in `elixir/` (without starting the Symphony CLI):

```elixir
alias SymphonyElixir.Feature.{Store, Fake}
alias SymphonyElixir.FeatureRunner
path = Path.expand("~/.local/share/symphony-feature-runner/state.sqlite3")
Store.init(path)
FeatureRunner.create(path, "demo", "Approved specification")
FeatureRunner.step(path, "demo", Fake.executor("mastermind", Fake.plan()))
FeatureRunner.step(path, "demo", Fake.executor("developer", %{"status" => "completed", "sha" => "fake-1"}))
FeatureRunner.get(path, "demo")
```

Always pass a database path outside both the implementation repo and disposable
feature workspaces. Future workspaces: `~/symphony-feature-workspaces/`.
Tests create real SQLite databases in unique system temporary directories and
remove them on completion. Store.init creates only the database and its parent;
it does not start a server or modify any tracker.

## Lifecycle and contracts

Planning -> Implementing -> Reviewing -> next task or FinalReview -> ReadyForHuman.
Changes requested return to Implementing with the same task identity. A final
review correction remembers that it must return to FinalReview, even when it
reopens task 1. Technical questions enter Resolving; Mastermind either resolves
or moves to WaitingForHuman. Human answers require the current feature revision
and resume the recorded originating phase. ReadyForHuman, WaitingForHuman and
Failed never invoke an executor. Failed has no automatic retry/reset API yet.

The fake plan contains exactly two tasks with unique nonempty id, scope and
acceptance strings. Developer completed results require a nonempty fake sha.
Reviews require the current head sha. Changes requested require nonempty string
findings; final corrections also identify an existing task_id. Questions and
answers require nonempty strings. Explicit failed results include a reason.
Malformed/out-of-phase results fail closed. These are deliberately small Elixir
map contracts, not JSON Schema or production agent evidence.

`Fake.executor(role, result)` asserts the expected role and returns the result.
Tests can supply any synchronous `(role, state) -> result` callback and observe
all invocations. There is no generic executor plugin framework.

## Stage 1 acceptance evidence

The following is the Stage 1 acceptance matrix. Test names are deliberately
listed so that the documented behavior is tied to executable evidence rather
than only to the state-machine description.

| Requirement | Executable evidence |
| --- | --- |
| Exactly two ordered tasks | `FeatureRunnerTest`: `two tasks are sequential, rework keeps identity, final approval stops execution`; invalid task counts are also rejected by `invalid plan, stale SHA and explicit failures fail closed`. |
| Rework retains the selected task identity | `FeatureRunnerTest`: `two tasks are sequential, rework keeps identity, final approval stops execution`. |
| Final review occurs after task review and can reopen a named task before returning to final review | `FeatureRunnerTest`: `technical resolution resumes review and final review rework returns to final`. |
| Waiting states are idle and answers resume the recorded phase at the current revision | `FeatureRunnerTest`: `human wait survives restart and answer resumes same task and stage`; `planning and final review questions resume their exact phase`; `FeatureRunnerRecoveryTest`: `WaitingForHuman remains idle after a BEAM VM is terminated`. |
| Each role result has one durable attempt per feature revision; recorded output is reused | `FeatureRunnerTest`: `restart after developer result replays without invoking developer`; `restart after review result advances exactly once`; `executor failure retains running attempt for retry`; `FeatureRunnerRecoveryTest`: `recorded developer output is applied after a BEAM VM is terminated`. |
| SQLite transactions serialize writers, revision checks reject stale writes, and a dead writer releases its lock | `FeatureRunnerTest`: `optimistic store update rejects stale writer and rolls back`; `independent connection cannot start second executor; killed owner releases lock`; `SQLite constraint error rolls back all writes in transaction`. |
| Durable effect intent, reconciliation, and exactly-once fake execution recovery | `FeatureRunnerTest`: `effect execution then crash is reconciled without duplicate execution`; `effect intent survives restart before execution`; `stale pending effect cannot execute against a newer feature`; `completed external effect can reconcile after feature advances`; `FeatureRunnerRecoveryTest`: `external fake effect is reconciled after confirmation is lost`. |

The recovery tests start separate BEAM VMs and terminate the owner process; the
ordinary test module uses separate SQLite connections and a killed owner to
exercise the writer lock. These are process/restart tests of the local SQLite
journal, not integration tests of external services.

## Persistence and concurrency

Three tables:

* features: id, optimistic revision, state_json (spec, phase, ordered task plan,
  current index, fake SHA, review, findings, questions and return phase).
* attempts: feature/revision key, running/recorded/applied status, result_json.
  Input is the unchanged feature revision; a durable running intent precedes
  execution. Historical full input snapshots/model IDs are deferred.
* effects: feature/key identity, intent/completed status, immutable intent_json,
  feature_revision and result_json.

Every operation opens and closes its own SQLite connection, enables foreign
keys and uses BEGIN IMMEDIATE. Callbacks execute synchronously under that lock.
This serializes writers **across the entire database**, not just one feature.
A competing writer fails immediately with SQLite writer busy; caller may retry.
No in-memory global registry or unbounded lease/retry mechanism is introduced.
A killed owner releases the connection resource; a test proves another process
can acquire the database afterward. Do not spawn external work from a callback.

This locking strategy is appropriate only for short deterministic fakes. Before
Stage 2, define ownership/cancellation for long-running subprocesses and release
long database transactions without allowing a stale subprocess writer.

## Result recovery

capture persists the attempt intent, executes only a running attempt, and stores
its result. advance atomically updates feature revision/state and marks that
result applied. step calls both. The intentional boundary allows crash injection
after a durable result but before its transition. Re-entry reuses recorded output;
reapplying an old revision fails. A crash before output persistence may re-execute
the same attempt, which is allowed. create is idempotent for identical specs and
rejects silently replacing the specification.

## Effects

intent stores the operation key before execution. run first reconciles: found
returns the external result, missing executes the fake effect. Confirmation is
stored transactionally. If execution happens but confirmation fails, a restart
reconciles instead of executing twice. A completed effect returns its stored
result without invoking callbacks. Reusing a key for another intent fails.
Pending effects from a stale feature revision cannot execute, but existing external
results can still be reconciled and confirmed after the feature advances.

Execution/reconciliation are callbacks, not extra durable status columns: after
an uncertain crash the only trusted local fact is the intent. The externally
observable fact is supplied by reconcile. Stage 1 tests simulate it with a
separate fake external store. No real commit/push/PR/Linear operation exists.
Effects are tested independently; the fake role lifecycle does not manufacture
GitHub operations or imply real publication.

## What Stage 1 guarantees - and what Codex exec must still provide

Stage 1 guarantees a deterministic fake core only: the pure state transition
rules, SQLite persistence, one-at-a-time local writers, attempt/result recovery,
and intent/reconcile/confirmation behavior when its synchronous fake callbacks
are truthful. Fake SHA values, fake plans, and the separate fake external store
are test evidence placeholders; they are not commits, test results, pull
requests, or evidence from a model session.

A future Codex exec integration must independently define and prove: durable
request/input and model-session identity; subprocess ownership, cancellation
and timeout; how a long-running process is executed outside the SQLite write
transaction; workspace/branch isolation; validation of actual commits, diffs,
tests and review evidence; reconciliation against real GitHub/Linear/Git
effects; credentials and multi-host ownership; and retry/idempotency semantics
for every external operation. It must not infer these guarantees from
`Fake.executor/2`, a fake SHA, or a recorded Stage 1 callback result.

## Scope limits

No real model sessions, retry budgets, schema migrations, multi-host scheduling,
dashboard, credentials, branch enforcement, isolation or Git/CI validation.
Schema is initial v1 only. Transaction/contract errors are explicit exceptions;
role-reported failure is a persisted Failed state. No automatic loop is exposed:
step performs at most one role result/transition. SQLite lock plus revision
protects this core, not future external agent side effects.

## Validation and Stage 1 boundary

Run `make all` from `elixir/`; it includes build, format check, lint, coverage
and dialyzer. Also run `git diff --check`. The focused Stage 1 suites are
`test/symphony_elixir/feature_runner_test.exs` and
`test/symphony_elixir/feature_runner_recovery_test.exs`.

Stage 1 ends at `ReadyForHuman` and has no automatic loop, runtime SQLite file,
production wiring, or Codex exec. It remains intentionally isolated from
`orchestrator.ex`, `agent_runner.ex`, and the production `WORKFLOW.md`.

## Stage 2 / Task 1 — fake executor ownership

Task 1 replaces the Stage 1 long callback transaction with `prepare -> execute
-> record -> apply`. `prepare` stores one durable attempt per feature revision,
including `attempt_id`, an input-state snapshot, `execution_id`, and an owner
token. The fake callback executes after `prepare` commits. `record` and `apply`
each use their own short `BEGIN IMMEDIATE` transaction.

The owner token is scoped to the current BEAM VM because this task has only an
in-process fake callback. A second writer in that VM observes the running
execution and does not invoke its callback. A fresh VM may replace that owner
when recovering a running attempt; it gets a new `execution_id`. `record`
compares both identifiers, so a delayed result from the prior execution is
rejected as stale. This is fencing for the fake executor only; external process
liveness, cancellation, and leases remain Task 2 work.

`Store.init/1` performs the minimal SQLite migration for existing journals by
adding the nullable attempt metadata columns and backfilling `attempt_id`.
Recorded results are still applied by the existing replay/recovery path.

## Stage 2 / Task 2 — ProcessOwner

`ProcessOwner` is the only owner of a controlled test subprocess. It receives
Task 1's `execution_id`, `attempt_id`, feature id and revision, records an
`intended` row in `process_executions` before launching anything, and assigns a
unique transient user-systemd unit name derived from that execution id. A second
intent is rejected while any row is intended, running, stopping or ambiguous.

The unit is launched with `KillMode=control-group`, `KillSignal=SIGTERM`,
`TimeoutStopSec=1s` and `SendSIGKILL=yes`. The post-start journal stores the
unit's `InvocationID`, `ControlGroup` and main PID. Cancellation and recovery
call `systemctl --user stop`; systemd first gives the entire cgroup the graceful
TERM period and then force-kills it within that bound. Termination is accepted
only after the unit is absent/inactive and `cgroup.procs` is absent or empty.

A restart never adopts a living process. It runs `stop old execution -> confirm
termination -> reconcile -> start new execution`. For a pre-metadata crash the
durable, unique unit name is sufficient to locate and stop the possibly started
unit. Once metadata exists, a different or missing `InvocationID`, a failed
systemd observation, or a non-empty cgroup is persisted as `ambiguous` and
blocks all later starts. It is never guessed to be the current writer.

This POC was verified on its target WSL environment: PID 1 is systemd,
`systemctl --user` is running, cgroup v2 is mounted, and a transient user scope
starts successfully. There is intentionally no weaker process-group fallback;
without these facilities Task 2 must stop rather than launch a subprocess.
Only the controlled Python fixture and `/bin/sleep` are used by Task 2 tests;
there is no `codex exec` integration.

Focused evidence is `Feature.ProcessOwnerTest`: child-tree cancellation,
TERM-ignoring forced termination, recovery after the owning BEAM VM is killed,
crash after durable intent before start metadata, invocation mismatch fencing,
and ambiguity blocking the next writer.

## Stage 2 / Task 3 — executor isolation and publisher exclusivity

Every controlled role process is now launched only through
`Feature.Sandbox` and `ProcessOwner.start/4` (or `launch/4`). The previous
three-argument start and launch APIs fail closed with `:sandbox_required`;
there is no direct subprocess fallback. The profile binds the exact SQLite path
as the coordinator runtime identity but **never mounts it**. It also creates a
small private, empty root directory next to that runtime for the sandbox root;
the directory contains only mount points and is read-only inside the role.

The bubblewrap command creates separate user, PID, IPC, UTS, cgroup and network
namespaces, clears the environment, drops all capabilities, and mounts:

* a read-only empty root with only pre-created mount points;
* read-only `/usr`, `/usr/bin`, `/usr/lib` and `/usr/lib64` for the
  selected command and its shared libraries;
* fresh `/dev` and `/proc`;
* exactly one writable role checkout at `/workspace`;
* exactly one writable role output directory at `/output`.

There is no `/home`, `/run`, host root, coordinator runtime directory, SSH
socket, credential directory, or network mount. The root is a read-only bind,
so even a role process that is UID 0 in its user namespace cannot create
persistent paths outside `/workspace` and `/output`. The ProcessOwner
systemd cgroup remains the lifecycle owner; the sandbox intentionally does not
use `--die-with-parent`, because `systemd-run` is a short-lived launcher.
Task 2's cgroup cancellation terminates the bwrap process and all role
descendants.

Roles receive only this explicit environment: `PATH`, `LANG`, `LC_ALL`,
`HOME`, `TMPDIR/TMP/TEMP`, and XDG cache/config/state paths under
`/output`, plus Git hardening:
`GIT_CONFIG_NOSYSTEM=1`, global and system config set to `/dev/null`,
`GIT_ASKPASS=/bin/false`, `SSH_ASKPASS=/bin/false`,
`GIT_SSH_COMMAND=/bin/false`, and `GIT_TERMINAL_PROMPT=0`.
`--clearenv` removes GitHub/Linear variables, `SSH_AUTH_SOCK`, connector
variables, and all other inherited host state. Network namespace isolation
also prevents a role from publishing even if it constructs its own command.

Developer and test profiles have their own writable workspace/output pair.
A reviewer profile additionally requires a distinct existing developer checkout
with `.git`; only the reviewer checkout is mounted at `/workspace`.
The developer checkout is only a coordinator-side identity check and is not
mounted, so reviewer code cannot read or modify it.

Focused evidence is `Feature.SandboxTest`: coordinator runtime and token
absence, SSH agent/key absence, credential-helper hardening, writes rejected
outside role mounts, permitted workspace/output writes, reviewer checkout
reads, and failed reviewer writes against the developer host path. Its
`ProcessOwner` companion smoke tests prove that the Task 2 subprocess path
uses the sandbox and that raw launch APIs fail closed.

This boundary deliberately does not run `codex exec`, make API calls, or
publish. Task 4 must define a non-host-credential login/credential-broker flow
(or a sandbox-local authenticated session) before adding Codex authentication;
it must not reintroduce host `HOME`, agent sockets, token variables, or
credential helpers.

## Stage 2 / Task 4 — secure Codex execution

`Feature.CodexExec` runs one structured `codex exec` invocation exclusively
through `ProcessOwner` and a Codex sandbox profile. Authentication is copied
into a disposable sandbox-local Codex home and removed by process cleanup. The
host Codex home, configuration, SSH state and tracker credentials are not
mounted. Codex API transport is available, while model-issued workspace
commands are configured without network access. The Codex-only profile mounts
the pinned `codex` and `codex-code-mode-host` executables read-only under
`/opt/codex/bin`, enables `features.code_mode_host=true` for that invocation,
and supplies only a sandbox-local tmpfs `/tmp` mountpoint for the host's nested
tool sandbox. It does not mount host `config.toml` or the broader Codex package.

Each result is fenced to its `attempt_id`, `execution_id`, `role`, and
`task_id`. The adapter uses ephemeral Codex sessions, bounds captured output,
validates JSONL and final structured output, rejects identity mismatches, and
does not permit Developer output to claim a SHA. `Feature.CodexRoleExecutor`
adds Task 6's role-specific result schemas and prompts on top of this transport.

## Stage 2 / Task 5 — coordinator-owned local Git

`Feature.Git` accepts only a repository root on the expected local feature
branch with no merge, cherry-pick or rebase in progress. A clean workspace
selects `HEAD`. For normal local feature execution, dirty paths have
**whole-repository scope, protected paths only**: every changed and untracked
path below the repository root is checked for traversal and symlink escapes,
checked against protected paths, then captured together in one coordinator-owned
commit using repository-local identity. Changes outside the repository are
never accepted.

The default protected policy covers `.git/**` and common private credential
files when present (`.env*`, `*.pem`, `*.key`, `id_rsa`, `.netrc`, and
`credentials*`/`secrets*`). Callers can add (not replace) repository-relative
`protected_paths`, for example `.github/workflows/**`, CI/publishing,
deployment, infrastructure, or other security-sensitive paths. Protection wins
over every other setting, and capture reports the exact blocked paths; it never
discards them.

`allowed_paths` remains available only as an intentionally narrow strict mode
for higher-risk workflows. If it is omitted, the whole repository is in scope
subject to `protected_paths`. If it is supplied (including an empty list), every
changed path must match it *and* must not match `protected_paths`. Thus,
`protected_paths` always takes precedence. The coordinator reads the resulting
commit directly from Git and durably binds it to the Developer attempt. Any
model-provided SHA is non-authoritative.

Review assignments are durably bound to the implementation attempt and SHA.
Each assignment creates a detached worktree outside the Developer repository,
and validation requires the exact attempt, execution, role, task and SHA while
the checkout still points at that commit. Assignment creation is idempotent for
restart recovery. Applied reviewer worktrees are removed, while their durable
assignment rows remain as evidence. Missing identity, wrong branch, unsafe
checkout paths, unexpected dirty files, in-progress Git operations, stale
identity and checkout tampering all fail closed.

## Stage 2 / Task 6 — complete local feature flow

`Feature.LocalRunner.run/3` is the opt-in, sequential local coordinator. It
runs:

`Planning -> Developer -> coordinator Git capture -> executable validation of
the immutable candidate SHA/tree -> exact-SHA Reviewer -> FinalReview -> final
executable validation of that same SHA/tree -> central readiness gate ->
ReadyForHuman`.

The planner is a real Mastermind role when configured with
`Feature.CodexRoleExecutor.executor/1`; it receives the approved specification
as authoritative and must return exactly two small ordered tasks. Developer,
Reviewer and FinalReview use the same secure Codex path. Every invocation gets
a distinct fenced execution and ephemeral Codex session. A Reviewer sees only
its detached exact-SHA checkout, never the mutable Developer workspace.

Role output is first stored in `local_role_outputs`, before coordinator Git
capture or state transition. This lets restart recovery reuse a completed role
result without invoking the role again. Implementation commits and reviewer
assignments have their own durable tables, so recovery after Developer output,
commit capture, reviewer checkout creation, or Reviewer output cannot silently
switch the SHA under review. Recorded FeatureRunner attempts retain the earlier
apply-on-restart behavior. Applied reviewer checkouts are reconciled and
removed on subsequent steps if cleanup was interrupted.

A changes-requested review returns to the same task, increments its durable
`rework_count`, captures a new implementation attempt/SHA, and requires a new
review assignment. `max_reworks` is explicit and bounded (default: 2); exceeding
it produces `Failed`. Technical questions enter `Resolving`. The Mastermind is
instructed to answer from the approved specification, plan, repository and
existing contracts, and to use `WaitingForHuman` only for a genuinely new
product decision, security-invariant change, or materially incompatible public
contract change.

Every executable validation uses a fresh detached worktree at the captured
candidate SHA. Its durable `validation_evidence` row records the SHA and tree,
command, working directory, timestamps, exit status, passed/failed/blocked
outcome, and bounded diagnostics. The coordinator verifies HEAD, tree, and a
clean checkout after the validator returns; a validator that changes sources
produces blocked evidence rather than evidence for the earlier tree.

Reviewer and FinalReview assignments are authoritative only after passed
validation evidence for their exact candidate SHA. Compile/test failures return
the affected task to Developer repair; unavailable tooling or environment stays
`ValidationBlocked` and is not classified as an implementation failure.

FinalReview is another exact-SHA reviewer assignment. Its approval starts final
validation; it does not directly enter `ReadyForHuman`. The central readiness
predicate is the sole transition to that state and requires accepted tasks, an
approval and passed final validation for the same final SHA, no actionable
findings or blockers, no pending human decision, and no active writer.
`ReadyForHuman` means local implementation and review are complete, not pushed,
published, or merged.

Example opt-in construction from `elixir/`:

```elixir
alias SymphonyElixir.Feature.{CodexRoleExecutor, LocalRunner, Store}
alias SymphonyElixir.FeatureRunner

Store.init(runtime)
FeatureRunner.create(runtime, feature_id, approved_specification)

LocalRunner.run(runtime, feature_id, %{
  workspace: developer_workspace,
  expected_branch: "feature/attendance",
  reviewer_root: reviewer_root,
  output_root: output_root,
  protected_paths: [
    ".github/workflows/**",
    "ci/**",
    "deploy/**",
    "infrastructure/**"
  ],
  max_reworks: 2,
  executor: CodexRoleExecutor.executor(%{model: "<codex-model>", reasoning_effort: "high"}),
  validator: fn %{workspace: workspace} ->
    case System.cmd("make", ["all"], cd: Path.join(workspace, "elixir"), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, %{status: status, output: output}}
    end
  end
})
```

Do not add `allowed_paths` for ordinary feature work. To deliberately opt into
strict scope, add it alongside the protected paths, for example
`allowed_paths: ["lib", "test", "mix.exs"]`; this is an additional restriction,
not a replacement for protected-path enforcement.

The acceptance suite uses fixture roles and real temporary Git repositories. It
proves planning, both tasks, exact-SHA review, rejected-review rework with a new
SHA and fresh review, stale review rejection, final exact-SHA review, mandatory
validation, `ReadyForHuman`, and recovery without duplicate completed role
execution. A real model smoke is intentionally optional; the secure Codex
transport has its own focused integration tests.

Task 6 remains local-only. It does not modify the production orchestrator or
`AgentRunner` and has no GitHub, push, PR, Linear, dashboard, child-issue,
parallel Developer or remote publishing behavior.


## POC coverage threshold

The POC coverage threshold is 95%. This keeps the gate high while recognizing
that its security confidence comes primarily from explicit invariant and
recovery tests for FeatureRunner, ProcessOwner and Sandbox, rather than from a
global 100% line-coverage target. No modules or lines are excluded to reach
this threshold.
# LocalRunner workspace and status notes

The standalone LocalRunner deliberately does not publish activity to the
standard Symphony web dashboard. Inspect its journal without changing it with:

```bash
cd elixir
mix feature.status /path/to/state.sqlite3 <feature-id>
mix feature.status /path/to/state.sqlite3 <feature-id> --watch
```

`--watch` only repeats SQLite reads; it never retries, reconciles, or starts a
feature.
