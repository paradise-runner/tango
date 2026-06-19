# Tango Orchestration Specification

Status: Draft v0, language-agnostic

Purpose: Define a local-first system that assigns tickets to AI coding agents and moves the work through research, planning, implementation, human review, merge, and completion.

This specification is partially informed by the OpenAI Symphony service specification. Tango intentionally differs from Symphony in three core ways:

- Tango does not require workflow files in target repositories.
- Tango binds repositories at ticket onboarding time; ticket contents can provide the task-specific workflow and agent instructions.
- Tango does not manage cloud-hosted agents. A conforming implementation runs locally and uses the coding-agent installation available on the operator's machine.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and `OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` means the behavior is part of the implementation contract, but this specification does not prescribe one universal policy. Implementations MUST document the selected behavior.

## 1. Problem Statement

Tango orchestrates local AI coding agents across a durable ticket lifecycle. The system accepts a work item, binds it to one or more repositories, assigns it to an agent, supervises local execution in isolated workspaces, records stage artifacts, pauses for human review, and coordinates merge completion.

Tango solves these operational problems:

- It turns local agent work into a repeatable lifecycle instead of ad hoc terminal sessions.
- It makes agent state and handoffs durable across restarts.
- It separates orchestration policy from agent execution details.
- It keeps repository selection explicit at ticket onboarding time.
- It makes human review and merge authority first-class lifecycle gates.

Important boundaries:

- Tango is an orchestrator, scheduler, state machine, and local runner.
- Tango is not a cloud agent control plane.
- Tango does not require a target repository to contain a Tango workflow file.
- Ticket updates, comments, pull requests, and merge operations MAY be performed by an agent using operator-selected skills/tools or by a human, depending on configured policy.

## 2. Goals and Non-Goals

### 2.1 Goals

- Represent agent work as a durable ticket lifecycle: `research -> plan -> implement -> human_review -> merge -> done`.
- Allow one assigned agent to progress autonomously from research through implementation without an intermediate human gate.
- Allow tickets to bind repository information and task instructions during onboarding.
- Dispatch bounded concurrent local agent runs.
- Preserve per-ticket workspaces and stage artifacts across restarts.
- Provide explicit human gates before merge completion.
- Support arbitrary external ticket and pull-request systems through user-provided agent skills and tools.
- Keep the language-agnostic spec independent from Gleam, Codex protocol details, tracker APIs, and forge-specific behavior.
- Expose operator-visible observability through structured events and status snapshots.

### 2.2 Non-Goals

- Hosting cloud agents or brokering remote agent sessions.
- Requiring `WORKFLOW.md` or any other Tango-specific workflow file inside target repositories.
- Replacing CI, code review tools, issue trackers, or source-control hosting.
- Acting as a general-purpose distributed workflow engine.
- Guaranteeing safe arbitrary code execution beyond the configured local sandbox, operating-system policy, and coding-agent runtime.
- Mandating one ticket tracker, forge provider, database, terminal UI, or merge strategy.
- Requiring built-in ticket-provider or forge adapters.

## 3. System Overview

### 3.1 Main Components

1. `Ticket Intake`
   - Creates local ticket stubs from external ticket references.
   - Captures external ticket references, ticket-system selection, ticket-system CLI and skill selection, ticket-level forge selection, capability profiles, repository bindings, task content when available, lifecycle overrides, labels, priority, and assignee intent.

2. `Ticket Store`
   - Persists normalized tickets, lifecycle state, stage artifacts, agent assignments, review decisions, and event history.
   - Does not require direct external tracker access.

3. `Repository Registry`
   - Validates repository bindings supplied at onboarding.
   - Normalizes clone sources, remotes, default branches, target branches, and checkout policy.

4. `Capability Manager`
   - Installs and validates operator-selected skill/tool bundles.
   - Defines which capabilities are available during execution and after human approval.
   - MUST NOT allow agents to install or change their own capabilities.

5. `Lifecycle Policy Engine`
   - Defines legal stage transitions, gate requirements, retry policy, and stage-level permissions.
   - Evaluates whether a ticket can enter the next stage.

6. `Orchestrator`
   - Owns scheduling state.
   - Claims eligible tickets, starts workers, handles retries, reconciles active runs, and releases claims.
   - MUST be the only component that mutates scheduling state.

7. `Workspace Manager`
   - Creates one deterministic per-ticket workspace containing all bound repositories.
   - Prepares repository checkouts according to the ticket's repository bindings.
   - Preserves or removes workspaces according to lifecycle policy.

8. `Harness Runtime Adapter`
   - Starts and supervises a local coding harness process for an assigned agent.
   - Receives the assembled run prompt, workspace path, workpad path, and optional runtime resume session.
   - Maps Tango's harness request/response contract to the selected local harness, such as Codex.

