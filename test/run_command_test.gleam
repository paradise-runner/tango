import fixtures
import gleam/option.{None, Some}
import gleeunit/should
import tango/app/run_command
import tango/app/run_reconcile
import tango/domain/lifecycle
import tango/domain/repo
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/memory_store

fn queued_ticket() -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: None,
    priority: Some(1),
    labels: [],
    lifecycle_policy: None,
    state: lifecycle.Queued,
    repo_bindings: [
      repo.RepoBinding(
        id: "repo-1",
        name: "tango",
        kind: repo.GitRemote,
        location: "repo",
        default_branch: None,
        base_ref: None,
        target_branch: None,
        work_branch: None,
        checkout_policy: repo.Clone,
      ),
    ],
    external_ref: Some("TANGO-1"),
    registry_binding: Some(fixtures.registry_binding()),
    registry_status_mapping: Some(fixtures.registry_status_mapping()),
    forge_binding: Some(fixtures.forge_binding()),
    observed_external_status_id: None,
    capability_profile_digest: Some("digest"),
    main_session_id: Some("main"),
    aux_session_ids: [],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: False,
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn main_session() -> session.AgentSession {
  session.AgentSession(
    id: "main",
    ticket_id: "ticket-1",
    role: session.Main,
    kind: session.Implementation,
    context_session_ids: [],
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn execution_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "run-1",
    ticket_id: "ticket-1",
    session_id: "main",
    kind: run.Execution,
    current_stage: Some(lifecycle.Research),
    stages: [lifecycle.Research, lifecycle.Plan, lifecycle.Implement],
    attempt: 1,
    workspace_path: "/tmp/workspace",
    agent_runtime: "fake",
    capability_profile_digest: Some("digest"),
    effective_capabilities: [],
    resume_state: lifecycle.Queued,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    error: None,
  )
}

fn merge_session() -> session.AgentSession {
  session.AgentSession(
    id: "merge-session",
    ticket_id: "ticket-1",
    role: session.Aux,
    kind: session.Merge,
    context_session_ids: [],
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn merge_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "merge-run",
    ticket_id: "ticket-1",
    session_id: "merge-session",
    kind: run.MergeRun,
    current_stage: Some(lifecycle.Merge),
    stages: [lifecycle.Merge],
    attempt: 1,
    workspace_path: "/tmp/workspace",
    agent_runtime: "fake",
    capability_profile_digest: Some("digest"),
    effective_capabilities: [],
    resume_state: lifecycle.Merging,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    error: None,
  )
}

fn prepared_state() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  #(backend, state)
}

pub fn start_run_links_session_and_activates_ticket_test() {
  let #(backend, state) = prepared_state()
  let assert Ok(started) =
    run_command.start(
      backend,
      state,
      execution_run(),
      "event-run",
      "2026-06-07T00:01:00Z",
    )

  started.ticket.state
  |> should.equal(lifecycle.Researching)
  let assert Ok(owner) = backend.get_session(started.state, "ticket-1", "main")
  owner.run_attempt_ids
  |> should.equal(["run-1"])
}

pub fn start_run_rejects_existing_run_id_test() {
  let #(backend, state) = prepared_state()
  let assert Ok(state) = backend.save_run(state, execution_run())

  run_command.start(
    backend,
    state,
    execution_run(),
    "event-run",
    "2026-06-07T00:01:00Z",
  )
  |> should.be_error()
}

pub fn interrupted_execution_fails_run_and_restores_dispatch_state_test() {
  let #(backend, state) = prepared_state()
  let assert Ok(started) =
    run_command.start(
      backend,
      state,
      execution_run(),
      "event-run",
      "2026-06-07T00:01:00Z",
    )
  let assert Ok(reconciled) =
    run_reconcile.reconcile_ticket(
      backend,
      started.state,
      "ticket-1",
      "2026-06-07T00:02:00Z",
      fn(attempt) { "interrupt-" <> attempt.id },
      fn(attempt) { "block-" <> attempt.id },
    )

  reconciled.ticket.state
  |> should.equal(lifecycle.Queued)
  reconciled.interrupted_runs
  |> should.equal([
    run.RunAttempt(
      ..execution_run(),
      ended_at: Some("2026-06-07T00:02:00Z"),
      status: run.Failed,
      error: Some("Interrupted by Tango process restart"),
    ),
  ])
}

pub fn interrupted_merge_blocks_for_human_recovery_test() {
  let backend = memory_store.store()
  let merging =
    ticket.Ticket(..queued_ticket(), state: lifecycle.Merging, aux_session_ids: [
      "merge-session",
    ])
  let assert Ok(state) = backend.save_ticket(memory_store.new(), merging)
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(started) =
    run_command.start(
      backend,
      state,
      merge_run(),
      "event-run",
      "2026-06-07T00:01:00Z",
    )
  let assert Ok(reconciled) =
    run_reconcile.reconcile_ticket(
      backend,
      started.state,
      "ticket-1",
      "2026-06-07T00:02:00Z",
      fn(attempt) { "interrupt-" <> attempt.id },
      fn(attempt) { "block-" <> attempt.id },
    )

  reconciled.ticket.state
  |> should.equal(lifecycle.Blocked)
  reconciled.ticket.active_block_id
  |> should.equal(Some("block-merge-run"))
  let assert Ok(block) =
    backend.get_block(reconciled.state, "ticket-1", "block-merge-run")
  block.resume_state
  |> should.equal(lifecycle.AwaitingHumanReview)
}
