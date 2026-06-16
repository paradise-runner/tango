import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tango/domain/artifact
import tango/domain/lifecycle
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/review
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/workspace/workspace

pub fn build(
  item: ticket.Ticket,
  agent_session: session.AgentSession,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
  workpad_path: String,
  prior_artifacts: List(artifact.ArtifactRecord),
  reviews: List(review.ReviewDecision),
) -> String {
  string.join(
    [
      "# Tango Stage",
      run_kind_text(attempt.kind),
      "session_id: " <> agent_session.id,
      "session_role: " <> session_role_text(agent_session.role),
      "context_session_ids: "
        <> string.join(agent_session.context_session_ids, with: ", "),
      "effective_capabilities: "
        <> string.join(attempt.effective_capabilities, with: ", "),
      "",
      "# Ticket",
      "ticket_id: " <> item.id,
      "identifier: " <> item.identifier,
      "stored_title: " <> option_value(item.title, ""),
      "external_ref: " <> option_value(item.external_ref, ""),
      "lifecycle_policy: " <> option_value(item.lifecycle_policy, "default"),
      "labels: " <> string.join(item.labels, with: ", "),
      "blockers_clear: " <> bool_text(item.blockers_clear),
      "active_block_id: " <> option_value(item.active_block_id, ""),
      registry_context(item),
      forge_context(item, attempt.kind),
      "",
      "# Repository Bindings",
      "workspace: " <> current_workspace.root_path,
      repository_bindings(item.repo_bindings, current_workspace.repos),
      "",
      "# Workpad",
      "workpad: " <> workpad_path,
      "allowed_output_filenames: "
        <> string.join(allowed_output_filenames(attempt.kind), with: ", "),
      "required_artifacts: "
        <> string.join(required_artifact_names(attempt.kind), with: ", "),
      "",
      "# Lifecycle Contract",
      lifecycle_contract(attempt.kind),
      "",
      "# Allowed Actions",
      allowed_actions(attempt.kind),
      "",
      "# Current Task",
      current_task(item, agent_session, attempt.kind),
      durable_context(prior_artifacts, reviews),
      "",
      "# Required Workpad Schemas",
      workpad_schemas(attempt.kind),
      "",
      "# Artifact Instructions",
      artifact_instructions(attempt.kind),
      "",
      "# Constraints",
      "Write outputs to the run workpad and finish by writing result.json last.",
      "Write JSON and Markdown outputs to a sibling temporary file and atomically rename them into place.",
      "Do not write files outside the allowed_output_filenames list.",
      "Do not modify Tango state files, ticket records, review records, approval records, or event logs.",
      external_ticket_work_protocol(attempt.kind),
      run_instructions(attempt.kind),
    ],
    with: "\n",
  )
}

fn repository_bindings(
  bindings: List(repo.RepoBinding),
  workspace_repos: List(workspace.WorkspaceRepo),
) -> String {
  bindings
  |> list.map(fn(binding) {
    string.join(
      [
        "- binding_id: " <> binding.id,
        "  name: " <> binding.name,
        "  kind: " <> repository_kind_text(binding.kind),
        "  source: " <> binding.location,
        "  workspace_path: " <> workspace_path_for(binding.id, workspace_repos),
        "  default_branch: " <> option_value(binding.default_branch, ""),
        "  base_ref: " <> option_value(binding.base_ref, ""),
        "  target_branch: " <> option_value(binding.target_branch, ""),
        "  work_branch: " <> option_value(binding.work_branch, ""),
        "  checkout_policy: clone",
      ],
      with: "\n",
    )
  })
  |> string.join(with: "\n")
}

fn workspace_path_for(
  binding_id: String,
  workspace_repos: List(workspace.WorkspaceRepo),
) -> String {
  case workspace_repos {
    [] -> ""
    [repo_info, ..rest] ->
      case repo_info.binding_id == binding_id {
        True -> repo_info.path
        False -> workspace_path_for(binding_id, rest)
      }
  }
}