9. `VCS Adapter`
   - Prepares repositories and validates source-control state, branches, diffs, and agent-created commits.
   - SHOULD support Git for the initial implementation.

10. `Review Gate`
   - Records durable review outcomes, including human approvals, external rejection or cancellation, deferral, and changes requested by watched pull-request feedback.
   - MUST create the approval decision only when a human invokes `tango review merge`.

11. `External Activity Watcher`
    - Watches tickets awaiting human review.
   - Uses read-only forge adapters to compare pull-request conversation comment counts, then starts bounded local agent checks only when new comments need interpretation.
    - MAY transition actionable feedback to `changes_requested`, but MUST NOT transition a ticket to `merging`.

12. `Merge Coordinator`
    - Verifies merge preconditions.
    - Creates an auxiliary merge session to merge approved pull requests after human review.

13. `Observability Surface`
    - Emits structured logs and status snapshots.
    - MAY provide a terminal UI, HTTP API, dashboard, or CLI status commands.

### 3.2 Abstraction Layers

1. `Task Policy Layer`
   - Ticket content, acceptance criteria, lifecycle overrides, and task-specific agent instructions.

2. `Configuration Layer`
   - Local Tango service configuration, adapter settings, concurrency limits, sandbox defaults, and operator preferences.

3. `Coordination Layer`
   - Scheduling, claims, retries, lifecycle gates, reconciliation, and durable state transitions.

4. `Execution Layer`
   - Workspace preparation, local agent subprocess supervision, VCS operations, and artifact collection.

5. `Integration Layer`
   - Local agent runtime adapters, user-provided agent skills/tools, and notification sinks.

6. `Observability Layer`
   - Events, logs, metrics, status snapshots, and review surfaces.

## 4. Core Domain Model

### 4.1 Ticket

A normalized work item that Tango can assign and execute.

Fields:

- `id` (string): Stable Tango ticket ID.
- `external_id` (string or null): Stable external tracker ID, if present.
- `external_ref` (string or null): External ticket URL or provider-specific reference the agent can resolve.
- `registry_binding` (registry binding or null): Selected external registry, operator-approved CLI, and registry skill.
- `registry_status_mapping` (semantic role to stable external status ID mapping or null): Pinned mapping resolved during onboarding.
- `observed_external_status_id` (string or null): Most recently reported stable external status ID.
- `forge_binding` (forge binding or null): Ticket-level forge, operator-approved CLI, and forge skill used for every bound repository and pull request.
- `identifier` (string): Human-readable key.
- `title` (string or null): MAY be populated after the agent fetches an external ticket.
- `description` (string or null): MAY be populated after the agent fetches an external ticket.
- `acceptance_criteria` (list of strings).
- `priority` (integer or null): Lower numbers dispatch first.
- `labels` (list of strings): Normalized to lowercase.
- `lifecycle_policy` (string or null): Ticket-specific lifecycle policy reference; null selects the configured default policy.
- `state` (lifecycle state): Current Tango lifecycle state.
- `repo_bindings` (list of repository bindings): REQUIRED before dispatch and MAY contain multiple repositories.
- `assignee` (agent assignment or null).
- `capability_profile` (capability profile reference or null).
- `main_session` (agent session reference or null): The single durable session association for research, planning, implementation, and later implementation changes.
- `aux_sessions` (list of agent session references): Append-only sessions for pull-request feedback checks and merge attempts.
- `blocked_by` (list of ticket or external refs).
- `active_block_id` (string or null): Current manual block record when state is `blocked`.
- `created_at` (timestamp).
- `updated_at` (timestamp).

### 4.2 Repository Binding

A repository selected at ticket onboarding time.

Fields:

- `id` (string): Stable binding ID within the ticket.
- `name` (string): Human-readable repository label.
- `kind` (string): `local_path`, `git_remote`, or implementation-defined.
- `location` (string): Absolute local path, remote URL, or provider-specific locator.
- `default_branch` (string or null).
- `base_ref` (string or null): Commit, branch, or tag to start from.
- `target_branch` (string or null): Merge destination.
- `work_branch` (string or null): Desired working branch name.
- `checkout_policy` (string): Implementation-defined, examples include `worktree`, `clone`, `reuse_local`.
- `merge_policy` (merge policy or null).

At least one repository binding MUST be present before a ticket can enter `researching`. Implementations MUST support tickets with multiple repository bindings.

### 4.3 Agent Assignment

Fields:

- `agent_id` (string): Logical local agent identity.
- `runtime` (string): Runtime adapter name, for example `codex`.
- `capabilities` (list of strings): Optional scheduler hints.
- `stage_permissions` (map stage -> permission profile).
- `max_turns` (integer or null).

Assignments MAY be explicit during onboarding or selected by scheduler policy.

