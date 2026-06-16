import fixtures
import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import tango/app/command
import tango/app/onboarding
import tango/capability/manager
import tango/cli
import tango/config
import tango/domain/artifact
import tango/domain/block
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/repo
import tango/domain/review
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/file
import tango/store/json_store

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

pub fn parse_supported_commands_test() {
  cli.parse(["init"])
  |> should.equal(Ok(cli.Init))

  cli.parse(["run"])
  |> should.equal(Ok(cli.Run))

  cli.parse(["status"])
  |> should.equal(Ok(cli.Status))

  cli.parse(["dashboard"])
  |> should.equal(Ok(cli.Dashboard))

  cli.parse(["capability", "list"])
  |> should.equal(Ok(cli.CapabilityList))

  cli.parse(["capability", "install", "forge", "github"])
  |> should.equal(
    Ok(cli.CapabilityInstall(
      manager.Forge,
      "github",
      manager.VerifyOrInstallCli,
    )),
  )

  cli.parse([
    "capability",
    "install",
    "ticket-system",
    "forgejo",
    "--skill-only",
  ])
  |> should.equal(
    Ok(cli.CapabilityInstall(manager.TicketSystem, "forgejo", manager.SkillOnly)),
  )

  cli.parse([
    "capability",
    "profile",
    "create",
    "default",
    "--ticket-system",
    "forgejo",
    "--forge",
    "forgejo",
  ])
  |> should.equal(
    Ok(cli.CapabilityProfileCreate("default", "forgejo", "forgejo")),
  )

  cli.parse(["ticket-system", "status-map", "github", "show"])
  |> should.equal(Ok(cli.TicketSystemStatusMapShow("github")))

  cli.parse([
    "ticket-system",
    "status-map",
    "github",
    "discover",
    "--repo",
    "example/tango",
  ])
  |> should.equal(
    Ok(cli.TicketSystemStatusMapDiscover("github", Some("example/tango"))),
  )

  cli.parse([
    "ticket-system",
    "status-map",
    "github",
    "validate",
    "--repo",
    "example/tango",
  ])
  |> should.equal(
    Ok(cli.TicketSystemStatusMapValidate("github", Some("example/tango"))),
  )

  cli.parse([
    "ticket-system",
    "status-map",
    "github",
    "set",
    "--role",
    "done",
    "--status-id",
    "complete",
  ])
  |> should.equal(
    Ok(cli.TicketSystemStatusMapSet("github", "done", "complete")),
  )

  cli.parse(["ticket", "list"])
  |> should.equal(Ok(cli.TicketList))

  cli.parse(["ticket", "show", "ticket-1"])
  |> should.equal(Ok(cli.TicketShow("ticket-1")))

  cli.parse(["review", "list"])
  |> should.equal(Ok(cli.ReviewList))

  cli.parse(["review", "show", "ticket-1"])
  |> should.equal(Ok(cli.ReviewShow("ticket-1")))

  cli.parse(["review", "merge", "ticket-1"])
  |> should.equal(Ok(cli.ReviewMerge("ticket-1")))

  cli.parse(["ticket", "queue", "ticket-1"])
  |> should.equal(Ok(cli.TicketQueue("ticket-1")))

  cli.parse(["ticket", "unblock", "ticket-1"])
  |> should.equal(Ok(cli.TicketUnblock("ticket-1")))
}

