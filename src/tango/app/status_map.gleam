import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/config
import tango/domain/registry_status
import tango/process

pub type CommandRunner =
  fn(String, List(String)) -> Result(process.CommandResult, String)

pub type StatusMapView {
  StatusMapView(
    name: String,
    provider_kind: String,
    validated: Bool,
    statuses: List(#(String, String)),
  )
}

pub type StatusMapError {
  ConfigFailure(config.ConfigError)
  MissingRepository(String)
  UnsupportedProvider(String)
  CommandFailed(String)
  InvalidDiscovery(String)
  MissingRole(String)
  MissingMappedStatus(String, String)
}

pub fn show(
  operator_config: config.Config,
  name: String,
) -> Result(StatusMapView, StatusMapError) {
  use registry <- result.try(
    config.get_registry(operator_config, name)
    |> result.map_error(ConfigFailure),
  )
  Ok(StatusMapView(
    name: name,
    provider_kind: config.provider_status_kind(name),
    validated: registry.status_map_validated,
    statuses: sorted_role_statuses(registry.statuses),
  ))
}

pub fn set(
  operator_config: config.Config,
  name: String,
  role: String,
  status_id: String,
) -> Result(config.Config, StatusMapError) {
  config.update_registry_status(operator_config, name, role, status_id)
  |> result.map_error(ConfigFailure)
}

pub fn discover(
  operator_config: config.Config,
  name: String,
  repository: Option(String),
  run: CommandRunner,
) -> Result(List(registry_status.ExternalStatus), StatusMapError) {
  use registry <- result.try(
    config.get_registry(operator_config, name)
    |> result.map_error(ConfigFailure),
  )
  case name {
    "github" -> discover_github(registry, name, repository, run)
    "forgejo" -> discover_forgejo_configured(registry, name, repository, run)
    _ -> Error(UnsupportedProvider(name))
  }
}

pub fn validate(
  operator_config: config.Config,
  name: String,
  repository: Option(String),
  run: CommandRunner,
) -> Result(
  #(config.Config, List(registry_status.ExternalStatus)),
  StatusMapError,
) {
  use registry <- result.try(
    config.get_registry(operator_config, name)
    |> result.map_error(ConfigFailure),
  )
  use _ <- result.try(
    config.required_status_roles()
    |> list.try_each(fn(role) {
      case dict.get(registry.statuses, role) {
        Ok(_) -> Ok(Nil)
        Error(_) -> Error(MissingRole(role))
      }
    }),
  )
  use discovered <- result.try(discover(operator_config, name, repository, run))
  use _ <- result.try(
    registry.statuses
    |> dict.to_list
    |> list.try_each(fn(entry) {
      let #(role, status_id) = entry
      case list.any(discovered, fn(status) { status.id == status_id }) {
        True -> Ok(Nil)
        False -> Error(MissingMappedStatus(role, status_id))
      }
    }),
  )
  use updated <- result.try(
    config.mark_registry_status_map_validated(operator_config, name, True)
    |> result.map_error(ConfigFailure),
  )
  Ok(#(updated, discovered))
}

fn discover_github(
  registry: config.RegistryConfig,
  name: String,
  repository: Option(String),
  run: CommandRunner,
) -> Result(List(registry_status.ExternalStatus), StatusMapError) {
  use repo <- result.try(required_repository(name, repository))
  use response <- result.try(
    run_success(run, registry.cli, [
      "label",
      "list",
      "--repo",
      repo,
      "--json",
      "name",
      "--limit",
      "500",
    ]),
  )
  json.parse(response.output, github_labels_decoder())
  |> result.map(sort_statuses)
  |> result.map_error(fn(error) {
    InvalidDiscovery("invalid GitHub label response: " <> string.inspect(error))
  })
}

fn discover_forgejo_configured(
  registry: config.RegistryConfig,
  name: String,
  repository: Option(String),
  run: CommandRunner,
) -> Result(List(registry_status.ExternalStatus), StatusMapError) {
  use repo <- result.try(required_repository(name, repository))
  registry.statuses
  |> dict.to_list
  |> list.try_map(fn(entry) {
    let #(_, status_id) = entry
    use _ <- result.try(
      run_success(run, registry.cli, [
        "--style",
        "minimal",
        "issue",
        "search",
        "--repo",
        repo,
        "--labels",
        status_id,
        "--state",
        "all",
      ]),
    )
    Ok(registry_status.ExternalStatus(id: status_id, name: status_id))
  })
  |> result.map(dedupe_statuses)
}

fn required_repository(
  name: String,
  repository: Option(String),
) -> Result(String, StatusMapError) {
  case repository {
    Some(value) ->
      case string.trim(value) {
        "" -> Error(MissingRepository(name))
        value -> Ok(value)
      }
    None -> Error(MissingRepository(name))
  }
}

fn run_success(
  run: CommandRunner,
  command: String,
  args: List(String),
) -> Result(process.CommandResult, StatusMapError) {
  use response <- result.try(
    run(command, args) |> result.map_error(CommandFailed),
  )
  case response.exit_code {
    0 -> Ok(response)
    _ -> Error(CommandFailed(response.output))
  }
}

fn github_labels_decoder() -> decode.Decoder(
  List(registry_status.ExternalStatus),
) {
  decode.list(of: github_label_decoder())
}

fn github_label_decoder() -> decode.Decoder(registry_status.ExternalStatus) {
  use name <- decode.field("name", decode.string)
  decode.success(registry_status.ExternalStatus(id: name, name: name))
}

fn sorted_role_statuses(statuses) -> List(#(String, String)) {
  statuses
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
}

fn sort_statuses(
  statuses: List(registry_status.ExternalStatus),
) -> List(registry_status.ExternalStatus) {
  statuses
  |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
}

fn dedupe_statuses(
  statuses: List(registry_status.ExternalStatus),
) -> List(registry_status.ExternalStatus) {
  statuses
  |> sort_statuses
  |> list.fold([], fn(acc: List(registry_status.ExternalStatus), status) {
    case list.any(acc, fn(existing) { existing.id == status.id }) {
      True -> acc
      False -> list.append(acc, [status])
    }
  })
}
