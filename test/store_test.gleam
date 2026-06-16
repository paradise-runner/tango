import fixtures
import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import tango/domain/artifact
import tango/domain/block
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/review
import tango/domain/review_cursor
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/codec
import tango/store/file
import tango/store/json_store
import tango/store/memory_store
import tango/store/store

fn sample_ticket() -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: Some("Build durable state"),
    priority: Some(1),
    labels: ["storage"],
    lifecycle_policy: Some("strict"),
    state: lifecycle.Queued,
    repo_bindings: [
      repo.RepoBinding(
        id: "repo-1",
        name: "tango",
        kind: repo.GitRemote,
        location: "https://example.test/tango.git",
        default_branch: Some("main"),
        base_ref: None,
        target_branch: Some("main"),
        work_branch: Some("tango/ticket-1"),
        checkout_policy: repo.Clone,
      ),
    ],
    external_ref: Some("https://tracker.test/TANGO-1"),
    registry_binding: Some(fixtures.registry_binding()),
    registry_status_mapping: Some(fixtures.registry_status_mapping()),
    forge_binding: Some(fixtures.forge_binding()),
    observed_external_status_id: Some("todo"),
    capability_profile_digest: Some("sha256:profile"),
    main_session_id: Some("session-main"),
    aux_session_ids: ["session-review"],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: False,
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn sample_event() -> event.TangoEvent {
  event.new(
    id: "event-1",
    ticket_id: Some("ticket-1"),
    type_: "ticket.queued",
    occurred_at: "2026-06-07T00:00:00Z",
    actor: "human:local",
    payload: dict.from_list([#("state", "queued")]),
  )
}

fn main_session() -> session.AgentSession {
  session.AgentSession(
    id: "session-main",
    ticket_id: "ticket-1",
    role: session.Main,
    kind: session.Implementation,
    context_session_ids: [],
    runtime_session_id: Some("codex-main"),
    run_attempt_ids: ["run-1"],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:01:00Z",
  )
}

fn aux_session() -> session.AgentSession {
  session.AgentSession(
    id: "session-review",
    ticket_id: "ticket-1",
    role: session.Aux,
    kind: session.PrFeedback,
    context_session_ids: [],
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:02:00Z",
    updated_at: "2026-06-07T00:02:00Z",
  )
}

pub fn session_codec_defaults_legacy_context_links_to_empty_test() {
  let legacy =
    "{\"schema_version\":1,\"id\":\"legacy\",\"ticket_id\":\"ticket-1\",\"role\":\"main\",\"kind\":\"implementation\",\"runtime_session_id\":null,\"run_attempt_ids\":[],\"created_at\":\"2026-06-07T00:00:00Z\",\"updated_at\":\"2026-06-07T00:00:00Z\"}"
  let assert Ok(decoded) = codec.decode_session(legacy)

  decoded.context_session_ids
  |> should.equal([])
}

fn sample_block() -> block.BlockRecord {
  block.BlockRecord(
    id: "block-1",
    ticket_id: "ticket-1",
    reason: "manual repair required",
    resolution_instructions: Some("Repair the workspace"),
    blocked_from: lifecycle.Queued,
    resume_state: lifecycle.Queued,
    created_by: "orchestrator",
    created_at: "2026-06-07T00:03:00Z",
    resolved_by: None,
    resolved_at: None,
  )
}

fn sample_artifact() -> artifact.ArtifactRecord {
  artifact.ArtifactRecord(
    id: "artifact-1",
    ticket_id: "ticket-1",
    run_id: "run-1",
    kind: artifact.ValidationReport,
    filename: "validation.json",
    content_type: "application/json",
    sha256: "abc123",
    content: "{\"schema_version\":1,\"checks\":[]}",
    created_at: "2026-06-07T00:03:30Z",
  )
}

fn sample_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "run-1",
    ticket_id: "ticket-1",
    session_id: "session-main",
    kind: run.Execution,
    current_stage: Some(lifecycle.Research),
    stages: [lifecycle.Research, lifecycle.Plan, lifecycle.Implement],
    attempt: 1,
    workspace_path: "/tmp/tango/ticket-1",
    agent_runtime: "fake",
    capability_profile_digest: Some("sha256:profile"),
    effective_capabilities: ["tickets"],
    resume_state: lifecycle.Queued,
    started_at: "2026-06-07T00:04:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    error: None,
  )
}

