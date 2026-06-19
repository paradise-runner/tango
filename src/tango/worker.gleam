import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import tango/app/command
import tango/app/run_command
import tango/attestation/adapter as attestation
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
import tango/git/adapter as git
import tango/harness/adapter as harness
import tango/log
import tango/prompt
import tango/run_process
import tango/runtime
import tango/store/file
import tango/store/store
import tango/workpad
import tango/workspace/workspace

pub type WorkerError {
  StoreFailure(store.StoreError)
  CommandFailure(command.CommandError)
  RunFailure(run_command.RunCommandError)
  WorkspaceFailure(workspace.WorkspaceError)
  WorkpadFailure(workpad.WorkpadError)
  HarnessFailure(harness.HarnessError)
  SessionNotFound(String)
  ArtifactMissing(String)
  ArtifactInvalid(String)
  CursorFailure(review_cursor.ReviewCommentCursorError)
}

pub type WorkerDependencies {
  WorkerDependencies(
    workspace: workspace.WorkspaceAdapter,
    git: git.GitAdapter,
    attestation: attestation.Adapters,
    harness: harness.HarnessAdapter,
  )
}

pub type WorkerResult(state) {
  WorkerResult(
    state: state,
    ticket: ticket.Ticket,
    run: run.RunAttempt,
    workpad_path: String,
    output: String,
  )
}

type ReviewCommentsArtifact {
  ReviewCommentsArtifact(observations: List(ReviewCommentObservation))
}

type ReviewCommentObservation {
  ReviewCommentObservation(
    pull_request_ref: String,
    previous_count: Int,
    final_count: Int,
    new_comments: List(String),
    actionable_feedback: Bool,
  )
}

type WorkpadResult {
  WorkpadResult(
    status: WorkpadResultStatus,
    completed_at: String,
    artifacts: dict.Dict(String, String),
    block: Option(WorkpadBlock),
  )
}

type WorkpadBlock {
  WorkpadBlock(reason: String, resolution_instructions: String)
}

type WorkpadResultStatus {
  ResultSucceeded
  ResultBlocked
  ResultFailed
}

type PullRequestSetArtifact {
  PullRequestSetArtifact(entries: List(PullRequestArtifactEntry))
}

type PullRequestArtifactEntry {
  PullRequestArtifactEntry(
    repo_binding_id: String,
    commit_id: String,
    pull_request_ref: String,
    head_commit_id: String,
    source_branch: String,
    target_branch: String,
    final_comment_count: Int,
  )
}

type MergeReportArtifact {
  MergeReportArtifact(entries: List(MergeReportEntry))
}

type MergeReportEntry {
  MergeReportEntry(
    repo_binding_id: String,
    pull_request_ref: String,
    approved_head_commit_id: String,
    status: merge.MergeEntryStatus,
  )
}

type RegistryExternalUpdatesArtifact {
  RegistryExternalUpdatesArtifact(updates: List(RegistryExternalUpdateEntry))
}

type ExternalUpdatesArtifact {
  ExternalUpdatesArtifact(updates: List(ExternalUpdateEntry))
}

type ExternalUpdateEntry {
  ExternalStatusSync(RegistryExternalUpdateEntry)
  ExternalObservability
}

type RegistryExternalUpdateEntry {
  RegistryExternalUpdateEntry(
    requested_role: lifecycle.RegistryStatusRole,
    requested_status: registry_status.ExternalStatus,
    observed_status: registry_status.ExternalStatus,
  )
}

pub fn execute(
  backend: store.Store(state),
  state: state,
  state_dir: String,
  dependencies: WorkerDependencies,
  attempt: run.RunAttempt,
) -> Result(WorkerResult(state), WorkerError) {
  log.info(
    "worker starting ticket_id="
    <> attempt.ticket_id
    <> " run_id="
    <> attempt.id
    <> " run_kind="
    <> run_kind_text(attempt.kind)
    <> " attempt="
    <> int.to_string(attempt.attempt)
    <> " session_id="
    <> attempt.session_id,
  )
  use item <- result.try(
    backend.get_ticket(state, attempt.ticket_id)
    |> result.map_error(StoreFailure),
  )
  use agent_session <- result.try(
    backend.get_session(state, attempt.ticket_id, attempt.session_id)
    |> result.map_error(fn(error) {
      case error {
        store.NotFound(_) -> SessionNotFound(attempt.session_id)
        other -> StoreFailure(other)
      }
    }),
  )
  use started <- result.try(
    run_command.start(
      backend,
      state,
      attempt,
      attempt.id <> "-start",
      attempt.started_at,
    )
    |> result.map_error(RunFailure),
  )
  log.info(
    "worker run record started ticket_id="
    <> item.id
    <> " run_id="
    <> attempt.id
    <> " state="
    <> lifecycle.to_string(item.state),
  )
  log.info(
    "worker ensuring workspace ticket_id="
    <> item.id
    <> " run_id="
    <> attempt.id,
  )
  use current_workspace <- result.try(
    dependencies.workspace.ensure(state_dir, item)
    |> result.map_error(WorkspaceFailure),
  )
  log.info(
    "worker workspace ready ticket_id="
    <> item.id
    <> " run_id="
    <> attempt.id
    <> " workspace_path="
    <> current_workspace.root_path,
  )
  log.info(
    "worker creating workpad ticket_id=" <> item.id <> " run_id=" <> attempt.id,
  )
  use workpad_item <- result.try(
    workpad.create(
      state_dir,
      item.id,
      agent_session,
      attempt,
      current_workspace,
    )
    |> result.map_error(WorkpadFailure),
  )
  log.info(
    "worker workpad ready ticket_id="
    <> item.id
    <> " run_id="
    <> attempt.id
    <> " workpad_path="
    <> workpad_item.root_path,
  )
  let attempt =
    run.RunAttempt(..attempt, workspace_path: current_workspace.root_path)
  use state <- result.try(
    backend.save_run(started.state, attempt)
    |> result.map_error(StoreFailure),
  )
  use #(state, _) <- result.try(
    run_command.update_status(
      backend,
      state,
      item.id,
      attempt.id,
      run.BuildingPrompt,
      None,
      None,
    )
    |> result.map_error(RunFailure),
  )
  log.info(
    "worker building prompt ticket_id=" <> item.id <> " run_id=" <> attempt.id,
  )
  let assembled_prompt =
    prompt.build(
      item,
      agent_session,
      attempt,
      current_workspace,
      workpad_item.root_path,
      prior_artifacts(backend, state, item.id, agent_session),
      prior_reviews(backend, state, item.id),
    )
  use #(state, _) <- result.try(
    run_command.update_status(
      backend,
      state,
      item.id,
      attempt.id,
      run.LaunchingAgent,
      None,
      None,
    )
    |> result.map_error(RunFailure),
  )
  let request =
    harness.HarnessRequest(
      prompt: assembled_prompt,
      workspace_path: current_workspace.root_path,
      workpad_path: workpad_item.root_path,
      sandbox_paths: sandbox_paths(item),
      resume_session_id: resume_session_id(agent_session, attempt),
      on_process_started: fn(pid) {
        record_agent_process_started(state_dir, item.id, attempt.id, pid)
      },
    )
  case
    preflight_run(
      backend,
      state,
      item,
      attempt,
      current_workspace,
      dependencies.git,
    )
  {
    Error(reason) -> {
      log.warn(
        "worker preflight blocked ticket_id="
        <> item.id
        <> " run_id="
        <> attempt.id
        <> " reason="
        <> reason,
      )
      finish_preflight_block(
        backend,
        state,
        started.ticket,
        attempt,
        workpad_item,
        reason,
      )
    }
    Ok(_) -> {
      log.info(
        "worker preflight passed ticket_id="
        <> item.id
        <> " run_id="
        <> attempt.id,
      )
      use #(state, _) <- result.try(
        run_command.update_status(
          backend,
          state,
          item.id,
          attempt.id,
          run.Streaming,
          None,
          None,
        )
        |> result.map_error(RunFailure),
      )
      log.info(
        "worker launching agent ticket_id="
        <> item.id
        <> " run_id="
        <> attempt.id,
      )
      let agent_result = dependencies.harness.run(request)
      let _ =
        run_process.mark_ended(
          state_dir,
          item.id,
          attempt.id,
          runtime.now_rfc3339(),
        )
      use response <- result.try(
        agent_result |> result.map_error(HarnessFailure),
      )
      log.info(
        "worker agent exited ticket_id="
        <> item.id
        <> " run_id="
        <> attempt.id
        <> " exit_code="
        <> int.to_string(response.exit_code)
        <> " output_chars="
        <> int.to_string(string.length(response.output))
        <> usage_log_text(response.usage),
      )
      log.info(
        "worker collecting artifacts ticket_id="
        <> item.id
        <> " run_id="
        <> attempt.id,
      )
      use #(state, final_run) <- result.try(
        finish_run(
          backend,
          state,
          item,
          attempt,
          current_workspace,
          dependencies.git,
          dependencies.attestation,
          workpad_item,
          response,
        )
        |> result.map_error(RunFailure),
      )
      log.info(
        "worker artifacts processed ticket_id="
        <> item.id
        <> " run_id="
        <> attempt.id
        <> " final_status="
        <> run_status_text(final_run.status),
      )
      let updated_ticket = case backend.get_ticket(state, item.id) {
        Ok(updated) -> updated
        Error(_) -> started.ticket
      }
      Ok(WorkerResult(
        state: state,
        ticket: updated_ticket,
        run: final_run,
        workpad_path: workpad_item.root_path,
        output: response.output,
      ))
    }
  }
}

fn prior_artifacts(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  agent_session: session.AgentSession,
) -> List(artifact.ArtifactRecord) {
  case backend.list_artifacts(state, ticket_id) {
    Ok(records) ->
      case agent_session.role, agent_session.kind {
        session.Main, session.Implementation -> []
        session.Aux, session.Implementation ->
          records
          |> list.filter(fn(record) {
            record.kind == artifact.ReviewCommentsReport
            || artifact_is_context(
              record,
              agent_session.context_session_ids,
              backend,
              state,
            )
          })
        _, _ -> records
      }
    Error(_) -> []
  }
}