### 4.4 Capability Profile

A reference to user-provided skills and tools that the local agent runtime can use for external ticket and pull-request management.

Logical capabilities MAY include:

- fetching ticket contents and acceptance criteria;
- updating ticket lifecycle state and comments;
- creating and updating pull requests;
- fetching pull-request comments and reviews;
- merging approved pull requests.

Tango MUST NOT require built-in provider-specific mutation adapters for these
capabilities. The agent reports normalized external state and references back
through stage artifacts. Tango MUST independently verify promotion-critical
external state through read-only ticket-system and forge attestation adapters.
Adding or selecting a ticket system or forge MUST fail unless a corresponding
read-only attestation adapter is registered.

Tango MUST manage capability installation and selection as an operator action. Agents MUST NOT install capabilities or modify their assigned capability profile.

The MVP MUST provide independently installable `github` and `forgejo` ticket-system and forge capabilities. Installing a ticket-system capability MUST persist an agent-readable issue-management skill and ticket-system configuration without creating or changing forge configuration. Installing a forge capability MUST persist an agent-readable pull-request and merge skill and forge configuration without creating or changing ticket-system configuration. The two capabilities MAY share a CLI, but capability profiles MUST select them independently so future non-forge ticket systems can be combined with supported forges. CLI installation MUST fail clearly when no supported operator-approved package installer is available. A `--skill-only` installation mode MAY skip CLI discovery and installation when the operator manages the CLI separately.

Ticket-system lifecycle status maps MUST be operator-managed and validated
before ticket onboarding may use them. Tango MUST provide a provider-aware
status-map command that can display the current map, set individual
lifecycle-role mappings, discover externally observable statuses where the
provider supports discovery, and persist a validated map. Mutating a mapped role
MUST clear the validation marker until validation succeeds again. Label-backed
systems such as GitHub and Forgejo MUST treat label names as external status
IDs only after Tango validates them against the provider; configured defaults or
operator-entered names are not evidence that the labels exist. Providers with
first-class workflow statuses SHOULD validate against stable workflow status IDs
rather than labels.

Before creating or changing an external ticket, comment, branch, pull request, or merge, an agent SHOULD inspect the current external state and reconcile it with the requested outcome. Retries MUST instruct the agent to discover and continue prior external work rather than blindly creating replacements.

Before promoting a successful execution result, Tango MUST attest that the
external ticket exists, has a readable current description revision, and is at
the configured human-review status. Tango MUST also attest every reported pull
request against its bound repository, source and target branches, and reported
head commit. Prompt-requested external TODO/checklist edits and progress or
handoff comments are agent work-protocol instructions and observability signals;
their absence MUST NOT block lifecycle promotion. Before recording successful
merge completion, Tango MUST independently attest that every approved pull
request is merged at the approved head and that the external ticket is at the
configured done status.

### 4.5 Lifecycle State

Tango has two related state concepts:

- `lifecycle_state`: Durable ticket state visible to humans and adapters.
- `run_state`: Internal worker state for an active local process.

Core lifecycle states:

- `onboarded`: Ticket exists but may still need repository binding or validation.
- `queued`: Ticket is eligible for agent assignment.
- `researching`: Agent is gathering context.
- `planning`: Agent is producing an implementation plan.
- `implementing`: Agent is modifying code and running validation.
- `awaiting_human_review`: Tango is paused for reviewer input.
- `changes_requested`: Reviewer requested another implementation pass.
- `merging`: Merge preconditions are being verified and merge is in progress.
- `done`: Work is complete according to policy.
- `blocked`: Ticket cannot progress until a dependency or human action is resolved.
- `failed`: Ticket exhausted retry policy or hit a non-recoverable error.
- `canceled`: Ticket was intentionally stopped.

Implementations MAY add substates, but they MUST preserve the semantics of the core states above.

#### 4.5.1 External Registry Status Mapping

Tango lifecycle state is authoritative for orchestration. External ticket registries may expose different workflow statuses, names, and identifiers, so Tango MUST map its lifecycle states through normalized semantic registry roles rather than assuming provider-specific status names.

Required semantic registry roles are:

- `backlog`
- `todo`
- `in_progress`
- `human_review`
- `merging`
- `blocked`
- `done`
- `wont_do`

The default lifecycle-to-role mapping is:

| Tango lifecycle state | Semantic registry role |
| --- | --- |
| `onboarded` | `backlog` |
| `queued` | `todo` |
| `researching`, `planning`, `implementing`, `changes_requested` | `in_progress` |
| `awaiting_human_review` | `human_review` |
| `merging` | `merging` |
| `blocked`, `failed` | `blocked` |
| `done` | `done` |
| `canceled` | `wont_do` |

