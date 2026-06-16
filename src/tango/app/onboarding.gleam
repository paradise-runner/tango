import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/attestation/configured as configured_attestation
import tango/config
import tango/domain/event
import tango/domain/forge
import tango/domain/lifecycle
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/ticket
import tango/registry/adapter as registry_adapter
import tango/store/store

pub type CreateTicketInput {
  CreateTicketInput(
    repositories: List(String),
    external_ref: String,
    registry_name: String,
    forge_name: String,
    capability_profile_name: String,
    labels: List(String),
    priority: Option(Int),
    lifecycle_policy: Option(String),
  )
}

pub type OnboardingError {
  ConfigFailure(config.ConfigError)
  StoreFailure(store.StoreError)
  InvalidRepository(repo.RepoBindingError)
  MissingRepository
  EmptyExternalReference
  EmptyCapabilityProfile(String)
  InvalidPriority
  EmptyLifecyclePolicy
  LocalRepositorySource(String)
  UnsupportedForge(String)
  MissingForgeSkill(String)
  MissingForgeExecutionTool(String)
  MissingForgeMergeTool(String)
  MissingRegistrySkill(String)
  MissingRegistryExecutionTool(String)
  MissingValidatedStatusMap(String)
  MissingRegistryStatus(String)
  MissingTicketAttestationAdapter(String)
  MissingForgeAttestationAdapter(String)
  DuplicateExternalReference(String)
  IncompatibleForgeRemote(String, String)
  RegistryFailure(registry_adapter.RegistryError)
}