fn repository_kind_text(kind: repo.RepositoryKind) -> String {
  case kind {
    repo.LocalPath -> "local_path"
    repo.GitRemote -> "git_remote"
    repo.ExternalRepo(value) -> value
  }
}

fn durable_context(
  prior_artifacts: List(artifact.ArtifactRecord),
  reviews: List(review.ReviewDecision),
) -> String {
  let artifacts =
    prior_artifacts
    |> list.map(fn(record) {
      string.join(
        [
          "## Artifact: " <> artifact.kind_to_string(record.kind),
          "run_id: " <> record.run_id,
          record.content,
        ],
        with: "\n",
      )
    })
    |> string.join(with: "\n\n")
  let review_context =
    reviews
    |> list.map(fn(decision) {
      string.join(
        [
          "## Review: " <> review.to_string(decision.decision),
          "reviewer: " <> decision.reviewer_id,
          "comments: " <> decision.comments,
          "reviewed_commits: " <> reviewed_commits(decision.reviewed_commit_set),
          "reviewed_pull_requests: "
            <> reviewed_pull_requests(decision.reviewed_pull_request_set),
        ],
        with: "\n",
      )
    })
    |> string.join(with: "\n\n")
  string.join(["# Durable Context", artifacts, review_context], with: "\n\n")
}

fn reviewed_commits(entries: List(review.ReviewedCommit)) -> String {
  entries
  |> list.map(fn(entry) { entry.repo_binding_id <> "=" <> entry.commit_id })
  |> string.join(with: ", ")
}

fn reviewed_pull_requests(entries: List(review.ReviewedPullRequest)) -> String {
  entries
  |> list.map(fn(entry) {
    entry.pull_request_ref <> "=" <> entry.reviewed_head_commit_id
  })
  |> string.join(with: ", ")
}

fn forge_context(item: ticket.Ticket, kind: run.RunKind) -> String {
  case item.forge_binding, kind {
    Some(binding), run.Execution
    | Some(binding), run.ReviewWatch
    | Some(binding), run.MergeRun
    ->
      string.join(
        [
          "",
          "# Forge",
          "forge: " <> binding.forge_name,
          "cli: " <> binding.cli_command,
          "skill: " <> binding.forge_skill,
          "Read and follow the installed forge skill at the path above before using the forge CLI.",
          "All repository and pull-request operations for this ticket must use this forge.",
        ],
        with: "\n",
      )
    _, _ -> ""
  }
}

fn registry_context(item: ticket.Ticket) -> String {
  case item.registry_binding, item.registry_status_mapping {
    Some(binding), Some(mapping) -> {
      let role = lifecycle.registry_status_role(item.state)
      let desired = registry_status.resolve(mapping, role)
      string.join(
        [
          "",
          "# Ticket System",
          "ticket_system: " <> binding.registry_name,
          "cli: " <> binding.cli_command,
          "skill: " <> binding.registry_skill,
          "external_ticket_ref: " <> binding.external_ticket_ref,
          "requested_role: " <> registry_role_text(role),
          "requested_status_id: " <> desired.id,
          "requested_status_name: " <> desired.name,
          "previously_observed_status_id: "
            <> option_text(item.observed_external_status_id),
        ],
        with: "\n",
      )
    }
    _, _ -> ""
  }
}

fn option_value(value: Option(String), fallback: String) -> String {
  case value {
    Some(value) -> value
    None -> fallback
  }
}

