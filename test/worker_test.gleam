import fixtures
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import tango/agent/adapter
import tango/agent/codex
import tango/attestation/adapter as attestation
import tango/domain/artifact
import tango/domain/forge
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/review
import tango/domain/review_cursor
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/git/adapter as git
import tango/store/file
import tango/store/memory_store
import tango/store/store
import tango/worker
import tango/workspace/aicasa
import tango/workspace/workspace

fn queued_ticket() -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: Some("Implement worker path"),
    priority: Some(1),
    labels: [],
    lifecycle_policy: None,
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

fn two_repo_ticket() -> ticket.Ticket {
  ticket.Ticket(..queued_ticket(), repo_bindings: [
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
    repo.RepoBinding(
      id: "repo-2",
      name: "docs",
      kind: repo.GitRemote,
      location: "https://example.test/docs.git",
      default_branch: Some("main"),
      base_ref: None,
      target_branch: Some("main"),
      work_branch: None,
      checkout_policy: repo.Clone,
    ),
  ])
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

fn awaiting_review_ticket() -> ticket.Ticket {
  ticket.Ticket(
    ..queued_ticket(),
    state: lifecycle.AwaitingHumanReview,
    aux_session_ids: ["feedback-1"],
  )
}

fn review_watch_session() -> session.AgentSession {
  session.AgentSession(
    id: "feedback-1",
    ticket_id: "ticket-1",
    role: session.Aux,
    kind: session.PrFeedback,
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
    agent_runtime: "codex",
    capability_profile_digest: Some("digest"),
    effective_capabilities: [],
    resume_state: lifecycle.Queued,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    usage: None,
    error: None,
  )
}

fn review_watch_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "watch-1",
    ticket_id: "ticket-1",
    session_id: "feedback-1",
    kind: run.ReviewWatch,
    current_stage: Some(lifecycle.HumanReview),
    stages: [lifecycle.HumanReview],
    attempt: 1,
    workspace_path: "/tmp/workspace",
    agent_runtime: "codex",
    capability_profile_digest: Some("digest"),
    effective_capabilities: [],
    resume_state: lifecycle.AwaitingHumanReview,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    usage: None,
    error: None,
  )
}

fn merging_ticket() -> ticket.Ticket {
  ticket.Ticket(..queued_ticket(), state: lifecycle.Merging, aux_session_ids: [
    "merge-1",
  ])
}

fn merge_session() -> session.AgentSession {
  session.AgentSession(
    id: "merge-1",
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
    session_id: "merge-1",
    kind: run.MergeRun,
    current_stage: Some(lifecycle.Merge),
    stages: [lifecycle.Merge],
    attempt: 1,
    workspace_path: "/tmp/workspace",
    agent_runtime: "codex",
    capability_profile_digest: Some("digest"),
    effective_capabilities: [],
    resume_state: lifecycle.Merging,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    usage: None,
    error: None,
  )
}

fn registry_sync_session() -> session.AgentSession {
  session.AgentSession(
    id: "registry-sync-1",
    ticket_id: "ticket-1",
    role: session.Aux,
    kind: session.RegistrySync,
    context_session_ids: [],
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn registry_sync_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "registry-sync-run",
    ticket_id: "ticket-1",
    session_id: "registry-sync-1",
    kind: run.RegistrySync,
    current_stage: Some(lifecycle.Implement),
    stages: [lifecycle.Implement],
    attempt: 1,
    workspace_path: "/tmp/workspace",
    agent_runtime: "codex",
    capability_profile_digest: Some("digest"),
    effective_capabilities: [],
    resume_state: lifecycle.Queued,
    started_at: "2026-06-07T00:01:00Z",
    ended_at: None,
    status: run.PreparingWorkspace,
    usage: None,
    error: None,
  )
}

fn merge_review() -> review.ReviewDecision {
  review.ReviewDecision(
    id: "review-merge",
    ticket_id: "ticket-1",
    reviewer_id: "local:test",
    decision: review.Approve,
    comments: "",
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

fn reviewed_pull_request_artifact() -> artifact.ArtifactRecord {
  artifact.ArtifactRecord(
    id: "artifact-prs",
    ticket_id: "ticket-1",
    run_id: "run-1",
    kind: artifact.PullRequestSet,
    filename: "pull-requests.json",
    content_type: "application/json",
    sha256: "sha",
    content: "{\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"repo-1\",\"commit_id\":\"abc123\",\"pull_request_ref\":\"https://example.test/pr/1\",\"head_commit_id\":\"abc123\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":2}]}",
    created_at: "2026-06-07T00:02:00Z",
  )
}