fn sandbox_paths(item: ticket.Ticket) -> List(String) {
  list.append(ticket_skill_paths(item), codex_skill_paths())
  |> unique_paths
}

fn ticket_skill_paths(item: ticket.Ticket) -> List(String) {
  let registry_paths = case item.registry_binding {
    Some(binding) -> existing_skill_parent(binding.registry_skill)
    None -> []
  }
  let forge_paths = case item.forge_binding {
    Some(binding) -> existing_skill_parent(binding.forge_skill)
    None -> []
  }
  list.append(registry_paths, forge_paths)
}

fn existing_skill_parent(path: String) -> List(String) {
  case file.is_regular_file_no_symlink(path), parent_dir(path) {
    True, Some(parent) -> [parent]
    _, _ -> []
  }
}

fn codex_skill_paths() -> List(String) {
  case codex_home() {
    Some(root) ->
      [join(root, "skills"), join(join(root, "plugins"), "cache")]
      |> existing_directories
    None -> []
  }
}

fn codex_home() -> Option(String) {
  case non_empty_env("CODEX_HOME") {
    Some(root) -> Some(root)
    None ->
      case non_empty_env("HOME") {
        Some(home) -> Some(join(home, ".codex"))
        None -> None
      }
  }
}

fn non_empty_env(name: String) -> Option(String) {
  case runtime.get_env(name) {
    Some(value) ->
      case string.trim(value) {
        "" -> None
        trimmed -> Some(trimmed)
      }
    None -> None
  }
}

fn existing_directories(paths: List(String)) -> List(String) {
  paths
  |> list.filter(fn(path) {
    case file.list_dir(path) {
      Ok(_) -> True
      Error(_) -> False
    }
  })
}

fn parent_dir(path: String) -> Option(String) {
  case string.trim(path) {
    "" -> None
    trimmed -> parent_segments(string.split(trimmed, "/"), [])
  }
}

fn parent_segments(
  segments: List(String),
  acc: List(String),
) -> Option(String) {
  case segments {
    [] | [_] -> None
    [segment, _] -> Some(string.join(list.reverse([segment, ..acc]), with: "/"))
    [segment, ..rest] -> parent_segments(rest, [segment, ..acc])
  }
}

fn unique_paths(paths: List(String)) -> List(String) {
  paths
  |> list.fold([], fn(acc, path) {
    case list.contains(acc, path) {
      True -> acc
      False -> list.append(acc, [path])
    }
  })
}

fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/"), string.starts_with(right, "/") {
    True, True -> left <> string.drop_start(right, 1)
    True, False -> left <> right
    False, True -> left <> right
    False, False -> left <> "/" <> right
  }
}

fn artifact_is_context(
  record: artifact.ArtifactRecord,
  context_session_ids: List(String),
  backend: store.Store(state),
  state: state,
) -> Bool {
  context_session_ids
  |> list.any(fn(session_id) {
    case backend.get_session(state, record.ticket_id, session_id) {
      Ok(agent_session) ->
        list.contains(agent_session.run_attempt_ids, record.run_id)
      Error(_) -> False
    }
  })
}

fn prior_reviews(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> List(review.ReviewDecision) {
  backend.list_reviews(state, ticket_id)
  |> result.unwrap([])
}

fn record_agent_process_started(
  state_dir: String,
  ticket_id: String,
  run_id: String,
  pid: Int,
) -> Nil {
  log.info(
    "worker agent process started ticket_id="
    <> ticket_id
    <> " run_id="
    <> run_id
    <> " pid="
    <> int.to_string(pid),
  )
  run_process.mark_started(
    state_dir,
    ticket_id,
    run_id,
    pid,
    runtime.now_rfc3339(),
  )
  |> result.map_error(fn(reason) {
    log.warn(
      "worker agent process marker failed ticket_id="
      <> ticket_id
      <> " run_id="
      <> run_id
      <> " reason="
      <> reason,
    )
  })
  |> result.unwrap(Nil)
}

fn preflight_run(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
  git_adapter: git.GitAdapter,
) -> Result(Nil, String) {
  case attempt.kind {
    run.MergeRun -> {
      use approval <- result.try(
        latest_merge_approval(backend, state, item.id)
        |> result.map_error(error_text),
      )
      use _ <- result.try(approval_matches_latest_durable_set(
        backend,
        state,
        item.id,
        approval,
      ))
      git_adapter.validate(current_workspace, approval_expected_heads(approval))
      |> result.map_error(git_error_text)
    }
    _ -> Ok(Nil)
  }
}

fn finish_preflight_block(
  backend: store.Store(state),
  state: state,
  fallback_ticket: ticket.Ticket,
  attempt: run.RunAttempt,
  workpad_item: workpad.Workpad,
  reason: String,
) -> Result(WorkerResult(state), WorkerError) {
  let now = runtime.now_rfc3339()
  use state <- result.try(block_merge_for_review(
    backend,
    state,
    fallback_ticket,
    attempt,
    now,
    reason,
  ))
  use #(state, final_run) <- result.try(
    run_command.update_status(
      backend,
      state,
      fallback_ticket.id,
      attempt.id,
      run.Failed,
      Some(now),
      Some(reason),
    )
    |> result.map_error(RunFailure),
  )
  let updated_ticket =
    backend.get_ticket(state, fallback_ticket.id)
    |> result.unwrap(fallback_ticket)
  Ok(WorkerResult(
    state: state,
    ticket: updated_ticket,
    run: final_run,
    workpad_path: workpad_item.root_path,
    output: reason,
  ))
}

fn resume_session_id(
  agent_session: session.AgentSession,
  attempt: run.RunAttempt,
) -> Option(String) {
  case
    agent_session.role,
    agent_session.runtime_session_id,
    attempt.attempt > 1
  {
    session.Main, Some(session_id), True -> Some(session_id)
    _, _, _ -> None
  }
}

fn finish_run(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
  git_adapter: git.GitAdapter,
  attestation_adapters: attestation.Adapters,
  workpad_item: workpad.Workpad,
  response: harness.HarnessResponse,
) -> Result(#(state, run.RunAttempt), run_command.RunCommandError) {
  use #(state, _) <- result.try(run_command.update_status(
    backend,
    state,
    item.id,
    attempt.id,
    run.CollectingArtifacts,
    None,
    None,
  ))
  case response.exit_code {
    0 -> {
      use state <- result.try(record_response_usage(
        backend,
        state,
        item.id,
        attempt.id,
        response,
      ))
      case
        post_process_success(
          backend,
          state,
          item,
          attempt,
          current_workspace,
          git_adapter,
          attestation_adapters,
          workpad_item,
        )
      {
        Ok(state) ->
          run_command.update_status(
            backend,
            state,
            item.id,
            attempt.id,
            run.Succeeded,
            None,
            None,
          )
        Error(error) ->
          run_command.update_status(
            backend,
            state,
            item.id,
            attempt.id,
            run.Failed,
            None,
            Some(error_text(error)),
          )
      }
    }
    _ -> {
      use state <- result.try(record_response_usage(
        backend,
        state,
        item.id,
        attempt.id,
        response,
      ))
      run_command.update_status(
        backend,
        state,
        item.id,
        attempt.id,
        run.Failed,
        None,
        Some(response.output),
      )
    }
  }
}

fn record_response_usage(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  run_id: String,
  response: harness.HarnessResponse,
) -> Result(state, run_command.RunCommandError) {
  case response.usage {
    None -> Ok(state)
    Some(usage) -> {
      use attempt <- result.try(
        backend.get_run(state, ticket_id, run_id)
        |> result.map_error(run_command.StoreFailure),
      )
      let updated = run.RunAttempt(..attempt, usage: Some(usage))
      use state <- result.try(
        backend.save_run(state, updated)
        |> result.map_error(run_command.StoreFailure),
      )
      Ok(state)
    }
  }
}

fn post_process_success(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
  git_adapter: git.GitAdapter,
  attestation_adapters: attestation.Adapters,
  workpad_item: workpad.Workpad,
) -> Result(state, WorkerError) {
  use result_marker <- result.try(read_result(
    workpad_item.root_path,
    workpad_item.manifest,
  ))
  use _ <- result.try(reject_failed_result(result_marker))
  use _ <- result.try(validate_workspace_result(
    backend,
    state,
    item,
    attempt,
    current_workspace,
    git_adapter,
    workpad_item.root_path,
    result_marker,
  ))
  use _ <- result.try(validate_external_attestations(
    backend,
    state,
    item,
    attempt,
    attestation_adapters,
    current_workspace,
    workpad_item.root_path,
    result_marker,
  ))
  use promoted <- result.try(promote_result_artifacts(
    backend,
    state,
    item.id,
    attempt.id,
    attempt.started_at,
    workpad_item.root_path,
    result_marker,
  ))
  case attempt.kind, result_marker.status {
    run.Execution, ResultSucceeded ->
      apply_execution_result(
        backend,
        promoted,
        item,
        attempt,
        workpad_item.root_path,
        result_marker,
      )
    run.Execution, ResultBlocked ->
      apply_blocked_result(backend, promoted, item, attempt, result_marker)
    run.Execution, ResultFailed ->
      Error(ArtifactInvalid("execution result status failed is not promotable"))
    run.ReviewWatch, ResultSucceeded -> {
      use review_source <- result.try(read_artifact_source(
        workpad_item.root_path,
        result_marker,
        artifact.ReviewCommentsReport,
      ))
      apply_review_watch_result(backend, promoted, item, attempt, review_source)
    }
    run.ReviewWatch, ResultBlocked ->
      apply_blocked_result(backend, promoted, item, attempt, result_marker)
    run.ReviewWatch, ResultFailed ->
      Error(ArtifactInvalid(
        "review watch result status failed is not promotable",
      ))
    run.RegistrySync, ResultSucceeded ->
      apply_registry_sync_result(
        backend,
        promoted,
        item,
        attempt,
        workpad_item.root_path,
        result_marker,
      )
    run.RegistrySync, ResultBlocked ->
      apply_blocked_result(backend, promoted, item, attempt, result_marker)
    run.RegistrySync, ResultFailed ->
      Error(ArtifactInvalid(
        "registry sync result status failed is not promotable",
      ))
    run.MergeRun, ResultSucceeded ->
      apply_merge_result(
        backend,
        promoted,
        item,
        attempt,
        workpad_item.root_path,
        result_marker,
      )
    run.MergeRun, ResultBlocked ->
      apply_blocked_result(backend, promoted, item, attempt, result_marker)
    run.MergeRun, ResultFailed ->
      Error(ArtifactInvalid("merge result status failed is not promotable"))
  }
}

