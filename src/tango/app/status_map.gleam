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

pub type AutomatchView {
  AutomatchView(
    name: String,
    provider_kind: String,
    matched: List(#(String, String)),
    unmatched_roles: List(String),
    ambiguous_roles: List(#(String, List(String))),
    discovered: List(registry_status.ExternalStatus),
  )
}

pub type StatusMapError {
  ConfigFailure(config.ConfigError)
  MissingRepository(String)
  UnsupportedProvider(String)
  CommandFailed(String)
  InvalidDiscovery(String)
  MissingRole(String)
  MissingRoles(List(String))
  MissingMappedStatus(String, String)
  MissingMappedStatuses(List(#(String, String)))
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
  let missing_roles =
    config.required_status_roles()
    |> list.filter(fn(role) {
      case dict.get(registry.statuses, role) {
        Ok(_) -> False
        Error(_) -> True
      }
    })
  use _ <- result.try(case missing_roles {
    [] -> Ok(Nil)
    missing -> Error(MissingRoles(missing))
  })

  use discovered <- result.try(discover(operator_config, name, repository, run))
  let missing_mapped_statuses =
    registry.statuses
    |> dict.to_list
    |> list.filter(fn(entry) {
      let #(_, status_id) = entry
      case list.any(discovered, fn(status) { status.id == status_id }) {
        True -> False
        False -> True
      }
    })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  use _ <- result.try(case missing_mapped_statuses {
    [] -> Ok(Nil)
    missing -> Error(MissingMappedStatuses(missing))
  })

  use updated <- result.try(
    config.mark_registry_status_map_validated(operator_config, name, True)
    |> result.map_error(ConfigFailure),
  )
  Ok(#(updated, discovered))
}

pub fn automatch(
  operator_config: config.Config,
  name: String,
  repository: Option(String),
  run: CommandRunner,
) -> Result(#(config.Config, AutomatchView), StatusMapError) {
  use registry <- result.try(
    config.get_registry(operator_config, name)
    |> result.map_error(ConfigFailure),
  )
  use discovered <- result.try(discover(operator_config, name, repository, run))
  let attempts =
    config.required_status_roles()
    |> list.map(fn(role) {
      #(role, automatch_candidates_for(name, role, discovered))
    })

  let matched =
    attempts
    |> list.filter_map(fn(attempt) {
      case attempt {
        #(role, [status]) -> Ok(#(role, status.id))
        _ -> Error(Nil)
      }
    })

  let unmatched =
    attempts
    |> list.filter_map(fn(attempt) {
      case attempt {
        #(role, []) -> Ok(role)
        _ -> Error(Nil)
      }
    })

  let ambiguous =
    attempts
    |> list.filter_map(fn(attempt) {
      case attempt {
        #(role, candidates) ->
          case candidates {
            [_, _, ..] ->
              Ok(#(role, candidates |> list.map(fn(status) { status.id })))
            _ -> Error(Nil)
          }
      }
    })

  let updated_statuses =
    matched
    |> list.fold(registry.statuses, fn(statuses, match) {
      let #(role, status_id) = match
      dict.insert(statuses, role, status_id)
    })

  let updated_registry =
    config.RegistryConfig(
      ..registry,
      statuses: updated_statuses,
      status_map_validated: False,
    )
  let updated_config =
    config.Config(
      ..operator_config,
      registries: dict.insert(
        operator_config.registries,
        name,
        updated_registry,
      ),
    )

  Ok(#(
    updated_config,
    AutomatchView(
      name: name,
      provider_kind: config.provider_status_kind(name),
      matched: matched,
      unmatched_roles: unmatched,
      ambiguous_roles: ambiguous,
      discovered: discovered,
    ),
  ))
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
  |> result.map(with_github_closed_status)
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

fn with_github_closed_status(
  statuses: List(registry_status.ExternalStatus),
) -> List(registry_status.ExternalStatus) {
  [
    registry_status.ExternalStatus(id: "closed", name: "Closed issue state"),
    ..statuses
    |> list.filter(fn(status) { status.id != "closed" })
  ]
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

fn automatch_candidates_for(
  provider: String,
  role: String,
  statuses: List(registry_status.ExternalStatus),
) -> List(registry_status.ExternalStatus) {
  case provider, role {
    "github", "done" ->
      statuses
      |> list.filter(fn(status) { status.id == "closed" })
      |> sort_statuses
    _, _ -> automatch_candidates(role, statuses)
  }
}

fn automatch_candidates(
  role: String,
  statuses: List(registry_status.ExternalStatus),
) -> List(registry_status.ExternalStatus) {
  statuses
  |> list.filter(fn(status) {
    let aliases = role_aliases(role)
    list.contains(aliases, normalize(status.id))
    || list.contains(aliases, normalize(status.name))
  })
  |> sort_statuses
}

fn normalize(value: String) -> String {
  value
  |> string.lowercase
  |> string.replace("-", "_")
  |> string.replace(" ", "_")
  |> string.replace(":", "_")
  |> string.replace("/", "_")
  |> string.replace(".", "_")
  |> string.replace("'", "")
  |> string.replace("__", "_")
}

fn role_aliases(role: String) -> List(String) {
  case role {
    "backlog" -> ["backlog", "status_backlog", "tango_backlog"]
    "todo" -> ["todo", "to_do", "status_todo", "status_to_do", "tango_todo"]
    "in_progress" -> [
      "in_progress",
      "active",
      "doing",
      "status_in_progress",
      "status_active",
      "tango_in_progress",
    ]
    "human_review" -> [
      "human_review",
      "review",
      "in_review",
      "needs_review",
      "status_human_review",
      "status_review",
      "status_in_review",
      "tango_human_review",
    ]
    "merging" -> [
      "merging",
      "merge",
      "review",
      "in_review",
      "status_merging",
      "status_merge",
      "status_review",
      "status_in_review",
      "tango_merging",
    ]
    "blocked" -> [
      "blocked",
      "status_blocked",
      "tango_blocked",
    ]
    "done" -> [
      "done",
      "closed",
      "complete",
      "completed",
      "status_done",
      "status_closed",
      "status_complete",
      "status_completed",
      "tango_done",
    ]
    "wont_do" -> [
      "wont_do",
      "wontdo",
      "wont_fix",
      "wontfix",
      "canceled",
      "cancelled",
      "status_wont_do",
      "status_wontfix",
      "status_canceled",
      "status_cancelled",
      "tango_wont_do",
    ]
    _ -> [role]
  }
}