fn sample_review() -> review.ReviewDecision {
  review.ReviewDecision(
    id: "review-1",
    ticket_id: "ticket-1",
    reviewer_id: "local:reviewer",
    decision: review.RequestChanges,
    comments: "Please address feedback",
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
    created_at: "2026-06-07T00:05:00Z",
  )
}

fn sample_merge() -> merge.MergeRecord {
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

fn sample_review_cursor() -> review_cursor.ReviewCommentCursor {
  review_cursor.ReviewCommentCursor(
    ticket_id: "ticket-1",
    pull_request_ref: "https://example.test/pr/1",
    comment_count: 3,
    observed_at: "2026-06-07T00:08:00Z",
  )
}

pub fn ticket_codec_round_trips_projection_test() {
  let ticket = sample_ticket()

  ticket
  |> codec.encode_ticket
  |> codec.decode_ticket
  |> should.equal(Ok(ticket))
}

pub fn session_codec_round_trips_test() {
  main_session()
  |> codec.encode_session
  |> codec.decode_session
  |> should.equal(Ok(main_session()))
}

pub fn block_codec_round_trips_test() {
  sample_block()
  |> codec.encode_block
  |> codec.decode_block
  |> should.equal(Ok(sample_block()))
}

pub fn artifact_codec_round_trips_test() {
  sample_artifact()
  |> codec.encode_artifact
  |> codec.decode_artifact
  |> should.equal(Ok(sample_artifact()))
}

pub fn run_codec_round_trips_test() {
  sample_run()
  |> codec.encode_run
  |> codec.decode_run
  |> should.equal(Ok(sample_run()))
}

pub fn review_codec_round_trips_test() {
  sample_review()
  |> codec.encode_review
  |> codec.decode_review
  |> should.equal(Ok(sample_review()))
}

pub fn merge_codec_round_trips_test() {
  sample_merge()
  |> codec.encode_merge
  |> codec.decode_merge
  |> should.equal(Ok(sample_merge()))
}

pub fn review_cursor_codec_round_trips_test() {
  [sample_review_cursor()]
  |> codec.encode_review_cursor_file
  |> codec.decode_review_cursor_file
  |> should.equal(Ok([sample_review_cursor()]))
}

pub fn incompatible_ticket_schema_fails_closed_test() {
  sample_ticket()
  |> codec.encode_ticket
  |> string.replace("\"schema_version\":4", "\"schema_version\":5")
  |> codec.decode_ticket
  |> should.be_error()
}

pub fn malformed_registry_binding_fails_closed_test() {
  let malformed =
    ticket.Ticket(
      ..sample_ticket(),
      registry_binding: Some(
        registry_status.RegistryBinding(
          ..fixtures.registry_binding(),
          pinned_mapping_digest: "",
        ),
      ),
      registry_status_mapping: None,
      forge_binding: None,
    )

  malformed
  |> codec.encode_ticket
  |> codec.decode_ticket
  |> should.be_error()
}

pub fn memory_store_replaces_ticket_and_keeps_events_immutable_test() {
  let state = memory_store.new()
  let assert Ok(state) = memory_store.save_ticket(state, sample_ticket())
  let assert Ok(state) = memory_store.save_session(state, main_session())
  let assert Ok(state) = memory_store.save_block(state, sample_block())
  let assert Ok(state) = memory_store.save_run(state, sample_run())
  let assert Ok(state) = memory_store.save_review(state, sample_review())
  let assert Ok(state) =
    memory_store.save_review_cursor(state, sample_review_cursor())
  let assert Ok(state) = memory_store.save_merge(state, sample_merge())
  memory_store.get_ticket(state, "ticket-1")
  |> should.equal(Ok(sample_ticket()))
  memory_store.get_session(state, "ticket-1", "session-main")
  |> should.equal(Ok(main_session()))
  memory_store.get_block(state, "ticket-1", "block-1")
  |> should.equal(Ok(sample_block()))
  memory_store.get_run(state, "ticket-1", "run-1")
  |> should.equal(Ok(sample_run()))
  memory_store.get_review(state, "ticket-1", "review-1")
  |> should.equal(Ok(sample_review()))
  memory_store.get_review_cursor(state, "ticket-1", "https://example.test/pr/1")
  |> should.equal(Ok(sample_review_cursor()))
  memory_store.get_merge(state, "ticket-1", "merge-1")
  |> should.equal(Ok(sample_merge()))

  let assert Ok(state) = memory_store.append_event(state, sample_event())
  memory_store.append_event(state, sample_event())
  |> should.equal(Error(store.ImmutableEventAlreadyExists("event-1")))
}

pub fn json_store_survives_reopen_and_keeps_events_immutable_test() {
  let assert Ok(root) = file.temporary_directory("tango-json-store")
  let state = json_store.new(root)
  let assert Ok(_) = json_store.save_ticket(state, sample_ticket())
  let assert Ok(_) = json_store.save_session(state, main_session())
  let assert Ok(_) = json_store.save_session(state, aux_session())
  let assert Ok(_) = json_store.save_block(state, sample_block())
  let assert Ok(_) = json_store.save_run(state, sample_run())
  let assert Ok(_) = json_store.save_review(state, sample_review())
  let assert Ok(_) =
    json_store.save_review_cursor(state, sample_review_cursor())
  let assert Ok(_) = json_store.save_merge(state, sample_merge())
  let assert Ok(_) = json_store.append_event(state, sample_event())

  let reopened = json_store.new(root)
  json_store.get_ticket(reopened, "ticket-1")
  |> should.equal(Ok(sample_ticket()))
  json_store.get_session(reopened, "ticket-1", "session-main")
  |> should.equal(Ok(main_session()))
  json_store.list_sessions(reopened, "ticket-1")
  |> should.equal(Ok([main_session(), aux_session()]))
  json_store.get_block(reopened, "ticket-1", "block-1")
  |> should.equal(Ok(sample_block()))
  json_store.get_run(reopened, "ticket-1", "run-1")
  |> should.equal(Ok(sample_run()))
  json_store.get_review(reopened, "ticket-1", "review-1")
  |> should.equal(Ok(sample_review()))
  json_store.get_review_cursor(
    reopened,
    "ticket-1",
    "https://example.test/pr/1",
  )
  |> should.equal(Ok(sample_review_cursor()))
  json_store.get_merge(reopened, "ticket-1", "merge-1")
  |> should.equal(Ok(sample_merge()))
  json_store.list_events(reopened, Some("ticket-1"))
  |> should.equal(Ok([sample_event()]))
  json_store.append_event(reopened, sample_event())
  |> should.equal(Error(store.ImmutableEventAlreadyExists("event-1")))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn json_store_atomic_replacement_leaves_no_temp_file_test() {
  let assert Ok(root) = file.temporary_directory("tango-json-store")
  let state = json_store.new(root)
  let assert Ok(_) = json_store.save_ticket(state, sample_ticket())
  let updated = ticket.Ticket(..sample_ticket(), state: lifecycle.Researching)
  let assert Ok(_) = json_store.save_ticket(state, updated)

  file.list_dir(root <> "/tickets/ticket-1")
  |> should.equal(Ok(["ticket.json"]))
  json_store.get_ticket(state, "ticket-1")
  |> should.equal(Ok(updated))

  file.remove_tree(root)
  |> should.be_ok()
}