fn validate_workspace_result(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
  git_adapter: git.GitAdapter,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(Nil, WorkerError) {
  case attempt.kind, result_marker.status {
    run.Execution, ResultSucceeded -> {
      use pull_requests <- result.try(pull_request_set(
        workpad_path,
        result_marker,
      ))
      use expected_heads <- result.try(execution_expected_heads(
        pull_requests.entries,
      ))
      use _ <- result.try(
        git_adapter.validate(current_workspace, expected_heads)
        |> result.map_error(fn(error) { ArtifactInvalid(git_error_text(error)) }),
      )
      use changed_repositories <- result.try(
        git_adapter.changed_repositories(current_workspace, item.repo_bindings)
        |> result.map_error(fn(error) { ArtifactInvalid(git_error_text(error)) }),
      )
      reject_omitted_changed_repositories(
        changed_repositories,
        pull_requests.entries,
      )
    }
    run.MergeRun, ResultSucceeded -> {
      use approval <- result.try(latest_merge_approval(backend, state, item.id))
      git_adapter.validate(current_workspace, approval_expected_heads(approval))
      |> result.map_error(fn(error) { ArtifactInvalid(git_error_text(error)) })
    }
    _, _ -> Ok(Nil)
  }
}

fn validate_external_attestations(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  adapters: attestation.Adapters,
  current_workspace: workspace.Workspace,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(Nil, WorkerError) {
  case attempt.kind, result_marker.status {
    run.Execution, ResultSucceeded -> {
      use _ <- result.try(attest_ticket_status(
        item,
        adapters.ticket_system,
        lifecycle.HumanReviewStatus,
        first_repository_path(current_workspace),
        False,
      ))
      use pull_requests <- result.try(pull_request_set(
        workpad_path,
        result_marker,
      ))
      attest_execution_pull_requests(
        item,
        adapters.forge,
        current_workspace,
        pull_requests.entries,
      )
    }
    run.RegistrySync, ResultSucceeded ->
      attest_ticket_status(
        item,
        adapters.ticket_system,
        lifecycle.registry_status_role(item.state),
        first_repository_path(current_workspace),
        False,
      )
      |> result.map(fn(_) { Nil })
    run.MergeRun, ResultSucceeded -> {
      use approval <- result.try(latest_merge_approval(backend, state, item.id))
      use report <- result.try(merge_report(workpad_path, result_marker))
      use pull_requests <- result.try(latest_durable_pull_request_set(
        backend,
        state,
        item.id,
      ))
      use _ <- result.try(attest_merge_pull_requests(
        item,
        adapters.forge,
        current_workspace,
        approval,
        report.entries,
        pull_requests.entries,
      ))
      case
        report.entries != []
        && list.all(report.entries, fn(entry) {
          entry.status == merge.Completed
        })
      {
        True ->
          attest_ticket_status(
            item,
            adapters.ticket_system,
            lifecycle.DoneStatus,
            first_repository_path(current_workspace),
            False,
          )
          |> result.map(fn(_) { Nil })
        False -> Ok(Nil)
      }
    }
    _, _ -> Ok(Nil)
  }
}

fn attest_ticket_status(
  item: ticket.Ticket,
  ticket_adapter: attestation.TicketAdapter,
  role: lifecycle.RegistryStatusRole,
  repository_path: Option(String),
  require_comment: Bool,
) -> Result(attestation.TicketSnapshot, WorkerError) {
  use binding <- result.try(case item.registry_binding {
    Some(value) -> Ok(value)
    None -> Error(ArtifactInvalid("registry binding is missing"))
  })
  use mapping <- result.try(case item.registry_status_mapping {
    Some(value) -> Ok(value)
    None -> Error(ArtifactInvalid("registry status mapping is missing"))
  })
  attestation.attest_ticket(
    ticket_adapter,
    attestation.TicketRequest(
      binding: binding,
      expected_status: registry_status.resolve(mapping, role),
      repository_path: repository_path,
      require_comment: require_comment,
    ),
  )
  |> result.map_error(attestation_error)
}

fn attest_execution_pull_requests(
  item: ticket.Ticket,
  forge_adapter: attestation.ForgeAdapter,
  current_workspace: workspace.Workspace,
  entries: List(PullRequestArtifactEntry),
) -> Result(Nil, WorkerError) {
  entries
  |> list.try_each(fn(entry) {
    use repository <- result.try(find_repository(item, entry.repo_binding_id))
    attest_pull_request(
      item,
      forge_adapter,
      repository,
      entry.pull_request_ref,
      entry.head_commit_id,
      entry.source_branch,
      entry.target_branch,
      False,
      repository_path(current_workspace, entry.repo_binding_id),
    )
  })
}

fn attest_merge_pull_requests(
  item: ticket.Ticket,
  forge_adapter: attestation.ForgeAdapter,
  current_workspace: workspace.Workspace,
  approval: review.ReviewDecision,
  entries: List(MergeReportEntry),
  pull_requests: List(PullRequestArtifactEntry),
) -> Result(Nil, WorkerError) {
  entries
  |> list.try_each(fn(entry) {
    case entry.status {
      merge.Completed -> {
        use repository <- result.try(find_repository(
          item,
          entry.repo_binding_id,
        ))
        use approved <- result.try(
          approval.reviewed_pull_request_set
          |> list.find(fn(pr) { pr.pull_request_ref == entry.pull_request_ref })
          |> result.map_error(fn(_) {
            ArtifactInvalid(
              "merge report pull request is absent from the approved set",
            )
          }),
        )
        use pull_request <- result.try(
          pull_requests
          |> list.find(fn(pr) { pr.pull_request_ref == entry.pull_request_ref })
          |> result.map_error(fn(_) {
            ArtifactInvalid(
              "merge report pull request is absent from the durable pull-request set",
            )
          }),
        )
        attest_pull_request(
          item,
          forge_adapter,
          repository,
          entry.pull_request_ref,
          approved.reviewed_head_commit_id,
          pull_request.source_branch,
          pull_request.target_branch,
          True,
          repository_path(current_workspace, entry.repo_binding_id),
        )
      }
      merge.Pending | merge.FailedEntry -> Ok(Nil)
    }
  })
}

fn attest_pull_request(
  item: ticket.Ticket,
  forge_adapter: attestation.ForgeAdapter,
  repository: repo.RepoBinding,
  pull_request_ref: String,
  expected_head_commit_id: String,
  expected_source_branch: String,
  expected_target_branch: String,
  require_merged: Bool,
  repository_path: Option(String),
) -> Result(Nil, WorkerError) {
  use binding <- result.try(case item.forge_binding {
    Some(value) -> Ok(value)
    None -> Error(ArtifactInvalid("forge binding is missing"))
  })
  attestation.attest_pull_request(
    forge_adapter,
    attestation.PullRequestRequest(
      binding: binding,
      repository: repository,
      pull_request_ref: pull_request_ref,
      expected_source_branch: Some(expected_source_branch),
      expected_target_branch: Some(expected_target_branch),
      expected_head_commit_id: expected_head_commit_id,
      require_merged: require_merged,
      repository_path: repository_path,
    ),
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(attestation_error)
}

fn find_repository(
  item: ticket.Ticket,
  binding_id: String,
) -> Result(repo.RepoBinding, WorkerError) {
  item.repo_bindings
  |> list.find(fn(binding) { binding.id == binding_id })
  |> result.map_error(fn(_) {
    ArtifactInvalid("unknown repository binding: " <> binding_id)
  })
}

fn repository_path(
  current_workspace: workspace.Workspace,
  binding_id: String,
) -> Option(String) {
  case
    current_workspace.repos
    |> list.find(fn(repository) { repository.binding_id == binding_id })
  {
    Ok(repository) -> Some(repository.path)
    Error(_) -> None
  }
}

fn latest_durable_pull_request_set(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(PullRequestSetArtifact, WorkerError) {
  use artifacts <- result.try(
    backend.list_artifacts(state, ticket_id) |> result.map_error(StoreFailure),
  )
  case latest_pull_request_artifact(artifacts) {
    Some(record) ->
      json.parse(record.content, pull_request_set_decoder())
      |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) })
    None -> Ok(PullRequestSetArtifact(entries: []))
  }
}

fn first_repository_path(
  current_workspace: workspace.Workspace,
) -> Option(String) {
  case current_workspace.repos {
    [repository, ..] -> Some(repository.path)
    [] -> None
  }
}

fn attestation_error(error: attestation.AttestationError) -> WorkerError {
  ArtifactInvalid("external attestation failed: " <> string.inspect(error))
}

fn execution_expected_heads(
  entries: List(PullRequestArtifactEntry),
) -> Result(List(git.ExpectedHead), WorkerError) {
  entries
  |> list.try_map(fn(entry) {
    case entry.commit_id == entry.head_commit_id {
      True -> Ok(git.ExpectedHead(entry.repo_binding_id, entry.commit_id))
      False ->
        Error(ArtifactInvalid(
          "reported pull-request head does not match implementation commit: "
          <> entry.repo_binding_id,
        ))
    }
  })
}

fn reject_omitted_changed_repositories(
  changed_repositories: List(String),
  entries: List(PullRequestArtifactEntry),
) -> Result(Nil, WorkerError) {
  case
    changed_repositories
    |> list.find(fn(binding_id) {
      !list.any(entries, fn(entry) { entry.repo_binding_id == binding_id })
    })
  {
    Ok(binding_id) ->
      Error(ArtifactInvalid(
        "modified repository omitted from pull-request set: " <> binding_id,
      ))
    Error(_) -> Ok(Nil)
  }
}

fn reject_failed_result(
  result_marker: WorkpadResult,
) -> Result(Nil, WorkerError) {
  case result_marker.status {
    ResultFailed -> Error(ArtifactInvalid("failed result is not promotable"))
    ResultSucceeded | ResultBlocked -> Ok(Nil)
  }
}

fn apply_review_watch_result(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  artifact_source: String,
) -> Result(state, WorkerError) {
  use artifact <- result.try(decode_review_comments(artifact_source))
  let observed_at = runtime.now_rfc3339()
  use state <- result.try(
    artifact.observations
    |> list.fold(Ok(state), fn(acc, observation) {
      use current_state <- result.try(acc)
      persist_review_cursor(
        backend,
        current_state,
        item.id,
        observation,
        observed_at,
      )
    }),
  )
  use state <- result.try(
    backend.append_event(
      state,
      event.new(
        id: attempt.id <> "-review-watch",
        ticket_id: Some(item.id),
        type_: "review.watch_completed",
        occurred_at: observed_at,
        actor: "agent:review-watch",
        payload: dict.from_list([
          #("run_id", attempt.id),
          #(
            "pull_request_count",
            int.to_string(list.length(artifact.observations)),
          ),
        ]),
      ),
    )
    |> result.map_error(StoreFailure),
  )
  case has_actionable_feedback(artifact) {
    False -> Ok(state)
    True -> {
      use _ <- result.try(
        lifecycle.can_transition(
          from: item.state,
          to: lifecycle.ChangesRequested,
          context: lifecycle.default_transition_context(),
        )
        |> result.map_error(fn(_) {
          ArtifactInvalid("review watch could not transition ticket")
        }),
      )
      use state <- result.try(
        backend.append_event(
          state,
          event.new(
            id: attempt.id <> "-review-comments",
            ticket_id: Some(item.id),
            type_: "review.comments_detected",
            occurred_at: observed_at,
            actor: "agent:review-watch",
            payload: dict.from_list([#("run_id", attempt.id)]),
          ),
        )
        |> result.map_error(StoreFailure),
      )
      backend.save_ticket(
        state,
        ticket.Ticket(
          ..item,
          state: lifecycle.ChangesRequested,
          updated_at: observed_at,
        ),
      )
      |> result.map_error(StoreFailure)
    }
  }
}

fn apply_execution_result(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(state, WorkerError) {
  let now = result_marker.completed_at
  use pull_requests <- result.try(pull_request_set(workpad_path, result_marker))
  use observed_external_status_id <- result.try(verified_external_status_id(
    item,
    workpad_path,
    result_marker,
    lifecycle.HumanReviewStatus,
  ))
  use state <- result.try(
    pull_requests.entries
    |> list.fold(Ok(state), fn(acc, entry) {
      use current_state <- result.try(acc)
      persist_review_cursor(
        backend,
        current_state,
        item.id,
        ReviewCommentObservation(
          pull_request_ref: entry.pull_request_ref,
          previous_count: entry.final_comment_count,
          final_count: entry.final_comment_count,
          new_comments: [],
          actionable_feedback: False,
        ),
        now,
      )
    }),
  )
  use state <- result.try(append_execution_lifecycle_events(
    backend,
    state,
    item,
    attempt,
    now,
  ))
  use state <- result.try(
    backend.append_event(
      state,
      event.new(
        id: attempt.id <> "-execution-promoted",
        ticket_id: Some(item.id),
        type_: "run.execution_promoted",
        occurred_at: now,
        actor: "orchestrator",
        payload: dict.from_list([
          #("run_id", attempt.id),
          #(
            "pull_request_count",
            int.to_string(list.length(pull_requests.entries)),
          ),
        ]),
      ),
    )
    |> result.map_error(StoreFailure),
  )
  let updated =
    ticket.Ticket(
      ..item,
      state: lifecycle.AwaitingHumanReview,
      observed_external_status_id: Some(observed_external_status_id),
      updated_at: now,
    )
  backend.save_ticket(state, updated)
  |> result.map_error(StoreFailure)
}

fn append_execution_lifecycle_events(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  now: String,
) -> Result(state, WorkerError) {
  let transitions = case attempt.resume_state {
    lifecycle.ChangesRequested -> [
      #(lifecycle.ChangesRequested, lifecycle.Implementing),
      #(lifecycle.Implementing, lifecycle.AwaitingHumanReview),
    ]
    _ -> [
      #(lifecycle.Queued, lifecycle.Researching),
      #(lifecycle.Researching, lifecycle.Planning),
      #(lifecycle.Planning, lifecycle.Implementing),
      #(lifecycle.Implementing, lifecycle.AwaitingHumanReview),
    ]
  }
  transitions
  |> list.fold(Ok(state), fn(acc, transition) {
    use state <- result.try(acc)
    backend.append_event(
      state,
      event.new(
        id: attempt.id <> "-lifecycle-" <> lifecycle.to_string(transition.1),
        ticket_id: Some(item.id),
        type_: "ticket.lifecycle_transition",
        occurred_at: now,
        actor: "agent:execution",
        payload: dict.from_list([
          #("from", lifecycle.to_string(transition.0)),
          #("to", lifecycle.to_string(transition.1)),
          #("run_id", attempt.id),
        ]),
      ),
    )
    |> result.map_error(StoreFailure)
  })
}

fn apply_merge_result(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(state, WorkerError) {
  use approval <- result.try(latest_merge_approval(backend, state, item.id))
  case approval_matches_latest_durable_set(backend, state, item.id, approval) {
    Ok(_) ->
      continue_merge_recording(
        backend,
        state,
        item,
        attempt,
        workpad_path,
        result_marker,
        approval,
      )
    Error(reason) ->
      block_merge_for_review(
        backend,
        state,
        item,
        attempt,
        result_marker.completed_at,
        reason,
      )
  }
}

fn continue_merge_recording(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  workpad_path: String,
  result_marker: WorkpadResult,
  approval: review.ReviewDecision,
) -> Result(state, WorkerError) {
  use report <- result.try(merge_report(workpad_path, result_marker))
  case merge_report_matches_approval(report, approval) {
    Error(reason) ->
      block_merge_for_review(
        backend,
        state,
        item,
        attempt,
        result_marker.completed_at,
        reason,
      )
    Ok(_) -> {
      let record =
        merge.MergeRecord(
          id: attempt.id <> "-merge",
          ticket_id: item.id,
          review_decision_id: approval.id,
          entries: report.entries
            |> list.map(fn(entry) {
              merge.MergeEntry(
                repo_binding_id: entry.repo_binding_id,
                pull_request_ref: entry.pull_request_ref,
                approved_head_commit_id: entry.approved_head_commit_id,
                status: entry.status,
              )
            }),
          created_at: attempt.started_at,
          completed_at: result_marker.completed_at,
        )
      case merge.is_successful(record) {
        False ->
          command.record_merge_result(
            backend,
            state,
            item.id,
            record,
            attempt.id <> "-merge-recorded",
            attempt.id <> "-merge-block",
          )
          |> result.map(fn(result) { result.state })
          |> result.map_error(CommandFailure)
        True ->
          case
            verify_merge_external_completion(
              backend,
              state,
              item,
              attempt,
              workpad_path,
              result_marker,
            )
          {
            Error(error) ->
              block_merge_for_review(
                backend,
                state,
                item,
                attempt,
                result_marker.completed_at,
                error_text(error),
              )
            Ok(state) ->
              command.record_merge_result(
                backend,
                state,
                item.id,
                record,
                attempt.id <> "-merge-recorded",
                attempt.id <> "-merge-block",
              )
              |> result.map(fn(result) { result.state })
              |> result.map_error(CommandFailure)
          }
      }
    }
  }
}

fn verify_merge_external_completion(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(state, WorkerError) {
  use observed_status_id <- result.try(verified_external_status_id(
    item,
    workpad_path,
    result_marker,
    lifecycle.DoneStatus,
  ))
  {
    use state <- result.try(
      backend.append_event(
        state,
        event.new(
          id: attempt.id <> "-external-completed",
          ticket_id: Some(item.id),
          type_: "registry.external_ticket_completed",
          occurred_at: result_marker.completed_at,
          actor: "agent:merge",
          payload: dict.from_list([
            #("observed_status_id", observed_status_id),
          ]),
        ),
      )
      |> result.map_error(StoreFailure),
    )
    backend.save_ticket(
      state,
      ticket.Ticket(
        ..item,
        observed_external_status_id: Some(observed_status_id),
        updated_at: result_marker.completed_at,
      ),
    )
    |> result.map_error(StoreFailure)
  }
}

fn verified_external_status_id(
  item: ticket.Ticket,
  workpad_path: String,
  result_marker: WorkpadResult,
  role: lifecycle.RegistryStatusRole,
) -> Result(String, WorkerError) {
  use updates <- result.try(registry_sync_updates(workpad_path, result_marker))
  use mapping <- result.try(case item.registry_status_mapping {
    Some(mapping) -> Ok(mapping)
    None -> Error(ArtifactInvalid("registry status mapping is missing"))
  })
  let expected = registry_status.resolve(mapping, role)
  case
    updates.updates
    |> list.find(fn(update) {
      update.requested_role == role
      && update.requested_status.id == expected.id
      && update.observed_status.id == expected.id
    })
  {
    Ok(update) -> Ok(update.observed_status.id)
    Error(Nil) ->
      Error(ArtifactInvalid(
        "run did not verify the external ticket at the configured "
        <> registry_status_role_text(role)
        <> " status",
      ))
  }
}

fn apply_blocked_result(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  result_marker: WorkpadResult,
) -> Result(state, WorkerError) {
  let assert Some(block_details) = result_marker.block
  let block_record =
    block.BlockRecord(
      id: attempt.id <> "-block",
      ticket_id: item.id,
      reason: block_details.reason,
      resolution_instructions: Some(block_details.resolution_instructions),
      blocked_from: item.state,
      resume_state: blocked_resume_state(attempt),
      created_by: "agent:" <> run_kind_actor(attempt.kind),
      created_at: result_marker.completed_at,
      resolved_by: None,
      resolved_at: None,
    )
  use _ <- result.try(
    block.validate(block_record)
    |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) }),
  )
  use state <- result.try(
    backend.save_block(state, block_record)
    |> result.map_error(StoreFailure),
  )
  use state <- result.try(
    backend.append_event(
      state,
      event.new(
        id: attempt.id <> "-blocked",
        ticket_id: Some(item.id),
        type_: "run.blocked",
        occurred_at: result_marker.completed_at,
        actor: "orchestrator",
        payload: dict.from_list([#("run_id", attempt.id)]),
      ),
    )
    |> result.map_error(StoreFailure),
  )
  backend.save_ticket(
    state,
    ticket.Ticket(
      ..item,
      state: lifecycle.Blocked,
      active_block_id: Some(block_record.id),
      updated_at: result_marker.completed_at,
    ),
  )
  |> result.map_error(StoreFailure)
}

fn apply_registry_sync_result(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(state, WorkerError) {
  use artifact <- result.try(registry_sync_updates(workpad_path, result_marker))
  use update <- result.try(case artifact.updates {
    [entry, ..] -> Ok(entry)
    [] -> Error(ArtifactInvalid("registry sync artifact must contain updates"))
  })
  use _ <- result.try(validate_registry_sync_update(item, update))
  use state <- result.try(
    backend.append_event(
      state,
      event.new(
        id: attempt.id <> "-registry-sync",
        ticket_id: Some(item.id),
        type_: "registry.status_sync_completed",
        occurred_at: result_marker.completed_at,
        actor: "registry-sync",
        payload: dict.from_list([
          #("run_id", attempt.id),
          #("requested_role", registry_status_role_text(update.requested_role)),
          #("requested_status_id", update.requested_status.id),
          #("observed_status_id", update.observed_status.id),
        ]),
      ),
    )
    |> result.map_error(StoreFailure),
  )
  backend.save_ticket(
    state,
    ticket.Ticket(
      ..item,
      observed_external_status_id: Some(update.observed_status.id),
      updated_at: result_marker.completed_at,
    ),
  )
  |> result.map_error(StoreFailure)
}

fn validate_registry_sync_update(
  item: ticket.Ticket,
  update: RegistryExternalUpdateEntry,
) -> Result(Nil, WorkerError) {
  case item.registry_status_mapping {
    None -> Error(ArtifactInvalid("registry status mapping is missing"))
    Some(mapping) -> {
      let expected_role = lifecycle.registry_status_role(item.state)
      let expected_status = registry_status.resolve(mapping, expected_role)
      case
        update.requested_role == expected_role,
        update.requested_status.id == expected_status.id,
        update.observed_status.id == expected_status.id
      {
        True, True, True -> Ok(Nil)
        False, _, _ ->
          Error(ArtifactInvalid(
            "registry sync requested role does not match current lifecycle state",
          ))
        _, False, _ ->
          Error(ArtifactInvalid(
            "registry sync requested status does not match the pinned mapping",
          ))
        _, _, False ->
          Error(ArtifactInvalid(
            "registry sync did not observe the requested stable status",
          ))
      }
    }
  }
}

fn block_merge_for_review(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  now: String,
  reason: String,
) -> Result(state, WorkerError) {
  let record =
    block.BlockRecord(
      id: attempt.id <> "-approval-block",
      ticket_id: item.id,
      reason: reason,
      resolution_instructions: Some(
        "Inspect the reviewed set, then invoke tango ticket unblock and tango review merge again.",
      ),
      blocked_from: item.state,
      resume_state: lifecycle.AwaitingHumanReview,
      created_by: "agent:merge",
      created_at: now,
      resolved_by: None,
      resolved_at: None,
    )
  command.block_ticket(
    backend,
    state,
    item.id,
    record,
    attempt.id <> "-approval-event",
    "agent:merge",
    now,
  )
  |> result.map(fn(result) { result.state })
  |> result.map_error(CommandFailure)
}

fn promote_result_artifacts(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  run_id: String,
  promoted_at: String,
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(state, WorkerError) {
  let entries = dict.to_list(result_marker.artifacts)
  use records <- result.try(
    entries
    |> list.try_map(fn(entry) {
      use kind <- result.try(parse_artifact_kind(entry.0))
      use source <- result.try(read_artifact_file(workpad_path, entry.1))
      use _ <- result.try(validate_artifact_content(kind, source))
      let record =
        artifact.ArtifactRecord(
          id: run_id <> "-" <> artifact.kind_to_string(kind),
          ticket_id: ticket_id,
          run_id: run_id,
          kind: kind,
          filename: entry.1,
          content_type: content_type(kind, entry.1),
          sha256: runtime.sha256(source),
          content: source,
          created_at: promoted_at,
        )
      use _ <- result.try(
        artifact.validate(record)
        |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) }),
      )
      Ok(record)
    }),
  )
  use state <- result.try(
    records
    |> list.fold(Ok(state), fn(acc, record) {
      use current_state <- result.try(acc)
      backend.save_artifact(current_state, record)
      |> result.map_error(StoreFailure)
    }),
  )
  backend.append_event(
    state,
    event.new(
      id: run_id <> "-artifacts",
      ticket_id: Some(ticket_id),
      type_: "run.artifacts_promoted",
      occurred_at: result_marker.completed_at,
      actor: "orchestrator",
      payload: dict.from_list([
        #("run_id", run_id),
        #("artifact_count", int.to_string(list.length(entries))),
      ]),
    ),
  )
  |> result.map_error(StoreFailure)
}

fn read_result(
  workpad_path: String,
  manifest: workpad.Manifest,
) -> Result(WorkpadResult, WorkerError) {
  use source <- result.try(read_artifact_file(workpad_path, "result.json"))
  use result_marker <- result.try(
    json.parse(source, workpad_result_decoder(manifest.run_id))
    |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) }),
  )
  use _ <- result.try(validate_result_against_manifest(
    workpad_path,
    manifest,
    result_marker,
  ))
  Ok(result_marker)
}