pub fn init_creates_state_directories_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-init")

  let assert Ok(message) =
    cli.run_in(cli.Init, root, "local:test", "2026-06-07T00:00:00Z", fn(prefix) {
      prefix <> "-1"
    })

  message
  |> should.equal("initialized tango state at " <> root)
  file.list_dir(root)
  |> should.equal(
    Ok(["capabilities", "config.toml", "tickets", "workpads", "workspaces"]),
  )
  config.load(root <> "/config.toml")
  |> should.equal(Ok(Some(config.defaults(root, Some("local:test")))))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn ticket_system_status_map_show_and_set_persists_config_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-status-map")
  let operator_config =
    config.Config(
      ..config.defaults(root, Some("local:test")),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: registry_statuses(),
            status_map_validated: True,
          ),
        ),
      ]),
    )
  let assert Ok(_) = config.save(root <> "/config.toml", operator_config)

  let assert Ok(show_output) =
    cli.run_in(
      cli.TicketSystemStatusMapShow("github"),
      root,
      "local:test",
      "2026-06-15T12:00:00Z",
      fn(prefix) { prefix <> "-1" },
    )

  show_output
  |> string.contains("provider_kind: labels")
  |> should.be_true()
  show_output
  |> string.contains("validated: true")
  |> should.be_true()
  show_output
  |> string.contains("done = status-done")
  |> should.be_true()

  cli.run_in(
    cli.TicketSystemStatusMapSet("github", "done", "closed"),
    root,
    "local:test",
    "2026-06-15T12:01:00Z",
    fn(prefix) { prefix <> "-2" },
  )
  |> should.equal(Ok(
    "updated ticket-system status map github done=closed (validation required)",
  ))

  let assert Ok(Some(updated)) = config.load(root <> "/config.toml")
  let assert Ok(registry) = dict.get(updated.registries, "github")
  dict.get(registry.statuses, "done")
  |> should.equal(Ok("closed"))
  registry.status_map_validated
  |> should.equal(False)

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn parse_ticket_create_command_test() {
  cli.parse([
    "ticket",
    "create",
    "--repo",
    "example/tango",
    "--repo",
    "https://github.com/example/other.git",
    "--ticket-ref",
    "TANGO-42",
    "--ticket-system",
    "github",
    "--forge",
    "github",
    "--capability-profile",
    "default",
    "--label",
    "Runtime",
    "--label",
    "urgent",
    "--priority",
    "2",
    "--lifecycle-policy",
    "strict",
    "--queue",
  ])
  |> should.equal(Ok(cli.TicketCreate(onboarding_input(), True)))
}

pub fn ticket_create_persists_normalized_onboarded_ticket_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-create")
  let operator_config =
    config.Config(
      ..config.defaults(root, Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["github-registry", "forge"],
            execution_tools: ["gh", "forge"],
            merge_tools: ["forge"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "forge", skill: "forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-registry",
            statuses: registry_statuses(),
            status_map_validated: True,
          ),
        ),
      ]),
    )
  let assert Ok(_) = config.save(root <> "/config.toml", operator_config)

  let assert Ok(message) =
    cli.run_in(
      cli.TicketCreate(onboarding_input(), False),
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-created" },
    )

  message
  |> should.equal("created TANGO-42 (ticket-created)")
  cli.run_in(
    cli.TicketCreate(onboarding_input(), False),
    root,
    "local:test",
    "2026-06-12T12:01:00Z",
    fn(prefix) { prefix <> "-duplicate" },
  )
  |> should.equal(
    Error(cli.Onboarding(onboarding.DuplicateExternalReference("TANGO-42"))),
  )
  let reopened = json_store.new(root)
  let assert Ok(created) = json_store.get_ticket(reopened, "ticket-created")
  created.identifier
  |> should.equal("TANGO-42")
  created.labels
  |> should.equal(["runtime", "urgent"])
  created.priority
  |> should.equal(Some(2))
  created.lifecycle_policy
  |> should.equal(Some("strict"))
  created.state
  |> should.equal(lifecycle.Onboarded)
  created.forge_binding
  |> should.equal(Some(fixtures.forge_binding()))
  created.repo_bindings
  |> should.equal([
    repo.RepoBinding(
      id: "repo-tango",
      name: "tango",
      kind: repo.GitRemote,
      location: "example/tango",
      default_branch: None,
      base_ref: None,
      target_branch: None,
      work_branch: None,
      checkout_policy: repo.Clone,
    ),
    repo.RepoBinding(
      id: "repo-other",
      name: "other",
      kind: repo.GitRemote,
      location: "https://github.com/example/other.git",
      default_branch: None,
      base_ref: None,
      target_branch: None,
      work_branch: None,
      checkout_policy: repo.Clone,
    ),
  ])
  ticket.onboarding_errors(created)
  |> should.equal([])
  json_store.list_events(reopened, Some("ticket-created"))
  |> should.equal(
    Ok([
      event.TangoEvent(
        schema_version: 1,
        id: "event-created",
        ticket_id: Some("ticket-created"),
        type_: "ticket.created",
        occurred_at: "2026-06-12T12:00:00Z",
        actor: "human:local:test",
        payload: dict.from_list([
          #("external_ref", "TANGO-42"),
          #("registry", "github"),
          #("forge", "github"),
          #("capability_profile", "default"),
          #("labels", "runtime,urgent"),
          #("priority", "2"),
          #("lifecycle_policy", "strict"),
        ]),
      ),
    ]),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn ticket_create_queue_queues_created_ticket_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-create-queue")
  let operator_config =
    config.Config(
      ..config.defaults(root, Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["github-registry", "forge"],
            execution_tools: ["gh", "forge"],
            merge_tools: ["forge"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "forge", skill: "forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-registry",
            statuses: registry_statuses(),
            status_map_validated: True,
          ),
        ),
      ]),
    )
  let assert Ok(_) = config.save(root <> "/config.toml", operator_config)

  cli.run_in(
    cli.TicketCreate(onboarding_input(), True),
    root,
    "local:test",
    "2026-06-15T12:00:00Z",
    fn(prefix) { prefix <> "-queued" },
  )
  |> should.equal(Ok("created and queued TANGO-42 (ticket-queued)"))

  let reopened = json_store.new(root)
  let assert Ok(created) = json_store.get_ticket(reopened, "ticket-queued")
  created.state
  |> should.equal(lifecycle.Queued)

  file.remove_tree(root)
  |> should.be_ok()
}