pub fn create_ticket(
  backend: store.Store(state),
  state: state,
  registry: registry_adapter.RegistryAdapter,
  operator_config: config.Config,
  input: CreateTicketInput,
  now: String,
  next_id: fn(String) -> String,
  stable_hash: fn(String) -> String,
) -> Result(#(state, ticket.Ticket), OnboardingError) {
  use repositories <- result.try(normalize_repositories(input.repositories))
  use external_ref <- result.try(non_empty_external_ref(input.external_ref))
  use labels <- result.try(normalize_labels(input.labels))
  use priority <- result.try(validate_priority(input.priority))
  use lifecycle_policy <- result.try(normalize_lifecycle_policy(
    input.lifecycle_policy,
  ))
  use registry_config <- result.try(
    config.get_registry(operator_config, input.registry_name)
    |> result.map_error(ConfigFailure),
  )
  use _ <- result.try(
    case configured_attestation.supports_ticket_system(input.registry_name) {
      True -> Ok(Nil)
      False -> Error(MissingTicketAttestationAdapter(input.registry_name))
    },
  )
  use _ <- result.try(
    case configured_attestation.supports_forge(input.forge_name) {
      True -> Ok(Nil)
      False -> Error(MissingForgeAttestationAdapter(input.forge_name))
    },
  )
  use profile <- result.try(
    config.get_capability_profile(
      operator_config,
      input.capability_profile_name,
    )
    |> result.map_error(ConfigFailure),
  )
  use _ <- result.try(validate_profile(input.capability_profile_name, profile))
  use _ <- result.try(validate_registry_profile(profile, registry_config))
  use forge_config <- result.try(selected_forge(
    operator_config,
    input.forge_name,
  ))
  use _ <- result.try(validate_forge_profile(profile, forge_config))
  use _ <- result.try(validate_forge_remotes(input.forge_name, repositories))
  use _ <- result.try(validate_status_map(input.registry_name, registry_config))
  use discovered_statuses <- result.try(
    registry.discover(registry_adapter.DiscoverRequest(
      registry_name: input.registry_name,
      cli_command: registry_config.cli,
      registry_skill: registry_config.skill,
    ))
    |> result.map_error(RegistryFailure),
  )
  use mapping <- result.try(status_mapping(
    registry_config,
    discovered_statuses,
    stable_hash,
  ))
  use _ <- result.try(reject_duplicate_external_ref(
    backend,
    state,
    input.registry_name,
    external_ref,
  ))

  let item =
    ticket.Ticket(
      id: next_id("ticket"),
      identifier: external_ref,
      title: None,
      priority: priority,
      labels: labels,
      lifecycle_policy: lifecycle_policy,
      state: lifecycle.Onboarded,
      repo_bindings: repositories,
      external_ref: Some(external_ref),
      registry_binding: Some(registry_status.RegistryBinding(
        registry_name: input.registry_name,
        cli_command: registry_config.cli,
        registry_skill: registry_config.skill,
        external_ticket_ref: external_ref,
        pinned_mapping_digest: mapping.digest,
      )),
      registry_status_mapping: Some(mapping),
      forge_binding: Some(forge.ForgeBinding(
        forge_name: input.forge_name,
        cli_command: forge_config.cli,
        forge_skill: forge_config.skill,
      )),
      observed_external_status_id: None,
      capability_profile_digest: Some(profile_digest(profile, stable_hash)),
      main_session_id: None,
      aux_session_ids: [],
      active_block_id: None,
      blockers_clear: True,
      recently_unblocked: False,
      created_at: now,
      updated_at: now,
    )

  use state <- result.try(
    backend.save_ticket(state, item) |> result.map_error(StoreFailure),
  )
  use state <- result.try(
    backend.append_event(
      state,
      event.new(
        id: next_id("event"),
        ticket_id: Some(item.id),
        type_: "ticket.created",
        occurred_at: now,
        actor: "human:" <> option_value(operator_config.operator_id, "unknown"),
        payload: dict.from_list([
          #("external_ref", external_ref),
          #("registry", input.registry_name),
          #("forge", input.forge_name),
          #("capability_profile", input.capability_profile_name),
          #("labels", string.join(labels, with: ",")),
          #("priority", optional_int(priority)),
          #("lifecycle_policy", option_value(lifecycle_policy, "default")),
        ]),
      ),
    )
    |> result.map_error(StoreFailure),
  )
  Ok(#(state, item))
}

fn validate_status_map(
  registry_name: String,
  registry_config: config.RegistryConfig,
) -> Result(Nil, OnboardingError) {
  case registry_config.status_map_validated {
    True -> Ok(Nil)
    False -> Error(MissingValidatedStatusMap(registry_name))
  }
}

fn validate_forge_remotes(
  forge_name: String,
  repositories: List(repo.RepoBinding),
) -> Result(Nil, OnboardingError) {
  repositories
  |> list.try_each(fn(repository) {
    case repository.kind {
      repo.GitRemote ->
        forge.validate_remote(forge_name, repository.location)
        |> result.map_error(fn(_) {
          IncompatibleForgeRemote(forge_name, repository.location)
        })
      _ -> Ok(Nil)
    }
  })
}

fn selected_forge(
  operator_config: config.Config,
  name: String,
) -> Result(config.ForgeConfig, OnboardingError) {
  case name {
    "github" | "forgejo" ->
      config.get_forge(operator_config, name)
      |> result.map_error(ConfigFailure)
    _ -> Error(UnsupportedForge(name))
  }
}

fn validate_forge_profile(
  profile: config.CapabilityProfile,
  forge_config: config.ForgeConfig,
) -> Result(Nil, OnboardingError) {
  case
    list.contains(profile.skills, forge_config.skill),
    list.contains(profile.execution_tools, forge_config.cli),
    list.contains(profile.merge_tools, forge_config.cli)
  {
    False, _, _ -> Error(MissingForgeSkill(forge_config.skill))
    _, False, _ -> Error(MissingForgeExecutionTool(forge_config.cli))
    _, _, False -> Error(MissingForgeMergeTool(forge_config.cli))
    True, True, True -> Ok(Nil)
  }
}

fn validate_registry_profile(
  profile: config.CapabilityProfile,
  registry_config: config.RegistryConfig,
) -> Result(Nil, OnboardingError) {
  case
    list.contains(profile.skills, registry_config.skill),
    list.contains(profile.execution_tools, registry_config.cli)
  {
    False, _ -> Error(MissingRegistrySkill(registry_config.skill))
    _, False -> Error(MissingRegistryExecutionTool(registry_config.cli))
    True, True -> Ok(Nil)
  }
}

fn normalize_repositories(
  locations: List(String),
) -> Result(List(repo.RepoBinding), OnboardingError) {
  case locations {
    [] -> Error(MissingRepository)
    _ -> {
      let bindings =
        locations
        |> list.try_map(fn(location) {
          let location = string.trim(location)
          case is_clone_source(location) {
            False -> Error(LocalRepositorySource(location))
            True -> {
              let name = repo.checkout_name(location)
              Ok(repo.RepoBinding(
                id: "repo-" <> name,
                name: name,
                kind: repo.GitRemote,
                location: location,
                default_branch: None,
                base_ref: None,
                target_branch: None,
                work_branch: None,
                checkout_policy: repo.Clone,
              ))
            }
          }
        })
      use bindings <- result.try(bindings)
      repo.validate_all(bindings)
      |> result.map_error(InvalidRepository)
    }
  }
}

fn is_clone_source(location: String) -> Bool {
  case
    string.starts_with(location, "https://"),
    string.starts_with(location, "http://"),
    string.starts_with(location, "ssh://"),
    string.starts_with(location, "git://"),
    string.contains(location, "@") && string.contains(location, ":"),
    string.split(location, "/")
  {
    True, _, _, _, _, _
    | _, True, _, _, _, _
    | _, _, True, _, _, _
    | _, _, _, True, _, _
    | _, _, _, _, True, _
    -> True
    _, _, _, _, _, [owner, name] ->
      string.trim(owner) != "" && string.trim(name) != ""
    _, _, _, _, _, _ -> False
  }
}

fn non_empty_external_ref(value: String) -> Result(String, OnboardingError) {
  case string.trim(value) {
    "" -> Error(EmptyExternalReference)
    value -> Ok(value)
  }
}

fn normalize_labels(
  values: List(String),
) -> Result(List(String), OnboardingError) {
  Ok(
    values
    |> list.map(fn(value) { string.lowercase(string.trim(value)) })
    |> list.filter(fn(value) { value != "" })
    |> unique_strings([]),
  )
}

fn validate_priority(
  value: Option(Int),
) -> Result(Option(Int), OnboardingError) {
  case value {
    Some(priority) if priority <= 0 -> Error(InvalidPriority)
    _ -> Ok(value)
  }
}

fn normalize_lifecycle_policy(
  value: Option(String),
) -> Result(Option(String), OnboardingError) {
  case value {
    None -> Ok(None)
    Some(value) ->
      case string.trim(value) {
        "" -> Error(EmptyLifecyclePolicy)
        value -> Ok(Some(value))
      }
  }
}

fn validate_profile(
  name: String,
  profile: config.CapabilityProfile,
) -> Result(Nil, OnboardingError) {
  case profile.skills, profile.execution_tools, profile.merge_tools {
    [], [], [] -> Error(EmptyCapabilityProfile(name))
    _, _, _ -> Ok(Nil)
  }
}

fn status_mapping(
  registry: config.RegistryConfig,
  discovered_statuses: List(registry_status.ExternalStatus),
  stable_hash: fn(String) -> String,
) -> Result(registry_status.RegistryStatusMapping, OnboardingError) {
  use backlog <- result.try(status(registry, discovered_statuses, "backlog"))
  use todo_status <- result.try(status(registry, discovered_statuses, "todo"))
  use in_progress <- result.try(status(
    registry,
    discovered_statuses,
    "in_progress",
  ))
  use human_review <- result.try(status(
    registry,
    discovered_statuses,
    "human_review",
  ))
  use merging <- result.try(status(registry, discovered_statuses, "merging"))
  use blocked <- result.try(status(registry, discovered_statuses, "blocked"))
  use done <- result.try(status(registry, discovered_statuses, "done"))
  use wont_do <- result.try(status(registry, discovered_statuses, "wont_do"))
  let digest =
    "sha256:"
    <> stable_hash(string.join(
      [
        backlog.id,
        todo_status.id,
        in_progress.id,
        human_review.id,
        merging.id,
        blocked.id,
        done.id,
        wont_do.id,
      ],
      with: "\n",
    ))
  Ok(registry_status.RegistryStatusMapping(
    backlog: backlog,
    todo_status: todo_status,
    in_progress: in_progress,
    human_review: human_review,
    merging: merging,
    blocked: blocked,
    done: done,
    wont_do: wont_do,
    digest: digest,
  ))
}

fn status(
  registry: config.RegistryConfig,
  discovered_statuses: List(registry_status.ExternalStatus),
  role: String,
) -> Result(registry_status.ExternalStatus, OnboardingError) {
  use id <- result.try(
    dict.get(registry.statuses, role)
    |> result.map_error(fn(_) { MissingRegistryStatus(role) }),
  )
  case string.trim(id) {
    "" -> Error(MissingRegistryStatus(role))
    status_id ->
      discovered_statuses
      |> list.find(fn(status) { status.id == status_id })
      |> result.map_error(fn(_) { MissingRegistryStatus(role) })
  }
}

fn profile_digest(
  profile: config.CapabilityProfile,
  stable_hash: fn(String) -> String,
) -> String {
  "sha256:"
  <> stable_hash(string.join(
    list.append(
      profile.skills,
      list.append(profile.execution_tools, profile.merge_tools),
    ),
    with: "\n",
  ))
}

fn reject_duplicate_external_ref(
  backend: store.Store(state),
  state: state,
  registry_name: String,
  external_ref: String,
) -> Result(Nil, OnboardingError) {
  use tickets <- result.try(
    backend.list_tickets(state) |> result.map_error(StoreFailure),
  )
  case
    list.any(tickets, fn(item) {
      case item.registry_binding {
        Some(binding) ->
          binding.registry_name == registry_name
          && binding.external_ticket_ref == external_ref
        None -> False
      }
    })
  {
    True -> Error(DuplicateExternalReference(external_ref))
    False -> Ok(Nil)
  }
}

fn option_value(value, fallback: String) -> String {
  case value {
    Some(value) -> value
    None -> fallback
  }
}

fn optional_int(value: Option(Int)) -> String {
  case value {
    Some(value) -> int.to_string(value)
    None -> ""
  }
}

fn unique_strings(remaining: List(String), seen: List(String)) -> List(String) {
  case remaining {
    [] -> list.reverse(seen)
    [value, ..rest] ->
      case list.contains(seen, value) {
        True -> unique_strings(rest, seen)
        False -> unique_strings(rest, [value, ..seen])
      }
  }
}
