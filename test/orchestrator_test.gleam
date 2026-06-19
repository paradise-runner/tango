import fixtures
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import tango/agent/adapter
import tango/attestation/adapter as attestation
import tango/domain/artifact
import tango/domain/lifecycle
import tango/domain/repo
import tango/domain/review
import tango/domain/review_cursor
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/git/adapter as git
import tango/orchestrator
import tango/review_watcher
import tango/runtime
import tango/store/file
import tango/store/json_store
import tango/store_server
import tango/worker
import tango/worker_supervisor
import tango/workspace/workspace

pub fn orchestrator_dispatches_queued_ticket_under_worker_supervision_test() {
  let assert Ok(root) = file.temporary_directory("tango-orchestrator")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, queued_ticket())
  let dependencies =
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
        let run_id = workpad_run_id(request.workpad_path)
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/ticket.json",
            "{\"schema_version\":1,\"external_ref\":\"TANGO-1\",\"title\":\"Dispatch me\",\"description_revision\":\"rev-1\",\"description\":\"Dispatch me\",\"acceptance_criteria\":[\"done\"],\"labels\":[],\"blockers\":[],\"tango_todo\":{\"section_present\":false,\"items\":[]},\"observed_external_status_id\":\"todo\"}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/research.md",
            "# Research\n",
          )
        let assert Ok(_) =
          file.atomic_replace(request.workpad_path <> "/plan.md", "# Plan\n")
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/diff-summary.md",
            "# Diff Summary\n",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/implementation.md",
            "# Implementation\n",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/validation.json",
            "{\"schema_version\":1,\"checks\":[{\"name\":\"test\",\"status\":\"passed\",\"summary\":\"ok\"}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/pull-requests.json",
            "{\"schema_version\":1,\"pull_requests\":[]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"requested_role\":\"human_review\",\"requested_status\":{\"id\":\"review\",\"name\":\"Review\"},\"observed_status\":{\"id\":\"review\",\"name\":\"Review\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\""
              <> run_id
              <> "\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"normalized_ticket\":\"ticket.json\",\"research_notes\":\"research.md\",\"plan\":\"plan.md\",\"diff_summary\":\"diff-summary.md\",\"implementation_notes\":\"implementation.md\",\"validation_report\":\"validation.json\",\"pull_request_set\":\"pull-requests.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "complete",
          runtime_session_id: Some("runtime-session"),
          usage: None,
        ))
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  let assert [attempt] = runs
  attempt.status
  |> should.equal(run.Succeeded)
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.AwaitingHumanReview)

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn orchestrator_dispatches_review_watch_ticket_test() {
  let assert Ok(root) = file.temporary_directory("tango-orchestrator-review")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, awaiting_review_ticket())
  let assert Ok(_) = backend.save_review_cursor(state, initial_review_cursor())
  let assert Ok(_) =
    backend.save_artifact(state, merge_pull_request_set_artifact())
  let passthrough = attestation.passthrough()
  let dependencies =
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
      attestation: attestation.Adapters(
        ticket_system: passthrough.ticket_system,
        forge: attestation.ForgeAdapter(
          read: passthrough.forge.read,
          read_comments: fn(request) {
            Ok(attestation.PullRequestCommentsSnapshot(
              pull_request_ref: request.pull_request_ref,
              comments: ["old", "needs changes"],
              final_comment_count: 2,
            ))
          },
        ),
      ),
      agent: adapter.AgentAdapter(run: fn(request) {
        let run_id = workpad_run_id(request.workpad_path)
        let artifact =
          "{\"schema_version\":1,\"pull_requests\":[{\"pull_request_ref\":\"https://example.test/pr/1\",\"previous_count\":1,\"final_count\":2,\"new_comments\":[\"needs changes\"],\"actionable_feedback\":true}]}"
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/review-comments.json",
            artifact,
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"requested_role\":\"done\",\"requested_status\":{\"id\":\"done\",\"name\":\"Done\"},\"observed_status\":{\"id\":\"done\",\"name\":\"Done\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\""
              <> run_id
              <> "\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"review_comments_report\":\"review-comments.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "complete",
          runtime_session_id: Some("runtime-review"),
          usage: None,
        ))
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  let assert Ok(watcher_started) =
    review_watcher.start(
      root,
      store_server_name,
      review_watcher.Dependencies(
        workspace: dependencies.workspace,
        forge: dependencies.attestation.forge,
      ),
      60_000,
      process.named_subject(orchestrator_name),
      orchestrator.ReviewWatchDue,
    )
  process.unlink(watcher_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  runs
  |> list.any(fn(attempt) {
    attempt.kind == run.ReviewWatch && attempt.status == run.Succeeded
  })
  |> should.be_true()
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.ChangesRequested)

  process.kill(watcher_started.pid)
  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn review_watcher_skips_agent_when_comment_count_is_unchanged_test() {
  let assert Ok(root) =
    file.temporary_directory("tango-orchestrator-review-skip")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, awaiting_review_ticket())
  let assert Ok(_) = backend.save_review_cursor(state, initial_review_cursor())
  let assert Ok(_) =
    backend.save_artifact(state, merge_pull_request_set_artifact())
  let passthrough = attestation.passthrough()
  let dependencies =
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
        ticket_system: passthrough.ticket_system,
        forge: attestation.ForgeAdapter(
          read: passthrough.forge.read,
          read_comments: fn(request) {
            Ok(attestation.PullRequestCommentsSnapshot(
              pull_request_ref: request.pull_request_ref,
              comments: ["old"],
              final_comment_count: 1,
            ))
          },
        ),
      ),
      agent: adapter.AgentAdapter(run: fn(_) {
        panic as "unchanged PR comments must not start a review agent"
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  let assert Ok(watcher_started) =
    review_watcher.start(
      root,
      store_server_name,
      review_watcher.Dependencies(
        workspace: dependencies.workspace,
        forge: dependencies.attestation.forge,
      ),
      60_000,
      process.named_subject(orchestrator_name),
      orchestrator.ReviewWatchDue,
    )
  process.unlink(watcher_started.pid)
  process.sleep(250)

  backend.list_runs(state, "ticket-1")
  |> should.equal(Ok([]))
  let assert Ok(cursor) =
    backend.get_review_cursor(state, "ticket-1", "https://example.test/pr/1")
  cursor.comment_count
  |> should.equal(1)

  process.kill(watcher_started.pid)
  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn orchestrator_dispatches_merge_ticket_test() {
  let assert Ok(root) = file.temporary_directory("tango-orchestrator-merge")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, merging_ticket())
  let assert Ok(_) = backend.save_session(state, merge_session())
  let assert Ok(_) =
    backend.save_artifact(state, merge_pull_request_set_artifact())
  let dependencies =
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
        let run_id = workpad_run_id(request.workpad_path)
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
            "{\"schema_version\":1,\"run_id\":\""
              <> run_id
              <> "\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"merge_report\":\"merge.json\",\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "merged",
          runtime_session_id: Some("runtime-merge"),
          usage: None,
        ))
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(100)

  backend.list_runs(state, "ticket-1")
  |> should.equal(Ok([]))
  let assert Ok(_) =
    store_server.store().save_review(store_server_name, merge_review())
  process.send(process.named_subject(orchestrator_name), orchestrator.Tick)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  runs
  |> list.any(fn(attempt) {
    attempt.kind == run.MergeRun && attempt.status == run.Succeeded
  })
  |> should.be_true()
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.Done)

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn orchestrator_dispatches_registry_sync_for_pending_review_status_test() {
  let assert Ok(root) = file.temporary_directory("tango-orchestrator-registry")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) =
    backend.save_ticket(
      state,
      ticket.Ticket(
        ..awaiting_review_ticket(),
        observed_external_status_id: Some("todo"),
      ),
    )
  let dependencies =
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
        let run_id = workpad_run_id(request.workpad_path)
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/external-updates.json",
            "{\"schema_version\":1,\"updates\":[{\"kind\":\"status_sync\",\"external_ticket_ref\":\"TANGO-1\",\"requested_role\":\"human_review\",\"requested_status\":{\"id\":\"review\",\"name\":\"Review\"},\"observed_status\":{\"id\":\"review\",\"name\":\"Review\"}}]}",
          )
        let assert Ok(_) =
          file.atomic_replace(
            request.workpad_path <> "/result.json",
            "{\"schema_version\":1,\"run_id\":\""
              <> run_id
              <> "\",\"status\":\"succeeded\",\"completed_at\":\"2026-06-07T00:10:00Z\",\"artifacts\":{\"external_updates\":\"external-updates.json\"},\"block\":null}",
          )
        Ok(adapter.AgentResponse(
          exit_code: 0,
          output: "registry synchronized",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  let assert [attempt] = runs
  attempt.kind
  |> should.equal(run.RegistrySync)
  attempt.status
  |> should.equal(run.Succeeded)
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.observed_external_status_id
  |> should.equal(Some("review"))

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn orchestrator_restores_failed_execution_for_polled_retry_test() {
  let assert Ok(root) = file.temporary_directory("tango-orchestrator-retry")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, queued_ticket())
  let dependencies =
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
          exit_code: 1,
          output: "agent failed",
          runtime_session_id: None,
          usage: None,
        ))
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  let assert [attempt] = runs
  attempt.status
  |> should.equal(run.Failed)
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.Queued)

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn orchestrator_records_worker_start_failure_reason_test() {
  let assert Ok(root) =
    file.temporary_directory("tango-orchestrator-worker-failure")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, queued_ticket())
  let dependencies =
    worker.WorkerDependencies(
      workspace: workspace.WorkspaceAdapter(ensure: fn(_, _) {
        Error(workspace.ProvisionFailed("executable not found: casa"))
      }),
      git: git.passthrough(),
      attestation: attestation.passthrough(),
      agent: adapter.AgentAdapter(run: fn(_) {
        panic as "agent should not launch when workspace provisioning fails"
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  let assert [attempt] = runs
  attempt.status
  |> should.equal(run.Failed)
  let assert Some(error) = attempt.error
  error
  |> string.contains("workspace failure")
  |> should.be_true()
  error
  |> string.contains("executable not found: casa")
  |> should.be_true()
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.Queued)

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn orchestrator_records_worker_crash_after_streaming_test() {
  let assert Ok(root) =
    file.temporary_directory("tango-orchestrator-worker-crash")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let assert Ok(_) = backend.save_ticket(state, queued_ticket())
  let dependencies =
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
        panic as "agent crashed after streaming"
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  let assert [attempt] = runs
  attempt.status
  |> should.equal(run.Failed)
  let assert Some(error) = attempt.error
  error
  |> string.contains("worker crashed")
  |> should.be_true()
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.Queued)

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn changes_requested_dispatches_fresh_contextual_implementation_session_test() {
  let assert Ok(root) =
    file.temporary_directory("tango-orchestrator-requested-changes")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let backend = json_store.store()
  let state = json_store.new(root)
  let changed =
    ticket.Ticket(
      ..queued_ticket(),
      state: lifecycle.ChangesRequested,
      main_session_id: Some("main"),
    )
  let prior_session =
    session.AgentSession(
      id: "main",
      ticket_id: "ticket-1",
      role: session.Main,
      kind: session.Implementation,
      context_session_ids: [],
      runtime_session_id: Some("runtime-main"),
      run_attempt_ids: ["prior-run"],
      created_at: "2026-06-07T00:00:00Z",
      updated_at: "2026-06-07T00:01:00Z",
    )
  let prior_artifact =
    artifact.ArtifactRecord(
      id: "prior-implementation",
      ticket_id: "ticket-1",
      run_id: "prior-run",
      kind: artifact.ImplementationNotes,
      filename: "implementation.md",
      content_type: "text/markdown",
      sha256: "sha",
      content: "Prior implementation context",
      created_at: "2026-06-07T00:01:00Z",
    )
  let assert Ok(_) = backend.save_ticket(state, changed)
  let assert Ok(_) = backend.save_session(state, prior_session)
  let assert Ok(_) = backend.save_artifact(state, prior_artifact)
  let dependencies =
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
        request.resume_session_id
        |> should.equal(None)
        request.prompt
        |> string.contains("context_session_ids: main")
        |> should.be_true()
        request.prompt
        |> string.contains("Prior implementation context")
        |> should.be_true()
        request.prompt
        |> string.contains("effective_capabilities: workspace_write")
        |> should.be_true()
        request.prompt
        |> string.contains("# External Ticket Work Protocol")
        |> should.be_true()
        request.prompt
        |> string.contains("respond to requested changes")
        |> should.be_true()
        request.prompt
        |> string.contains("TODO/comment entries are observability-only")
        |> should.be_true()
        Ok(adapter.AgentResponse(
          exit_code: 1,
          output: "stop after prompt inspection",
          runtime_session_id: Some("must-not-be-reused"),
          usage: None,
        ))
      }),
    )

  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let assert Ok(store_started) = store_server.start(store_server_name, root)
  process.unlink(store_started.pid)
  let assert Ok(worker_started) =
    worker_supervisor.start(worker_supervisor_name)
  process.unlink(worker_started.pid)
  let orchestrator_name = orchestrator.new_name()
  let assert Ok(orchestrator_started) =
    orchestrator.start(
      orchestrator_name,
      root,
      store_server_name,
      dependencies,
      1,
      60_000,
      worker_supervisor_name,
    )
  process.unlink(orchestrator_started.pid)
  process.sleep(250)

  let assert Ok(runs) = backend.list_runs(state, "ticket-1")
  let assert [attempt] = runs
  attempt.session_id
  |> should.not_equal("main")
  let assert Ok(aux) =
    backend.get_session(state, "ticket-1", attempt.session_id)
  aux.role
  |> should.equal(session.Aux)
  aux.kind
  |> should.equal(session.Implementation)
  aux.context_session_ids
  |> should.equal(["main"])
  let assert Ok(item) = backend.get_ticket(state, "ticket-1")
  item.state
  |> should.equal(lifecycle.ChangesRequested)

  process.kill(orchestrator_started.pid)
  process.kill(worker_started.pid)
  process.kill(store_started.pid)
  file.remove_tree(root)
  |> should.be_ok()
}