Multiple semantic roles MAY map to the same external registry status. For example, a registry without a distinct merging status may map both `human_review` and `merging` to its review status.

Each configured registry mapping MUST resolve every required semantic role to a stable external status ID. Human-readable status names MAY be stored for display, but MUST NOT be used as the durable identity when the registry provides stable IDs. Tango MUST store the resolved mapping and its content digest so later runs use the mapping selected at onboarding.

The selected registry skill MUST discover the registry's available statuses and report their stable IDs and names during onboarding. Tango MUST reject dispatch when any required semantic role is missing or ambiguous. Agents update the external ticket to the resolved status ID for the requested semantic role and report the observed final external status. An external status update does not itself change Tango lifecycle state.

When an active execution, review-watch, or merge run cannot perform the required external status update, Tango MUST create a bounded auxiliary registry-sync session. This includes terminal `failed` transitions, which MUST request the semantic `blocked` role. Registry-sync sessions only reconcile external ticket status and report the result; they MUST NOT modify repositories, approve work, merge pull requests, or change Tango lifecycle state.

### 4.6 Stage Artifact

A durable output produced by an agent, human, or adapter.

Fields:

- `id` (string).
- `ticket_id` (string).
- `stage` (lifecycle stage).
- `kind` (string): Examples: `research_notes`, `plan`, `diff_summary`, `test_report`, `review_decision`, `merge_record`.
- `content_type` (string): Examples: `text/markdown`, `application/json`, `text/plain`.
- `content` (string or external reference).
- `created_by` (agent ID, human ID, or adapter ID).
- `created_at` (timestamp).

Stage artifacts are part of the durable handoff between lifecycle stages. Tango MUST preserve them indefinitely by default for audit and cost tracking. Removal requires an explicit operator action.

### 4.7 Agent Session

A durable association between one Tango task and related agent work. An agent session is distinct from a local process invocation.

Fields:

- `id` (string): Stable Tango session ID.
- `ticket_id` (string).
- `role` (string): `main` or `aux`.
- `kind` (string): `implementation`, `pr_feedback`, `registry_sync`, or `merge`.
- `context_session_ids` (list of strings): Ordered Tango session IDs whose
  durable artifacts and runtime metadata are relevant context for this
  session.
- `runtime_session_id` (string or null): Runtime-specific session identifier
  when available.
- `run_attempt_ids` (list of strings): Ordered local process attempts associated with this session.
- `created_at` (timestamp).
- `updated_at` (timestamp).

Each ticket MUST have at most one `main` session. The main session MUST have
kind `implementation`, MUST have an empty `context_session_ids` list, and owns
the initial research, planning, and implementation effort before the ticket
first reaches human review.

Each requested-changes implementation pass, pull-request feedback check,
registry-status synchronization, and merge invocation MUST create a new `aux`
session. `aux_sessions` MUST be append-only and ordered by creation time.
Auxiliary sessions MUST NOT become the ticket's main session.

An auxiliary `implementation` session created from `changes_requested` MUST
include the ticket's main session ID as the first `context_session_ids` entry
and MAY append prior auxiliary implementation session IDs in creation order
when their artifacts remain relevant. Tango MUST use these session IDs as the
durable lookup path for prior research, planning, implementation, and review
context instead of resuming the prior runtime thread.

### 4.8 Run Attempt

One supervised local agent process invocation associated with one agent
session. The main session MAY contain multiple execution attempts before first
human review. Each auxiliary `implementation` session MAY contain multiple
execution attempts under retry policy. Each pull-request feedback,
registry-status synchronization, and merge auxiliary session normally contains
one bounded attempt.

Fields:

- `id` (string).
- `ticket_id` (string).
- `session_id` (string): Owning main or auxiliary agent session.
- `kind` (string): `execution`, `review_watch`, `registry_sync`, or `merge`.
- `current_stage` (lifecycle stage or null).
- `stages` (list of lifecycle stages covered by the attempt).
- `attempt` (integer, 1-based).
- `workspace_path` (absolute path).
- `agent_runtime` (string).
- `capability_profile_digest` (string or null): Exact resolved profile content used by this attempt.
- `effective_capabilities` (list of strings): Capabilities exposed to this attempt after run-kind filtering.
- `started_at` (timestamp).
- `ended_at` (timestamp or null).
- `status` (run status).
- `error` (string or null).

Run statuses:

- `preparing_workspace`
- `building_prompt`
- `launching_agent`
- `streaming`
- `collecting_artifacts`
- `succeeded`
- `failed`
- `timed_out`
- `stalled`
- `canceled`

### 4.9 Review Decision

Fields:

- `ticket_id` (string).
- `reviewer_id` (string).
- `decision` (string): `approve`, `request_changes`, `reject`, `cancel`, or `defer`.
- `comments` (string).
- `reviewed_commit_set` (list of repository binding ID and commit ID pairs).
- `reviewed_pull_request_set` (list of pull-request references and reviewed head commit IDs).
- `authorization_mechanism` (string): Identifies the human-intent or human-presence mechanism used.
- `created_at` (timestamp).

The interactive `tango review merge <ticket>` command MUST create the approval decision that authorizes merge progression. Its approval MUST use the invoking human as `reviewer_id`, record the merge command as its authorization mechanism, and bind the exact commit and pull-request head sets displayed during confirmation.

An approval MUST be bound to the exact reviewed commit and pull-request head sets. Any implementation or pull-request head change after approval MUST invalidate the approval and return the ticket to `awaiting_human_review`.

### 4.10 Block Record

A durable record describing manual work required before a ticket can continue.

Fields:

- `id` (string).
- `ticket_id` (string).
- `reason` (string): Human-readable description of the blocking condition.
- `resolution_instructions` (string or null): Work a human is expected to perform.
- `blocked_from` (lifecycle state).
- `resume_state` (lifecycle state): State restored by the unblock command; MUST be `queued`, `changes_requested`, or `awaiting_human_review`.
- `created_by` (agent ID, human ID, or orchestrator ID).
- `created_at` (timestamp).
- `resolved_by` (human ID or null).
- `resolved_at` (timestamp or null).

An agent or Tango MAY create a block record, but only the human-only `tango ticket unblock <ticket>` command MAY resolve it. Unblocking marks the record resolved, clears `active_block_id`, and restores `resume_state`; it does not itself authorize merge or completion. A merge blocked after partial progress MUST resume at `awaiting_human_review` so a human must invoke `tango review merge` again.

### 4.11 Event

Tango emits durable events for state reconstruction and observability.

Minimum event fields:

- `id` (string).
- `ticket_id` (string or null).
- `type` (string).
- `occurred_at` (timestamp).
- `actor` (string): `orchestrator`, `agent:<id>`, `human:<id>`, or `adapter:<id>`.
- `payload` (map/object).

Implementations SHOULD use append-only event recording even when also storing current-state projections.

## 5. Ticket Onboarding Contract

Tango does not discover task workflow from a target repository file. Ticket onboarding MUST provide enough information to make the ticket dispatchable or explicitly leave it in `onboarded` until missing fields are supplied.

Minimum dispatchable onboarding payload:

- at least one `repo_binding`
- an external ticket registry, its operator-selected CLI, and a registry skill available to the assigned agent
- an `external_ref` resolvable by the selected registry skill
- a validated semantic registry status mapping using stable external status IDs
- one selected `github` or `forgejo` forge binding whose CLI and skill are available to the assigned capability profile
- a capability profile able to fetch and manage the external ticket and pull requests
- lifecycle policy reference or default lifecycle policy

Optional onboarding payload:

- labels
- priority
- blockers
- preferred agent runtime
- branch naming override
- merge policy override
- task-specific prompt additions

Ticket contents MAY replace what Symphony-style systems would put in a repository workflow prompt. A conforming implementation MUST still prepend or otherwise enforce Tango's lifecycle contract so the agent understands the current stage and output requirements.

When onboarding uses an external ticket reference, the assigned agent MUST fetch and normalize the ticket contents through user-provided skills/tools before implementation. The agent MAY use those capabilities to fully manage external ticket and pull-request state. Tango remains authoritative for its internal orchestration lifecycle.

Onboarding MUST use the selected registry skill and CLI to discover available external statuses, resolve the required semantic registry roles, and persist the resulting stable-ID mapping and digest. Tango MUST NOT queue a ticket whose registry mapping is incomplete or ambiguous.

For the MVP, onboarding MUST select exactly one ticket-level forge named `github` or `forgejo`. Every repository and pull request for that ticket MUST use the selected forge. The selected capability profile MUST include the forge skill and MUST expose the selected forge CLI during both execution and merge runs. Mixed-forge tickets are not supported by the MVP.

Onboarding MUST accept repository clone sources supported by the configured workspace provider and MUST reject local absolute or relative paths. The MVP accepts GitHub `owner/repo` shorthand and full Git clone URLs. Onboarding MUST reject an explicit repository remote that is incompatible with the selected ticket-level forge.

Ticket creation MAY request immediate queueing. When requested, Tango MUST persist the onboarded ticket before attempting the normal queue transition. If queueing fails, the valid ticket MUST remain `onboarded` and the failure MUST be reported.

## 6. Configuration Resolution

Tango configuration has three logical sources:

1. Operator/service configuration.
2. Ticket onboarding payload.
3. Runtime adapter defaults.

Configuration precedence:

- Safety, sandbox, credential, and merge-authority settings from operator/service configuration MUST NOT be weakened by ticket content unless the operator explicitly allows that field to be overridden.
- Ticket onboarding payload SHOULD override task-specific defaults such as repository binding, acceptance criteria, reviewer list, and branch naming.
- Runtime adapter defaults MAY fill missing values, but MUST be surfaced in status output when they affect execution.

Implementations MUST document:

- where local service configuration lives;
- where ticket state and artifacts live;
- which fields are dynamically reloadable;
- which fields can be overridden by ticket content;
- how credentials are supplied to adapters.

## 7. Lifecycle State Machine

### 7.1 Canonical Flow

The canonical flow is:

1. `onboarded`
2. `queued`
3. `researching`
4. `planning`
5. `implementing`
6. `awaiting_human_review`
7. `merging`
8. `done`

### 7.2 Legal Transitions

- `onboarded -> queued`: Required fields validated.
- `queued -> researching`: Scheduler claims ticket and starts research.
- `researching -> planning`: The execution agent reports that it has enough context to plan.
- `planning -> implementing`: The execution agent reports that its plan is sufficient to begin implementation.
- `implementing -> awaiting_human_review`: Implementation artifact and validation summary recorded.
- `awaiting_human_review -> changes_requested`: The review watcher detects actionable pull-request feedback that requires implementation changes.
- `changes_requested -> implementing`: Scheduler creates a new auxiliary
  implementation session linked to the task's main session and starts another
  implementation attempt in that session.
- `awaiting_human_review -> merging`: A human invokes `tango review merge`, confirms the displayed commit and pull-request head sets, and Tango records the resulting approval decision.
- `merging -> done`: Merge record satisfies policy.
- `merging -> blocked`: One or more pull requests merged but a later pull-request merge failed.
- Any non-terminal state -> `blocked`: Dependency, missing input, or external condition blocks progress.
- `blocked -> resume_state`: A human invokes `tango ticket unblock` after resolving the block record.
- Any non-terminal state -> `failed`: Retry policy exhausted or non-recoverable error.
- Any non-terminal state -> `canceled`: Operator cancels ticket.

The initial assigned agent MUST advance continuously from `researching`
through `planning` and `implementing` in the task's main session without human
interaction. Research and planning transitions are progress reports, not
gates: the agent decides when it has enough information to proceed. Tango MUST
record the lifecycle transitions and required stage artifacts, but MUST NOT
pause the agent to accept them.

Later implementation passes triggered by `changes_requested` MUST start in a
fresh auxiliary `implementation` session. Tango MUST populate that session from
durable artifacts, review feedback, and the referenced `context_session_ids`
instead of resuming the original implementation runtime thread.

The core lifecycle does not include a plan-approval gate.

### 7.3 Stage Contracts

#### Research

Purpose: Understand the repository, constraints, and task scope.

Default permissions:

- The agent MUST be instructed not to modify repository files during research.
- Mechanical read-only enforcement is OPTIONAL.
- MAY allow non-destructive inspection commands.

Required artifact:

- `research_notes` summarizing relevant files, existing behavior, risks, unknowns, and implementation constraints.

The agent MAY report this artifact and proceed immediately. Tango validates and promotes it after the execution session ends.

#### Plan

Purpose: Produce a concrete implementation and validation plan.

Default permissions:

- The agent MUST be instructed not to modify repository files during planning.
- Mechanical read-only enforcement is OPTIONAL.

Required artifact:

- `plan` with steps, expected file areas, validation commands, risk notes, and rollback considerations.

The agent MAY report this artifact and proceed immediately. Tango validates and promotes it after the execution session ends.

#### Implement

Purpose: Modify code and validate the acceptance criteria.

Default permissions:

- MAY write to the ticket workspace.
- SHOULD be limited to the bound repository workspace and configured writable roots.

Required artifacts:

- `diff_summary`
- `validation_report`
- `implementation_notes`
- `commit_set` containing the resulting commit ID for every modified repository binding
- `pull_request_set` containing the pull-request reference, head commit, source
  branch, and target branch for every modified repository binding

The assigned agent owns commit and pull-request creation during implementation. A successful implementation stage MUST leave each modified repository in a committed, reviewable state with a pull request.

Tango implementation prompts MUST instruct the agent to post useful progress and handoff comments back to the external ticket when its capability profile supports that operation. Those comments are not lifecycle-gating evidence. After creating pull requests and reporting review status, the implementation agent MUST stop without merging.

#### Human Review

Purpose: Let a human inspect the plan, pull requests, diffs, validation, and agent notes.

Rules:

- Tango MUST pause automatic merge progression until review policy is satisfied.
- Review decisions MUST be durable.
- Pull-request feedback requesting changes MUST route the ticket back to
  implementation in a new auxiliary `implementation` session linked to the
  task's main session unless policy routes it elsewhere.