fn validate_result_against_manifest(
  workpad_path: String,
  manifest: workpad.Manifest,
  result_marker: WorkpadResult,
) -> Result(Nil, WorkerError) {
  let referenced = dict.to_list(result_marker.artifacts)
  use _ <- result.try(validate_workpad_entries(workpad_path, manifest))
  let required =
    manifest.required_artifacts
    |> list.map(artifact.kind_to_string)
  let present =
    referenced
    |> list.map(fn(entry) { entry.0 })
    |> list.sort(by: string.compare)
  case present == list.sort(required, by: string.compare) {
    False ->
      Error(ArtifactInvalid(
        "result.json artifact keys do not match required artifacts",
      ))
    True -> {
      use _ <- result.try(
        referenced
        |> list.try_each(fn(entry) {
          validate_artifact_reference(workpad_path, manifest, entry.0, entry.1)
        }),
      )
      case result_marker.status, result_marker.block {
        ResultBlocked, Some(_) -> Ok(Nil)
        ResultBlocked, None ->
          Error(ArtifactInvalid("blocked result requires block details"))
        ResultSucceeded, Some(_) | ResultFailed, Some(_) ->
          Error(ArtifactInvalid(
            "only blocked results may include block details",
          ))
        _, _ -> Ok(Nil)
      }
    }
  }
}

