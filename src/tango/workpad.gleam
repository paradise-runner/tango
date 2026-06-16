import gleam/json
import gleam/list
import gleam/result
import gleam/string
import tango/domain/artifact
import tango/domain/run
import tango/domain/session
import tango/store/file
import tango/workspace/workspace

pub type Workpad {
  Workpad(root_path: String, manifest_path: String, manifest: Manifest)
}

pub type Manifest {
  Manifest(
    schema_version: Int,
    ticket_id: String,
    session_id: String,
    session_role: String,
    context_session_ids: List(String),
    run_id: String,
    run_kind: String,
    workspace_path: String,
    repositories: List(ManifestRepository),
    allowed_output_filenames: List(String),
    required_artifacts: List(artifact.ArtifactKind),
  )
}

pub type ManifestRepository {
  ManifestRepository(binding_id: String, path: String)
}

pub type WorkpadError {
  CreateFailed(String)
}

pub fn create(
  state_dir: String,
  ticket_id: String,
  agent_session: session.AgentSession,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
) -> Result(Workpad, WorkpadError) {
  let root_path = join(join(join(state_dir, "workpads"), ticket_id), attempt.id)
  let manifest_path = join(root_path, "manifest.json")
  let manifest = manifest(ticket_id, agent_session, attempt, current_workspace)
  use _ <- result.try(
    file.atomic_replace(manifest_path, manifest_json(manifest))
    |> result.map_error(CreateFailed),
  )
  Ok(Workpad(
    root_path: root_path,
    manifest_path: manifest_path,
    manifest: manifest,
  ))
}

fn manifest(
  ticket_id: String,
  agent_session: session.AgentSession,
  attempt: run.RunAttempt,
  current_workspace: workspace.Workspace,
) -> Manifest {
  Manifest(
    schema_version: 1,
    ticket_id: ticket_id,
    session_id: agent_session.id,
    session_role: session_role_text(agent_session.role),
    context_session_ids: agent_session.context_session_ids,
    run_id: attempt.id,
    run_kind: run_kind_text(attempt.kind),
    workspace_path: current_workspace.root_path,
    repositories: current_workspace.repos
      |> list.map(fn(repo_info) {
        ManifestRepository(
          binding_id: repo_info.binding_id,
          path: repo_info.path,
        )
      }),
    allowed_output_filenames: allowed_output_filenames(attempt.kind),
    required_artifacts: required_artifacts(attempt.kind),
  )
}

fn manifest_json(manifest: Manifest) -> String {
  json.object([
    #("schema_version", json.int(manifest.schema_version)),
    #("ticket_id", json.string(manifest.ticket_id)),
    #("session_id", json.string(manifest.session_id)),
    #("session_role", json.string(manifest.session_role)),
    #(
      "context_session_ids",
      json.array(manifest.context_session_ids, json.string),
    ),
    #("run_id", json.string(manifest.run_id)),
    #("run_kind", json.string(manifest.run_kind)),
    #("workspace_path", json.string(manifest.workspace_path)),
    #(
      "repositories",
      json.array(manifest.repositories, fn(repo_info) {
        json.object([
          #("binding_id", json.string(repo_info.binding_id)),
          #("path", json.string(repo_info.path)),
        ])
      }),
    ),
    #(
      "allowed_output_filenames",
      json.array(manifest.allowed_output_filenames, json.string),
    ),
    #(
      "required_artifacts",
      json.array(manifest.required_artifacts, fn(kind) {
        json.string(artifact.kind_to_string(kind))
      }),
    ),
  ])
  |> json.to_string
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

fn required_artifacts(kind: run.RunKind) -> List(artifact.ArtifactKind) {
  case kind {
    run.Execution -> [
      artifact.NormalizedTicket,
      artifact.ResearchNotes,
      artifact.Plan,
      artifact.DiffSummary,
      artifact.ImplementationNotes,
      artifact.ValidationReport,
      artifact.PullRequestSet,
      artifact.ExternalUpdates,
    ]
    run.ReviewWatch -> [
      artifact.ReviewCommentsReport,
      artifact.ExternalUpdates,
    ]
    run.RegistrySync -> [artifact.ExternalUpdates]
    run.MergeRun -> [artifact.MergeReport, artifact.ExternalUpdates]
  }
}

fn session_role_text(role: session.SessionRole) -> String {
  case role {
    session.Main -> "main"
    session.Aux -> "aux"
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

fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/") {
    True -> left <> right
    False -> left <> "/" <> right
  }
}