fn multi_repo_merge_review() -> review.ReviewDecision {
  review.ReviewDecision(
    ..merge_review(),
    reviewed_commit_set: [
      review.ReviewedCommit(repo_binding_id: "repo-1", commit_id: "abc123"),
      review.ReviewedCommit(repo_binding_id: "repo-2", commit_id: "def456"),
    ],
    reviewed_pull_request_set: [
      review.ReviewedPullRequest(
        pull_request_ref: "https://example.test/pr/1",
        reviewed_head_commit_id: "abc123",
      ),
      review.ReviewedPullRequest(
        pull_request_ref: "https://example.test/pr/2",
        reviewed_head_commit_id: "def456",
      ),
    ],
  )
}

fn multi_repo_pull_request_artifact() -> artifact.ArtifactRecord {
  artifact.ArtifactRecord(
    ..reviewed_pull_request_artifact(),
    content: "{\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"repo-1\",\"commit_id\":\"abc123\",\"pull_request_ref\":\"https://example.test/pr/1\",\"head_commit_id\":\"abc123\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":2},{\"repo_binding_id\":\"repo-2\",\"commit_id\":\"def456\",\"pull_request_ref\":\"https://example.test/pr/2\",\"head_commit_id\":\"def456\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":1}]}",
  )
}

fn initial_review_cursor() -> review_cursor.ReviewCommentCursor {
  review_cursor.ReviewCommentCursor(
    ticket_id: "ticket-1",
    pull_request_ref: "https://example.test/pr/1",
    comment_count: 1,
    observed_at: "2026-06-07T00:00:00Z",
  )
}

pub fn codex_exec_command_uses_workspace_write_and_workpad_test() {
  let request =
    adapter.AgentRequest(
      prompt: "hello",
      workspace_path: "/tmp/workspace",
      workpad_path: "/tmp/workpad",
      sandbox_paths: [],
      resume_session_id: None,
      on_process_started: fn(_) { Nil },
    )

  codex.command_args(request)
  |> should.equal([
    "exec",
    "--json",
    "--cd",
    "/tmp/workspace",
    "--sandbox",
    "workspace-write",
    "--add-dir",
    "/tmp/workpad",
    "--skip-git-repo-check",
    "-c",
    "approval_policy=never",
    "-c",
    "sandbox_workspace_write.network_access=true",
    "hello",
  ])
}

pub fn codex_exec_command_adds_sandbox_paths_test() {
  let request =
    adapter.AgentRequest(
      prompt: "hello",
      workspace_path: "/tmp/workspace",
      workpad_path: "/tmp/workpad",
      sandbox_paths: ["/tmp/codex-skills", "/tmp/tango-capabilities"],
      resume_session_id: None,
      on_process_started: fn(_) { Nil },
    )

  codex.command_args(request)
  |> should.equal([
    "exec",
    "--json",
    "--cd",
    "/tmp/workspace",
    "--sandbox",
    "workspace-write",
    "--add-dir",
    "/tmp/workpad",
    "--add-dir",
    "/tmp/codex-skills",
    "--add-dir",
    "/tmp/tango-capabilities",
    "--skip-git-repo-check",
    "-c",
    "approval_policy=never",
    "-c",
    "sandbox_workspace_write.network_access=true",
    "hello",
  ])
}

pub fn codex_resume_command_uses_resume_session_id_test() {
  let request =
    adapter.AgentRequest(
      prompt: "resume",
      workspace_path: "/tmp/workspace",
      workpad_path: "/tmp/workpad",
      sandbox_paths: ["/tmp/codex-skills"],
      resume_session_id: Some("session-123"),
      on_process_started: fn(_) { Nil },
    )

  codex.command_args(request)
  |> should.equal([
    "exec",
    "resume",
    "session-123",
    "--json",
    "--skip-git-repo-check",
    "-c",
    "approval_policy=never",
    "-c",
    "sandbox_workspace_write.network_access=true",
    "resume",
  ])
}

pub fn codex_json_output_extracts_latest_usage_test() {
  let output =
    "{\"type\":\"session.started\",\"thread_id\":\"thread-1\"}\n"
    <> "{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10,\"cached_input_tokens\":4,\"output_tokens\":5,\"reasoning_output_tokens\":2,\"total_tokens\":15}}\n"
    <> "{\"type\":\"turn.completed\",\"usage\":{\"prompt_tokens\":20,\"cached_tokens\":8,\"completion_tokens\":7,\"reasoning_tokens\":3,\"total_tokens\":27}}"

  codex.extract_usage(output)
  |> should.equal(
    Some(run.RunUsage(
      input_tokens: 20,
      cached_input_tokens: 8,
      output_tokens: 7,
      reasoning_output_tokens: 3,
      total_tokens: 27,
    )),
  )
}

pub fn aicasa_workspace_name_is_slugged_and_hashed_test() {
  aicasa.workspace_name("TANGO/One Two")
  |> string.starts_with("tango-one-two-")
  |> should.be_true()
}

