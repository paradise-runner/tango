import fixtures
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import tango/app/command
import tango/app/reconcile
import tango/domain/block
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/repo
import tango/domain/review
import tango/domain/session
import tango/domain/ticket
import tango/store/memory_store

fn onboarded_ticket() -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: None,
    priority: Some(1),
    labels: [],
    lifecycle_policy: None,
    state: lifecycle.Onboarded,
    repo_bindings: [
      repo.RepoBinding(
        id: "repo-1",
        name: "tango",
        kind: repo.GitRemote,
        location: "https://example.test/tango.git",
        default_branch: Some("main"),
        base_ref: None,
        target_branch: Some("main"),
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
    main_session_id: None,
    aux_session_ids: [],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: False,
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn agent_session(
  id: String,
  role: session.SessionRole,
  kind: session.SessionKind,
) -> session.AgentSession {
  session.AgentSession(
    id: id,
    ticket_id: "ticket-1",
    role: role,
    kind: kind,
    context_session_ids: case role, kind {
      session.Aux, session.Implementation -> ["main"]
      _, _ -> []
    },
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn merge_session() -> session.AgentSession {
  agent_session("merge-session", session.Aux, session.Merge)
}

fn awaiting_review_ticket() -> ticket.Ticket {
  ticket.Ticket(..onboarded_ticket(), state: lifecycle.AwaitingHumanReview)
}

fn request_changes_review() -> review.ReviewDecision {
  review.ReviewDecision(
    id: "review-1",
    ticket_id: "ticket-1",
    reviewer_id: "local:reviewer",
    decision: review.RequestChanges,
    comments: "needs another pass",
    reviewed_commit_set: [
      review.ReviewedCommit(repo_binding_id: "repo-1", commit_id: "abc123"),
    ],
    reviewed_pull_request_set: [
      review.ReviewedPullRequest(
        pull_request_ref: "https://example.test/pr/1",
        reviewed_head_commit_id: "abc123",
      ),
    ],
    authorization_mechanism: "tango review request-changes",
    created_at: "2026-06-07T00:04:00Z",
  )
}

fn approve_review() -> review.ReviewDecision {
  review.ReviewDecision(
    ..request_changes_review(),
    id: "review-approve",
    decision: review.Approve,
    comments: "approved for merge",
    authorization_mechanism: "tango merge",
    created_at: "2026-06-07T00:05:00Z",
  )
}

fn successful_merge_record() -> merge.MergeRecord {
  merge.MergeRecord(
    id: "merge-1",
    ticket_id: "ticket-1",
    review_decision_id: "review-approve",
    entries: [
      merge.MergeEntry(
        repo_binding_id: "repo-1",
        pull_request_ref: "https://example.test/pr/1",
        approved_head_commit_id: "abc123",
        status: merge.Completed,
      ),
    ],
    created_at: "2026-06-07T00:06:00Z",
    completed_at: "2026-06-07T00:07:00Z",
  )
}

fn blocked_merge_record() -> merge.MergeRecord {
  merge.MergeRecord(..successful_merge_record(), id: "merge-2", entries: [
    merge.MergeEntry(
      repo_binding_id: "repo-1",
      pull_request_ref: "https://example.test/pr/1",
      approved_head_commit_id: "abc123",
      status: merge.Pending,
    ),
  ])
}

pub fn queue_ticket_validates_and_persists_event_test() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), onboarded_ticket())
  let assert Ok(result) =
    command.queue_ticket(
      backend,
      state,
      "ticket-1",
      "event-queue",
      "human:local",
      "2026-06-07T00:01:00Z",
    )

  result.value.state
  |> should.equal(lifecycle.Queued)
  backend.list_events(result.state, Some("ticket-1"))
  |> should.equal(
    Ok([
      event.TangoEvent(
        schema_version: 1,
        id: "event-queue",
        ticket_id: Some("ticket-1"),
        type_: "ticket.queued",
        occurred_at: "2026-06-07T00:01:00Z",
        actor: "human:local",
        payload: dict.from_list([#("state", "queued")]),
      ),
    ]),
  )
}

pub fn incomplete_ticket_cannot_be_queued_test() {
  let backend = memory_store.store()
  let incomplete =
    ticket.Ticket(
      ..onboarded_ticket(),
      repo_bindings: [],
      registry_status_mapping: None,
      forge_binding: None,
    )
  let assert Ok(state) = backend.save_ticket(memory_store.new(), incomplete)

  command.queue_ticket(
    backend,
    state,
    "ticket-1",
    "event-queue",
    "human:local",
    "2026-06-07T00:01:00Z",
  )
  |> should.be_error()
}

pub fn main_and_aux_sessions_update_projection_test() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), onboarded_ticket())
  let main = agent_session("main", session.Main, session.Implementation)
  let assert Ok(result) =
    command.ensure_main_session(
      backend,
      state,
      "ticket-1",
      main,
      "event-main",
      "orchestrator",
      "2026-06-07T00:01:00Z",
    )
  let aux = agent_session("feedback", session.Aux, session.PrFeedback)
  let assert Ok(result) =
    command.append_aux_session(
      backend,
      result.state,
      "ticket-1",
      aux,
      "event-aux",
      "orchestrator",
      "2026-06-07T00:02:00Z",
    )

  let assert Ok(updated) = backend.get_ticket(result.state, "ticket-1")
  updated.main_session_id
  |> should.equal(Some("main"))
  updated.aux_session_ids
  |> should.equal(["feedback"])
}