fn validate_workpad_entries(
  workpad_path: String,
  manifest: workpad.Manifest,
) -> Result(Nil, WorkerError) {
  use entries <- result.try(
    file.list_dir(workpad_path)
    |> result.map_error(fn(error) { ArtifactInvalid(error) }),
  )
  entries
  |> list.try_each(fn(filename) {
    case list.contains(manifest.allowed_output_filenames, filename) {
      True -> Ok(Nil)
      False ->
        Error(ArtifactInvalid(
          "workpad contains file not allowed by manifest: " <> filename,
        ))
    }
  })
}

fn validate_artifact_reference(
  workpad_path: String,
  manifest: workpad.Manifest,
  kind: String,
  filename: String,
) -> Result(Nil, WorkerError) {
  use _ <- result.try(parse_artifact_kind(kind))
  case
    list.contains(manifest.allowed_output_filenames, filename),
    is_plain_filename(filename)
  {
    False, _ ->
      Error(ArtifactInvalid(
        "artifact file is not allowed by manifest: " <> filename,
      ))
    _, False ->
      Error(ArtifactInvalid(
        "artifact file must be a plain filename: " <> filename,
      ))
    True, True -> {
      use _ <- result.try(read_artifact_file(workpad_path, filename))
      use result_mtime <- result.try(file_mtime(workpad_path <> "/result.json"))
      use artifact_mtime <- result.try(file_mtime(
        workpad_path <> "/" <> filename,
      ))
      case artifact_mtime <= result_mtime {
        True -> Ok(Nil)
        False ->
          Error(ArtifactInvalid(
            "result.json was not the last promoted artifact written",
          ))
      }
    }
  }
}

fn read_artifact_source(
  workpad_path: String,
  result_marker: WorkpadResult,
  kind: artifact.ArtifactKind,
) -> Result(String, WorkerError) {
  use filename <- result.try(artifact_filename(result_marker, kind))
  read_artifact_file(workpad_path, filename)
}

fn artifact_filename(
  result_marker: WorkpadResult,
  kind: artifact.ArtifactKind,
) -> Result(String, WorkerError) {
  result_marker.artifacts
  |> dict.get(artifact.kind_to_string(kind))
  |> result.map_error(fn(_) {
    ArtifactInvalid(
      "missing artifact reference for " <> artifact.kind_to_string(kind),
    )
  })
}