fn onboarding_input() {
  onboarding.CreateTicketInput(
    repositories: ["example/tango", "https://github.com/example/other.git"],
    external_ref: "TANGO-42",
    registry_name: "github",
    forge_name: "github",
    capability_profile_name: "default",
    labels: ["Runtime", "urgent"],
    priority: Some(2),
    lifecycle_policy: Some("strict"),
  )
}

fn registry_statuses() {
  dict.from_list([
    #("backlog", "status-backlog"),
    #("todo", "status-todo"),
    #("in_progress", "status-active"),
    #("human_review", "status-review"),
    #("merging", "status-review"),
    #("blocked", "status-blocked"),
    #("done", "status-done"),
    #("wont_do", "status-canceled"),
  ])
}

fn pull_request_set_artifact() -> artifact.ArtifactRecord {
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

fn active_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "run-1",
    ticket_id: "ticket-1",
    session_id: "session-1",
    kind: run.Execution,
    current_stage: Some(lifecycle.Implement),
    stages: [lifecycle.Research, lifecycle.Plan, lifecycle.Implement],
    attempt: 1,
    workspace_path: "/tmp/tango/workspaces/ticket-1",
    agent_runtime: "codex",
    capability_profile_digest: Some("digest"),
    effective_capabilities: ["forge"],
    resume_state: lifecycle.Queued,
    started_at: "2026-06-07T00:05:00Z",
    ended_at: None,
    status: run.Streaming,
    error: None,
  )
}