fn run_instructions(kind: run.RunKind) -> String {
  case kind {
    run.RegistrySync ->
      string.join(
        [
          "Use the configured ticket-system CLI and skill to update the external ticket to the requested stable status ID.",
          "Refetch the ticket to verify the observed final stable status.",
          "Write external-updates.json with one status_sync entry and result.json with only external_updates.",
          "Do not use forge tools, modify repositories, create pull requests, approve work, merge pull requests, or change Tango lifecycle state.",
        ],
        with: "\n",
      )
    run.ReviewWatch ->
      string.join(
        [
          "Inspect pull-request comments since the previously observed counts carried in durable artifacts or review cursors.",
          "Write review-comments.json with actionable feedback findings and external-updates.json for any comment or status observation you attempted.",
          "Do not modify repositories, push commits, create pull requests, approve work, authorize merge, or merge pull requests.",
        ],
        with: "\n",
      )
    run.MergeRun ->
      string.join(
        [
          "Inspect current pull-request state before acting.",
          "Treat already-merged approved pull requests as completed and preserve completed entries during partial-progress retries.",
          "Merge only pull requests listed in the durable reviewed_pull_requests set and only when the live head still equals reviewed_head_commit_id.",
          "Stop with status blocked if implementation commits or pull-request heads changed, if merge conflict resolution would alter implementation commits, or if an approved pull request is missing.",
          "For no-code completion with an empty reviewed pull-request set, do not invent repository changes; close or complete the external ticket and report an empty merge.json entries list.",
          "Close the external ticket and verify its configured done status only after every approved pull request is complete.",
        ],
        with: "\n",
      )
    run.Execution ->
      string.join(
        [
          "Research the external ticket and repository state before planning.",
          "Write a concrete plan before implementation and keep it aligned with the acceptance criteria and blockers.",
          "Implement only repository changes required by the ticket, then validate them with concrete commands or explain why validation could not be run.",
          "Commit repository changes and create or update pull requests for each modified repository.",
          "Post useful progress comments and maintain the external Tango TODO section when the ticket-system capability supports it.",
          "Post a final review handoff comment when implementation changed code, or a final research/recommendation handoff comment when no repository changes are required.",
          "Never merge pull requests, approve work, or complete the external ticket in an execution run.",
        ],
        with: "\n",
      )
  }
}

fn current_task(
  item: ticket.Ticket,
  agent_session: session.AgentSession,
  kind: run.RunKind,
) -> String {
  case kind, item.state, agent_session.role, agent_session.kind {
    run.Execution,
      lifecycle.ChangesRequested,
      session.Aux,
      session.Implementation
    ->
      "Respond to requested changes using the durable context_session_ids. Preserve prior accepted work, address review feedback, update validation, update pull requests, and return to human review without merging."
    run.Execution, _, _, _ ->
      "Advance the ticket from research through plan, implementation or no-code recommendation, validation, pull-request or empty pull-request reporting, and human review handoff."
    run.ReviewWatch, _, _, _ ->
      "Classify newly observed review feedback and report whether implementation changes are required."
    run.RegistrySync, _, _, _ ->
      "Synchronize only the external ticket status to the requested stable status."
    run.MergeRun, _, _, _ ->
      "Execute only the human-approved merge or no-code completion for the reviewed commit and pull-request sets."
  }
}

fn lifecycle_contract(kind: run.RunKind) -> String {
  case kind {
    run.Execution ->
      string.join(
        [
          "Tango owns lifecycle state. You report progress through workpad artifacts and external comments only.",
          "For execution, proceed continuously through research, plan, implementation-or-no-code recommendation, validation, and handoff.",
          "stage.json is optional progress telemetry with current_stage values researching, planning, or implementing. It must not be used as a pause point.",
          "A successful code-changing execution ends in human review with pull requests ready for review. A successful research-only or no-code execution also ends in human review with an empty pull-request set.",
          "Use result status blocked only when manual action is required; include block.reason and block.resolution_instructions.",
        ],
        with: "\n",
      )
    run.ReviewWatch ->
      "Tango owns lifecycle state. Review-watch reports new pull-request feedback only; it never approves or merges work."
    run.RegistrySync ->
      "Tango owns lifecycle state. Registry-sync reconciles the external status mirror only; it never changes repositories, reviews, approvals, or Tango state."
    run.MergeRun ->
      "Tango has already recorded human approval through tango review merge. Merge work is scoped to the durable reviewed commit and pull-request sets and must block rather than expand that scope."
  }
}

