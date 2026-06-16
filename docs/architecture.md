# Tango Gleam Architecture

Status: Draft v0

This document maps the language-agnostic Tango specification to a Gleam implementation. It keeps Codex and Git details behind adapters while delegating external ticket and pull-request operations to user-provided agent skills and tools.

## 1. Implementation Posture

Tango should be a local Gleam/OTP application with a CLI entrypoint and a supervised daemon mode.

Primary implementation goals:

- one authoritative orchestrator process owns scheduling decisions;
- ticket state is durable and restartable;
- each active agent run is isolated in its own supervised worker;
- human review is represented as durable state, not a blocked worker process;
- Codex is an adapter around the operator's local Codex installation;
- repository workflow files are not required or discovered.

The initial runtime should be optimized for correctness and inspectability over maximum automation. The assigned agent owns implementation commits and merge execution, but merge execution is disabled until a human approval authorizes the exact reviewed commit set.

Resolved initial decisions:

- Durable state uses JSON files.
- Durable state and managed workspaces live under `~/.tango`.
- One agent run progresses continuously through research, planning, implementation, and commit creation before human review.
- Tickets support multiple repository bindings from the start.
- `aicasa` is the sole external workspace-provisioning dependency and creates one multi-repository workspace per ticket.
- Tango has no built-in ticket-provider or forge adapters.
- Every dispatchable ticket selects an external ticket registry, an operator-approved registry CLI, an agent registry skill, and one MVP-level GitHub or Forgejo binding.
- Tango manages installation and selection of user-chosen skill/tool capability profiles that let agents fetch and fully manage external tickets and pull requests.
- Registry skills discover stable external status IDs during onboarding; Tango stores a pinned semantic status mapping for the ticket.
- Tango lifecycle states remain authoritative. External registry updates mirror semantic roles, with internal `Failed` mirrored as external `blocked`.
- Research and planning are instruction-enforced rather than mechanically read-only.
- Every agent run receives a narrowly writable workpad under `~/.tango/workpads`.
- The agent owns implementation commits.
- The agent creates pull requests and, after a human-only approval gate, owns pull-request merge execution.
- Each task owns one main implementation session and an append-only array of auxiliary sessions for follow-up implementation, pull-request feedback, registry-status synchronization, and merge work.
- Later requested implementation changes create a fresh auxiliary implementation session linked back to the main session through `context_session_ids`; pull-request feedback checks, registry-sync work, and merge work also use auxiliary sessions.
- The initial Codex transport is `codex exec --json`.
- Prompts instruct agents to post progress and handoff comments back to external tickets through their capability profiles, but those comments are not lifecycle-gating evidence.
- Only `tango review merge <ticket>` creates an approval decision, advances Human Review to Merging, and appends an auxiliary merge session.
- Completed workspaces, workpads, artifacts, events, and usage history are retained indefinitely by default.
- The MVP intentionally uses agent instruction and process spindown as its high-trust merge boundary.
- New tickets are queued explicitly by CLI; a Tango watch loop cheaply polls
  pull-request conversation comments while tickets await review and starts
  bounded agent checks only when new comments exist.
- Review watching uses a stored per-pull-request comment count and only processes comments when the count increases.
- The MVP assumes the operator runs only one Tango daemon or foreground `tango run` process at a time.
- The initial human review surface is an interactive CLI; the next operator surface is a terminal dashboard.

## 2. Proposed Application Shape

Suggested module layout:

```text
src/
  tango.gleam
  tango/app.gleam
  tango/cli.gleam
  tango/config.gleam
  tango/domain/
    ticket.gleam
    lifecycle.gleam
    registry_status.gleam
    repo.gleam
    artifact.gleam
    event.gleam
  tango/store/
    store.gleam
    json_store.gleam
    memory_store.gleam
  tango/orchestrator.gleam
  tango/worker.gleam
  tango/workspace/
    workspace.gleam
    aicasa.gleam
  tango/prompt.gleam
  tango/agent/
    adapter.gleam
    codex.gleam
    fake.gleam
  tango/vcs/
    adapter.gleam
    git.gleam
  tango/capability/
    capability.gleam
    manager.gleam
  tango/review.gleam
  tango/watch.gleam
  tango/merge.gleam
  tango/observability.gleam
  tango/dashboard.gleam
  tango/store_server.gleam
  tango/review_watcher.gleam
  tango/terminal_dashboard.gleam
```

The `domain` modules should stay pure. Anything that launches processes, reads files, writes state, or calls network APIs should sit behind ports/adapters.

Tango does not perform ticket-provider or forge mutations. Ticket onboarding
records an external ticket reference and a capability profile naming the
user-provided skills/tools the agent should use. The agent remains responsible
for mutations, while Tango-owned read-only attestation adapters independently
verify promotion-critical ticket and pull-request state. Tango's JSON ticket is
authoritative for orchestration state.

## 3. OTP Supervision Model

Suggested supervision tree:

```text
TangoAppSupervisor
  StoreServer
  EventBus
  CapabilityManager
  RepoRegistry
  Orchestrator
  ReviewWatcher
  WorkerSupervisor
  TerminalDashboard
```

Responsibilities:

