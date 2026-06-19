# Tango Implementation TODO

Current snapshot: 2026-06-15

This tracker lists the remaining work from [SPEC.md](SPEC.md) and
[docs/architecture.md](docs/architecture.md), grouped by release impact.

## Completed Baseline

- [x] Core domain/store/command foundations are in place, including tickets,
  sessions, runs, blocks, reviews, merges, and immutable events.
- [x] The foreground runtime exists: `tango run`, the OTP supervision tree,
  the orchestrator loop, review-watch scheduling, registry-sync scheduling,
  merge-worker dispatch, and startup recovery.
- [x] The main read/write CLI surface exists: `tango ticket create`, `tango
  ticket list`, `tango ticket show`, `tango ticket queue`, `tango ticket
  unblock`, `tango review merge`, `tango review list`, `tango review show`,
  `tango status`, and the current snapshot-style `tango dashboard`.
- [x] Merge approval confirmation, reviewed-set capture, review cursors,
  configured registry mappings, and registry-sync adapter wiring are
  implemented.
- [x] Ticket onboarding persists independent ticket-system and MVP-level
  `github` or `forgejo` forge bindings, validates their CLIs and skills against
  the selected capability profile, and injects both bindings into agent
  prompts.
- [x] Research-only and no-code tickets are valid Tango work.
  - An execution run may finish with no pull requests when no repository changes
    are required, after posting its research or recommendation to the external
    ticket.
  - `tango review merge` remains the human completion gate for research-only and
    no-code tickets.

## MVP Necessary

- [x] **CRITICAL: Expand and clarify the agent prompt contract.**
  - Include the normalized external ticket title, description, acceptance
    criteria, blockers, repository bindings, lifecycle contract, allowed
    actions, required artifacts, and concrete workpad schemas.
  - Give execution runs explicit research, plan, implementation, validation,
    progress-comment, TODO-update, pull-request, and handoff instructions.
  - Give research-only and no-code runs explicit instructions to post findings
    to the external ticket and return an empty pull-request set without inventing
    repository changes.
  - Keep implementation prompts explicitly merge-free and merge prompts
    explicitly scoped to the reviewed commit and pull-request sets.
  - Add prompt golden tests for execution, requested changes, review feedback,
    registry sync, merge, and research-only/no-code work.
- [x] **CRITICAL: Add read-only forge and ticket-system attestation adapters.**
  - Keep agent skills and CLIs responsible for external mutations, but use
    Tango-owned read-only adapters to validate the external state reported by
    agents before lifecycle promotion.
  - Ticket-system attestation must verify ticket existence, current description
    revision, and observed lifecycle status.
  - Forge attestation must verify pull-request existence, bound repository,
    source and target branches, reported head commit, current state, and merged
    state when applicable.
  - Merge completion must independently verify every approved pull request was
    merged and the external ticket reached the configured done state.
  - Add fake-adapter contract tests and opt-in integration tests for GitHub and
    Forgejo.
  - Capability installation, profile creation, and onboarding reject any
    provider without a registered read-only attestation adapter.
- [x] **CRITICAL: Add the external-ticket TODO and commenting work protocol.**
  - Define this as a prompt/work protocol, not a lifecycle-validation gate:
    Tango prompts the agent to maintain the external TODO list and comments,
    but promotion must not depend on proving those updates happened.
  - Define a structured TODO checklist with stable item IDs and completion state
    that can be carried in a Tango-owned external-ticket description section.
  - Define the Tango-owned description section, revision/conflict behavior, and
    how operator-authored description content is preserved.
  - Instruct execution and requested-changes agents to create and iteratively
    update the TODO list, post useful progress comments while working, and post a
    final research or review handoff comment.
  - Extend normalized-ticket and external-update artifacts so agents can report
    attempted TODO and comment changes for observability and debugging.
  - Keep read-only ticket-system attestation focused on externally observable
    lifecycle gates such as ticket existence, readable description revision, and
    configured status; absence of TODO/checklist edits or comments must not block
    promotion.
  - Add prompt golden tests proving the TODO/comment instructions are present and
    promotion tests proving missing TODO/comment evidence is non-gating.