fn allowed_actions(kind: run.RunKind) -> String {
  case kind {
    run.Execution ->
      string.join(
        [
          "- read the external ticket, repository history, existing branches, existing pull requests, and comments",
          "- update the Tango-owned TODO section and post progress or handoff comments",
          "- modify repositories, run validation commands, create commits, push branches, and create or update pull requests when implementation is required",
          "- write only the execution workpad artifacts listed below",
          "- do not merge, close the external ticket as done, approve reviews, edit Tango state, or fabricate repository changes for research-only/no-code work",
        ],
        with: "\n",
      )
    run.ReviewWatch ->
      string.join(
        [
          "- read existing pull requests and comments",
          "- optionally post a bounded clarification or acknowledgment comment when supported",
          "- write only review-comments.json, external-updates.json, and result.json",
          "- do not edit repositories, create commits, create pull requests, approve reviews, merge, or change external ticket completion state",
        ],
        with: "\n",
      )
    run.RegistrySync ->
      string.join(
        [
          "- read and update only the configured external ticket status",
          "- refetch the external ticket to verify the observed final status",
          "- write only external-updates.json and result.json",
          "- do not use forge tools, edit repositories, create pull requests, approve reviews, merge, or modify Tango state",
        ],
        with: "\n",
      )
    run.MergeRun ->
      string.join(
        [
          "- read approved pull requests, current live heads, merge state, and external ticket state",
          "- merge only approved pull-request heads or record empty no-code completion",
          "- close or complete the external ticket only after all approved pull requests are merged or the approved set is empty",
          "- write only merge.json, external-updates.json, and result.json",
          "- do not create new implementation commits, change pull-request heads, add unapproved pull requests, or broaden the reviewed set",
        ],
        with: "\n",
      )
  }
}

fn artifact_instructions(kind: run.RunKind) -> String {
  case kind {
    run.Execution ->
      string.join(
        [
          "ticket.json must normalize the fetched external ticket title, description, acceptance_criteria, labels, blockers, observed status, description_revision, and tango_todo.",
          "research.md records investigation, relevant files, external references, blockers, and why code is or is not required.",
          "plan.md records the intended implementation or no-code recommendation and maps it to acceptance criteria.",
          "diff-summary.md records repository changes by binding ID; for research-only/no-code work, state that no repository files changed.",
          "implementation.md records commits, changed files, and behavior changes; for research-only/no-code work, state that implementation was not required.",
          "validation.json records every validation check attempted with status passed, failed, or skipped and a short summary.",
          "pull-requests.json records each created or updated pull request. For research-only/no-code work, write {\"schema_version\":1,\"pull_requests\":[]}.",
          "external-updates.json records status_sync, todo_update, and comment attempts. TODO/comment entries are observability-only.",
          "result.json must map every required artifact kind to its filename and must be written last.",
        ],
        with: "\n",
      )
    run.ReviewWatch ->
      "review-comments.json records newly observed comments and actionable feedback. external-updates.json records any comment/status observations. result.json must be written last."
    run.RegistrySync ->
      "external-updates.json must contain a status_sync entry for the requested role/status and observed final status. result.json must be written last."
    run.MergeRun ->
      "merge.json records ordered approved pull-request merge results with completed, pending, or failed status. external-updates.json records external ticket completion/status verification. result.json must be written last."
  }
}

fn external_ticket_work_protocol(kind: run.RunKind) -> String {
  case kind {
    run.Execution ->
      string.join(
        [
          "# External Ticket Work Protocol",
          "Treat the external TODO list and progress comments as prompt/work protocol, not lifecycle-gating evidence.",
          "Fetch the external ticket before editing it. Preserve all operator-authored description content outside Tango-owned markers.",
          "Maintain exactly one Tango-owned TODO section in the external ticket description, bounded by <!-- tango:todo:start --> and <!-- tango:todo:end -->.",
          "Inside that section, use a Markdown checklist with stable IDs in the form TG-TODO-001, TG-TODO-002, and so on. Never renumber existing IDs; mark state with [ ], [x], or [~] and keep each item text useful to a reviewer.",
          "If the description revision changes while editing, refetch, preserve operator-authored content, merge only the Tango-owned TODO section, and report the conflict in external-updates.json.",
          "Create and update TODO items as you research, plan, implement, validate, and respond to requested changes.",
          "Post useful progress comments while working and a final research handoff or review handoff comment before exiting when the ticket-system capability supports comments.",
          "Report attempted TODO edits and comment posts in external-updates.json for observability. Missing TODO or comment evidence must not stop you from writing result.json.",
          "In ticket.json include description_revision and a tango_todo object with section_present and items fields.",
          "In external-updates.json you may report status_sync, todo_update, and comment entries. TODO/comment entries are observability-only.",
        ],
        with: "\n",
      )
    _ -> ""
  }
}