pub fn ticket_queue_updates_ticket_and_appends_event_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-queue")
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, onboarded_ticket())

  let assert Ok(message) =
    cli.run_in(
      cli.TicketQueue("ticket-1"),
      root,
      "local:test",
      "2026-06-07T00:01:00Z",
      fn(prefix) { prefix <> "-queue" },
    )

  message
  |> should.equal("queued TANGO-1 (ticket-1)")
  let reopened = json_store.new(root)
  json_store.get_ticket(reopened, "ticket-1")
  |> should.equal(Ok(
    ticket.Ticket(
      ..onboarded_ticket(),
      state: lifecycle.Queued,
      updated_at: "2026-06-07T00:01:00Z",
    ),
  ))
  json_store.list_events(reopened, Some("ticket-1"))
  |> should.equal(
    Ok([
      event.TangoEvent(
        schema_version: 1,
        id: "event-queue",
        ticket_id: Some("ticket-1"),
        type_: "ticket.queued",
        occurred_at: "2026-06-07T00:01:00Z",
        actor: "human:local:test",
        payload: dict.from_list([#("state", "queued")]),
      ),
    ]),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn ticket_unblock_resolves_active_block_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-unblock")
  let backend = json_store.store()
  let state = json_store.new(root)
  let queued = ticket.Ticket(..onboarded_ticket(), state: lifecycle.Queued)
  let assert Ok(state) = backend.save_ticket(state, queued)
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

  let assert Ok(_) = backend.list_events(blocked.state, Some("ticket-1"))

  let assert Ok(message) =
    cli.run_in(
      cli.TicketUnblock("ticket-1"),
      root,
      "local:test",
      "2026-06-07T00:02:00Z",
      fn(prefix) { prefix <> "-unblock" },
    )

  message
  |> should.equal("unblocked TANGO-1 -> ticket-1 now queued")
  let reopened = json_store.new(root)
  let assert Ok(updated) = json_store.get_ticket(reopened, "ticket-1")
  updated.state
  |> should.equal(lifecycle.Queued)
  updated.active_block_id
  |> should.equal(None)
  let assert Ok(resolved) =
    json_store.get_block(reopened, "ticket-1", "block-1")
  resolved.resolved_by
  |> should.equal(Some("local:test"))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_merge_approves_ticket_and_creates_merge_session_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-merge")
  let backend = json_store.store()
  let review_ready =
    ticket.Ticket(..onboarded_ticket(), state: lifecycle.AwaitingHumanReview)
  let state = json_store.new(root)
  let assert Ok(_state) = backend.save_ticket(state, review_ready)
  let assert Ok(_state) =
    backend.save_artifact(state, pull_request_set_artifact())

  let assert Ok(message) =
    cli.run_in_with_confirmation(
      cli.ReviewMerge("ticket-1"),
      root,
      "local:test",
      "2026-06-07T00:03:00Z",
      fn(prefix) {
        case prefix {
          "review" -> "review-merge"
          "session" -> "merge-session"
          "review-event" -> "event-review"
          "merge-event" -> "event-merge"
          other -> other <> "-1"
        }
      },
      fn(_) { True },
    )

  message
  |> should.equal("merge approved ticket-1 -> merging")
  let reopened = json_store.new(root)
  let assert Ok(updated) = json_store.get_ticket(reopened, "ticket-1")
  updated.state
  |> should.equal(lifecycle.Merging)
  updated.aux_session_ids
  |> should.equal(["merge-session"])
  json_store.get_review(reopened, "ticket-1", "review-merge")
  |> should.equal(
    Ok(review.ReviewDecision(
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
    )),
  )
  json_store.get_session(reopened, "ticket-1", "merge-session")
  |> should.equal(
    Ok(session.AgentSession(
      id: "merge-session",
      ticket_id: "ticket-1",
      role: session.Aux,
      kind: session.Merge,
      context_session_ids: [],
      runtime_session_id: None,
      run_attempt_ids: [],
      created_at: "2026-06-07T00:03:00Z",
      updated_at: "2026-06-07T00:03:00Z",
    )),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_merge_requires_confirmation_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-merge-confirm")
  let backend = json_store.store()
  let review_ready =
    ticket.Ticket(..onboarded_ticket(), state: lifecycle.AwaitingHumanReview)
  let state = json_store.new(root)
  let assert Ok(_state) = backend.save_ticket(state, review_ready)

  cli.run_in_with_confirmation(
    cli.ReviewMerge("ticket-1"),
    root,
    "local:test",
    "2026-06-07T00:03:00Z",
    fn(prefix) { prefix <> "-1" },
    fn(_) { False },
  )
  |> should.equal(Error(cli.MergeConfirmationDeclined))
  json_store.list_reviews(state, "ticket-1")
  |> should.equal(Ok([]))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_merge_uses_deterministic_latest_artifact_tie_breaker_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-merge-latest")
  let backend = json_store.store()
  let review_ready =
    ticket.Ticket(..onboarded_ticket(), state: lifecycle.AwaitingHumanReview)
  let old =
    artifact.ArtifactRecord(
      ..pull_request_set_artifact(),
      id: "artifact-a",
      run_id: "run-a",
      content: "{\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"repo-1\",\"commit_id\":\"old123\",\"pull_request_ref\":\"https://example.test/pr/1\",\"head_commit_id\":\"old123\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":2}]}",
    )
  let latest =
    artifact.ArtifactRecord(
      ..pull_request_set_artifact(),
      id: "artifact-z",
      run_id: "run-z",
      content: "{\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"repo-1\",\"commit_id\":\"new123\",\"pull_request_ref\":\"https://example.test/pr/1\",\"head_commit_id\":\"new123\",\"source_branch\":\"feature\",\"target_branch\":\"main\",\"final_comment_count\":2}]}",
    )
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, review_ready)
  let assert Ok(_) = backend.save_artifact(state, old)
  let assert Ok(_) = backend.save_artifact(state, latest)
  let assert Ok(_) =
    cli.run_in_with_confirmation(
      cli.ReviewMerge("ticket-1"),
      root,
      "local:test",
      "2026-06-07T00:03:00Z",
      fn(prefix) { prefix <> "-latest" },
      fn(_) { True },
    )

  let assert Ok(decision) =
    backend.get_review(state, "ticket-1", "review-latest")
  decision.reviewed_commit_set
  |> should.equal([
    review.ReviewedCommit(repo_binding_id: "repo-1", commit_id: "new123"),
  ])

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn status_reports_queue_review_blocked_and_active_runs_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-status")
  let backend = json_store.store()
  let state = json_store.new(root)
  let queued = ticket.Ticket(..onboarded_ticket(), state: lifecycle.Queued)
  let review_ready =
    ticket.Ticket(
      ..onboarded_ticket(),
      id: "ticket-2",
      identifier: "TANGO-2",
      state: lifecycle.AwaitingHumanReview,
    )
  let blocked_ticket =
    ticket.Ticket(
      ..onboarded_ticket(),
      id: "ticket-3",
      identifier: "TANGO-3",
      state: lifecycle.Blocked,
      active_block_id: Some("block-3"),
    )
  let assert Ok(state) = backend.save_ticket(state, queued)
  let assert Ok(state) = backend.save_ticket(state, review_ready)
  let assert Ok(state) = backend.save_ticket(state, blocked_ticket)
  let assert Ok(state) = backend.save_run(state, active_run())
  let assert Ok(_state) =
    backend.save_block(
      state,
      block.BlockRecord(
        id: "block-3",
        ticket_id: "ticket-3",
        reason: "waiting on ops",
        resolution_instructions: None,
        blocked_from: lifecycle.Implementing,
        resume_state: lifecycle.AwaitingHumanReview,
        created_by: "orchestrator",
        created_at: "2026-06-07T00:06:00Z",
        resolved_by: None,
        resolved_at: None,
      ),
    )

  let assert Ok(output) =
    cli.run_in(
      cli.Status,
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-status" },
    )

  output
  |> should.equal(
    "operator: local:test\n"
    <> "generated_at: 2026-06-12T12:00:00Z\n"
    <> "tickets_total: 3\n"
    <> "queued: 1\n"
    <> "awaiting_human_review: 1\n"
    <> "blocked: 1\n"
    <> "active_runs: 1\n\n"
    <> "queued tickets:\n"
    <> "  TANGO-1 | queued | priority=1 | external_ref=TANGO-1\n\n"
    <> "awaiting human review:\n"
    <> "  TANGO-2 | awaiting_human_review | priority=1 | external_ref=TANGO-1\n\n"
    <> "blocked tickets:\n"
    <> "  TANGO-3 | block-3:waiting on ops->awaiting_human_review\n\n"
    <> "active runs:\n"
    <> "  TANGO-1 | run-1 | execution | streaming | attempt=1 | session=session-1 | started_at=2026-06-07T00:05:00Z",
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn dashboard_lists_ticket_rows_with_operator_state_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-dashboard")
  let backend = json_store.store()
  let state = json_store.new(root)
  let queued = ticket.Ticket(..onboarded_ticket(), state: lifecycle.Queued)
  let review_ready =
    ticket.Ticket(
      ..onboarded_ticket(),
      id: "ticket-2",
      identifier: "TANGO-2",
      state: lifecycle.AwaitingHumanReview,
    )
  let assert Ok(state) = backend.save_ticket(state, queued)
  let assert Ok(state) = backend.save_ticket(state, review_ready)
  let assert Ok(state) = backend.save_run(state, active_run())
  let assert Ok(_state) =
    backend.save_review(
      state,
      review.ReviewDecision(
        id: "review-1",
        ticket_id: "ticket-2",
        reviewer_id: "local:test",
        decision: review.Defer,
        comments: "",
        reviewed_commit_set: [],
        reviewed_pull_request_set: [],
        authorization_mechanism: "manual",
        created_at: "2026-06-07T00:07:00Z",
      ),
    )

  let assert Ok(output) =
    cli.run_in(
      cli.Dashboard,
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-dashboard" },
    )

  output
  |> should.equal(
    "dashboard: terminal\n"
    <> "operator: local:test\n"
    <> "generated_at: 2026-06-12T12:00:00Z\n"
    <> "tickets: 2\n"
    <> "active_runs: 1\n\n"
    <> "tickets:\n"
    <> "  TANGO-1 | queued | priority=1 | active_run=execution:streaming | latest_review=- | block=-\n"
    <> "  TANGO-2 | awaiting_human_review | priority=1 | active_run=- | latest_review=defer@2026-06-07T00:07:00Z | block=-",
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn ticket_list_show_and_review_surfaces_render_history_test() {
  let assert Ok(root) = file.temporary_directory("tango-cli-read-surfaces")
  let backend = json_store.store()
  let state = json_store.new(root)
  let listed = ticket.Ticket(..onboarded_ticket(), state: lifecycle.Queued)
  let assert Ok(state) = backend.save_ticket(state, listed)
  let assert Ok(state) =
    backend.save_session(
      state,
      session.AgentSession(
        id: "session-1",
        ticket_id: "ticket-1",
        role: session.Main,
        kind: session.Implementation,
        context_session_ids: [],
        runtime_session_id: Some("runtime-1"),
        run_attempt_ids: ["run-1"],
        created_at: "2026-06-07T00:01:00Z",
        updated_at: "2026-06-07T00:01:00Z",
      ),
    )
  let assert Ok(state) = backend.save_run(state, active_run())
  let assert Ok(state) =
    backend.save_review(
      state,
      review.ReviewDecision(
        id: "review-1",
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
        created_at: "2026-06-07T00:08:00Z",
      ),
    )
  let assert Ok(_state) =
    backend.save_merge(
      state,
      merge.MergeRecord(
        id: "merge-1",
        ticket_id: "ticket-1",
        review_decision_id: "review-1",
        entries: [],
        created_at: "2026-06-07T00:09:00Z",
        completed_at: "2026-06-07T00:10:00Z",
      ),
    )

  let assert Ok(ticket_list) =
    cli.run_in(
      cli.TicketList,
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-list" },
    )
  ticket_list
  |> should.equal(
    "tickets:\n" <> "  TANGO-1 | queued | priority=1 | external_ref=TANGO-1",
  )

  let assert Ok(ticket_show) =
    cli.run_in(
      cli.TicketShow("ticket-1"),
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-show" },
    )
  ticket_show
  |> should.equal(
    "ticket: TANGO-1 (ticket-1)\n"
    <> "state: queued\n"
    <> "priority: 1\n"
    <> "external_ref: TANGO-1\n"
    <> "forge: github\n"
    <> "repos: 1\n"
    <> "main_session_id: -\n"
    <> "aux_sessions: 0\n"
    <> "active_block_id: -\n"
    <> "observed_external_status_id: -\n"
    <> "created_at: 2026-06-07T00:00:00Z\n"
    <> "updated_at: 2026-06-07T00:00:00Z\n\n"
    <> "sessions:\n"
    <> "  session-1 | main/implementation | runs=1 | runtime_session_id=runtime-1\n\n"
    <> "runs:\n"
    <> "  run-1 | execution | streaming | attempt=1 | session=session-1 | started_at=2026-06-07T00:05:00Z\n\n"
    <> "blocks:\n"
    <> "  (none)\n\n"
    <> "reviews:\n"
    <> "  review-1 | approve | reviewer=local:test | commits=1 | prs=1 | at=2026-06-07T00:08:00Z\n\n"
    <> "merges:\n"
    <> "  merge-1 | review=review-1 | entries=0 | completed_at=2026-06-07T00:10:00Z",
  )

  let assert Ok(review_list) =
    cli.run_in(
      cli.ReviewList,
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-reviews" },
    )
  review_list
  |> should.equal(
    "reviews:\n"
    <> "  TANGO-1 | approve | reviewer=local:test | at=2026-06-07T00:08:00Z",
  )

  let assert Ok(review_show) =
    cli.run_in(
      cli.ReviewShow("ticket-1"),
      root,
      "local:test",
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-review-show" },
    )
  review_show
  |> should.equal(
    "review history: TANGO-1 (ticket-1)\n"
    <> "state: queued\n\n"
    <> "reviews:\n"
    <> "  review-1 | approve | reviewer=local:test | commits=1 | prs=1 | at=2026-06-07T00:08:00Z",
  )

  file.remove_tree(root)
  |> should.be_ok()
}