- `StoreServer`: serializes writes to durable state and exposes query/update functions.
- `EventBus`: broadcasts lifecycle and runtime events to logs, status views, and tests.
- `CapabilityManager`: installs, validates, and selects operator-approved skill/tool bundles.
- `RepoRegistry`: validates and caches repository bindings.
- `Orchestrator`: owns scheduling state, claims, retries, and reconciliation.
- `ReviewWatcher`: cheaply polls read-only forge comment streams for tickets awaiting review and schedules review-feedback agents only when new conversation comments exist.
- `WorkerSupervisor`: starts temporary execution, review-watch, registry-sync, or merge workers.
- `TerminalDashboard`: presents live orchestrator state without owning correctness.

The orchestrator should monitor workers and treat worker exits as messages. Workers should never directly mutate scheduling state.

## 4. Core Types

The exact syntax will evolve, but the implementation should model the spec with explicit algebraic data types rather than stringly typed state.

```gleam
pub type LifecycleState {
  Onboarded
  Queued
  Researching
  Planning
  Implementing
  AwaitingHumanReview
  ChangesRequested
  Merging
  Done
  Blocked
  Failed
  Canceled
}

pub type Stage {
  Research
  Plan
  Implement
  HumanReview
  Merge
}

pub type RuntimeName {
  Codex
  Fake
  External(String)
}

pub type RepositoryKind {
  GitRemote
  ExternalRepo(String)
}
```

Records should be defined for:

- `Ticket`
- `RepoBinding`
- `AgentAssignment`
- `CapabilityProfile`
- `RegistryBinding`
- `RegistryStatusMapping`
- `StageArtifact`
- `AgentSession`
- `RunAttempt`
- `ReviewDecision`
- `ReviewCommentCursor`
- `BlockRecord`
- `MergeRecord`
- `TangoEvent`

Use opaque constructors or validation functions for IDs, branch names, and repository bindings so invalid tickets fail before scheduling.

Registry status roles should use an explicit algebraic data type:

```gleam
pub type RegistryStatusRole {
  Backlog
  Todo
  InProgress
  HumanReview
  Merging
  Blocked
  Done
  WontDo
}
```

`RegistryBinding` stores the selected registry name, CLI command, registry skill, external ticket reference, and pinned mapping digest. `RegistryStatusMapping` stores one resolved stable external status ID and display name for every `RegistryStatusRole`.

`ForgeBinding` stores one ticket-level forge name, CLI command, and forge skill. The MVP accepts only configured `github` and `forgejo` bindings and requires every repository on the ticket to use that selected forge. Per-repository forge bindings are deferred until mixed-forge tickets are supported.

Onboarding validates explicit repository remote hosts against the selected forge before registry discovery or ticket persistence. GitHub accepts explicit `github.com` remotes; Forgejo rejects `github.com` remotes and accepts other explicit hosts. GitHub `owner/repo` shorthand and full Git clone URLs are eligible workspace sources. Local absolute and relative paths are rejected so aicasa always creates an isolated clone owned by the ticket workspace.

`AgentSession` should model:

```gleam
pub type SessionRole {
  Main
  Aux
}

pub type SessionKind {
  Implementation
  PrFeedback
  RegistrySync
  Merge
}
```

The ticket stores one optional main session ID and an ordered append-only list
of auxiliary session IDs. The main session kind is always `Implementation` and
has an empty `context_session_ids` list. Auxiliary session kinds are
`Implementation`, `PrFeedback`, `RegistrySync`, or `Merge`. Every session
stores an ordered `context_session_ids` list for durable cross-session lookup;
requested-changes implementation sessions must reference the main session ID
first and may append prior follow-up implementation session IDs when their
artifacts remain relevant. A session also stores its runtime session ID when
available and an ordered list of associated run attempt IDs.

## 5. Durable State

The MVP uses JSON files with an in-memory store for tests.

Rationale:

- lifecycle state needs durable review waits and restart recovery;
- JSON files are inspectable, portable, and easy for operators to recover manually;
- one `StoreServer` serializes writes, avoiding concurrent writers inside a Tango process;
- atomic temporary-file writes followed by rename prevent partially written state files;
- tests can run against the same store behavior through a `Store` interface.

Recommended layout:

```text
~/.tango/
  tickets/
    <ticket-id>/
      ticket.json
      assignment.json
      repo-bindings.json
      registry-binding.json
      registry-status-mapping.json
      sessions/
        main.json
        aux/
          <session-id>.json
      artifacts/
        <artifact-id>.json
      runs/
        <run-id>.json
      reviews/
        <review-id>.json
      review-cursors.json
      blocks/
        <block-id>.json
      merges/
        <merge-id>.json
      events/
        <event-id>.json
  capabilities/
    <profile-id>.json
  workspaces/
    <ticket-workspace-name>/
      .aicasa.json
      <repository-directory>/
  workpads/
    <ticket-id>/
      <run-id>/
        manifest.json
        stage.json
        ticket.json
        research.md
        plan.md
        diff-summary.md
        implementation.md
        validation.json
        pull-requests.json
        review-comments.json
        merge.json
        external-updates.json
        result.json
```

Each JSON document should include a schema version. State replacement should write a sibling temporary file, flush it, then atomically rename it. Events should be immutable individual JSON documents so event history remains append-only.

CLI commands should send mutations through the running `StoreServer`; offline mutation commands must acquire an exclusive `~/.tango/lock` before writing.

The MVP deliberately does not implement multi-document transactions or distributed locking. It assumes one Tango process, writes immutable artifacts, sessions, and decisions before replacing `ticket.json`, and treats `ticket.json` as the authoritative lifecycle projection. On startup, reconciliation ignores unreferenced immutable files and moves a ticket to `Blocked` when its authoritative projection references missing or invalid required state.

