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

## Scope limits

No real model sessions, retry budgets, schema migrations, multi-host scheduling,
dashboard, credentials, branch enforcement, isolation or Git/CI validation.
Schema is initial v1 only. Transaction/contract errors are explicit exceptions;
role-reported failure is a persisted Failed state. No automatic loop is exposed:
step performs at most one role result/transition. SQLite lock plus revision
protects this core, not future external agent side effects.

## Validation

Run `mix test test/symphony_elixir/feature_runner_test.exs`, `mix lint`,
`mix format --check-formatted`, full repository tests and `make all`.
The test suite covers the two-task rework lifecycle, recorded developer/reviewer
recovery, human waits and stale answers, technical resolution, final-review
rework, stale reviews, malformed plans, failed roles, competing/killed writers,
idempotent creation, effect intent recovery and lost effect confirmation.