fn pull_request_set(
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(PullRequestSetArtifact, WorkerError) {
  use source <- result.try(read_artifact_source(
    workpad_path,
    result_marker,
    artifact.PullRequestSet,
  ))
  json.parse(source, pull_request_set_decoder())
  |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) })
}

fn merge_report(
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(MergeReportArtifact, WorkerError) {
  use source <- result.try(read_artifact_source(
    workpad_path,
    result_marker,
    artifact.MergeReport,
  ))
  json.parse(source, merge_report_decoder())
  |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) })
}

fn registry_sync_updates(
  workpad_path: String,
  result_marker: WorkpadResult,
) -> Result(RegistryExternalUpdatesArtifact, WorkerError) {
  use source <- result.try(read_artifact_source(
    workpad_path,
    result_marker,
    artifact.ExternalUpdates,
  ))
  json.parse(source, registry_external_updates_decoder())
  |> result.map_error(fn(error) {
    ArtifactInvalid(
      "registry sync external updates are invalid: " <> string.inspect(error),
    )
  })
}

fn latest_merge_approval(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(review.ReviewDecision, WorkerError) {
  use reviews <- result.try(
    backend.list_reviews(state, ticket_id) |> result.map_error(StoreFailure),
  )
  reviews
  |> list.filter(review.is_approval)
  |> list.sort(fn(left, right) {
    case string.compare(left.created_at, right.created_at) {
      order.Lt -> order.Gt
      order.Gt -> order.Lt
      order.Eq -> order.Eq
    }
  })
  |> list.first
  |> result.map_error(fn(_) { ArtifactInvalid("merge approval is missing") })
}

fn approval_matches_latest_durable_set(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  approval: review.ReviewDecision,
) -> Result(Nil, String) {
  use artifacts <- result.try(
    backend.list_artifacts(state, ticket_id)
    |> result.map_error(string.inspect),
  )
  case latest_pull_request_artifact(artifacts) {
    None -> reviewed_sets_match(approval, [], [])
    Some(latest) -> {
      use pull_requests <- result.try(
        json.parse(latest.content, pull_request_set_decoder())
        |> result.map_error(string.inspect),
      )
      reviewed_sets_match(
        approval,
        reviewed_commit_set(pull_requests.entries),
        reviewed_pull_request_set(pull_requests.entries),
      )
    }
  }
}

fn merge_report_matches_approval(
  report: MergeReportArtifact,
  approval: review.ReviewDecision,
) -> Result(Nil, String) {
  let commit_set =
    report.entries
    |> list.fold([], fn(acc, entry) {
      let next =
        review.ReviewedCommit(
          repo_binding_id: entry.repo_binding_id,
          commit_id: entry.approved_head_commit_id,
        )
      case
        list.any(acc, fn(existing: review.ReviewedCommit) {
          existing.repo_binding_id == next.repo_binding_id
          && existing.commit_id == next.commit_id
        })
      {
        True -> acc
        False -> list.append(acc, [next])
      }
    })
  let pull_request_set =
    report.entries
    |> list.map(fn(entry) {
      review.ReviewedPullRequest(
        pull_request_ref: entry.pull_request_ref,
        reviewed_head_commit_id: entry.approved_head_commit_id,
      )
    })
  reviewed_sets_match(approval, commit_set, pull_request_set)
}

fn reviewed_sets_match(
  approval: review.ReviewDecision,
  reviewed_commit_set: List(review.ReviewedCommit),
  reviewed_pull_request_set: List(review.ReviewedPullRequest),
) -> Result(Nil, String) {
  case
    approval.reviewed_commit_set == reviewed_commit_set,
    approval.reviewed_pull_request_set == reviewed_pull_request_set
  {
    True, True -> Ok(Nil)
    _, _ ->
      Error("reviewed commit or pull-request set changed after human approval")
  }
}

fn approval_expected_heads(
  approval: review.ReviewDecision,
) -> List(git.ExpectedHead) {
  approval.reviewed_commit_set
  |> list.map(fn(commit) {
    git.ExpectedHead(commit.repo_binding_id, commit.commit_id)
  })
}

fn git_error_text(error: git.GitError) -> String {
  case error {
    git.RepositoryMissing(binding_id) ->
      "workspace repository is missing: " <> binding_id
    git.DirtyWorktree(binding_id) ->
      "workspace repository is dirty: " <> binding_id
    git.WrongHead(binding_id, expected, actual) ->
      "workspace repository head changed: "
      <> binding_id
      <> " expected "
      <> expected
      <> " actual "
      <> actual
    git.CommandFailed(binding_id, output) ->
      "git validation failed for " <> binding_id <> ": " <> output
  }
}

fn latest_pull_request_artifact(
  artifacts: List(artifact.ArtifactRecord),
) -> Option(artifact.ArtifactRecord) {
  case
    artifacts
    |> list.filter(fn(item) { item.kind == artifact.PullRequestSet })
    |> list.sort(fn(left, right) {
      case string.compare(left.created_at, right.created_at) {
        order.Lt -> order.Gt
        order.Gt -> order.Lt
        order.Eq -> compare_desc(left.id, right.id)
      }
    })
    |> list.first
  {
    Ok(found) -> Some(found)
    Error(Nil) -> None
  }
}

fn compare_desc(left: String, right: String) -> order.Order {
  case string.compare(left, right) {
    order.Lt -> order.Gt
    order.Gt -> order.Lt
    order.Eq -> order.Eq
  }
}

fn blocked_resume_state(attempt: run.RunAttempt) -> lifecycle.LifecycleState {
  case attempt.kind, attempt.resume_state {
    run.Execution, lifecycle.ChangesRequested -> lifecycle.ChangesRequested
    run.Execution, _ -> lifecycle.Queued
    run.ReviewWatch, _ | run.MergeRun, _ -> lifecycle.AwaitingHumanReview
    run.RegistrySync, lifecycle.ChangesRequested -> lifecycle.ChangesRequested
    run.RegistrySync, lifecycle.AwaitingHumanReview ->
      lifecycle.AwaitingHumanReview
    run.RegistrySync, _ -> lifecycle.Queued
  }
}

fn reviewed_commit_set(
  entries: List(PullRequestArtifactEntry),
) -> List(review.ReviewedCommit) {
  entries
  |> list.fold([], fn(acc, entry) {
    let next =
      review.ReviewedCommit(
        repo_binding_id: entry.repo_binding_id,
        commit_id: entry.commit_id,
      )
    case
      list.any(acc, fn(existing: review.ReviewedCommit) {
        existing.repo_binding_id == next.repo_binding_id
        && existing.commit_id == next.commit_id
      })
    {
      True -> acc
      False -> list.append(acc, [next])
    }
  })
}

fn reviewed_pull_request_set(
  entries: List(PullRequestArtifactEntry),
) -> List(review.ReviewedPullRequest) {
  entries
  |> list.map(fn(entry) {
    review.ReviewedPullRequest(
      pull_request_ref: entry.pull_request_ref,
      reviewed_head_commit_id: entry.head_commit_id,
    )
  })
}

fn validate_artifact_content(
  kind: artifact.ArtifactKind,
  source: String,
) -> Result(Nil, WorkerError) {
  case kind {
    artifact.NormalizedTicket ->
      decode_schema_version_one(source, "normalized ticket artifact", [
        "description_revision",
        "description",
        "acceptance_criteria",
        "labels",
        "blockers",
        "tango_todo",
      ])
    artifact.ResearchNotes
    | artifact.Plan
    | artifact.DiffSummary
    | artifact.ImplementationNotes ->
      case string.trim(source) {
        "" -> Error(ArtifactInvalid("markdown artifact must not be empty"))
        _ -> Ok(Nil)
      }
    artifact.ValidationReport ->
      decode_schema_version_one(source, "validation artifact", ["checks"])
    artifact.PullRequestSet ->
      pull_request_set_decoder()
      |> decode_json(source, "pull request set artifact")
    artifact.ReviewCommentsReport ->
      review_comments_decoder()
      |> decode_json(source, "review comments artifact")
    artifact.MergeReport ->
      decode_schema_version_one(source, "merge artifact", ["entries"])
    artifact.ExternalUpdates ->
      external_updates_decoder()
      |> decode_json(source, "external updates artifact")
  }
}

fn decode_json(
  decoder: decode.Decoder(a),
  source: String,
  label: String,
) -> Result(Nil, WorkerError) {
  json.parse(source, decoder)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) {
    ArtifactInvalid(label <> " is invalid: " <> string.inspect(error))
  })
}

fn decode_schema_version_one(
  source: String,
  label: String,
  required_fields: List(String),
) -> Result(Nil, WorkerError) {
  use version <- result.try(
    json.parse(source, schema_version_decoder())
    |> result.map_error(fn(error) {
      ArtifactInvalid(label <> " is invalid: " <> string.inspect(error))
    }),
  )
  case
    version == 1,
    required_fields
    |> list.all(fn(field) { string.contains(source, "\"" <> field <> "\"") })
  {
    False, _ -> Error(ArtifactInvalid(label <> " must use schema version 1"))
    _, False -> Error(ArtifactInvalid(label <> " is missing required fields"))
    True, True -> Ok(Nil)
  }
}

fn schema_version_decoder() -> decode.Decoder(Int) {
  use version <- decode.field("schema_version", decode.int)
  decode.success(version)
}

fn pull_request_set_decoder() -> decode.Decoder(PullRequestSetArtifact) {
  use version <- decode.field("schema_version", decode.int)
  use entries <- decode.field(
    "pull_requests",
    decode.list(of: pull_request_entry_decoder()),
  )
  case version {
    1 -> decode.success(PullRequestSetArtifact(entries: entries))
    _ ->
      decode.failure(
        PullRequestSetArtifact(entries: []),
        expected: "pull request set schema version 1",
      )
  }
}