- External ticket rejection MAY transition the ticket to `failed`, `cancel` MUST transition it to `canceled`, and `defer` MUST leave it in `awaiting_human_review`.
- Each pull-request comment check MUST run in a new bounded auxiliary session appended to the task.
- Tango MUST store a last-observed conversation comment count for each pull request.
- The review watcher MUST poll pull-request conversation comments through a read-only forge adapter before starting an agent. It MUST NOT start an agent when the normalized comment count is unchanged.
- The read-only forge adapter MUST normalize pull-request conversation comments in stable oldest-first order. The normalized comment count is the length of that list, MUST include human- and agent-authored comments, and MUST exclude approvals, status changes, CI checks, and other non-comment activity.
- When the cheap watcher observes no new comments, Tango MUST advance the cursor observation timestamp without starting an agent.
- When the cheap watcher observes new comments, Tango MUST leave the cursor at the previous count and start a bounded review-watch agent to interpret only those new comments.
- When a review-watch agent exits, Tango MUST advance the stored count to the greater of the prior count and final observed total, including comments posted by the agent itself, so the agent does not process its own comments on the next check.
- The review-watch agent decides whether new comments are actionable. It MUST NOT treat pull-request approvals or other review metadata as merge authorization.

#### Merge

Purpose: Start a new auxiliary merge session that merges approved pull requests and closes the external ticket when present.

Rules:

- Merge MUST require an approval decision created by the interactive `tango review merge` command.
- Merge MUST verify configured preconditions, such as clean workspace, target branch freshness, or CI status when available.
- The assigned agent owns pull-request merge execution after a valid human approval authorizes the exact reviewed commit and pull-request head sets.
- Merge MUST run in a new auxiliary session populated from durable Tango artifacts and external references.
- The merge agent MUST NOT create or modify implementation commits or pull-request heads without invalidating approval and returning the ticket to human review.
- Merge output MUST include a durable `merge_record` listing completed, pending, and failed pull-request merges.
- When the ticket has an external reference, successful merge completion MUST include closing or completing that external ticket; failure to do so MUST block completion for human resolution.
- On partial multi-repository merge failure, the agent SHOULD post a status comment to the external ticket, and Tango MUST transition the ticket to `blocked`.

#### Done

Purpose: Mark the ticket complete.

Rules:

- `done` MUST only be reached after a human invokes `tango review merge` and the resulting merge session records a successful merge record.
- For a no-code task, `tango review merge` approves an empty commit and pull-request set and starts a completion session that closes the external ticket when present and records an empty successful merge record.
- Completion SHOULD instruct the agent to update external ticket state when its capability profile supports that operation.

## 8. Prompt Envelope Contract

The agent prompt for each run MUST include:

- Tango lifecycle stage and allowed transitions.
- Owning session ID, session role, and run kind.
- Referenced `context_session_ids` when the run depends on prior session
  artifacts or runtime metadata.
- Ticket title, description, acceptance criteria, labels, and blockers.
- External ticket reference and selected capability profile when task contents must be fetched.
- Selected registry, registry CLI, registry skill, and resolved semantic registry status mapping.
- Selected forge, forge CLI, and forge skill.
- Repository binding details relevant to the workspace.
- Stage-specific task instructions.
- Prior stage artifacts.
- Output artifact requirements.
- Safety and permission constraints.
- Human handoff expectations.

The prompt SHOULD be assembled from structured fields rather than relying on a free-form ticket body alone.

Unknown template variables, missing required ticket fields, or missing prior artifacts SHOULD fail the affected stage before launching the agent.

## 9. Scheduling, Claims, and Retry

### 9.1 Eligibility

A ticket is dispatch-eligible when all are true:

- It is in a scheduler-owned active state, such as `queued` or `changes_requested`.
- Required onboarding fields are present.
- Repository bindings validate.
- Blockers are clear.
- Review gates are not waiting for humans.
- Global, per-agent, per-repository, and per-stage concurrency limits allow dispatch.
- The ticket is not already claimed or running.

### 9.2 Dispatch Ordering

Default ordering SHOULD be:

1. priority ascending, null last;
2. blocker-free tickets before recently unblocked tickets;
3. oldest `created_at`;
4. `identifier` lexicographic tie-breaker.

### 9.3 Claims

The orchestrator MUST claim a ticket before starting a worker. Claims MUST be released when:

- the worker exits and no retry is scheduled;
- the ticket enters a human-waiting state;
- the ticket enters a terminal state;
- reconciliation finds the ticket is no longer eligible.

### 9.4 Retry

Retry policy is implementation-defined but MUST distinguish:

- transient adapter errors;
- agent runtime failures;
- validation failures;
- human-requested changes;
- non-recoverable policy errors.