- [x] Replace agent-driven review polling with a cheap PR-event watcher.
  - Poll or subscribe for pull-request events without starting an agent.
  - Filter out approvals, checks, status changes, and other non-comment events.
  - Start a bounded review-feedback agent only when new conversation comments
    need interpretation.
  - Preserve durable event cursors and deduplicate delivery across restarts.
- [x] Finish workpad validation and artifact promotion.
  - Run-kind manifests define allowed files and required artifacts, including
    execution diff summaries, and `result.json` must be the final artifact
    writer.
  - Workers validate the full workpad against Tango's stored manifest, reject
    traversal, symlink-backed, malformed, missing, and disallowed outputs, and
    preserve failed workpads for inspection.
  - Artifact sets are validated in full before immutable artifacts and
    promotion events are persisted, preventing partial promotion.
- [x] Complete the execution and merge lifecycle.
  - Execution promotion records the autonomous research, plan, implement, and
    review-handoff lifecycle transitions and verifies the external ticket at
    the configured human-review status.
  - `changes_requested` dispatch creates a fresh auxiliary implementation
    session with validated `context_session_ids`; it never resumes the prior
    runtime thread.
  - Prompt envelopes and workpad manifests carry durable session context,
    selected prior artifacts, review feedback, merge approvals,
    registry/forge bindings, and run-kind-specific effective capabilities.
  - Merge prompts reconcile already-completed pull requests and prior partial
    progress; partial reports remain durable blocked merge records for
    re-approval and retry.
  - Successful merge completion requires a verified external-ticket update to
    the configured `done` status. Execution, review-watch, registry-sync, and
    merge runs use the configured registry/forge prompt path and persist their
    external-update artifacts.
- [ ] Finish onboarding and capability surfaces.
  - [x] Add operator-safe config precedence and validation for runtime settings.
  - [x] Finish onboarding inputs for repository clone sources, external ticket
    references, ticket-system binding, ticket-system CLI and skill selection,
    forge remote compatibility checks, capability profile selection, lifecycle
    overrides, and immediate queueing.
    - [x] Persist and normalize onboarding priority.
    - [ ] Pause automatic lifecycle-label provisioning and reconciliation until
      provider-specific status mapping is operator-configurable.
    - [x] Reject capability profiles that do not expose the selected registry
      skill and execution CLI.
    - [x] Add lifecycle overrides and forge remote compatibility checks.
    - [x] Reject local repository paths and accept `casa` clone sources.
    - [x] Add `tango ticket create --queue`.
  - [x] Implement independent built-in GitHub and Forgejo ticket-system and
    forge capability install/profile persistence under `~/.tango/capabilities`,
    including PATH verification, Homebrew CLI installation fallback, and
    Tango-owned issue and forge skills.
  - [x] Add the minimum capability-management CLI:
    `tango capability list`,
    `tango capability install <ticket-system|forge> <github|forgejo>
    [--skill-only]`, and `tango capability profile create <name>
    --ticket-system <name> --forge <name>`.
  - [x] Expose installed ticket-system/forge skills and operator Codex skill
    cache roots to fresh sandboxed agent runs.
- [x] Add ticket-system status-map management.
  - Add a provider-aware command such as
    `tango ticket-system status-map <name> ...` to discover, display, validate,
    and persist Tango lifecycle-role mappings.
  - Do not assume lifecycle labels already exist or treat configured label names
    as discovered stable status IDs.
  - Define how label-based systems such as GitHub and Forgejo differ from ticket
    systems with first-class workflow statuses.
  - Current MVP supports `show`, `set`, `discover`, and `validate`. GitHub
    discovers repository labels through `gh label list`; Forgejo validates the
    configured label map through `fj issue search --labels` because the MVP CLI
    integration does not expose a label-list command.
- [x] Finish Git and forge precondition validation.
  - The existing Git adapter covers clean/dirty worktrees and local expected
    heads.
  - Add changed-repository detection so an implementation result cannot omit a
    modified repository or incorrectly claim to be no-code.
  - Read-only forge attestation now verifies pull-request repository, source and
    target branches, head commit, and merge state. Repository CI remains
    authoritative for tests, linting, and formatting.