fn pull_request_entry_decoder() -> decode.Decoder(PullRequestArtifactEntry) {
  use repo_binding_id <- decode.field("repo_binding_id", decode.string)
  use commit_id <- decode.field("commit_id", decode.string)
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  use head_commit_id <- decode.field("head_commit_id", decode.string)
  use source_branch <- decode.field("source_branch", decode.string)
  use target_branch <- decode.field("target_branch", decode.string)
  use final_comment_count <- decode.field("final_comment_count", decode.int)
  case
    string.trim(repo_binding_id),
    string.trim(commit_id),
    string.trim(pull_request_ref),
    string.trim(head_commit_id),
    string.trim(source_branch),
    string.trim(target_branch),
    final_comment_count >= 0
  {
    "", _, _, _, _, _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty repo binding id",
      )
    _, "", _, _, _, _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty commit id",
      )
    _, _, "", _, _, _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty pull request ref",
      )
    _, _, _, "", _, _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty head commit id",
      )
    _, _, _, _, "", _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty source branch",
      )
    _, _, _, _, _, "", _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty target branch",
      )
    _, _, _, _, _, _, False ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-negative final comment count",
      )
    _, _, _, _, _, _, True ->
      decode.success(PullRequestArtifactEntry(
        repo_binding_id: repo_binding_id,
        commit_id: commit_id,
        pull_request_ref: pull_request_ref,
        head_commit_id: head_commit_id,
        source_branch: source_branch,
        target_branch: target_branch,
        final_comment_count: final_comment_count,
      ))
  }
}

fn invalid_pull_request_entry() -> PullRequestArtifactEntry {
  PullRequestArtifactEntry(
    repo_binding_id: "",
    commit_id: "",
    pull_request_ref: "",
    head_commit_id: "",
    source_branch: "",
    target_branch: "",
    final_comment_count: 0,
  )
}

fn merge_report_decoder() -> decode.Decoder(MergeReportArtifact) {
  use version <- decode.field("schema_version", decode.int)
  use entries <- decode.field(
    "entries",
    decode.list(of: merge_report_entry_decoder()),
  )
  case version {
    1 -> decode.success(MergeReportArtifact(entries: entries))
    _ ->
      decode.failure(
        MergeReportArtifact(entries: []),
        expected: "merge report schema version 1",
      )
  }
}

fn merge_report_entry_decoder() -> decode.Decoder(MergeReportEntry) {
  use repo_binding_id <- decode.field("repo_binding_id", decode.string)
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  use approved_head_commit_id <- decode.field(
    "approved_head_commit_id",
    decode.string,
  )
  use status <- decode.field("status", merge_entry_status_decoder())
  case
    string.trim(repo_binding_id),
    string.trim(pull_request_ref),
    string.trim(approved_head_commit_id)
  {
    "", _, _ ->
      decode.failure(
        invalid_merge_report_entry(),
        expected: "non-empty repo binding id",
      )
    _, "", _ ->
      decode.failure(
        invalid_merge_report_entry(),
        expected: "non-empty pull request ref",
      )
    _, _, "" ->
      decode.failure(
        invalid_merge_report_entry(),
        expected: "non-empty approved head commit id",
      )
    _, _, _ ->
      decode.success(MergeReportEntry(
        repo_binding_id: repo_binding_id,
        pull_request_ref: pull_request_ref,
        approved_head_commit_id: approved_head_commit_id,
        status: status,
      ))
  }
}

fn invalid_merge_report_entry() -> MergeReportEntry {
  MergeReportEntry(
    repo_binding_id: "",
    pull_request_ref: "",
    approved_head_commit_id: "",
    status: merge.Pending,
  )
}

fn registry_external_updates_decoder() -> decode.Decoder(
  RegistryExternalUpdatesArtifact,
) {
  decode.then(external_updates_decoder(), fn(artifact) {
    decode.success(
      RegistryExternalUpdatesArtifact(updates: status_updates(artifact.updates)),
    )
  })
}

fn status_updates(updates: List(ExternalUpdateEntry)) {
  updates
  |> list.filter_map(fn(update) {
    case update {
      ExternalStatusSync(entry) -> Ok(entry)
      ExternalObservability -> Error(Nil)
    }
  })
}

fn external_updates_decoder() -> decode.Decoder(ExternalUpdatesArtifact) {
  use version <- decode.field("schema_version", decode.int)
  use updates <- decode.field(
    "updates",
    decode.list(of: external_update_entry_decoder()),
  )
  case version {
    1 -> decode.success(ExternalUpdatesArtifact(updates: updates))
    _ ->
      decode.failure(
        ExternalUpdatesArtifact(updates: []),
        expected: "external updates schema version 1",
      )
  }
}

fn external_update_entry_decoder() -> decode.Decoder(ExternalUpdateEntry) {
  use kind <- decode.optional_field("kind", "", decode.string)
  case kind {
    "" -> decode.success(ExternalObservability)
    "status_sync" ->
      decode.then(registry_external_update_entry_decoder(), fn(entry) {
        decode.success(ExternalStatusSync(entry))
      })
    "todo_update" ->
      decode.then(todo_update_decoder(), fn(_) {
        decode.success(ExternalObservability)
      })
    "comment" ->
      decode.then(comment_update_decoder(), fn(_) {
        decode.success(ExternalObservability)
      })
    _ ->
      decode.failure(
        ExternalObservability,
        expected: "known external update entry kind",
      )
  }
}

fn todo_update_decoder() -> decode.Decoder(Nil) {
  use action <- decode.field("action", decode.string)
  use _before <- decode.field(
    "description_revision_before",
    decode.optional(decode.string),
  )
  use _after <- decode.field(
    "description_revision_after",
    decode.optional(decode.string),
  )
  use _items <- decode.field(
    "items",
    decode.list(of: external_todo_item_decoder()),
  )
  use _reported_at <- decode.field(
    "reported_at",
    decode.optional(decode.string),
  )
  case string.trim(action) {
    "" -> decode.failure(Nil, expected: "non-empty todo_update action")
    _ -> decode.success(Nil)
  }
}

fn comment_update_decoder() -> decode.Decoder(Nil) {
  use purpose <- decode.field("purpose", decode.string)
  use _posted <- decode.field("posted", decode.bool)
  use body <- decode.field("body", decode.string)
  use _reported_at <- decode.field(
    "reported_at",
    decode.optional(decode.string),
  )
  case string.trim(purpose), string.trim(body) {
    "", _ -> decode.failure(Nil, expected: "non-empty comment purpose")
    _, "" -> decode.failure(Nil, expected: "non-empty comment body")
    _, _ -> decode.success(Nil)
  }
}

fn external_todo_item_decoder() -> decode.Decoder(Nil) {
  use id <- decode.field("id", decode.string)
  use state <- decode.field("state", decode.string)
  use text <- decode.field("text", decode.string)
  case string.trim(id), string.trim(state), string.trim(text) {
    "", _, _ -> decode.failure(Nil, expected: "non-empty TODO item id")
    _, "", _ -> decode.failure(Nil, expected: "non-empty TODO item state")
    _, _, "" -> decode.failure(Nil, expected: "non-empty TODO item text")
    _, _, _ -> decode.success(Nil)
  }
}

fn registry_external_update_entry_decoder() -> decode.Decoder(
  RegistryExternalUpdateEntry,
) {
  use kind <- decode.field("kind", decode.string)
  use requested_role <- decode.field(
    "requested_role",
    registry_status_role_decoder(),
  )
  use requested_status <- decode.field(
    "requested_status",
    external_status_decoder(),
  )
  use observed_status <- decode.field(
    "observed_status",
    external_status_decoder(),
  )
  case kind {
    "status_sync" ->
      decode.success(RegistryExternalUpdateEntry(
        requested_role: requested_role,
        requested_status: requested_status,
        observed_status: observed_status,
      ))
    _ ->
      decode.failure(
        RegistryExternalUpdateEntry(
          requested_role: lifecycle.Todo,
          requested_status: registry_status.ExternalStatus(id: "", name: ""),
          observed_status: registry_status.ExternalStatus(id: "", name: ""),
        ),
        expected: "status_sync external update entry",
      )
  }
}

fn registry_status_role_decoder() -> decode.Decoder(
  lifecycle.RegistryStatusRole,
) {
  decode.then(decode.string, fn(role) {
    case role {
      "backlog" -> decode.success(lifecycle.Backlog)
      "todo" -> decode.success(lifecycle.Todo)
      "in_progress" -> decode.success(lifecycle.InProgress)
      "human_review" -> decode.success(lifecycle.HumanReviewStatus)
      "merging" -> decode.success(lifecycle.MergingStatus)
      "blocked" -> decode.success(lifecycle.BlockedStatus)
      "done" -> decode.success(lifecycle.DoneStatus)
      "wont_do" -> decode.success(lifecycle.WontDo)
      _ ->
        decode.failure(lifecycle.Todo, expected: "known registry status role")
    }
  })
}

fn external_status_decoder() -> decode.Decoder(registry_status.ExternalStatus) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  case string.trim(id), string.trim(name) {
    "", _ ->
      decode.failure(
        registry_status.ExternalStatus(id: "", name: ""),
        expected: "non-empty external status id",
      )
    _, "" ->
      decode.failure(
        registry_status.ExternalStatus(id: "", name: ""),
        expected: "non-empty external status name",
      )
    _, _ -> decode.success(registry_status.ExternalStatus(id: id, name: name))
  }
}

fn merge_entry_status_decoder() -> decode.Decoder(merge.MergeEntryStatus) {
  decode.then(decode.string, fn(status) {
    case status {
      "completed" -> decode.success(merge.Completed)
      "pending" -> decode.success(merge.Pending)
      "failed" -> decode.success(merge.FailedEntry)
      _ ->
        decode.failure(
          merge.Pending,
          expected: "merge entry status completed, pending, or failed",
        )
    }
  })
}

