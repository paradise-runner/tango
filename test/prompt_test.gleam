import fixtures
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import tango/domain/artifact
import tango/domain/lifecycle
import tango/domain/repo
import tango/domain/review
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/prompt
import tango/workspace/workspace

fn sample_ticket(state: lifecycle.LifecycleState) -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: Some("Clarify the agent prompt"),
    priority: Some(1),
    labels: ["mvp", "prompt"],
    lifecycle_policy: None,
    state: state,
    repo_bindings: [
      repo.RepoBinding(
        id: "repo-1",
        name: "tango",
        kind: repo.GitRemote,
        location: "https://example.test/tango.git",
        default_branch: Some("main"),
        base_ref: Some("main"),
        target_branch: Some("main"),
        work_branch: Some("tango-1-agent-prompt"),
        checkout_policy: repo.Clone,
      ),
    ],
    external_ref: Some("TANGO-1"),
    registry_binding: Some(fixtures.registry_binding()),
    registry_status_mapping: Some(fixtures.registry_status_mapping()),
    forge_binding: Some(fixtures.forge_binding()),
    observed_external_status_id: Some("todo"),
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

fn aux_implementation_session() -> session.AgentSession {
  session.AgentSession(
    id: "aux-implementation",
    ticket_id: "ticket-1",
    role: session.Aux,
    kind: session.Implementation,
    context_session_ids: ["main", "review-watch"],
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn aux_session(kind: session.SessionKind) -> session.AgentSession {
  session.AgentSession(
    id: "aux",
    ticket_id: "ticket-1",
    role: session.Aux,
    kind: kind,
    context_session_ids: [],
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn attempt(
  kind: run.RunKind,
  resume_state: lifecycle.LifecycleState,
) -> run.RunAttempt {
  run.RunAttempt(
    id: "run-1",
    ticket_id: "ticket-1",
    session_id: "main",
    kind: kind,
    current_stage: Some(lifecycle.Research),
    stages: [lifecycle.Research, lifecycle.Plan, lifecycle.Implement],
    attempt: 1,
    workspace_path: "/tmp/workspace",
    agent_runtime: "codex",
    capability_profile_digest: Some("digest"),
    effective_capabilities: ["workspace_write", "ticket_system", "forge"],
    resume_state: resume_state,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.BuildingPrompt,
    usage: None,
    error: None,
  )
}

fn sample_workspace() -> workspace.Workspace {
  workspace.Workspace(root_path: "/tmp/workspace", repos: [
    workspace.WorkspaceRepo(
      binding_id: "repo-1",
      source: "https://example.test/tango.git",
      path: "/tmp/workspace/tango",
    ),
  ])
}

fn prior_artifact() -> artifact.ArtifactRecord {
  artifact.ArtifactRecord(
    id: "artifact-1",
    ticket_id: "ticket-1",
    run_id: "run-0",
    kind: artifact.ImplementationNotes,
    filename: "implementation.md",
    content_type: "text/markdown",
    sha256: "sha",
    content: "Prior implementation context",
    created_at: "2026-06-07T00:02:00Z",
  )
}

fn merge_review() -> review.ReviewDecision {
  review.ReviewDecision(
    id: "review-1",
    ticket_id: "ticket-1",
    reviewer_id: "local:test",
    decision: review.Approve,
    comments: "Looks ready.",
    reviewed_commit_set: [
      review.ReviewedCommit(repo_binding_id: "repo-1", commit_id: "abc123"),
    ],
    reviewed_pull_request_set: [
      review.ReviewedPullRequest(
        pull_request_ref: "https://example.test/pr/1",
        reviewed_head_commit_id: "abc123",
      ),
    ],
    authorization_mechanism: "tango review merge",
    created_at: "2026-06-07T00:03:00Z",
  )
}

fn build_prompt(
  item: ticket.Ticket,
  agent_session: session.AgentSession,
  attempt: run.RunAttempt,
  artifacts: List(artifact.ArtifactRecord),
  reviews: List(review.ReviewDecision),
) -> String {
  prompt.build(
    item,
    agent_session,
    attempt,
    sample_workspace(),
    "/tmp/workpad",
    artifacts,
    reviews,
  )
}

fn assert_contains(source: String, expected: String) {
  source
  |> string.contains(expected)
  |> should.be_true()
}

fn assert_not_contains(source: String, unexpected: String) {
  source
  |> string.contains(unexpected)
  |> should.be_false()
}

pub fn execution_prompt_golden_includes_ticket_repo_lifecycle_and_schemas_test() {
  let source =
    build_prompt(
      sample_ticket(lifecycle.Queued),
      main_session(),
      attempt(run.Execution, lifecycle.Queued),
      [],
      [],
    )

  assert_contains(source, "# Ticket")
  assert_contains(source, "stored_title: Clarify the agent prompt")
  assert_contains(source, "external_ticket_ref: TANGO-1")
  assert_contains(source, "- binding_id: repo-1")
  assert_contains(source, "workspace_path: /tmp/workspace/tango")
  assert_contains(
    source,
    "required_artifacts: normalized_ticket, research_notes, plan, diff_summary, implementation_notes, validation_report, pull_request_set, external_updates",
  )
  assert_contains(source, "ticket.json schema:")
  assert_contains(source, "acceptance_criteria")
  assert_contains(source, "blockers")
  assert_contains(source, "validation.json schema:")
  assert_contains(source, "pull-requests.json schema:")
  assert_contains(
    source,
    "Never merge pull requests, approve work, or complete the external ticket in an execution run.",
  )
}

pub fn requested_changes_prompt_golden_links_context_and_feedback_test() {
  let item = sample_ticket(lifecycle.ChangesRequested)
  let source =
    build_prompt(
      item,
      aux_implementation_session(),
      attempt(run.Execution, lifecycle.ChangesRequested),
      [prior_artifact()],
      [
        review.ReviewDecision(
          ..merge_review(),
          decision: review.RequestChanges,
          comments: "Please add the missing validation command.",
        ),
      ],
    )

  assert_contains(source, "session_role: aux")
  assert_contains(source, "context_session_ids: main, review-watch")
  assert_contains(
    source,
    "Respond to requested changes using the durable context_session_ids.",
  )
  assert_contains(source, "Prior implementation context")
  assert_contains(source, "## Review: request_changes")
  assert_contains(source, "Please add the missing validation command.")
  assert_contains(
    source,
    "Create and update TODO items as you research, plan, implement, validate, and respond to requested changes.",
  )
}

pub fn review_feedback_prompt_golden_is_comment_scoped_test() {
  let source =
    build_prompt(
      sample_ticket(lifecycle.AwaitingHumanReview),
      aux_session(session.PrFeedback),
      attempt(run.ReviewWatch, lifecycle.AwaitingHumanReview),
      [],
      [],
    )

  assert_contains(source, "review_watch")
  assert_contains(source, "Classify newly observed review feedback")
  assert_contains(source, "review-comments.json schema:")
  assert_contains(
    source,
    "write only review-comments.json, external-updates.json, and result.json",
  )
  assert_contains(
    source,
    "do not edit repositories, create commits, create pull requests, approve reviews, merge",
  )
  assert_not_contains(source, "ticket.json schema:")
  assert_not_contains(source, "pull-requests.json schema:")
}

pub fn registry_sync_prompt_golden_excludes_forge_and_repo_mutations_test() {
  let source =
    build_prompt(
      sample_ticket(lifecycle.Failed),
      aux_session(session.RegistrySync),
      attempt(run.RegistrySync, lifecycle.Failed),
      [],
      [],
    )

  assert_contains(source, "registry_sync")
  assert_contains(source, "requested_role: blocked")
  assert_contains(source, "external-updates.json schema:")
  assert_contains(source, "write only external-updates.json and result.json")
  assert_contains(
    source,
    "Do not use forge tools, modify repositories, create pull requests, approve work, merge pull requests, or change Tango lifecycle state.",
  )
  assert_not_contains(source, "# Forge")
  assert_not_contains(source, "merge.json schema:")
}

pub fn merge_prompt_golden_is_scoped_to_reviewed_sets_test() {
  let source =
    build_prompt(
      sample_ticket(lifecycle.Merging),
      aux_session(session.Merge),
      attempt(run.MergeRun, lifecycle.Merging),
      [],
      [merge_review()],
    )

  assert_contains(source, "merge")
  assert_contains(
    source,
    "Tango has already recorded human approval through tango review merge.",
  )
  assert_contains(
    source,
    "Merge only pull requests listed in the durable reviewed_pull_requests set",
  )
  assert_contains(source, "reviewed_commits: repo-1=abc123")
  assert_contains(
    source,
    "reviewed_pull_requests: https://example.test/pr/1=abc123",
  )
  assert_contains(source, "merge.json schema:")
  assert_contains(
    source,
    "do not create new implementation commits, change pull-request heads, add unapproved pull requests, or broaden the reviewed set",
  )
  assert_not_contains(source, "ticket.json schema:")
  assert_not_contains(source, "pull-requests.json schema:")
}

pub fn research_only_no_code_prompt_golden_requires_empty_pull_request_set_test() {
  let item =
    ticket.Ticket(
      ..sample_ticket(lifecycle.Queued),
      lifecycle_policy: Some("research-only"),
      labels: ["research-only"],
    )
  let source =
    build_prompt(
      item,
      main_session(),
      attempt(run.Execution, lifecycle.Queued),
      [],
      [],
    )

  assert_contains(
    source,
    "A successful research-only or no-code execution also ends in human review with an empty pull-request set.",
  )
  assert_contains(
    source,
    "Post a final review handoff comment when implementation changed code, or a final research/recommendation handoff comment when no repository changes are required.",
  )
  assert_contains(
    source,
    "For research-only/no-code work, write {\"schema_version\":1,\"pull_requests\":[]}.",
  )
  assert_contains(
    source,
    "do not merge, close the external ticket as done, approve reviews, edit Tango state, or fabricate repository changes for research-only/no-code work",
  )
}