pub fn unreferenced_session_is_ignored_by_topology_test() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), onboarded_ticket())
  let orphan = agent_session("orphan", session.Aux, session.PrFeedback)
  let assert Ok(state) = backend.save_session(state, orphan)
  let aux = agent_session("feedback", session.Aux, session.PrFeedback)

  command.append_aux_session(
    backend,
    state,
    "ticket-1",
    aux,
    "event-aux",
    "orchestrator",
    "2026-06-07T00:02:00Z",
  )
  |> should.be_ok()
}

pub fn corrupt_referenced_topology_blocks_new_aux_session_test() {
  let backend = memory_store.store()
  let corrupt =
    ticket.Ticket(..onboarded_ticket(), aux_session_ids: [
      "feedback",
      "feedback",
    ])
  let assert Ok(state) = backend.save_ticket(memory_store.new(), corrupt)
  let existing = agent_session("feedback", session.Aux, session.PrFeedback)
  let assert Ok(state) = backend.save_session(state, existing)
  let new_aux = agent_session("merge", session.Aux, session.Merge)

  command.append_aux_session(
    backend,
    state,
    "ticket-1",
    new_aux,
    "event-aux",
    "orchestrator",
    "2026-06-07T00:02:00Z",
  )
  |> should.be_error()
}

pub fn reconciliation_blocks_missing_session_reference_test() {
  let backend = memory_store.store()
  let broken =
    ticket.Ticket(
      ..onboarded_ticket(),
      state: lifecycle.Queued,
      main_session_id: Some("missing-main"),
    )
  let assert Ok(state) = backend.save_ticket(memory_store.new(), broken)
  let assert Ok(result) =
    reconcile.reconcile_ticket(
      backend,
      state,
      "ticket-1",
      "block-reconcile",
      "event-block",
      "2026-06-07T00:03:00Z",
    )

  result.changed
  |> should.be_true()
  result.ticket.state
  |> should.equal(lifecycle.Blocked)
  result.ticket.active_block_id
  |> should.equal(Some("block-reconcile"))
  backend.get_block(result.state, "ticket-1", "block-reconcile")
  |> should.be_ok()
}

pub fn reconcile_all_blocks_broken_non_terminal_tickets_test() {
  let backend = memory_store.store()
  let broken =
    ticket.Ticket(
      ..onboarded_ticket(),
      state: lifecycle.Queued,
      main_session_id: Some("missing-main"),
    )
  let assert Ok(state) = backend.save_ticket(memory_store.new(), broken)
  let assert Ok(#(state, results)) =
    reconcile.reconcile_all(
      backend,
      state,
      "2026-06-07T00:03:00Z",
      fn(item) { "block-" <> item.id },
      fn(item) { "event-" <> item.id },
    )

  results
  |> list.length
  |> should.equal(1)
  let assert Ok(updated) = backend.get_ticket(state, "ticket-1")
  updated.state
  |> should.equal(lifecycle.Blocked)
}

pub fn block_record_must_match_current_ticket_state_test() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), onboarded_ticket())
  let mismatched =
    block.BlockRecord(
      id: "block-1",
      ticket_id: "ticket-1",
      reason: "bad state",
      resolution_instructions: None,
      blocked_from: lifecycle.Queued,
      resume_state: lifecycle.Queued,
      created_by: "orchestrator",
      created_at: "2026-06-07T00:01:00Z",
      resolved_by: None,
      resolved_at: None,
    )

  command.block_ticket(
    backend,
    state,
    "ticket-1",
    mismatched,
    "event-block",
    "orchestrator",
    "2026-06-07T00:01:00Z",
  )
  |> should.be_error()
}

pub fn human_unblock_resolves_record_and_restores_resume_state_test() {
  let backend = memory_store.store()
  let queued = ticket.Ticket(..onboarded_ticket(), state: lifecycle.Queued)
  let assert Ok(state) = backend.save_ticket(memory_store.new(), queued)
  let record =
    block.BlockRecord(
      id: "block-1",
      ticket_id: "ticket-1",
      reason: "manual repair",
      resolution_instructions: None,
      blocked_from: lifecycle.Queued,
      resume_state: lifecycle.Queued,
      created_by: "orchestrator",
      created_at: "2026-06-07T00:01:00Z",
      resolved_by: None,
      resolved_at: None,
    )
  let assert Ok(blocked) =
    command.block_ticket(
      backend,
      state,
      "ticket-1",
      record,
      "event-block",
      "orchestrator",
      "2026-06-07T00:01:00Z",
    )
  let assert Ok(unblocked) =
    command.unblock_ticket(
      backend,
      blocked.state,
      "ticket-1",
      "local",
      "2026-06-07T00:02:00Z",
      "event-unblock",
    )

  unblocked.value.state
  |> should.equal(lifecycle.Queued)
  unblocked.value.active_block_id
  |> should.equal(None)
  let assert Ok(resolved) =
    backend.get_block(unblocked.state, "ticket-1", "block-1")
  resolved.resolved_by
  |> should.equal(Some("local"))
}