fn workpad_result_decoder(run_id: String) -> decode.Decoder(WorkpadResult) {
  use version <- decode.field("schema_version", decode.int)
  use actual_run_id <- decode.field("run_id", decode.string)
  use status_text <- decode.field("status", decode.string)
  use completed_at <- decode.field("completed_at", decode.string)
  use artifacts <- decode.field(
    "artifacts",
    decode.dict(decode.string, decode.string),
  )
  use block <- decode.field("block", decode.optional(workpad_block_decoder()))
  case
    version,
    actual_run_id == run_id,
    parse_result_status(status_text),
    string.trim(completed_at) != ""
  {
    1, True, Ok(status), True ->
      decode.success(WorkpadResult(
        status: status,
        completed_at: completed_at,
        artifacts: artifacts,
        block: block,
      ))
    _, False, _, _ ->
      decode.failure(
        invalid_workpad_result(),
        expected: "result run_id must match manifest run id",
      )
    _, _, Error(_), _ ->
      decode.failure(
        invalid_workpad_result(),
        expected: "result status must be succeeded, blocked, or failed",
      )
    _, _, _, _ ->
      decode.failure(
        invalid_workpad_result(),
        expected: "result schema version 1 with non-empty completed_at",
      )
  }
}

fn workpad_block_decoder() -> decode.Decoder(WorkpadBlock) {
  use reason <- decode.field("reason", decode.string)
  use resolution_instructions <- decode.field(
    "resolution_instructions",
    decode.string,
  )
  case string.trim(reason), string.trim(resolution_instructions) {
    "", _ ->
      decode.failure(
        WorkpadBlock(reason: "", resolution_instructions: ""),
        expected: "non-empty block reason",
      )
    _, "" ->
      decode.failure(
        WorkpadBlock(reason: "", resolution_instructions: ""),
        expected: "non-empty block resolution instructions",
      )
    _, _ ->
      decode.success(WorkpadBlock(
        reason: reason,
        resolution_instructions: resolution_instructions,
      ))
  }
}

fn invalid_workpad_result() -> WorkpadResult {
  WorkpadResult(
    status: ResultFailed,
    completed_at: "",
    artifacts: dict.new(),
    block: None,
  )
}

fn parse_result_status(status: String) -> Result(WorkpadResultStatus, Nil) {
  case status {
    "succeeded" -> Ok(ResultSucceeded)
    "blocked" -> Ok(ResultBlocked)
    "failed" -> Ok(ResultFailed)
    _ -> Error(Nil)
  }
}

fn parse_artifact_kind(
  value: String,
) -> Result(artifact.ArtifactKind, WorkerError) {
  case value {
    "normalized_ticket" -> Ok(artifact.NormalizedTicket)
    "research_notes" -> Ok(artifact.ResearchNotes)
    "plan" -> Ok(artifact.Plan)
    "diff_summary" -> Ok(artifact.DiffSummary)
    "implementation_notes" -> Ok(artifact.ImplementationNotes)
    "validation_report" -> Ok(artifact.ValidationReport)
    "pull_request_set" -> Ok(artifact.PullRequestSet)
    "review_comments_report" -> Ok(artifact.ReviewCommentsReport)
    "merge_report" -> Ok(artifact.MergeReport)
    "external_updates" -> Ok(artifact.ExternalUpdates)
    _ -> Error(ArtifactInvalid("unknown artifact kind: " <> value))
  }
}

fn content_type(kind: artifact.ArtifactKind, filename: String) -> String {
  case kind, string.ends_with(filename, ".md") {
    artifact.ResearchNotes, True
    | artifact.Plan, True
    | artifact.DiffSummary, True
    | artifact.ImplementationNotes, True
    -> "text/markdown"
    _, _ -> "application/json"
  }
}

fn read_artifact_file(
  workpad_path: String,
  filename: String,
) -> Result(String, WorkerError) {
  let path = workpad_path <> "/" <> filename
  case file.is_regular_file_no_symlink(path) {
    False ->
      Error(ArtifactInvalid(
        "artifact file must be a regular file and not a symlink: " <> filename,
      ))
    True ->
      file.read(path)
      |> result.map_error(fn(error) {
        case error {
          "enoent" -> ArtifactMissing(filename)
          other -> ArtifactInvalid(other)
        }
      })
  }
}

fn file_mtime(path: String) -> Result(Int, WorkerError) {
  runtime.modified_at_seconds(path)
  |> result.map_error(fn(error) {
    case error {
      "enoent" -> ArtifactMissing(path)
      other -> ArtifactInvalid(other)
    }
  })
}

fn is_plain_filename(filename: String) -> Bool {
  !string.contains(filename, "/")
  && !string.contains(filename, "\\")
  && !string.contains(filename, "..")
}

fn run_kind_actor(kind: run.RunKind) -> String {
  case kind {
    run.Execution -> "execution"
    run.ReviewWatch -> "review-watch"
    run.RegistrySync -> "registry-sync"
    run.MergeRun -> "merge"
  }
}

fn registry_status_role_text(role: lifecycle.RegistryStatusRole) -> String {
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

fn persist_review_cursor(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  observation: ReviewCommentObservation,
  observed_at: String,
) -> Result(state, WorkerError) {
  let updated = case
    backend.get_review_cursor(state, ticket_id, observation.pull_request_ref)
  {
    Ok(cursor) ->
      review_cursor.advance(cursor, observation.final_count, observed_at)
      |> result.map_error(CursorFailure)
    Error(store.NotFound(_)) ->
      review_cursor.validate(review_cursor.ReviewCommentCursor(
        ticket_id: ticket_id,
        pull_request_ref: observation.pull_request_ref,
        comment_count: int.max(
          observation.previous_count,
          observation.final_count,
        ),
        observed_at: observed_at,
      ))
      |> result.map_error(CursorFailure)
    Error(error) -> Error(StoreFailure(error))
  }
  use updated <- result.try(updated)
  backend.save_review_cursor(state, updated)
  |> result.map_error(StoreFailure)
}

fn has_actionable_feedback(artifact: ReviewCommentsArtifact) -> Bool {
  artifact.observations
  |> list.any(fn(observation) {
    observation.actionable_feedback && observation.new_comments != []
  })
}

fn decode_review_comments(
  source: String,
) -> Result(ReviewCommentsArtifact, WorkerError) {
  json.parse(source, review_comments_decoder())
  |> result.map_error(fn(error) { ArtifactInvalid(string.inspect(error)) })
}

fn review_comments_decoder() -> decode.Decoder(ReviewCommentsArtifact) {
  use version <- decode.field("schema_version", decode.int)
  use observations <- decode.field(
    "pull_requests",
    decode.list(of: review_comment_observation_decoder()),
  )
  case version {
    1 -> decode.success(ReviewCommentsArtifact(observations: observations))
    _ ->
      decode.failure(
        ReviewCommentsArtifact(observations: []),
        expected: "review comments schema version 1",
      )
  }
}

fn review_comment_observation_decoder() -> decode.Decoder(
  ReviewCommentObservation,
) {
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  use previous_count <- decode.field("previous_count", decode.int)
  use final_count <- decode.field("final_count", decode.int)
  use new_comments <- decode.field(
    "new_comments",
    decode.list(of: decode.string),
  )
  use actionable_feedback <- decode.field("actionable_feedback", decode.bool)
  case string.trim(pull_request_ref), previous_count >= 0, final_count >= 0 {
    "", _, _ ->
      decode.failure(
        invalid_observation(),
        expected: "non-empty pull request ref",
      )
    _, False, _ | _, _, False ->
      decode.failure(
        invalid_observation(),
        expected: "non-negative comment counts",
      )
    _, True, True ->
      decode.success(ReviewCommentObservation(
        pull_request_ref: pull_request_ref,
        previous_count: previous_count,
        final_count: final_count,
        new_comments: new_comments,
        actionable_feedback: actionable_feedback,
      ))
  }
}

fn invalid_observation() -> ReviewCommentObservation {
  ReviewCommentObservation(
    pull_request_ref: "",
    previous_count: 0,
    final_count: 0,
    new_comments: [],
    actionable_feedback: False,
  )
}

fn run_kind_text(kind: run.RunKind) -> String {
  case kind {
    run.Execution -> "execution"
    run.ReviewWatch -> "review_watch"
    run.RegistrySync -> "registry_sync"
    run.MergeRun -> "merge"
  }
}

fn run_status_text(status: run.RunStatus) -> String {
  case status {
    run.PreparingWorkspace -> "preparing_workspace"
    run.BuildingPrompt -> "building_prompt"
    run.LaunchingAgent -> "launching_agent"
    run.Streaming -> "streaming"
    run.CollectingArtifacts -> "collecting_artifacts"
    run.Succeeded -> "succeeded"
    run.Failed -> "failed"
    run.TimedOut -> "timed_out"
    run.Stalled -> "stalled"
    run.Canceled -> "canceled"
  }
}

fn usage_log_text(usage: Option(run.RunUsage)) -> String {
  case usage {
    None -> ""
    Some(usage) ->
      " usage_input_tokens="
      <> int.to_string(usage.input_tokens)
      <> " usage_cached_input_tokens="
      <> int.to_string(usage.cached_input_tokens)
      <> " usage_output_tokens="
      <> int.to_string(usage.output_tokens)
      <> " usage_reasoning_output_tokens="
      <> int.to_string(usage.reasoning_output_tokens)
      <> " usage_total_tokens="
      <> int.to_string(usage.total_tokens)
  }
}

pub fn error_text(error: WorkerError) -> String {
  case error {
    StoreFailure(inner) -> "store failure: " <> string.inspect(inner)
    CommandFailure(inner) -> "command failure: " <> string.inspect(inner)
    RunFailure(inner) -> "run failure: " <> string.inspect(inner)
    WorkspaceFailure(inner) -> "workspace failure: " <> string.inspect(inner)
    WorkpadFailure(inner) -> "workpad failure: " <> string.inspect(inner)
    HarnessFailure(inner) -> "harness failure: " <> string.inspect(inner)
    SessionNotFound(session_id) -> "session not found: " <> session_id
    ArtifactMissing(name) -> "missing artifact: " <> name
    ArtifactInvalid(reason) -> "invalid artifact: " <> reason
    CursorFailure(inner) -> "cursor failure: " <> string.inspect(inner)
  }
}