Workpads are agent-authored handoff areas, not authoritative Tango state. A worker validates workpad contents and promotes accepted outputs into immutable artifacts. Agent sandboxes must receive write access only to their repository workspaces and exact run workpad; they must not receive write access to ticket, review, event, or approval state under `~/.tango`.

Completed workspaces, workpads, artifacts, events, and usage records are retained indefinitely by default. Explicit operator pruning may be added later but must never happen automatically.

### 5.1 Workpad Protocol

The workpad is a versioned file protocol between Tango and an agent process. Protocol JSON Schemas must live under `priv/schemas/workpad/v1/` and be included verbatim in the prompt envelope.

Tango creates `manifest.json` before launch. It contains `schema_version`, `ticket_id`, `session_id`, `session_role`, `run_id`, `run_kind`, `workspace_path`, repository binding-to-path mappings, allowed output filenames, and required artifacts. The agent treats it as immutable, and the worker validates outputs against its own stored copy rather than trusting the workpad copy.

The agent may atomically replace `stage.json` while running:

```json
{
  "schema_version": 1,
  "run_id": "run-id",
  "sequence": 2,
  "current_stage": "planning",
  "history": [
    {
      "sequence": 1,
      "stage": "researching",
      "reported_at": "RFC3339 timestamp"
    },
    {
      "sequence": 2,
      "stage": "planning",
      "reported_at": "RFC3339 timestamp"
    }
  ]
}
```

`sequence` must increase monotonically, and each replacement must preserve all prior history entries unchanged. This lets Tango recover every reported transition even if polling misses an intermediate file version. Stage reports are observability signals only; Tango must not pause or gate the execution agent when it moves from research to planning to implementation.

Agent-authored JSON and Markdown outputs must be written to a sibling temporary file and renamed into place. Output references must be relative filenames from the manifest, must not contain `..`, and must not resolve through symlinks outside the run workpad.

Minimum structured outputs:

- `ticket.json`: normalized external reference, title, description, acceptance criteria, labels, blockers, and observed external registry status.
- `validation.json`: a list of checks with command or check name, status, and summary.
- `pull-requests.json`: repository binding ID, commit ID, pull-request reference,
  head commit ID, source branch, target branch, and final observed comment count
  for each modified repository.
- `review-comments.json`: pull-request reference, previous and final comment counts, only the newly observed comments, and whether the agent found actionable feedback.
- `merge.json`: ordered pull-request merge entries with repository binding ID, approved head, and `completed`, `pending`, or `failed` status.
- `external-updates.json`: external TODO/checklist edits, comments, or state changes the agent reports attempting, requested semantic status role, requested stable status ID, observed final stable status ID, plus final observed comment counts when applicable. TODO/checklist and comment reports are observability-only and must not gate lifecycle promotion.
- `result.json`: final status, optional block description, and a map of artifact kinds to workpad filenames.

Example final completion marker:

```json
{
  "schema_version": 1,
  "run_id": "run-id",
  "status": "succeeded",
  "completed_at": "RFC3339 timestamp",
  "artifacts": {
    "normalized_ticket": "ticket.json",
    "research_notes": "research.md",
    "plan": "plan.md",
    "diff_summary": "diff-summary.md",
    "implementation_notes": "implementation.md",
    "validation_report": "validation.json",
    "pull_request_set": "pull-requests.json",
    "external_updates": "external-updates.json"
  },
  "block": null
}
```

Required outputs depend on `run_kind`: execution requires the normalized ticket, research, plan, implementation, validation, pull-request, and external-update outputs; review-watch requires review-comments and external-update outputs; registry-sync requires external-update output; merge requires merge and external-update outputs. `result.json` is the completion marker and must be renamed into place last. Its status is `succeeded`, `blocked`, or `failed`; `blocked` must include the reason and resolution instructions used to create a `BlockRecord`.

The worker may observe `stage.json` during execution, but it validates and promotes outputs only after the agent process exits successfully and `result.json` validates. A missing or malformed result fails the run without promoting artifacts. Repository changes and the workpad remain available for inspection or retry.

## 6. Lifecycle Engine

The lifecycle engine should be pure and heavily tested.

Responsibilities:

- validate legal transitions;
- record non-gating execution-stage progress;
- decide whether human review is waiting;
- decide whether a ticket is dispatch-eligible;
- distinguish infrastructure retry from human-requested implementation loops.

Suggested API:

```gleam
pub fn can_transition(
  from state: LifecycleState,
  to next: LifecycleState,
  context context: TransitionContext,
) -> Result(Nil, LifecycleError)

pub fn record_execution_progress(
  ticket ticket: Ticket,
  stage stage: Stage,
) -> Result(LifecycleState, LifecycleError)
```

Keep this module independent of Codex, Git, JSON storage, and the CLI.

`record_execution_progress` accepts monotonic `Research -> Plan -> Implement` reports from the active execution attempt. These reports update visible lifecycle state but do not gate or interrupt the agent.

## 7. Orchestrator

The orchestrator should be a `gleam_otp` process that owns:

- in-memory claims;
- running worker refs;
- retry timers;
- concurrency counters;
- polling cadence;
- status snapshots.

Message examples:

```gleam
pub type OrchestratorMessage {
  Tick
  DispatchTicket(String)
  WorkerStarted(ticket_id: String, run_id: String)
  WorkerEvent(ticket_id: String, event: AgentEvent)
  WorkerExited(ticket_id: String, result: WorkerResult)
  RetryDue(ticket_id: String)
  ReviewSubmitted(ticket_id: String, decision: ReviewDecision)
  Unblock(ticket_id: String)
  Cancel(ticket_id: String)
}
```