pub fn worker_execute_creates_manifest_and_completes_run_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [
              workspace.WorkspaceRepo(
                binding_id: "repo-1",
                source: "https://example.test/tango.git",
                path: root <> "/workspace-" <> item.id <> "/tango",
              ),
            ],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        request.prompt
        |> string.contains("cli: test-registry")
        |> should.be_true()
        request.prompt
        |> string.contains("skill: test-registry-skill")
        |> should.be_true()
        request.prompt
        |> string.contains("requested_status_id: todo")
        |> should.be_true()
        request.prompt
        |> string.contains("forge: github")
        |> should.be_true()
        request.prompt
        |> string.contains("skill: forge")
        |> should.be_true()
        request.prompt
        |> string.contains("Read and follow the installed forge skill")
        |> should.be_true()
        request.prompt
        |> string.contains("# External Ticket Work Protocol")
        |> should.be_true()
        request.prompt
        |> string.contains("<!-- tango:todo:start -->")
        |> should.be_true()
        request.prompt
        |> string.contains("TG-TODO-001")
        |> should.be_true()
        request.prompt
        |> string.contains(
          "Missing TODO or comment evidence must not stop you from writing result.json",
        )
        |> should.be_true()
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{\"thread_id\":\"thread-1\"}\n{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":100,\"cached_input_tokens\":25,\"output_tokens\":20,\"reasoning_output_tokens\":5,\"total_tokens\":120}}",
          runtime_session_id: Some("thread-1"),
          usage: Some(run.RunUsage(
            input_tokens: 100,
            cached_input_tokens: 25,
            output_tokens: 20,
            reasoning_output_tokens: 5,
            total_tokens: 120,
          )),
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.error
  |> should.equal(None)
  result.run.status
  |> should.equal(run.Succeeded)
  result.run.usage
  |> should.equal(
    Some(run.RunUsage(
      input_tokens: 100,
      cached_input_tokens: 25,
      output_tokens: 20,
      reasoning_output_tokens: 5,
      total_tokens: 120,
    )),
  )
  result.run.workspace_path
  |> should.equal(root <> "/workspace-ticket-1")
  result.ticket.state
  |> should.equal(lifecycle.AwaitingHumanReview)
  file.read(result.workpad_path <> "/manifest.json")
  |> should.be_ok()
  let assert Ok(artifacts) = backend.list_artifacts(result.state, "ticket-1")
  artifacts
  |> list.length
  |> should.equal(8)
  artifacts
  |> list.any(fn(record) {
    record.kind == artifact.PullRequestSet
    && record.run_id == "run-1"
    && record.filename == "pull-requests.json"
    && record.created_at == execution_run().started_at
  })
  |> should.be_true()
  backend.get_review_cursor(
    result.state,
    "ticket-1",
    "https://example.test/pr/1",
  )
  |> should.equal(
    Ok(review_cursor.ReviewCommentCursor(
      ticket_id: "ticket-1",
      pull_request_ref: "https://example.test/pr/1",
      comment_count: 2,
      observed_at: "2026-06-07T00:10:00Z",
    )),
  )
  let assert Ok(events) = backend.list_events(result.state, Some("ticket-1"))
  events
  |> list.filter(fn(item) { item.type_ == "ticket.lifecycle_transition" })
  |> list.length
  |> should.equal(4)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn worker_request_exposes_installed_skill_directories_to_agent_sandbox_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-skill-sandbox")
  let ticket_system_skill =
    root <> "/capabilities/ticket-systems/github/SKILL.md"
  let forge_skill = root <> "/capabilities/forges/github/SKILL.md"
  let assert Ok(_) =
    file.atomic_replace(ticket_system_skill, "# github-ticket-system\n")
  let assert Ok(_) = file.atomic_replace(forge_skill, "# github-forge\n")
  let item =
    ticket.Ticket(
      ..queued_ticket(),
      registry_binding: Some(registry_status.RegistryBinding(
        registry_name: "github",
        cli_command: "gh",
        registry_skill: ticket_system_skill,
        external_ticket_ref: "TANGO-1",
        pinned_mapping_digest: "sha256:statuses",
      )),
      forge_binding: Some(forge.ForgeBinding(
        forge_name: "github",
        cli_command: "gh",
        forge_skill: forge_skill,
      )),
    )
  let backend = memory_store.store()
  let assert Ok(state) = backend.save_ticket(memory_store.new(), item)
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        request.sandbox_paths
        |> list.contains(root <> "/capabilities/ticket-systems/github")
        |> should.be_true()
        request.sandbox_paths
        |> list.contains(root <> "/capabilities/forges/github")
        |> should.be_true()
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Succeeded)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn execution_promotion_does_not_require_external_comments_test() {
  let assert Ok(root) = file.temporary_directory("tango-no-comment-gate")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [
              workspace.WorkspaceRepo(
                binding_id: "repo-1",
                source: "https://example.test/tango.git",
                path: root <> "/workspace-" <> item.id <> "/tango",
              ),
            ],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.Adapters(
        ticket_system: attestation.TicketAdapter(read: fn(request) {
          Ok(
            attestation.TicketSnapshot(
              external_ref: request.binding.external_ticket_ref,
              description_revision: "rev-empty-comments",
              comments: [],
              status_ids: [request.expected_status.id],
            ),
          )
        }),
        forge: attestation.passthrough().forge,
      ),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{\"thread_id\":\"thread-1\"}",
          runtime_session_id: Some("thread-1"),
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.error
  |> should.equal(None)
  result.run.status
  |> should.equal(run.Succeeded)
  result.ticket.state
  |> should.equal(lifecycle.AwaitingHumanReview)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn registry_sync_rejects_unverified_observed_status_test() {
  let assert Ok(root) = file.temporary_directory("tango-registry-sync-stale")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, registry_sync_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"external_ticket_ref\":\"TANGO-1\",\"requested_role\":\"todo\",\"requested_status\":{\"id\":\"todo\",\"name\":\"Todo\"},\"observed_status\":{\"id\":\"backlog\",\"name\":\"Backlog\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"registry-sync-run\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "registry remained stale",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, registry_sync_run())

  result.run.status
  |> should.equal(run.Failed)
  result.ticket.observed_external_status_id
  |> should.equal(None)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn registry_sync_mirrors_failed_as_blocked_test() {
  let assert Ok(root) = file.temporary_directory("tango-registry-sync-failed")
  let backend = memory_store.store()
  let failed_ticket = ticket.Ticket(..queued_ticket(), state: lifecycle.Failed)
  let assert Ok(state) = backend.save_ticket(memory_store.new(), failed_ticket)
  let assert Ok(state) = backend.save_session(state, registry_sync_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        request.prompt
        |> string.contains("requested_role: blocked")
        |> should.be_true()
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"external_ticket_ref\":\"TANGO-1\",\"requested_role\":\"blocked\",\"requested_status\":{\"id\":\"blocked\",\"name\":\"Blocked\"},\"observed_status\":{\"id\":\"blocked\",\"name\":\"Blocked\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"registry-sync-run\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "failed mirrored as blocked",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )
  let attempt =
    run.RunAttempt(..registry_sync_run(), resume_state: lifecycle.Failed)

  let assert Ok(result) = worker.execute(backend, state, root, deps, attempt)

  result.run.status
  |> should.equal(run.Succeeded)
  result.ticket.state
  |> should.equal(lifecycle.Failed)
  result.ticket.observed_external_status_id
  |> should.equal(Some("blocked"))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn worker_execute_fails_without_result_json_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-failed")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(_) {
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn worker_execute_does_not_partially_promote_malformed_artifacts_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-malformed")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"run-1\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"normalized_ticket\":\"ticket.json\",\"research_notes\":\"research.md\",\"plan\":\"plan.md\",\"diff_summary\":\"diff-summary.md\",\"implementation_notes\":\"implementation.md\",\"validation_report\":\"validation.json\",\"pull_request_set\":\"pull-requests.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn worker_execute_rejects_disallowed_workpad_file_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-disallowed")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/manifest.json",
            "{\"allowed_output_filenames\":[\"unexpected.txt\"]}",
          )
        let assert Ok(_) =
          file.atomic_replace(request.workpad_path <> "/unexpected.txt", "no")
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_watch_advances_cursor_and_requests_changes_test() {
  let assert Ok(root) = file.temporary_directory("tango-review-watch")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), awaiting_review_ticket())
  let assert Ok(state) = backend.save_session(state, review_watch_session())
  let assert Ok(state) =
    backend.save_review_cursor(state, initial_review_cursor())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let artifact =
          "{\"schema_version\":1,\"pull_requests\":[{\"pull_request_ref\":\"https://example.test/pr/1\",\"previous_count\":1,\"final_count\":3,\"new_comments\":[\"please update tests\"],\"actionable_feedback\":true}]}"
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/review-comments.json",
            artifact,
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"target\":\"pull_request\",\"summary\":\"posted follow-up\",\"requested_status_role\":null,\"requested_stable_status_id\":null,\"observed_final_stable_status_id\":null,\"final_comment_count\":3}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"watch-1\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"review_comments_report\":\"review-comments.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, review_watch_run())

  result.run.error
  |> should.equal(None)
  result.run.status
  |> should.equal(run.Succeeded)
  result.ticket.state
  |> should.equal(lifecycle.ChangesRequested)
  backend.get_review_cursor(
    result.state,
    "ticket-1",
    "https://example.test/pr/1",
  )
  |> should.equal(
    Ok(review_cursor.ReviewCommentCursor(
      ticket_id: "ticket-1",
      pull_request_ref: "https://example.test/pr/1",
      comment_count: 3,
      observed_at: result.ticket.updated_at,
    )),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_watch_unchanged_count_does_not_transition_or_authorize_merge_test() {
  let assert Ok(root) = file.temporary_directory("tango-review-watch-unchanged")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), awaiting_review_ticket())
  let assert Ok(state) = backend.save_session(state, review_watch_session())
  let assert Ok(state) =
    backend.save_review_cursor(state, initial_review_cursor())
  let deps =
    review_watch_dependencies(
      root,
      "{\"schema_version\":1,\"pull_requests\":[{\"pull_request_ref\":\"https://example.test/pr/1\",\"previous_count\":1,\"final_count\":1,\"new_comments\":[],\"actionable_feedback\":false}]}",
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, review_watch_run())

  result.ticket.state
  |> should.equal(lifecycle.AwaitingHumanReview)
  backend.list_reviews(result.state, "ticket-1")
  |> should.equal(Ok([]))
  let assert Ok(events) = backend.list_events(result.state, Some("ticket-1"))
  events
  |> list.any(fn(item) { item.type_ == "review.comments_detected" })
  |> should.be_false()

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_watch_self_post_advances_cursor_without_requesting_changes_test() {
  let assert Ok(root) = file.temporary_directory("tango-review-watch-self-post")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), awaiting_review_ticket())
  let assert Ok(state) = backend.save_session(state, review_watch_session())
  let assert Ok(state) =
    backend.save_review_cursor(state, initial_review_cursor())
  let deps =
    review_watch_dependencies(
      root,
      "{\"schema_version\":1,\"pull_requests\":[{\"pull_request_ref\":\"https://example.test/pr/1\",\"previous_count\":1,\"final_count\":2,\"new_comments\":[\"tango status update\"],\"actionable_feedback\":false}]}",
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, review_watch_run())

  result.ticket.state
  |> should.equal(lifecycle.AwaitingHumanReview)
  let assert Ok(cursor) =
    backend.get_review_cursor(
      result.state,
      "ticket-1",
      "https://example.test/pr/1",
    )
  cursor.comment_count
  |> should.equal(2)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn merge_retry_accepts_completed_already_merged_pr_and_marks_ticket_done_test() {
  let assert Ok(root) = file.temporary_directory("tango-merge-worker")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), merging_ticket())
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(state) = backend.save_review(state, merge_review())
  let assert Ok(state) =
    backend.save_artifact(state, reviewed_pull_request_artifact())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/merge.json",
            "{\"schema_version\":1,\"entries\":[{\"repo_binding_id\":\"repo-1\",\"pull_request_ref\":\"https://example.test/pr/1\",\"approved_head_commit_id\":\"abc123\",\"status\":\"completed\"}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"requested_role\":\"done\",\"requested_status\":{\"id\":\"done\",\"name\":\"Done\"},\"observed_status\":{\"id\":\"done\",\"name\":\"Done\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"merge-run\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"merge_report\":\"merge.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, merge_run())

  result.run.status
  |> should.equal(run.Succeeded)
  result.ticket.state
  |> should.equal(lifecycle.Done)
  result.ticket.observed_external_status_id
  |> should.equal(Some("done"))
  backend.get_merge(result.state, "ticket-1", "merge-run-merge")
  |> should.equal(
    Ok(merge.MergeRecord(
      id: "merge-run-merge",
      ticket_id: "ticket-1",
      review_decision_id: "review-merge",
      entries: [
        merge.MergeEntry(
          repo_binding_id: "repo-1",
          pull_request_ref: "https://example.test/pr/1",
          approved_head_commit_id: "abc123",
          status: merge.Completed,
        ),
      ],
      created_at: "2026-06-07T00:01:00Z",
      completed_at: "2026-06-07T00:10:00Z",
    )),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn partial_multi_repo_merge_persists_progress_and_requires_reapproval_test() {
  let assert Ok(root) = file.temporary_directory("tango-merge-partial")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), merging_ticket())
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(state) = backend.save_review(state, multi_repo_merge_review())
  let assert Ok(state) =
    backend.save_artifact(state, multi_repo_pull_request_artifact())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/merge.json",
            "{\"schema_version\":1,\"entries\":[{\"repo_binding_id\":\"repo-1\",\"pull_request_ref\":\"https://example.test/pr/1\",\"approved_head_commit_id\":\"abc123\",\"status\":\"completed\"},{\"repo_binding_id\":\"repo-2\",\"pull_request_ref\":\"https://example.test/pr/2\",\"approved_head_commit_id\":\"def456\",\"status\":\"pending\"}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"merge-run\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"merge_report\":\"merge.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, merge_run())

  result.ticket.state
  |> should.equal(lifecycle.Blocked)
  let assert Ok(record) =
    backend.get_merge(result.state, "ticket-1", "merge-run-merge")
  record.entries
  |> list.map(fn(entry) { entry.status })
  |> should.equal([merge.Completed, merge.Pending])
  let assert Some(block_id) = result.ticket.active_block_id
  let assert Ok(block_record) =
    backend.get_block(result.state, "ticket-1", block_id)
  block_record.resume_state
  |> should.equal(lifecycle.AwaitingHumanReview)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn execution_dirty_worktree_fails_before_artifact_promotion_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-dirty")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: single_repo_workspace(root),
      git: git.GitAdapter(
        validate: fn(_, _) { Error(git.DirtyWorktree("repo-1")) },
        changed_repositories: fn(_, _) { Ok([]) },
      ),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  result.ticket.state
  |> should.equal(lifecycle.Researching)
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn execution_rejects_reported_pull_request_head_that_differs_from_commit_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-wrong-pr-head")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: single_repo_workspace(root),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/pull-requests.json",
            "{\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"repo-1\",\"commit_id\":\"abc123\",\"pull_request_ref\":\"https://example.test/pr/1\",\"head_commit_id\":\"changed\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":2}]}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn execution_rejects_no_code_when_repository_changed_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-false-no-code")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: single_repo_workspace(root),
      git: git.GitAdapter(
        validate: fn(_, _) { Ok(Nil) },
        changed_repositories: fn(_, _) { Ok(["repo-1"]) },
      ),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/pull-requests.json",
            "{\"schema_version\":1,\"pull_requests\":[]}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  result.run.error
  |> should.equal(Some(
    "invalid artifact: modified repository omitted from pull-request set: repo-1",
  ))
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn execution_rejects_omitted_modified_repository_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-omitted-repo")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), two_repo_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let deps =
    worker.WorkerDependencies(
      workspace: two_repo_workspace(root),
      git: git.GitAdapter(
        validate: fn(_, _) { Ok(Nil) },
        changed_repositories: fn(_, _) { Ok(["repo-1", "repo-2"]) },
      ),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  result.run.error
  |> should.equal(Some(
    "invalid artifact: modified repository omitted from pull-request set: repo-2",
  ))
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn execution_rejects_forge_attestation_drift_before_promotion_test() {
  let assert Ok(root) = file.temporary_directory("tango-worker-forge-drift")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, main_session())
  let passthrough = attestation.passthrough()
  let deps =
    worker.WorkerDependencies(
      workspace: single_repo_workspace(root),
      git: git.passthrough(),
      attestation: attestation.Adapters(
        ticket_system: passthrough.ticket_system,
        forge: attestation.ForgeAdapter(
          read: fn(request) {
            Ok(attestation.PullRequestSnapshot(
              pull_request_ref: request.pull_request_ref,
              repository_location: request.repository.location,
              source_branch: "feature",
              target_branch: "main",
              head_commit_id: "changed",
              state: attestation.Open,
            ))
          },
          read_comments: fn(request) {
            Ok(attestation.PullRequestCommentsSnapshot(
              pull_request_ref: request.pull_request_ref,
              comments: [],
              final_comment_count: 0,
            ))
          },
        ),
      ),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          write_execution_success_artifacts(request.workpad_path)
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, execution_run())

  result.run.status
  |> should.equal(run.Failed)
  result.run.error
  |> should.equal(Some(
    "invalid artifact: external attestation failed: PullRequestHeadMismatch(\"abc123\", \"changed\")",
  ))
  backend.list_artifacts(result.state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn merge_completion_rejects_unmerged_forge_attestation_test() {
  let assert Ok(root) = file.temporary_directory("tango-merge-unattested")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), merging_ticket())
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(state) = backend.save_review(state, merge_review())
  let assert Ok(state) =
    backend.save_artifact(state, reviewed_pull_request_artifact())
  let passthrough = attestation.passthrough()
  let deps =
    worker.WorkerDependencies(
      workspace: single_repo_workspace(root),
      git: git.passthrough(),
      attestation: attestation.Adapters(
        ticket_system: passthrough.ticket_system,
        forge: attestation.ForgeAdapter(
          read: fn(request) {
            Ok(attestation.PullRequestSnapshot(
              pull_request_ref: request.pull_request_ref,
              repository_location: request.repository.location,
              source_branch: "feature",
              target_branch: "main",
              head_commit_id: request.expected_head_commit_id,
              state: attestation.Open,
            ))
          },
          read_comments: fn(request) {
            Ok(attestation.PullRequestCommentsSnapshot(
              pull_request_ref: request.pull_request_ref,
              comments: [],
              final_comment_count: 0,
            ))
          },
        ),
      ),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/merge.json",
            "{\"schema_version\":1,\"entries\":[{\"repo_binding_id\":\"repo-1\",\"pull_request_ref\":\"https://example.test/pr/1\",\"approved_head_commit_id\":\"abc123\",\"status\":\"completed\"}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"requested_role\":\"done\",\"requested_status\":{\"id\":\"done\",\"name\":\"Done\"},\"observed_status\":{\"id\":\"done\",\"name\":\"Done\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"merge-run\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"merge_report\":\"merge.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, merge_run())

  result.run.status
  |> should.equal(run.Failed)
  result.ticket.state
  |> should.equal(lifecycle.Merging)
  backend.get_merge(result.state, "ticket-1", "merge-run-merge")
  |> should.equal(Error(store.NotFound("merge-run-merge")))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn merge_wrong_workspace_head_blocks_before_agent_launch_test() {
  let assert Ok(root) = file.temporary_directory("tango-merge-wrong-head")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), merging_ticket())
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(state) = backend.save_review(state, merge_review())
  let assert Ok(state) =
    backend.save_artifact(state, reviewed_pull_request_artifact())
  let deps =
    worker.WorkerDependencies(
      workspace: single_repo_workspace(root),
      git: git.GitAdapter(
        validate: fn(_, _) {
          Error(git.WrongHead("repo-1", "abc123", "changed"))
        },
        changed_repositories: fn(_, _) { Ok([]) },
      ),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(_) {
        panic as "merge agent must not launch with a changed workspace head"
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, merge_run())

  result.run.status
  |> should.equal(run.Failed)
  result.ticket.state
  |> should.equal(lifecycle.Blocked)
  result.output
  |> string.contains("workspace repository head changed")
  |> should.be_true()

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn merge_run_blocks_when_reviewed_set_drifted_test() {
  let assert Ok(root) = file.temporary_directory("tango-merge-worker-drift")
  let backend = memory_store.store()
  let drifted_review =
    review.ReviewDecision(
      ..merge_review(),
      reviewed_commit_set: [
        review.ReviewedCommit(repo_binding_id: "repo-1", commit_id: "old123"),
      ],
      reviewed_pull_request_set: [
        review.ReviewedPullRequest(
          pull_request_ref: "https://example.test/pr/1",
          reviewed_head_commit_id: "old123",
        ),
      ],
    )
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), merging_ticket())
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(state) = backend.save_review(state, drifted_review)
  let assert Ok(state) =
    backend.save_artifact(state, reviewed_pull_request_artifact())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(_) {
        Error(adapter.LaunchFailed(
          "merge agent must not launch after reviewed-set drift",
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, merge_run())

  result.run.status
  |> should.equal(run.Failed)
  result.ticket.state
  |> should.equal(lifecycle.Blocked)
  result.ticket.active_block_id
  |> should.equal(Some("merge-run-approval-block"))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn merge_blocked_result_resumes_at_human_review_test() {
  let assert Ok(root) = file.temporary_directory("tango-merge-worker-blocked")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), merging_ticket())
  let assert Ok(state) = backend.save_session(state, merge_session())
  let assert Ok(state) = backend.save_review(state, merge_review())
  let assert Ok(state) =
    backend.save_artifact(state, reviewed_pull_request_artifact())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/merge.json",
            "{\"schema_version\":1,\"entries\":[]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"merge-run\",\"status\":\"blocked\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"merge_report\":\"merge.json\",\"external_updates\":\"external-updates.json\"},\"block\":{\"reason\":\"merge needs human recovery\",\"resolution_instructions\":\"inspect the pull request\"}}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "{}",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, merge_run())

  result.run.status
  |> should.equal(run.Succeeded)
  result.ticket.state
  |> should.equal(lifecycle.Blocked)
  let assert Some(block_id) = result.ticket.active_block_id
  let assert Ok(record) = backend.get_block(result.state, "ticket-1", block_id)
  record.resume_state
  |> should.equal(lifecycle.AwaitingHumanReview)

  file.remove_tree(root)
  |> should.be_ok()
}

fn single_repo_workspace(root: String) -> workspace.WorkspaceAdapter {
  workspace.WorkspaceAdapter(ensure: fn(_, item) {
    Ok(
      workspace.Workspace(root_path: root <> "/workspace-" <> item.id, repos: [
        workspace.WorkspaceRepo(
          binding_id: "repo-1",
          source: "https://example.test/tango.git",
          path: root <> "/workspace-" <> item.id <> "/tango",
        ),
      ]),
    )
  })
}

fn two_repo_workspace(root: String) -> workspace.WorkspaceAdapter {
  workspace.WorkspaceAdapter(ensure: fn(_, item) {
    Ok(
      workspace.Workspace(root_path: root <> "/workspace-" <> item.id, repos: [
        workspace.WorkspaceRepo(
          binding_id: "repo-1",
          source: "https://example.test/tango.git",
          path: root <> "/workspace-" <> item.id <> "/tango",
        ),
        workspace.WorkspaceRepo(
          binding_id: "repo-2",
          source: "https://example.test/docs.git",
          path: root <> "/workspace-" <> item.id <> "/docs",
        ),
      ]),
    )
  })
}

fn review_watch_dependencies(
  root: String,
  artifact_source: String,
) -> worker.WorkerDependencies {
  worker.WorkerDependencies(
    workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
      Ok(
        workspace.Workspace(
          root_path: root <> "/workspace-" <> item.id,
          repos: [],
        ),
      )
    }),
    git: git.passthrough(),
    attestation: attestation.passthrough(),
    agent: adapter.AgentAdapter(run: fn(request) {
      let assert Ok(_) =
        file.atomic_replace(
          request.workpad_path <> "/review-comments.json",
          artifact_source,
        )
      let assert Ok(_) =
        file.atomic_replace(
          request.workpad_path <> "/external-updates.json",
          "{\"schema_version\":1,\"updates\":[]}",
        )
      let assert Ok(_) =
        file.atomic_replace(
          request.workpad_path <> "/result.json",
          "{\"schema_version\":1,\"run_id\":\"watch-1\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"review_comments_report\":\"review-comments.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
        )
      Ok(adapter.AgentResponse(
        exit_code: 0,
        output: "{}",
        runtime_session_id: None,
        usage: None,
      ))
    }),
  )
}