pub fn request_changes_review_persists_and_transitions_ticket_test() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), awaiting_review_ticket())
  let assert Ok(result) =
    command.submit_review(
      backend,
      state,
      "ticket-1",
      request_changes_review(),
      "event-review",
    )

  let assert Ok(updated) = backend.get_ticket(result.state, "ticket-1")
  updated.state
  |> should.equal(lifecycle.ChangesRequested)
  backend.get_review(result.state, "ticket-1", "review-1")
  |> should.be_ok()
}

pub fn unblock_restores_dispatch_eligibility_test() {
  let backend = memory_store.store()
  let blocked =
    ticket.Ticket(
      ..onboarded_ticket(),
      state: lifecycle.Blocked,
      active_block_id: Some("block-1"),
      blockers_clear: False,
    )
  let record =
    block.BlockRecord(
      id: "block-1",
      ticket_id: "ticket-1",
      reason: "manual recovery required",
      resolution_instructions: Some("resolve the issue"),
      blocked_from: lifecycle.Queued,
      resume_state: lifecycle.Queued,
      created_by: "agent:execution",
      created_at: "2026-06-07T00:01:00Z",
      resolved_by: None,
      resolved_at: None,
    )
  let assert Ok(state) = backend.save_ticket(memory_store.new(), blocked)
  let assert Ok(state) = backend.save_block(state, record)
  let assert Ok(result) =
    command.unblock_ticket(
      backend,
      state,
      "ticket-1",
      "local:reviewer",
      "2026-06-07T00:02:00Z",
      "event-unblock",
    )

  result.value.state
  |> should.equal(lifecycle.Queued)
  result.value.blockers_clear
  |> should.be_true()
}

pub fn approve_merge_creates_review_session_and_merging_state_test() {
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), awaiting_review_ticket())
  let assert Ok(result) =
    command.approve_merge(
      backend,
      state,
      "ticket-1",
      approve_review(),
      merge_session(),
      "event-review",
      "event-merge",
    )

  let assert Ok(updated) = backend.get_ticket(result.state, "ticket-1")
  updated.state
  |> should.equal(lifecycle.Merging)
  updated.aux_session_ids
  |> should.equal(["merge-session"])
  backend.get_review(result.state, "ticket-1", "review-approve")
  |> should.be_ok()
  backend.get_session(result.state, "ticket-1", "merge-session")
  |> should.be_ok()
}

pub fn successful_merge_record_marks_ticket_done_test() {
  let backend = memory_store.store()
  let merging =
    ticket.Ticket(..awaiting_review_ticket(), state: lifecycle.Merging)
  let assert Ok(state) = backend.save_ticket(memory_store.new(), merging)
  let assert Ok(state) = backend.save_review(state, approve_review())
  let assert Ok(result) =
    command.record_merge_result(
      backend,
      state,
      "ticket-1",
      successful_merge_record(),
      "event-merge",
      "block-merge",
    )

  let assert Ok(updated) = backend.get_ticket(result.state, "ticket-1")
  updated.state
  |> should.equal(lifecycle.Done)
  backend.get_merge(result.state, "ticket-1", "merge-1")
  |> should.be_ok()
}

pub fn pending_merge_record_blocks_for_human_recovery_test() {
  let backend = memory_store.store()
  let merging =
    ticket.Ticket(..awaiting_review_ticket(), state: lifecycle.Merging)
  let assert Ok(state) = backend.save_ticket(memory_store.new(), merging)
  let assert Ok(state) = backend.save_review(state, approve_review())
  let assert Ok(result) =
    command.record_merge_result(
      backend,
      state,
      "ticket-1",
      blocked_merge_record(),
      "event-merge",
      "block-merge",
    )

  let assert Ok(updated) = backend.get_ticket(result.state, "ticket-1")
  updated.state
  |> should.equal(lifecycle.Blocked)
  updated.active_block_id
  |> should.equal(Some("block-merge"))
  let assert Ok(unblocked) =
    command.unblock_ticket(
      backend,
      result.state,
      "ticket-1",
      "local:reviewer",
      "2026-06-07T00:04:00Z",
      "event-unblock-merge",
    )
  unblocked.value.state
  |> should.equal(lifecycle.AwaitingHumanReview)
}