Scheduling loop:

1. Reconcile running workers.
2. Load dispatchable tickets from the store.
3. Filter by blockers, claims, review gates, repository limits, agent limits, and stage limits.
4. Claim tickets in memory and persist a claim/run attempt event.
5. Start workers under `WorkerSupervisor`.
6. Release or retry claims on worker exit.

The MVP assumes one Tango process and does not attempt cross-process claim fencing. On restart, interrupted execution, review-watch, and registry-sync attempts are marked failed and made retryable from their prior dispatch state. An interrupted merge attempt moves to `Blocked` because external merge progress may be uncertain; a human resolves the issue, runs `tango ticket unblock`, and invokes `tango review merge` again.

## 8. Worker Lifecycle

An execution worker handles one ticket's implementation session. The main
session covers the initial research, planning, implementation, and commit
creation pass. Later requested-changes passes run in fresh auxiliary
implementation sessions that point back to the main session through
`context_session_ids`. Human review does not consume a worker while waiting for
a person.

Execution worker sequence:

1. Load ticket, create or load its main implementation session, and load prior artifacts.
2. Ask `aicasa` to create or inspect the ticket's multi-repository workspace.
3. Create the run workpad and build one autonomous execution prompt envelope.
4. Launch the assigned local agent through `AgentAdapter`.
5. Require the agent to fetch the external ticket using the selected capability profile and write a normalized ticket snapshot to the workpad.
6. Require the agent to reconcile the external ticket to the stable status ID mapped from the current Tango lifecycle state and report the observed final status.
7. Observe workpad stage markers as non-gating progress reports while allowing the agent to continue.
8. Allow implementation and require the agent to commit changes in every modified repository.
9. Require the agent to use its capabilities to push work branches, open pull requests, and update external ticket state.
10. Instruct the agent to post a review handoff comment, record final observed comment counts, write `result.json` last, and exit.
11. Validate the final workpad result, clean repositories, commit IDs, reported pull-request heads, required artifacts, and acceptance checks.
12. Persist the reviewed commit and pull-request set, initialize review comment cursors from the final observed counts, and transition to `AwaitingHumanReview`.

Because one agent run crosses research, planning, and implementation, Tango enforces the early read-only stages through instructions rather than sandbox changes. The workpad provides the agent a writable place to report stage progress and artifacts. These reports never pause the agent; the worker validates and promotes them after the process exits.

When pull-request feedback requests changes, Tango appends an auxiliary
`Implementation` session linked to the main session. The new session carries
`context_session_ids` for the main session and any still-relevant prior
follow-up implementation sessions. Tango rebuilds the prompt from durable
artifacts, review feedback, current commit and pull-request state, and
external references, then launches a fresh execution attempt. The agent
reconciles existing external state, addresses feedback, creates new commits,
updates the pull request, and returns the ticket to human review. Tango does
not resume the previous runtime thread for this flow.

The current MVP `ReviewWatcher` periodically polls read-only forge comment
streams for each pull request on tickets awaiting review. The forge adapter
returns normalized conversation comments only; approvals, checks, status
changes, and other non-comment activity are excluded before Tango considers
dispatch. If the normalized comment count is unchanged, Tango updates the
cursor observation timestamp and does not start an agent. If the count
increases, Tango leaves the cursor at the previous count and appends a bounded
auxiliary `PrFeedback` session to interpret only the newly observed comments.
Before that agent exits, it obtains the final total count after any comments it
posted; Tango advances the cursor to `max(previous_count, final_count)` so the
agent's own comments are not treated as new on the next poll. Comment edits and
deletions do not wake the MVP watcher. The auxiliary session may trigger
`changes_requested`; it never interprets external approvals as Tango approval,
modifies implementation, or authorizes merge.

A separate merge worker starts only after a human invokes `tango review merge <ticket>` and Tango creates the approval decision. Tango appends an auxiliary `Merge` session with the approved commit and pull-request set plus merge instructions. The merge agent reconciles current pull-request state, merges the pull requests, and closes the external ticket when present. If merge conflict resolution or any other action changes implementation commits or pull-request heads, the merge worker must stop and return the ticket to human review. The merge session never resumes or replaces the main session.

## 9. Prompt Assembly

Prompt assembly belongs in Gleam, not inside free-form ticket text.

Inputs:

- stable Tango lifecycle instructions;
- current stage contract;
- ticket title, description, acceptance criteria, labels, and blockers;
- selected registry, registry CLI, registry skill, and pinned semantic status mapping;
- selected ticket-level forge, forge CLI, and forge skill;
- repository binding details;
- workspace path;
- run workpad path and artifact schemas;
- referenced `context_session_ids` and the selected prior artifacts from them;
- prior artifacts;
- permission and safety constraints;
- required output schema.

Recommended prompt sections:

```text
# Tango Stage
# Ticket
# Repository
# Prior Artifacts
# Current Task
# Required Output
# Constraints
```

Ticket content can replace task-specific workflow details, but it should not replace Tango's lifecycle contract or safety constraints.

## 10. Codex Adapter

The Codex adapter should be one implementation of `AgentAdapter`.

Suggested interface:

```gleam
pub type AgentAdapter {
  AgentAdapter(
    start: fn(AgentStartRequest) -> Result(RuntimeSession, AgentError),
    run: fn(RuntimeSession, AgentRunRequest) -> Result(AgentRunOutput, AgentError),
    stop: fn(RuntimeSession) -> Result(Nil, AgentError),
  )
}
```

Codex-specific details should live in `tango/agent/codex.gleam`:

- command discovery;
- protocol selection;
- sandbox/approval configuration;
- event parsing;
- timeout and stall detection;
- token usage extraction;
- final artifact extraction.

Selected initial transport: `codex exec --json`.

The adapter launches each attempt with the inspected `aicasa` workspace as Codex's workspace root:

```text
codex exec --json --cd <ticket-workspace-path> --sandbox workspace-write <prompt>
```

Runtime configuration must add only the exact run workpad as an additional
writable root. Requested-changes implementation sessions, review-watch
sessions, registry-sync sessions, and merge sessions all start independently
with `codex exec`. Requested-changes sessions rely on `context_session_ids`
and durable artifacts rather than runtime resume.

| Concern | `codex exec` | `codex app-server` |
| --- | --- | --- |
| Maturity | Stable | Experimental |
| Integration shape | Spawn one non-interactive process per execution, review-watch, registry-sync, or merge run | Implement a long-lived protocol client over stdio, WebSocket, or Unix socket |
| Events | Optional newline-delimited JSON event stream via `--json` | Structured request/response messages and continuous notifications |
| Continuity | Every main and auxiliary session starts with a fresh `exec` invocation | Explicitly start/resume threads and start turns |
| Control | Coarse process-level control | Fine-grained thread, turn, interruption, and event control |
| Tango implementation cost | Lower | Higher |

`codex exec --json` is stable and fits Tango's main-plus-auxiliary session
model. The first execution attempt creates the task's main Codex session and
records its runtime session ID. Each requested-changes implementation session,
review-watch session, registry-sync session, and merge auxiliary session
starts with a new `codex exec` invocation and records its own runtime session
ID. Requested-changes implementation sessions include the main session ID and
any relevant prior implementation session IDs in `context_session_ids` so
prompt assembly can point the agent at prior artifacts and external
references.

Tango rebuilds required context from JSON artifacts and external references
for every new session instead of relying on runtime resume. Prompt assembly
keeps durable instructions, tool definitions, and schemas in a consistent
prefix and appends volatile task updates later to maximize any available
prompt-cache reuse. Cache reuse is a cost optimization, not a correctness
requirement or guaranteed persistence across asynchronous gaps. `app-server`
remains a future adapter option when Tango needs fine-grained live controls
that `exec` cannot provide.

The architecture should support both behind the same adapter so this decision does not leak into the lifecycle engine.

## 11. Aicasa Workspace and Git Adapter