Failure-driven retries SHOULD use exponential backoff with a configurable maximum. Human-requested changes SHOULD create a new implementation attempt rather than being treated as infrastructure failure.

## 10. Workspace and Repository Management

Workspace path derivation MUST be deterministic from the ticket ID or identifier. One ticket workspace MUST contain every repository binding and MUST be used as the agent process working directory so the agent can work across repositories.

Workspace preparation MUST:

- create or reuse one isolated workspace for the ticket containing each repository binding;
- checkout or attach the bound repository according to `checkout_policy`;
- avoid destructive resets unless explicitly configured;
- expose the effective workspace path to the agent runtime;
- record enough metadata to recover or inspect the workspace after restart.

Workspaces and workpads MUST be preserved indefinitely by default for audit and cost tracking. Removal requires an explicit operator action.

## 11. Local Agent Runtime

Tango's core spec is runtime-agnostic. A conforming implementation MAY support Codex, another local coding agent, or multiple adapters.

Runtime requirements:

- The agent MUST run as a local process or local runtime controlled by the operator's machine.
- The implementation MUST NOT require a cloud-hosted agent management API for core orchestration.
- The adapter MUST report lifecycle events, final status, and stage artifacts back to Tango.
- The adapter SHOULD expose token usage, rate limits, and raw event summaries when available.

For a Codex-based implementation, Codex command names, protocol schemas, sandbox settings, and session semantics are implementation details and belong in the implementation architecture, not this language-agnostic spec.

## 12. Human Review and Merge Authority

Tango MUST treat human review as a durable gate, not a transient process wait.

Only the interactive `tango review merge <ticket>` command MAY record an approval that transitions a ticket toward `merging`. Agent runtimes MUST NOT be given authority to approve their own work.

New tickets enter Tango through explicit onboarding or queue commands. While a ticket is in `awaiting_human_review`, Tango MUST periodically run a cheap pull-request conversation-comment watcher. The watcher MUST filter out approvals, checks, status changes, and other non-comment activity before dispatch. It MUST append a bounded auxiliary review-watch session only when new conversation comments exist. The session inspects only comments beyond the stored count and decides whether they require changes. Watch checks MUST NOT treat external approvals as Tango approval or enter `merging`; only the human merge command may do that.

Review surfaces MAY include:

- CLI commands;
- terminal UI;
- local web UI;
- external issue tracker comments;
- pull request reviews;
- structured files in the Tango state store.

The core merge authority mode is `agent_after_human_approval`: a human invokes `tango review merge`, the command creates the durable approval decision, and Tango appends an auxiliary merge session to merge pull requests and close the external ticket when present after preconditions pass.

The initial human-intent gate is an interactive CLI merge command. The implementation agent is instructed to stop after requesting review, and no merge worker exists until the command is invoked. Implementations MUST document that this is a high-trust policy boundary, not a strong security boundary against a local agent capable of invoking the CLI itself.

## 13. Observability

Implementations MUST expose:

- startup and validation errors;
- ticket lifecycle transitions;
- worker start and exit events;
- retry scheduling;
- review decisions;
- merge records;
- agent runtime failures.

Status snapshots SHOULD include:

- active tickets by stage;
- running workers;
- retry queue;
- tickets awaiting human review;
- recent failures;
- aggregate runtime and token usage when available.

## 14. Safety and Trust

Implementations MUST document their trust model.

Minimum safety requirements:

- Do not weaken operator-level sandbox or credential policy based on ticket content.
- Do not merge or enter `done` without an approval created by the interactive merge command.
- Do not delete or reset workspaces destructively unless configured.
- Redact secrets from logs where practical.
- Keep agent execution scoped to configured workspaces and writable roots.

## 15. Conformance Levels

### 15.1 Core Conformance

An implementation is core-conformant when it supports:

- local ticket onboarding;
- repository binding at onboarding time;
- multiple repository bindings per ticket;
- durable lifecycle state;
- one main implementation session and append-only auxiliary implementation,
  PR-feedback, registry-sync, and merge sessions per task;
- research, plan, implement, human review, merge, and done states;
- autonomous agent progression from research through implementation;
- local agent runtime adapter;
- operator-managed agent capability profiles;
- required external registry, registry CLI, registry skill, and stable-ID semantic status mapping;
- deterministic workspace creation;
- human review gate before merge;
- agent-owned implementation commits and post-approval merge execution;
- structured event logs or equivalent inspectable history.

### 15.2 Extended Conformance

Extended features MAY include:

- provider-specific capability bundles;
- local dashboard or HTTP API;
- multiple agent runtimes;
- operator-controlled pruning and archival policies;
- CI status integration;
- reviewer assignment rules.

## 16. References

- OpenAI Symphony service specification: <https://github.com/openai/symphony/blob/main/SPEC.md>
