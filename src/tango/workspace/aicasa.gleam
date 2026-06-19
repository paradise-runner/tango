import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import tango/domain/repo
import tango/domain/ticket
import tango/process
import tango/workspace/workspace

pub type AicasaConfig {
  AicasaConfig(command: String, root: String)
}

pub fn adapter(config: AicasaConfig) -> workspace.WorkspaceAdapter {
  workspace.WorkspaceAdapter(ensure: fn(state_dir, item) {
    ensure(state_dir, item, config)
  })
}

pub fn ensure(
  _state_dir: String,
  item: ticket.Ticket,
  config: AicasaConfig,
) -> Result(workspace.Workspace, workspace.WorkspaceError) {
  let root = config.root
  let name = workspace_name(item.id)
  let provisioned = case inspect_workspace(root, name, config) {
    Ok(current) ->
      ensure_missing_repositories(root, name, item, current, config)
    Error(_) -> {
      use _ <- result.try(run_new(root, name, item.repo_bindings, config))
      inspect_workspace(root, name, config)
    }
  }
  use provisioned <- result.try(provisioned)
  bind_repositories(provisioned, item.repo_bindings)
}

fn ensure_missing_repositories(
  root: String,
  name: String,
  item: ticket.Ticket,
  current: workspace.Workspace,
  config: AicasaConfig,
) -> Result(workspace.Workspace, workspace.WorkspaceError) {
  let existing_names =
    current.repos |> list.map(fn(repo_info) { basename(repo_info.path) })
  let missing =
    item.repo_bindings
    |> list.filter(fn(binding) {
      !list.contains(existing_names, repo.checkout_name(binding.location))
    })

  case missing {
    [] -> Ok(current)
    _ -> {
      use _ <- result.try(run_add(root, name, missing, config))
      inspect_workspace(root, name, config)
    }
  }
}

fn inspect_workspace(
  root: String,
  name: String,
  config: AicasaConfig,
) -> Result(workspace.Workspace, workspace.WorkspaceError) {
  use command_result <- result.try(
    process.run_command(
      config.command,
      ["inspect", name],
      [#("AICASA_ROOT", root)],
      None,
    )
    |> result.map_error(workspace.ProvisionFailed),
  )
  case command_result.exit_code {
    0 -> decode_workspace(command_result.output)
    _ -> Error(workspace.ProvisionFailed(command_result.output))
  }
}

fn run_new(
  root: String,
  name: String,
  bindings: List(repo.RepoBinding),
  config: AicasaConfig,
) -> Result(Nil, workspace.WorkspaceError) {
  let sources =
    bindings
    |> list.map(fn(binding) { binding.location })
    |> string.join(with: ",")

  use command_result <- result.try(
    process.run_command(
      config.command,
      ["new", name, sources],
      [#("AICASA_ROOT", root)],
      None,
    )
    |> result.map_error(workspace.ProvisionFailed),
  )
  case command_result.exit_code {
    0 -> Ok(Nil)
    _ -> Error(workspace.ProvisionFailed(command_result.output))
  }
}

fn run_add(
  root: String,
  name: String,
  bindings: List(repo.RepoBinding),
  config: AicasaConfig,
) -> Result(Nil, workspace.WorkspaceError) {
  let sources =
    bindings
    |> list.map(fn(binding) { binding.location })
    |> string.join(with: ",")

  use command_result <- result.try(
    process.run_command(
      config.command,
      ["add", name, sources],
      [#("AICASA_ROOT", root)],
      None,
    )
    |> result.map_error(workspace.ProvisionFailed),
  )
  case command_result.exit_code {
    0 -> Ok(Nil)
    _ -> Error(workspace.ProvisionFailed(command_result.output))
  }
}

pub fn workspace_name(ticket_id: String) -> String {
  slug(ticket_id) <> "-" <> process.stable_hash(ticket_id)
}

fn decode_workspace(
  source: String,
) -> Result(workspace.Workspace, workspace.WorkspaceError) {
  case json.parse(source, workspace_decoder()) {
    Ok(decoded) -> Ok(decoded)
    Error(_) -> Error(workspace.ProvisionFailed("invalid casa inspect JSON"))
  }
}

fn workspace_decoder() -> decode.Decoder(workspace.Workspace) {
  use schema_version <- decode.field("schema_version", decode.int)
  use root_path <- decode.then(workspace_root_decoder())
  use repos <- decode.field("repositories", decode.list(of: repo_decoder()))
  case schema_version {
    1 -> decode.success(workspace.Workspace(root_path: root_path, repos: repos))
    _ ->
      decode.failure(
        workspace.Workspace(root_path: "", repos: []),
        expected: "casa inspect schema version 1",
      )
  }
}

fn workspace_root_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.at(["path"], decode.string), or: [
    decode.at(["workspace_root"], decode.string),
  ])
}

fn repo_decoder() -> decode.Decoder(workspace.WorkspaceRepo) {
  use path <- decode.field("path", decode.string)
  use directory <- decode.optional_field(
    "directory",
    basename(path),
    decode.string,
  )
  use exists <- decode.optional_field("exists", True, decode.bool)
  let binding_id = case string.trim(directory) {
    "" -> basename(path)
    _ -> directory
  }
  let repo =
    workspace.WorkspaceRepo(binding_id: binding_id, source: "", path: path)
  case exists {
    True -> decode.success(repo)
    False -> decode.failure(repo, expected: "existing casa repository")
  }
}

fn bind_repositories(
  current: workspace.Workspace,
  bindings: List(repo.RepoBinding),
) -> Result(workspace.Workspace, workspace.WorkspaceError) {
  use repos <- result.try(
    current.repos
    |> list.try_map(fn(repo_info) {
      let checkout_name = basename(repo_info.path)
      use binding <- result.try(
        bindings
        |> list.find(fn(binding) {
          repo.checkout_name(binding.location) == checkout_name
        })
        |> result.map_error(fn(_) {
          workspace.ProvisionFailed(
            "aicasa repository does not match a ticket binding: "
            <> checkout_name,
          )
        }),
      )
      Ok(workspace.WorkspaceRepo(
        binding_id: binding.id,
        source: binding.location,
        path: repo_info.path,
      ))
    }),
  )
  Ok(workspace.Workspace(..current, repos: repos))
}

fn basename(path: String) -> String {
  path |> string.split("/") |> list.last |> result.unwrap(path)
}

fn slug(value: String) -> String {
  value
  |> string.lowercase
  |> string.replace("/", "-")
  |> string.replace(" ", "-")
  |> string.replace("_", "-")
}