pub fn registry_sync_run_updates_observed_external_status_test() {
  let assert Ok(root) = file.temporary_directory("tango-registry-sync")
  let backend = memory_store.store()
  let assert Ok(state) =
    backend.save_ticket(memory_store.new(), queued_ticket())
  let assert Ok(state) = backend.save_session(state, registry_sync_session())
  let deps =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, item) {
        Ok(
          workspace.Workspace(
            root_path: root <> "/workspace-" <> item.id,
            repos: [],
          ),
        )
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(request) {
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"external_ticket_ref\":\"TANGO-1\",\"requested_role\":\"todo\",\"requested_status\":{\"id\":\"todo\",\"name\":\"Todo\"},\"observed_status\":{\"id\":\"todo\",\"name\":\"Todo\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\"registry-sync-run\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "registry synchronized",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let assert Ok(result) =
    worker.execute(backend, state, root, deps, registry_sync_run())

  result.run.status
  |> should.equal(run.Succeeded)
  result.ticket.observed_external_status_id
  |> should.equal(Some("todo"))
  let assert Ok(artifacts) = backend.list_artifacts(result.state, "ticket-1")
  artifacts
  |> list.any(fn(record) {
    record.kind == artifact.ExternalUpdates
    && record.run_id == "registry-sync-run"
    && string.contains(record.content, "\"requested_role\":\"todo\"")
  })
  |> should.be_true()

  file.remove_tree(root)
  |> should.be_ok()
}

fn write_execution_success_artifacts(
  workpad_path: String,
) -> Result(Nil, String) {
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/ticket.json",
    "{\"schema_version\":1,\"external_ref\":\"TANGO-1\",\"title\":\"Implement worker path\",\"description_revision\":\"rev-1\",\"description\":\"Build worker promotion\",\"acceptance_criteria\":[\"tests pass\"],\"labels\":[\"runtime\"],\"blockers\":[],\"tango_todo\":{\"section_present\":true,\"items\":[{\"id\":\"TG-TODO-001\",\"state\":\"done\",\"text\":\"Implement worker promotion\"}]},\"observed_external_status_id\":\"todo\"}",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/research.md",
    "# Research\n\nChecked the workspace.\n",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/plan.md",
    "# Plan\n\nImplement promotion.\n",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/diff-summary.md",
    "# Diff Summary\n\nUpdated the worker promotion path.\n",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/implementation.md",
    "# Implementation\n\nApplied the worker changes.\n",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/validation.json",
    "{\"schema_version\":1,\"checks\":[{\"name\":\"gleam test\",\"status\":\"passed\",\"summary\":\"all tests green\"}]}",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/pull-requests.json",
    "{\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"repo-1\",\"commit_id\":\"abc123\",\"pull_request_ref\":\"https://example.test/pr/1\",\"head_commit_id\":\"abc123\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":2}]}",
  ))
  use _ <- result.try(file.atomic_replace(
    workpad_path <> "/external-updates.json",
    "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"requested_role\":\"human_review\",\"requested_status\":{\"id\":\"review\",\"name\":\"Review\"},\"observed_status\":{\"id\":\"review\",\"name\":\"Review\"}},{\"kind\":\"todo_update\",\"action\":\"updated\",\"description_revision_before\":\"rev-0\",\"description_revision_after\":\"rev-1\",\"items\":[{\"id\":\"TG-TODO-001\",\"state\":\"done\",\"text\":\"Implement worker promotion\"}],\"reported_at\":\"2026-06-07T00:09:00Z\"},{\"kind\":\"comment\",\"purpose\":\"review_handoff\",\"posted\":true,\"body\":\"Ready for review.\",\"reported_at\":\"2026-06-07T00:09:30Z\"}]}",
  ))
  file.atomic_replace(
    workpad_path <> "/result.json",
    "{\"schema_version\":1,\"run_id\":\"run-1\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"normalized_ticket\":\"ticket.json\",\"research_notes\":\"research.md\",\"plan\":\"plan.md\",\"diff_summary\":\"diff-summary.md\",\"implementation_notes\":\"implementation.md\",\"validation_report\":\"validation.json\",\"pull_request_set\":\"pull-requests.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
  )
}