fn workpad_schemas(kind: run.RunKind) -> String {
  string.join(
    list.append(
      [
        "manifest.json is immutable input created by Tango. Treat workspace_path, repositories, allowed_output_filenames, and required_artifacts as authoritative.",
      ],
      schema_sections(kind),
    ),
    with: "\n\n",
  )
}

fn schema_sections(kind: run.RunKind) -> List(String) {
  case kind {
    run.Execution -> [
      stage_schema(),
      ticket_schema(),
      validation_schema(),
      pull_requests_schema(),
      external_updates_schema(),
      result_schema(required_artifact_names(run.Execution)),
    ]
    run.ReviewWatch -> [
      review_comments_schema(),
      external_updates_schema(),
      result_schema(required_artifact_names(run.ReviewWatch)),
    ]
    run.RegistrySync -> [
      external_updates_schema(),
      result_schema(required_artifact_names(run.RegistrySync)),
    ]
    run.MergeRun -> [
      merge_schema(),
      external_updates_schema(),
      result_schema(required_artifact_names(run.MergeRun)),
    ]
  }
}

fn stage_schema() -> String {
  "stage.json schema: {\"schema_version\":1,\"run_id\":\""
  <> "RUN_ID"
  <> "\",\"sequence\":1,\"current_stage\":\"researching|planning|implementing\",\"history\":[{\"sequence\":1,\"stage\":\"researching|planning|implementing\",\"reported_at\":\"RFC3339\"}]}"
}

fn ticket_schema() -> String {
  "ticket.json schema: {\"schema_version\":1,\"external_ref\":\"string\",\"title\":\"string\",\"description\":\"string\",\"description_revision\":\"string|null\",\"acceptance_criteria\":[\"string\"],\"labels\":[\"string\"],\"blockers\":[\"string\"],\"observed_status\":{\"id\":\"string\",\"name\":\"string\"},\"tango_todo\":{\"section_present\":true,\"items\":[{\"id\":\"TG-TODO-001\",\"state\":\"todo|doing|done\",\"text\":\"string\"}]}}"
}

fn validation_schema() -> String {
  "validation.json schema: {\"schema_version\":1,\"checks\":[{\"name\":\"string\",\"command\":\"string|null\",\"status\":\"passed|failed|skipped\",\"summary\":\"string\"}]}"
}

fn pull_requests_schema() -> String {
  "pull-requests.json schema: {\"schema_version\":1,\"pull_requests\":[{\"repo_binding_id\":\"string\",\"commit_id\":\"string\",\"pull_request_ref\":\"string\",\"head_commit_id\":\"string\",\"source_branch\":\"string\",\"target_branch\":\"string\",\"final_comment_count\":0}]}"
}

fn review_comments_schema() -> String {
  "review-comments.json schema: {\"schema_version\":1,\"pull_requests\":[{\"pull_request_ref\":\"string\",\"previous_comment_count\":0,\"final_comment_count\":0,\"new_comments\":[{\"author\":\"string\",\"body\":\"string\",\"created_at\":\"RFC3339\"}],\"actionable\":true,\"summary\":\"string\"}]}"
}