- [x] Close the prior lifecycle regression-test gaps.
  - Current review-watcher coverage for cheap unchanged-count polling,
    comments-only dispatch, actionable comments, self-post cursor advancement,
    and no false merge authorization.
  - Merge retry coverage for partial multi-repo progress, already-merged PRs,
    and required re-approval.
  - Git/workspace validation coverage for dirty worktrees and wrong heads.
- [ ] Tango as a Binary

## Bugs

- [ ] Fix cross-process mutation safety.
  - Yes: when Tango is running, every CLI mutation must route through the
    running `StoreServer` over a local IPC boundary so the daemon remains the
    single writer.
  - The daemon should hold an exclusive state-directory lock for its lifetime.
  - When the daemon is not running, an offline mutation command must acquire the
    same exclusive lock before opening the JSON store directly.
  - Keep read-only CLI commands available directly where safe, but provide a
    consistent snapshot path through the server when needed.
  - Preserve startup reconciliation for crashes between the immutable-record
    writes and final ticket-projection replacement.
- [ ] Fix command and adapter correctness gaps.
  - Return non-zero process exit status on usage, config, store, command,
    onboarding, and runtime failures.
  - [x] Tighten `casa inspect` parsing beyond the current narrow happy path.
  - Replace best-effort Codex runtime-session extraction with a more durable
    protocol/event integration.
- [ ] Fill in missing lifecycle event coverage.
  - Add stronger review-watch, registry-sync, and merge event coverage so
    debugging and downstream read surfaces do not depend on inference.

## To Explore

- [ ] Explore bounded command execution and stranded-worker recovery.
  - Determine whether the shell/process wrapper can enforce configurable hard
    timeouts and inactivity/stall timeouts while still collecting useful output.
  - Determine how to terminate the full spawned process tree, not only the
    immediate Erlang port or worker process.
  - Monitor worker processes so abnormal exits always notify the orchestrator,
    release claims, and move active runs to a recoverable terminal state.
  - Decide how timeout, stall, launch failure, validation failure, and worker
    crash map to retry classes, maximum attempts, and exponential backoff.
  - Add recovery tests proving a killed or crashed worker cannot leave a
    permanent scheduler claim or silently running child process.
- [ ] Explore status-map UX and provider semantics before resuming automatic
  lifecycle-label management.

## Accepted MVP Risks

- [x] Use prompt guardrails and separate implementation/merge sessions as the
  MVP merge-authority boundary.
  - Implementation sessions are instructed to research, plan, implement,
    comment, and open pull requests without merging.
  - Merge sessions are created only after `tango review merge` and receive the
    merge-specific instructions.
  - Strong capability isolation, separate implementation and merge credentials,
    and provider-enforced merge authorization are future hardening work.
- [x] Allow research-only and no-code completion through the human merge command
  when read-only attestation confirms no repository changes or pull requests
  were omitted.

## Post-MVP / V2

- [ ] Add daemon-health warnings and log drill-down to `tango status` and
  `tango dashboard`.
  - Show concise `WARN` markers for stranded active states, stale or failed
    runs, repeated retries, and projection inconsistencies.
  - Add a stable `tango logs --ticket <id> [--run <id>]` surface, with optional
    terminal hyperlinks to the backing structured log.
- [ ] Broaden integration coverage once the MVP contract above is closed.
  - Add wider integration tests around Codex, `casa`, workpad validation,
    and artifact promotion.
- [ ] Add stronger capability and credential isolation.
  - Separate implementation and merge credentials or proxy capability calls so
    implementation sessions cannot invoke merge operations.
- [ ] Add operator controls for pause, cancel, bounded manual retry, process
  termination, archival, and pruning.
- [ ] Add harness and model/provider selection.
  - [x] Build the initial `HarnessAdapter` contract and move Codex behind it.
  - [ ] Add operator-facing harness and model/provider selection.