The workspace manager uses the external [`aicasa`](https://github.com/paradise-runner/aicasa) CLI for all workspace provisioning. Tango must not implement a second clone or worktree manager.

Recommended path shape:

```text
~/.tango/
  workspaces/
    <ticket-workspace-name>/
      .aicasa.json
      <repository-directory>/
  artifacts/
    <ticket-key>/
  logs/
```

Tango sets `AICASA_ROOT=~/.tango/workspaces`, derives a valid single-directory workspace name from the ticket ID, and invokes the `aicasa` binary directly rather than relying on the interactive `aic` shell wrapper:

```text
aicasa new <ticket-workspace-name> <repo-source>[,<repo-source>...]
aicasa add <ticket-workspace-name> <repo-source>[,<repo-source>...]
aicasa inspect <ticket-workspace-name>
```

At startup, Tango verifies that `aicasa` is installed and that `aicasa inspect` returns supported schema version `1`. The workspace name is a valid slug plus a stable hash of the Tango ticket ID so path derivation is deterministic and collision-resistant. If the workspace already exists, Tango inspects it, uses `aicasa add` for missing bindings, and inspects it again. Tango validates the inspection JSON schema, requires every repository to exist, and maps each inspected repository path back to exactly one repository binding. Because `aicasa` derives checkout directory names from repository source basenames, onboarding must reject bindings that would produce duplicate directory names. The inspected workspace root is the working directory and writable root for every agent attempt on the ticket.

The MVP supports `checkout_policy = clone` only. Full Git clone URLs and GitHub `owner/repo` shorthand are passed to `aicasa` as clone sources. Local Git paths, `reuse_local`, and worktree attachment must fail onboarding.

Git adapter responsibilities:

- validate each inspected repository and its configured remote;
- create one work branch per repository binding;
- report status and diff;
- validate agent-created implementation commits;
- expose a safe summary for review.

The agent owns commits. The implementation prompt must specify commit conventions, and Tango must reject implementation completion when a modified repository is dirty or lacks a resulting commit ID.

For multi-repository tickets, the review artifact contains an ordered commit set:

```text
<repo-binding-id> -> <commit-id>
```

Human approval is bound to this exact set. Any changed commit ID invalidates approval.

## 12. Agent Capability Profiles

A capability profile identifies user-provided skills and tools available to an
agent run. Tango implements only provider-specific read-only attestation
clients; provider mutations remain agent capabilities.

Responsibilities:

- fetch the external ticket and acceptance criteria;
- update external ticket lifecycle state and comments;
- push agent-created work branches;
- create or update one pull request per modified repository binding;
- obtain pull-request comment counts and fetch new pull-request comments for follow-up sessions;
- merge approved pull requests;
- write normalized results and external references to the workpad.

The `CapabilityManager` installs and validates capabilities selected by the operator, then records profiles under `~/.tango/capabilities`. Every dispatchable ticket must select a ticket system, a CLI and skill for that ticket system, and one configured GitHub or Forgejo forge binding available through its capability profile. Capability installation and profile mutation are operator-only operations; agents must not be able to install tools or change their own capability profile.

The MVP ships independent built-in `github` and `forgejo` ticket-system and forge definitions. `tango capability install ticket-system <github|forgejo>` writes an issue-management skill under `~/.tango/capabilities/ticket-systems/<provider>/` and updates only `[registries.<provider>]`. `tango capability install forge <github|forgejo>` writes a pull-request and merge skill under `~/.tango/capabilities/forges/<provider>/` and updates only `[forges.<provider>]`. GitHub capabilities use `gh`; Forgejo capabilities use `fj`. Each installation verifies its CLI on `PATH`, or installs the corresponding Homebrew formula when absent. Systems without the CLI or Homebrew fail installation with an operator-facing error rather than leaving partial configuration.

Every installable or selectable ticket system and forge must register a
read-only attestation adapter. Capability installation, profile creation, and
ticket onboarding reject providers without one, including providers added by
manual configuration. The configured GitHub adapter consumes structured `gh`
JSON reads. The Forgejo adapter runs repository-scoped `fj` reads from the
ticket workspace.

`tango capability install <ticket-system|forge> <provider> --skill-only` skips CLI discovery and package installation, writes the selected skill and manifest, and records the expected command. This mode is for operator-managed CLI installations; Tango does not guarantee that the command will be available to later agent runs.

`tango capability profile create <name> --ticket-system <name> --forge <name>` combines independently installed ticket-system and forge skills. The ticket-system CLI is exposed during execution and registry-sync runs; the forge CLI is exposed during execution, review-watch, and merge runs. The same CLI may satisfy both bindings without coupling their configuration or skills.

`tango ticket-system status-map <name> show|discover|validate|set` manages the
operator-owned mapping from Tango lifecycle roles to stable external status IDs.
Installing a ticket-system capability may write proposed defaults, but the
stored map starts with `status_map_validated = false`. `set --role <role>
--status-id <stable-id>` updates one mapping and clears validation. `show`
renders the provider kind, validation marker, and current role bindings.
`validate --repo <owner/repo>` independently confirms every required role maps
to an externally observable status before setting `status_map_validated = true`.
Ticket onboarding rejects unvalidated maps before it asks the configured
registry adapter for external status names.

GitHub and Forgejo are label-backed in the MVP: the stable external status ID is
the label name after provider validation. GitHub discovery uses `gh label list
--repo <owner/repo> --json name`, so `discover` can list repository labels.
Forgejo's MVP CLI integration does not expose a repository label-list command;
Forgejo `discover` and `validate` therefore verify the configured labels with
`fj --style minimal issue search --repo <owner/repo> --labels <label> --state
all` and report the configured labels that the provider command accepts. Future
ticket systems with first-class workflow statuses should implement discovery and
validation against stable workflow-status IDs, not label display names.

Each stored profile has a schema version and content digest. Every ticket pins the selected profile digest during onboarding, and every `RunAttempt` records that digest and its effective capability list. Later attempts continue using the pinned digest until an operator explicitly upgrades the ticket's profile.

Capability profiles do not contain provider credentials. The local Codex installation resolves and executes installed skills/tools using credentials available under operator policy. Prompts must distinguish capabilities allowed during autonomous execution from merge capabilities that may only be used after Tango records human approval.

The MVP uses a high-trust policy boundary: the implementation prompt explicitly forbids merging and requires the agent to stop after posting review handoff status. Tango does not start a merge worker until a human invokes `tango review merge <ticket>`. Provider-side branch protection and separate merge credentials are optional hardening, not MVP requirements.

Because external results are agent-reported, Tango independently validates
local commit IDs and worktree state and uses read-only attestation adapters
before promotion. Execution attestation verifies the external ticket's current
description revision, configured human-review status, and each reported pull
request's repository, branches, and head commit. Prompt-requested TODO/checklist
edits and progress or handoff comments are work-protocol instructions and
observability signals; their absence must not block promotion. Successful merge
attestation verifies every approved pull request is merged at the approved head
and the ticket is at the configured done status. Before creating or changing
external resources, prompts require the agent to inspect current state and
continue existing branches, pull requests, comments, and merges when they
already satisfy the requested outcome. Multi-repository merges are not atomic;
the agent must report the ordered merge plan and each completed pull-request
merge so Tango can record partial progress.

### 12.1 Registry Status Mapping

Before onboarding, an operator validates the selected ticket-system status map
with `tango ticket-system status-map <name> validate --repo <owner/repo>`.
During onboarding, Tango reads only validated configured mappings. The
configured registry adapter returns the validated stable ID and display-name
pairs, Tango resolves a complete semantic mapping, stores it with a content
digest, and pins that digest to the ticket.

Default lifecycle mapping:

| Tango lifecycle state | Registry role |
| --- | --- |
| `Onboarded` | `Backlog` |
| `Queued` | `Todo` |
| `Researching`, `Planning`, `Implementing`, `ChangesRequested` | `InProgress` |
| `AwaitingHumanReview` | `HumanReview` |
| `Merging` | `Merging` |
| `Blocked`, `Failed` | `Blocked` |
| `Done` | `Done` |
| `Canceled` | `WontDo` |

Multiple roles may resolve to the same external status ID. Missing or ambiguous roles fail onboarding and leave the ticket `Onboarded`.

After a Tango lifecycle transition, the active agent run receives the desired semantic role and its resolved stable external status ID when it can safely perform the update. Otherwise, Tango appends a bounded auxiliary `RegistrySync` session that only reconciles the external ticket status and reports the observed final status in `external-updates.json`. Terminal `Failed` transitions always request the external `Blocked` role. Registry-sync sessions cannot modify repositories, approve work, merge pull requests, or change Tango lifecycle state.

Tango does not derive or change its lifecycle state from the external status. Failed external updates are recorded for retry and block completion when the target role is `Done`.

## 13. Review and Merge

Human review should be stored as data:

- ticket enters `AwaitingHumanReview`;
- worker exits;
- reviewer inspects artifacts, pull requests, diffs, and CI results;
- reviewer comments on pull requests when changes are needed, may reject in the external ticketing tool, or invokes `tango review merge` to approve;
- orchestrator reacts on the next message/tick.

Actionable pull-request comments detected by the review watcher start a later
implementation attempt in a new auxiliary `Implementation` session linked to
the main session through `context_session_ids`. External ticket rejection may
transition the ticket to `Failed`. `Cancel` transitions to `Canceled`, and
`defer` leaves the ticket awaiting review.

Each `ReviewCommentCursor` contains a pull-request reference, the highest
observed non-negative comment count, and the observation timestamp. The
read-only forge adapter normalizes human- and agent-authored pull-request
conversation comments into a stable oldest-first list while excluding
approvals, statuses, checks, and other activity; the count is that list's
length. Cursors are initialized from the implementation agent's final observed
counts, refreshed by cheap watcher polls when unchanged, and advanced from
successfully validated review-watch results using `max(previous_count,
final_count)` after an agent interprets new comments. The MVP intentionally
does not detect edits or deletions.

Initial review CLI commands could be:

```text
tango review list
tango review show <ticket>
tango review merge <ticket>
```

`tango review merge <ticket>` displays Tango's latest durable commit and pull-request head sets, requires an interactive terminal and explicit confirmation, creates the durable `approve` decision for those exact sets, and authorizes the transition to `Merging`. The merge agent then verifies the live external heads before acting. This is a human-intent gate, not a strong security boundary: an agent able to spawn or drive a terminal may be able to invoke it.

The MVP accepts this high-trust boundary because the implementation agent is explicitly instructed to stop after requesting review. The merge action still belongs to Tango's CLI and is not part of the implementation agent's lifecycle prompt.

Merge coordinator and merge worker responsibilities:

- verify the approval created by the current `tango review merge` invocation;
- verify the current commit set exactly matches the reviewed commit set;
- require the agent to verify every pull-request head matches the approved commit set;
- verify workspace state;
- require the agent to verify configured CI and pull-request status through its capabilities;
- append an auxiliary `Merge` session to merge the approved pull requests and close the external ticket when present;
- stop and invalidate approval if the agent changes implementation commits or pull-request heads;
- record partial multi-repository merge progress;
- persist `MergeRecord`;
- transition to `Done` only after the merge session records a successful merge record, or to `Blocked` when human action is required.

For no-code tasks, `tango review merge` creates an approval for empty commit and pull-request sets and starts a merge/completion session that closes the external ticket when present and records an empty successful `MergeRecord`. This is the only no-code path to `Done`.

When a ticket has an external reference, the merge/completion session must close or complete it before reporting success. If that update fails, Tango creates a block record instead of entering `Done`.

The agent owns merge execution, but only Tango's review controller can create approval and authorize the transition from `AwaitingHumanReview` to `Merging`.

When an agent or Tango encounters a condition requiring manual work, it creates a `BlockRecord` with a reason, resolution instructions, blocked-from state, and a dispatchable or human-waiting resume state. Active execution failures resume at `Queued` or `ChangesRequested`; merge failures resume at `AwaitingHumanReview`. On partial multi-repository merge failure, the merge agent posts a comment when possible, records completed/pending/failed details, and Tango blocks the ticket with `AwaitingHumanReview` as its resume state. After resolving the issue, a human runs `tango ticket unblock <ticket>` and then invokes `tango review merge` again. The next merge agent inspects current PR state and skips already-completed merges.

## 14. CLI Surface

Minimum CLI for MVP:

```text
tango init
tango capability list
tango capability install <ticket-system|forge> <github|forgejo> [--skill-only]
tango capability profile create <name> --ticket-system <name> --forge <name>
tango ticket-system status-map <name> show
tango ticket-system status-map <name> discover --repo <owner/repo>
tango ticket-system status-map <name> validate --repo <owner/repo>
tango ticket-system status-map <name> set --role <role> --status-id <stable-id>
tango ticket create --repo <owner/repo-or-clone-url> [--repo <owner/repo-or-clone-url> ...] --ticket-ref <reference> --ticket-system <name> --forge <github|forgejo> --capability-profile <name> [--lifecycle-policy <reference>] [--queue]
tango ticket list
tango ticket show <ticket>
tango ticket queue <ticket>
tango ticket unblock <ticket>
tango run
tango status
tango dashboard
tango review list
tango review show <ticket>
tango review merge <ticket>
```

`tango run` can start the local daemon in the foreground for MVP. A later `tango daemon start` can add background operation.

`tango review merge` and `tango ticket unblock` require an interactive terminal and use the configured operator ID as `reviewer_id` or `resolved_by`. The MVP defaults a missing operator ID to `local:<operating-system-username>` and documents this as a high-trust identity assertion.

## 15. Configuration

Suggested local config keys:

```toml
[state]
dir = "~/.tango"

[operator]
id = "local-operator"

[orchestrator]
poll_interval_ms = 30000
max_concurrent_workers = 2

[agent.codex]
command = "codex"
transport = "exec"
default_model = ""

[workspace.aicasa]
command = "aicasa"
root = "~/.tango/workspaces"

[capability_profiles.default]
skills = ["~/.tango/capabilities/github/SKILL.md"]
execution_tools = ["gh"]
merge_tools = ["gh"]

[registries.linear]
cli = "linear"
skill = "linear-registry"

[registries.linear.statuses]
backlog = "stable-status-id-backlog"
todo = "stable-status-id-todo"
in_progress = "stable-status-id-in-progress"
human_review = "stable-status-id-review"
merging = "stable-status-id-review"
blocked = "stable-status-id-blocked"
done = "stable-status-id-done"
wont_do = "stable-status-id-canceled"

[forges.github]
cli = "gh"
skill = "github-forge"

[forges.forgejo]
cli = "fj"
skill = "forgejo-forge"

[review]
require_human_review = true
watch_interval_ms = 30000
watch_activity = "comments_only"

[merge]
authority = "agent_after_human_approval"

[retention]
completed = "indefinite"

[dashboard]
kind = "terminal"
```

This config should not live in target repositories by default. A project may choose to store a Tango config in its own orchestrator repo, but target code repositories must not be required to carry Tango workflow files.

## 16. Observability

The event schema should be stable enough for a future dashboard.

Minimum emitted events:

- `ticket.created`
- `ticket.queued`
- `ticket.claimed`
- `session.main_created`
- `session.aux_created`
- `session.context_linked`
- `registry.status_sync_started`
- `registry.status_sync_completed`
- `registry.status_sync_failed`
- `stage.started`
- `agent.event`
- `stage.succeeded`
- `stage.failed`
- `review.requested`
- `review.comments_detected`
- `review.watch_started`
- `review.watch_completed`
- `review.submitted`
- `merge.started`
- `merge.blocked`
- `merge.succeeded`
- `ticket.blocked`
- `ticket.unblocked`
- `ticket.done`

Logs should include `ticket_id`, `identifier`, `stage`, `run_id`, and `agent_runtime` when applicable.

## 17. Testing Strategy

Test layers:

- pure lifecycle transition tests;
- session-topology tests proving each task has at most one main implementation session and an append-only auxiliary session list;
- follow-up implementation session tests proving requested changes append auxiliary implementation sessions linked to the main session instead of resuming it;
- execution progress tests proving research and planning reports do not gate or interrupt the worker;
- prompt assembly golden tests;
- workpad protocol schema, path traversal, atomic completion marker, malformed output, and promote-after-exit tests;
- store contract tests against memory and JSON stores;
- atomic JSON write and restart recovery tests;
- startup reconciliation tests for orphaned immutable files and missing projection references;
- fake agent adapter tests for success, failure, timeout, malformed artifact, and cancellation;
- fake Git adapter tests for dirty workspace and merge precondition failures;
- fake read-only attestation adapter contract tests for ticket revisions,
  statuses, pull-request bindings, branches, heads, and merged state;
- fake `aicasa` adapter tests for workspace creation, inspection, partial-clone recovery with `add`, missing repositories, and duplicate checkout directory names;
- fake agent capability tests for ticket fetching, external-state reconciliation, pull-request head changes, comment-count changes, self-comment cursor advancement, and partial multi-repository merges;
- registry status mapping tests for stable-ID discovery, missing and ambiguous roles, shared external statuses, pinned mappings, and `Failed -> Blocked`;
- review-watcher tests proving unchanged counts do not start agents, only
  conversation comments trigger dispatch, actionable comments transition state,
  and comments arriving during a watch are included in the final cursor;
- merge-command tests proving it creates the approval decision and binds the confirmed commit and pull-request head sets;
- blocked-ticket tests for manual unblock, partial-merge recovery, already-merged pull requests, and required re-approval;
- no-code tests proving only `tango review merge` can start completion and reach `Done`;
- end-to-end local tests using fake adapters;
- optional integration tests against GitHub, Forgejo, and a real local Codex
  installation, gated behind environment variables.

The MVP should not require Codex to be installed for the core test suite.

## 18. Resolved MVP Policies

- Every dispatchable ticket must select a registry, registry CLI, and registry skill.
- Cost tracking stores raw token and runtime usage only; Tango does not calculate monetary cost in the MVP.
- Tickets pin the selected capability profile digest during onboarding. Changing it requires an explicit operator action.
- Durable JSON schemas require explicit versioned migrations; incompatible state must fail closed rather than being silently rewritten.
- Cancellation, shutdown, timeout, and stall behavior must be implemented and covered by restart-recovery tests before real-agent execution is enabled.

## 19. References

- Tango language-agnostic specification: [`../SPEC.md`](../SPEC.md)
- OpenAI Codex CLI `exec` reference: <https://developers.openai.com/codex/cli/reference#codex-exec>
- OpenAI Codex App Server: <https://developers.openai.com/codex/app-server>
- OpenAI Prompt Caching 201: <https://developers.openai.com/cookbook/examples/prompt_caching_201#42-stabilize-the-prefix>
- aicasa: <https://github.com/paradise-runner/aicasa>