fn merge_schema() -> String {
  "merge.json schema: {\"schema_version\":1,\"entries\":[{\"repo_binding_id\":\"string\",\"pull_request_ref\":\"string\",\"approved_head_commit_id\":\"string\",\"status\":\"completed|pending|failed\"}]}"
}

fn external_updates_schema() -> String {
  "external-updates.json schema: {\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"external_ticket_ref\":\"string\",\"requested_role\":\"backlog|todo|in_progress|human_review|merging|blocked|done|wont_do\",\"requested_status\":{\"id\":\"string\",\"name\":\"string\"},\"observed_status\":{\"id\":\"string\",\"name\":\"string\"}},{\"kind\":\"todo_update\",\"action\":\"created|updated|skipped\",\"description_revision_before\":\"string|null\",\"description_revision_after\":\"string|null\",\"items\":[{\"id\":\"TG-TODO-001\",\"state\":\"todo|doing|done\",\"text\":\"string\"}],\"reported_at\":\"RFC3339|null\"},{\"kind\":\"comment\",\"purpose\":\"progress|handoff|blocked\",\"posted\":true,\"body\":\"string\",\"reported_at\":\"RFC3339|null\"}]}"
}

fn result_schema(required_artifacts: List(String)) -> String {
  "result.json schema: {\"schema_version\":1,\"run_id\":\"RUN_ID\",\"status\":\"succeeded|blocked|failed\",\"completed_at\":\"RFC3339\",\"artifacts\":{"
  <> artifact_keys(required_artifacts)
  <> "},\"block\":{\"reason\":\"string\",\"resolution_instructions\":\"string\"}|null}"
}

fn artifact_keys(required_artifacts: List(String)) -> String {
  required_artifacts
  |> list.map(fn(kind) { "\"" <> kind <> "\":\"filename\"" })
  |> string.join(with: ",")
}

fn allowed_output_filenames(kind: run.RunKind) -> List(String) {
  case kind {
    run.Execution -> [
      "manifest.json",
      "stage.json",
      "ticket.json",
      "research.md",
      "plan.md",
      "diff-summary.md",
      "implementation.md",
      "validation.json",
      "pull-requests.json",
      "external-updates.json",
      "result.json",
    ]
    run.ReviewWatch -> [
      "manifest.json",
      "review-comments.json",
      "external-updates.json",
      "result.json",
    ]
    run.RegistrySync -> [
      "manifest.json",
      "external-updates.json",
      "result.json",
    ]
    run.MergeRun -> [
      "manifest.json",
      "merge.json",
      "external-updates.json",
      "result.json",
    ]
  }
}

fn required_artifact_names(kind: run.RunKind) -> List(String) {
  case kind {
    run.Execution -> [
      "normalized_ticket",
      "research_notes",
      "plan",
      "diff_summary",
      "implementation_notes",
      "validation_report",
      "pull_request_set",
      "external_updates",
    ]
    run.ReviewWatch -> ["review_comments_report", "external_updates"]
    run.RegistrySync -> ["external_updates"]
    run.MergeRun -> ["merge_report", "external_updates"]
  }
}

fn registry_role_text(role: lifecycle.RegistryStatusRole) -> String {
  case role {
    lifecycle.Backlog -> "backlog"
    lifecycle.Todo -> "todo"
    lifecycle.InProgress -> "in_progress"
    lifecycle.HumanReviewStatus -> "human_review"
    lifecycle.MergingStatus -> "merging"
    lifecycle.BlockedStatus -> "blocked"
    lifecycle.DoneStatus -> "done"
    lifecycle.WontDo -> "wont_do"
  }
}

fn run_kind_text(kind: run.RunKind) -> String {
  case kind {
    run.Execution -> "execution"
    run.ReviewWatch -> "review_watch"
    run.RegistrySync -> "registry_sync"
    run.MergeRun -> "merge"
  }
}

fn session_role_text(role: session.SessionRole) -> String {
  case role {
    session.Main -> "main"
    session.Aux -> "aux"
  }
}

fn option_text(value: Option(String)) -> String {
  case value {
    Some(text) -> text
    None -> ""
  }
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
