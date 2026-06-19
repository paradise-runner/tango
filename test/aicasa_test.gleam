import gleam/option.{None}
import gleeunit/should
import tango/domain/lifecycle
import tango/domain/repo
import tango/domain/ticket
import tango/process
import tango/store/file
import tango/workspace/aicasa
import tango/workspace/workspace

pub fn ensure_accepts_current_casa_inspect_schema_test() {
  let assert Ok(root) = file.temporary_directory("tango-aicasa-current")
  let command = fake_casa(root, current_casa_inspection_json())

  let result =
    aicasa.ensure(
      root,
      sample_ticket(),
      aicasa.AicasaConfig(command: command, root: root <> "/workspaces"),
    )

  result
  |> should.equal(
    Ok(
      workspace.Workspace(root_path: "/tmp/tango/workspaces/ticket-1", repos: [
        workspace.WorkspaceRepo(
          binding_id: "repo-1",
          source: "https://example.test/tango.git",
          path: "/tmp/tango/workspaces/ticket-1/tango",
        ),
      ]),
    ),
  )
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn ensure_accepts_legacy_workspace_root_schema_test() {
  let assert Ok(root) = file.temporary_directory("tango-aicasa-legacy")
  let command = fake_casa(root, legacy_casa_inspection_json())

  let result =
    aicasa.ensure(
      root,
      sample_ticket(),
      aicasa.AicasaConfig(command: command, root: root <> "/workspaces"),
    )

  result
  |> should.equal(
    Ok(
      workspace.Workspace(root_path: "/tmp/tango/workspaces/ticket-1", repos: [
        workspace.WorkspaceRepo(
          binding_id: "repo-1",
          source: "https://example.test/tango.git",
          path: "/tmp/tango/workspaces/ticket-1/tango",
        ),
      ]),
    ),
  )
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn ensure_rejects_missing_inspected_repositories_test() {
  let assert Ok(root) = file.temporary_directory("tango-aicasa-missing")
  let command = fake_casa(root, missing_repository_inspection_json())

  let result =
    aicasa.ensure(
      root,
      sample_ticket(),
      aicasa.AicasaConfig(command: command, root: root <> "/workspaces"),
    )

  result
  |> should.equal(Error(workspace.ProvisionFailed("invalid casa inspect JSON")))
  file.remove_tree(root)
  |> should.be_ok()
}

fn fake_casa(root: String, output: String) -> String {
  let command = root <> "/fake-casa"
  let script = "#!/bin/sh\ncat <<'JSON'\n" <> output <> "\nJSON\n"
  let assert Ok(_) = file.atomic_replace(command, script)
  let assert Ok(result) =
    process.run_command("chmod", ["755", command], [], None)
  result.exit_code
  |> should.equal(0)
  command
}

fn current_casa_inspection_json() -> String {
  "{"
  <> "\"schema_version\":1,"
  <> "\"name\":\"ticket-1\","
  <> "\"path\":\"/tmp/tango/workspaces/ticket-1\","
  <> "\"metadata_path\":\"/tmp/tango/workspaces/ticket-1/.aicasa.json\","
  <> "\"metadata_present\":true,"
  <> "\"repositories\":[{"
  <> "\"directory\":\"tango\","
  <> "\"source\":\"https://example.test/tango.git\","
  <> "\"path\":\"/tmp/tango/workspaces/ticket-1/tango\","
  <> "\"exists\":true"
  <> "}]"
  <> "}"
}

fn legacy_casa_inspection_json() -> String {
  "{"
  <> "\"schema_version\":1,"
  <> "\"workspace_root\":\"/tmp/tango/workspaces/ticket-1\","
  <> "\"repositories\":[{"
  <> "\"path\":\"/tmp/tango/workspaces/ticket-1/tango\""
  <> "}]"
  <> "}"
}

fn missing_repository_inspection_json() -> String {
  "{"
  <> "\"schema_version\":1,"
  <> "\"path\":\"/tmp/tango/workspaces/ticket-1\","
  <> "\"repositories\":[{"
  <> "\"directory\":\"tango\","
  <> "\"path\":\"/tmp/tango/workspaces/ticket-1/tango\","
  <> "\"exists\":false"
  <> "}]"
  <> "}"
}

fn sample_ticket() -> ticket.Ticket {
  ticket.Ticket(
    id: "ticket-1",
    identifier: "TANGO-1",
    title: None,
    priority: None,
    labels: [],
    lifecycle_policy: None,
    state: lifecycle.Queued,
    repo_bindings: [
      repo.RepoBinding(
        id: "repo-1",
        name: "tango",
        kind: repo.GitRemote,
        location: "https://example.test/tango.git",
        default_branch: None,
        base_ref: None,
        target_branch: None,
        work_branch: None,
        checkout_policy: repo.Clone,
      ),
    ],
    external_ref: None,
    registry_binding: None,
    registry_status_mapping: None,
    forge_binding: None,
    observed_external_status_id: None,
    capability_profile_digest: None,
    main_session_id: None,
    aux_session_ids: [],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: False,
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}