fn queued_ticket() -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: Some("Dispatch me"),
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
    main_session_id: None,
    aux_session_ids: [],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: False,
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

fn awaiting_review_ticket() -> ticket.Ticket {
  ticket.Ticket(
    ..queued_ticket(),
    state: lifecycle.AwaitingHumanReview,
    observed_external_status_id: Some("review"),
    aux_session_ids: [],
  )
}

fn merging_ticket() -> ticket.Ticket {
  ticket.Ticket(..queued_ticket(), state: lifecycle.Merging, aux_session_ids: [
    "merge-session",
  ])
}

fn initial_review_cursor() -> review_cursor.ReviewCommentCursor {
  review_cursor.ReviewCommentCursor(
    ticket_id: "ticket-1",
    pull_request_ref: "https://example.test/pr/1",
    comment_count: 1,
    observed_at: "2026-06-07T00:00:00Z",
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

fn merge_pull_request_set_artifact() -> artifact.ArtifactRecord {
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

fn workpad_run_id(workpad_path: String) -> String {
  let assert Ok(contents) = file.read(workpad_path <> "/manifest.json")
  let assert [_, run_and_rest, ..] = string.split(contents, "\"run_id\":\"")
  let assert [run_id, ..] = string.split(run_and_rest, "\"")
  run_id
}
