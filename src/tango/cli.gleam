import gleam/dynamic/decode
import gleam/erlang/process as erlang_process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import tango/app/command
import tango/app/onboarding
import tango/app/status_map
import tango/application
import tango/capability/manager
import tango/config
import tango/dashboard
import tango/domain/artifact
import tango/domain/lifecycle
import tango/domain/registry_status
import tango/domain/review
import tango/domain/session
import tango/process
import tango/registry/configured
import tango/runtime
import tango/store/json_store
import tango/store/store

pub type CliCommand {
  Init
  Run
  Status
  Dashboard
  DashboardOnce
  CapabilityList
  CapabilityInstall(manager.CapabilityKind, String, manager.InstallMode)
  CapabilityProfileCreate(String, String, String)
  TicketSystemStatusMapShow(String)
  TicketSystemStatusMapDiscover(String, Option(String))
  TicketSystemStatusMapAutomatch(String, Option(String))
  TicketSystemStatusMapValidate(String, Option(String))
  TicketSystemStatusMapSet(String, String, String)
  TicketCreate(onboarding.CreateTicketInput, Bool)
  TicketList
  TicketShow(String)
  ReviewList
  ReviewShow(String)
  ReviewMerge(String)
  TicketQueue(String)
  TicketUnblock(String)
  Help
}

pub type CliError {
  Usage(String)
  MissingHomeDirectory
  Runtime(String)
  MergeConfirmationDeclined
  Config(config.ConfigError)
  Capability(manager.CapabilityError)
  Store(store.StoreError)
  Command(command.CommandError)
  Onboarding(onboarding.OnboardingError)
  StatusMap(status_map.StatusMapError)
}

pub type MergeConfirmation {
  MergeConfirmation(
    ticket_id: String,
    ticket_identifier: String,
    reviewed_commit_set: List(review.ReviewedCommit),
    reviewed_pull_request_set: List(review.ReviewedPullRequest),
  )
}

type MergeApprovalSnapshot {
  MergeApprovalSnapshot(
    reviewed_commit_set: List(review.ReviewedCommit),
    reviewed_pull_request_set: List(review.ReviewedPullRequest),
  )
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
  )
}

const dashboard_refresh_ms = 300

pub fn main() -> Nil {
  case runtime.argv() |> parse {
    Ok(Dashboard) -> run_live_dashboard() |> handle_main_result
    Ok(command) -> command |> run |> handle_main_output
    Error(error) -> handle_main_error(error)
  }
}

fn handle_main_output(result: Result(String, CliError)) -> Nil {
  case result {
    Ok(output) -> io.println(output)
    Error(error) -> handle_main_error(error)
  }
}

fn handle_main_result(result: Result(Nil, CliError)) -> Nil {
  case result {
    Ok(Nil) -> Nil
    Error(error) -> handle_main_error(error)
  }
}

fn handle_main_error(error: CliError) -> Nil {
  io.println_error(render_error(error))
  runtime.halt(1)
}

fn run_live_dashboard() -> Result(Nil, CliError) {
  use resolved <- result.try(resolve_runtime())
  let #(root, operator_id) = resolved
  render_live_dashboard_loop(
    json_store.store(),
    json_store.new(root),
    root,
    operator_id,
    0,
  )
}

fn render_live_dashboard_loop(
  backend: store.Store(state),
  state: state,
  root: String,
  operator_id: String,
  frame_index: Int,
) -> Result(Nil, CliError) {
  case
    render_dashboard_frame(
      backend,
      state,
      root,
      operator_id,
      runtime.now_rfc3339(),
      frame_index,
    )
  {
    Ok(output) -> {
      io.print(clear_terminal() <> output <> "\n")
      erlang_process.sleep(dashboard_refresh_ms)
      render_live_dashboard_loop(
        backend,
        state,
        root,
        operator_id,
        frame_index + 1,
      )
    }
    Error(error) -> Error(error)
  }
}

fn clear_terminal() -> String {
  "\u{1b}[2J\u{1b}[H"
}

pub fn parse(args: List(String)) -> Result(CliCommand, CliError) {
  case args {
    [] | ["help"] | ["--help"] | ["-h"] -> Ok(Help)
    ["init"] -> Ok(Init)
    ["run"] -> Ok(Run)
    ["status"] -> Ok(Status)
    ["dashboard"] -> Ok(Dashboard)
    ["dashboard", "--once"] -> Ok(DashboardOnce)
    ["capability", "list"] -> Ok(CapabilityList)
    ["capability", "install", kind, bundle] ->
      parse_capability_install(kind, bundle, manager.VerifyOrInstallCli)
    ["capability", "install", kind, bundle, "--skill-only"] ->
      parse_capability_install(kind, bundle, manager.SkillOnly)
    [
      "capability",
      "profile",
      "create",
      name,
      "--ticket-system",
      ticket_system,
      "--forge",
      forge,
    ] ->
      case string.trim(name), string.trim(ticket_system), string.trim(forge) {
        "", _, _ | _, "", _ | _, _, "" -> Error(Usage(usage()))
        name, ticket_system, forge ->
          Ok(CapabilityProfileCreate(name, ticket_system, forge))
      }
    ["ticket-system", "status-map", name, ..args] ->
      parse_ticket_system_status_map(name, args)
    ["ticket", "create", ..args] -> parse_ticket_create(args)
    ["ticket", "list"] -> Ok(TicketList)
    ["ticket", "show", ticket_id] -> parse_ticket_id(ticket_id, TicketShow)
    ["review", "list"] -> Ok(ReviewList)
    ["review", "show", ticket_id] -> parse_ticket_id(ticket_id, ReviewShow)
    ["review", "merge", ticket_id] -> parse_ticket_id(ticket_id, ReviewMerge)
    ["ticket", "queue", ticket_id] -> parse_ticket_id(ticket_id, TicketQueue)
    ["ticket", "unblock", ticket_id] ->
      parse_ticket_id(ticket_id, TicketUnblock)
    _ -> Error(Usage(usage()))
  }
}

pub fn run(command: CliCommand) -> Result(String, CliError) {
  use resolved <- result.try(resolve_runtime())
  let #(root, operator_id) = resolved
  run_with_confirmation(
    command,
    root,
    operator_id,
    runtime.now_rfc3339(),
    runtime.unique_id,
    fn(confirmation) {
      runtime.confirm(render_merge_confirmation(confirmation))
    },
  )
}

pub fn run_in(
  command: CliCommand,
  root: String,
  operator_id: String,
  now: String,
  next_id: fn(String) -> String,
) -> Result(String, CliError) {
  run_with_confirmation(command, root, operator_id, now, next_id, fn(_) { True })
}

pub fn run_in_with_confirmation(
  command: CliCommand,
  root: String,
  operator_id: String,
  now: String,
  next_id: fn(String) -> String,
  confirm_merge: fn(MergeConfirmation) -> Bool,
) -> Result(String, CliError) {
  run_with_confirmation(command, root, operator_id, now, next_id, confirm_merge)
}

fn run_with_confirmation(
  command: CliCommand,
  root: String,
  operator_id: String,
  now: String,
  next_id: fn(String) -> String,
  confirm_merge: fn(MergeConfirmation) -> Bool,
) -> Result(String, CliError) {
  let backend = json_store.store()
  let state = json_store.new(root)

  case command {
    Help -> Ok(usage())
    Init -> init(root, operator_id)
    Run -> run_application(root)
    Status -> render_status(backend, state, root, operator_id, now)
    Dashboard | DashboardOnce ->
      render_dashboard(backend, state, root, operator_id, now)
    CapabilityList -> capability_list(root)
    CapabilityInstall(kind, bundle, mode) ->
      capability_install(root, kind, bundle, mode)
    CapabilityProfileCreate(name, ticket_system, forge) ->
      capability_profile_create(root, name, ticket_system, forge)
    TicketSystemStatusMapShow(name) -> ticket_system_status_map_show(root, name)
    TicketSystemStatusMapDiscover(name, repository) ->
      ticket_system_status_map_discover(root, name, repository)
    TicketSystemStatusMapAutomatch(name, repository) ->
      ticket_system_status_map_automatch(root, name, repository)
    TicketSystemStatusMapValidate(name, repository) ->
      ticket_system_status_map_validate(root, name, repository)
    TicketSystemStatusMapSet(name, role, status_id) ->
      ticket_system_status_map_set(root, name, role, status_id)
    TicketCreate(input, queue) ->
      create_ticket(
        backend,
        state,
        root,
        input,
        queue,
        operator_id,
        now,
        next_id,
      )
    TicketList -> list_tickets(backend, state)
    TicketShow(ticket_id) -> show_ticket(backend, state, ticket_id)
    ReviewList -> list_reviews(backend, state)
    ReviewShow(ticket_id) -> show_reviews(backend, state, ticket_id)
    ReviewMerge(ticket_id) ->
      approve_merge(
        backend,
        state,
        ticket_id,
        operator_id,
        now,
        next_id,
        confirm_merge,
      )
    TicketQueue(ticket_id) ->
      command.queue_ticket(
        backend,
        state,
        ticket_id,
        next_id("event"),
        "human:" <> operator_id,
        now,
      )
      |> result.map(fn(result) {
        "queued " <> result.value.identifier <> " (" <> result.value.id <> ")"
      })
      |> map_command_error
    TicketUnblock(ticket_id) ->
      command.unblock_ticket(
        backend,
        state,
        ticket_id,
        operator_id,
        now,
        next_id("event"),
      )
      |> result.map(fn(result) {
        "unblocked "
        <> result.value.identifier
        <> " -> "
        <> result.value.id
        <> " now "
        <> lifecycle_state(result.value.state)
      })
      |> map_command_error
  }
}

pub fn render_error(error: CliError) -> String {
  case error {
    Usage(text) -> text
    MissingHomeDirectory ->
      "missing HOME; set HOME or TANGO_STATE_DIR before running tango"
    Runtime(reason) -> "runtime error: " <> reason
    MergeConfirmationDeclined -> "merge approval canceled"
    Config(config.Io(reason)) -> "config I/O failed: " <> reason
    Config(config.InvalidConfig(reason)) -> "config is invalid: " <> reason
    Capability(manager.UnsupportedBundle(name)) ->
      "unsupported capability bundle: " <> name
    Capability(manager.MissingAttestationAdapter(name)) ->
      "capability has no read-only attestation adapter: " <> name
    Capability(manager.CliNotFound(cli)) ->
      "installed capability CLI is not available on PATH: " <> cli
    Capability(manager.InstallerNotFound) ->
      "capability CLI is missing and Homebrew is not available"
    Capability(manager.InstallFailed(reason)) ->
      "capability CLI installation failed: " <> reason
    Capability(manager.Io(reason)) ->
      "capability installation I/O failed: " <> reason
    Capability(manager.ConfigFailure(error)) -> render_error(Config(error))
    Store(store.NotFound(id)) -> "ticket not found: " <> id
    Store(store.DecodeFailed(reason)) -> "store decode failed: " <> reason
    Store(store.SchemaVersionUnsupported(version)) ->
      "unsupported schema version: " <> int.to_string(version)
    Store(store.IoFailed(reason)) -> "store I/O failed: " <> reason
    Store(store.ImmutableArtifactAlreadyExists(id)) ->
      "duplicate immutable artifact id: " <> id
    Store(store.ImmutableEventAlreadyExists(id)) ->
      "duplicate immutable event id: " <> id
    Command(command.OnboardingIncomplete(_)) ->
      "ticket onboarding is incomplete; queue is rejected"
    Command(command.StoreFailure(error)) -> render_error(Store(error))
    Command(command.LifecycleFailure(_)) ->
      "ticket is not in a state that allows this command"
    Command(command.SessionFailure(_)) -> "session topology is invalid"
    Command(command.BlockFailure(_)) -> "block record is invalid"
    Command(command.ReviewFailure(_)) -> "review decision is invalid"
    Command(command.MergeFailure(_)) -> "merge record is invalid"
    Command(command.RunFailure(_)) -> "run state is invalid"
    Command(command.SessionTicketMismatch(_, _)) ->
      "ticket/session reference mismatch"
    Command(command.SessionReferenceMissing(id)) ->
      "referenced session is missing: " <> id
    Command(command.BlockReferenceMissing(id)) ->
      "active block record is missing: " <> id
    Command(command.ReviewReferenceMissing(id)) ->
      "referenced review decision is missing: " <> id
    Command(command.BlockRecordStateMismatch(_, _)) ->
      "block record does not match the current ticket state"
    Command(command.ApprovalRequiresMergeCommand) ->
      "approve decisions must use the merge command"
    Onboarding(onboarding.ConfigFailure(error)) -> render_error(Config(error))
    Onboarding(onboarding.StoreFailure(error)) -> render_error(Store(error))
    Onboarding(onboarding.InvalidRepository(_)) ->
      "ticket onboarding has an invalid repository binding"
    Onboarding(onboarding.MissingRepository) ->
      "ticket onboarding requires at least one --repo"
    Onboarding(onboarding.EmptyExternalReference) ->
      "ticket onboarding requires a non-empty --ticket-ref"
    Onboarding(onboarding.EmptyCapabilityProfile(name)) ->
      "capability profile has no capabilities: " <> name
    Onboarding(onboarding.InvalidPriority) ->
      "ticket onboarding priority must be a positive integer"
    Onboarding(onboarding.EmptyLifecyclePolicy) ->
      "ticket onboarding lifecycle policy must not be empty"
    Onboarding(onboarding.LocalRepositorySource(source)) ->
      "repository source must be owner/repo shorthand or a full Git clone URL: "
      <> source
    Onboarding(onboarding.UnsupportedForge(name)) ->
      "unsupported forge: " <> name <> "; expected github or forgejo"
    Onboarding(onboarding.MissingForgeSkill(skill)) ->
      "capability profile is missing forge skill: " <> skill
    Onboarding(onboarding.MissingForgeExecutionTool(tool)) ->
      "capability profile is missing forge execution tool: " <> tool
    Onboarding(onboarding.MissingForgeMergeTool(tool)) ->
      "capability profile is missing forge merge tool: " <> tool
    Onboarding(onboarding.MissingRegistrySkill(skill)) ->
      "capability profile is missing registry skill: " <> skill
    Onboarding(onboarding.MissingRegistryExecutionTool(tool)) ->
      "capability profile is missing registry execution tool: " <> tool
    Onboarding(onboarding.MissingValidatedStatusMap(name)) ->
      "ticket-system status map is not validated: "
      <> name
      <> "; run tango ticket-system status-map "
      <> name
      <> " validate --repo <owner/repo>"
    Onboarding(onboarding.MissingRegistryStatus(role)) ->
      "registry status mapping is missing required role: " <> role
    Onboarding(onboarding.MissingTicketAttestationAdapter(name)) ->
      "ticket system has no read-only attestation adapter: " <> name
    Onboarding(onboarding.MissingForgeAttestationAdapter(name)) ->
      "forge has no read-only attestation adapter: " <> name
    Onboarding(onboarding.DuplicateExternalReference(reference)) ->
      "ticket already exists for external reference: " <> reference
    Onboarding(onboarding.IncompatibleForgeRemote(forge, remote)) ->
      "repository remote is incompatible with selected forge "
      <> forge
      <> ": "
      <> remote
    Onboarding(onboarding.RegistryFailure(inner)) ->
      "registry adapter failed: " <> string.inspect(inner)
    StatusMap(status_map.ConfigFailure(error)) -> render_error(Config(error))
    StatusMap(status_map.MissingRepository(name)) ->
      "ticket-system status-map requires --repo for " <> name
    StatusMap(status_map.UnsupportedProvider(name)) ->
      "unsupported ticket-system status-map provider: " <> name
    StatusMap(status_map.CommandFailed(reason)) ->
      "ticket-system status-map command failed: " <> reason
    StatusMap(status_map.InvalidDiscovery(reason)) ->
      "ticket-system status-map discovery failed: " <> reason
    StatusMap(status_map.MissingRole(role)) ->
      "ticket-system status-map is missing required role: " <> role
    StatusMap(status_map.MissingRoles(roles)) ->
      "ticket-system status-map is missing required roles: "
      <> string.join(roles, ", ")
    StatusMap(status_map.MissingMappedStatus(role, status_id)) ->
      "ticket-system status-map role "
      <> role
      <> " refers to missing status id: "
      <> status_id
    StatusMap(status_map.MissingMappedStatuses(statuses)) ->
      "ticket-system status-map roles refer to missing status ids: "
      <> string.join(
        list.map(statuses, fn(status) { status.0 <> "=" <> status.1 }),
        ", ",
      )
  }
}

fn init(root: String, operator_id: String) -> Result(String, CliError) {
  use _ <- result.try(ensure_directories(root))
  use _ <- result.try(write_config(root, operator_id))
  Ok("initialized tango state at " <> root)
}

fn ensure_directories(root: String) -> Result(Nil, CliError) {
  [
    root,
    join(root, "tickets"),
    join(root, "capabilities"),
    join(root, "workspaces"),
    join(root, "workpads"),
  ]
  |> list.try_each(fn(path) {
    runtime.ensure_dir(path) |> result.map_error(Runtime)
  })
}

fn state_dir() -> Result(String, CliError) {
  case runtime.get_env("TANGO_STATE_DIR") {
    Some(root) ->
      case string.trim(root) {
        "" -> home_state_dir()
        _ -> Ok(root)
      }
    _ -> home_state_dir()
  }
}

fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/"), string.starts_with(right, "/") {
    True, True -> left <> string.drop_start(right, 1)
    True, False -> left <> right
    False, True -> left <> right
    False, False -> left <> "/" <> right
  }
}

fn usage() -> String {
  string.join(
    [
      "usage:",
      "  tango init",
      "  tango run",
      "  tango status",
      "  tango dashboard [--once]",
      "  tango capability list",
      "  tango capability install <ticket-system|forge> <github|forgejo> [--skill-only]",
      "  tango capability profile create <name> --ticket-system <name> --forge <name>",
      "  tango ticket-system status-map <name> show",
      "  tango ticket-system status-map <name> discover --repo <owner/repo>",
      "  tango ticket-system status-map <name> automatch --repo <owner/repo>",
      "  tango ticket-system status-map <name> validate --repo <owner/repo>",
      "  tango ticket-system status-map <name> set --role <role> --status-id <stable-id>",
      "  tango ticket create --repo <owner/repo-or-clone-url> [--repo <owner/repo-or-clone-url> ...] --ticket-ref <reference> --ticket-system <name> --forge <github|forgejo> --capability-profile <name> [--label <label> ...] [--priority <positive-int>] [--lifecycle-policy <reference>] [--queue]",
      "  tango ticket list",
      "  tango ticket show <ticket-id>",
      "  tango review list",
      "  tango review show <ticket-id>",
      "  tango review merge <ticket-id>",
      "  tango ticket queue <ticket-id>",
      "  tango ticket unblock <ticket-id>",
    ],
    with: "\n",
  )
}

fn capability_list(root: String) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  let installed = manager.installed(operator_config)
  Ok(string.join(
    case installed {
      [] -> ["capabilities:", "  (none)"]
      installed -> [
        "capabilities:",
        ..installed
        |> list.map(fn(bundle) {
          "  "
          <> manager.kind_name(bundle.kind)
          <> ":"
          <> bundle.name
          <> " | cli="
          <> bundle.cli_command
          <> " | path="
          <> bundle.cli_path
          <> " | skill="
          <> bundle.skill_path
        })
      ]
    },
    with: "\n",
  ))
}

fn capability_install(
  root: String,
  kind: manager.CapabilityKind,
  bundle: String,
  mode: manager.InstallMode,
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  use installed <- result.try(
    manager.install(root, operator_config, kind, bundle, mode)
    |> result.map_error(Capability),
  )
  let #(updated, bundle) = installed
  use _ <- result.try(
    config.save(join(root, "config.toml"), updated) |> result.map_error(Config),
  )
  let cli = case mode {
    manager.VerifyOrInstallCli -> bundle.cli_path
    manager.SkillOnly -> "skipped"
  }
  Ok(
    "installed "
    <> manager.kind_name(kind)
    <> " "
    <> bundle.name
    <> " capability (cli="
    <> cli
    <> ", skill="
    <> bundle.skill_path
    <> ")",
  )
}

fn parse_capability_install(
  kind: String,
  bundle: String,
  mode: manager.InstallMode,
) -> Result(CliCommand, CliError) {
  case string.trim(kind), string.trim(bundle) {
    "ticket-system", bundle if bundle != "" ->
      Ok(CapabilityInstall(manager.TicketSystem, bundle, mode))
    "forge", bundle if bundle != "" ->
      Ok(CapabilityInstall(manager.Forge, bundle, mode))
    _, _ -> Error(Usage(usage()))
  }
}

fn parse_ticket_system_status_map(
  name: String,
  args: List(String),
) -> Result(CliCommand, CliError) {
  case string.trim(name), args {
    "", _ -> Error(Usage(usage()))
    name, ["show"] -> Ok(TicketSystemStatusMapShow(name))
    name, ["discover", ..args] ->
      parse_status_map_repo(args)
      |> result.map(fn(repository) {
        TicketSystemStatusMapDiscover(name, repository)
      })
    name, ["automatch", ..args] ->
      parse_status_map_repo(args)
      |> result.map(fn(repository) {
        TicketSystemStatusMapAutomatch(name, repository)
      })
    name, ["validate", ..args] ->
      parse_status_map_repo(args)
      |> result.map(fn(repository) {
        TicketSystemStatusMapValidate(name, repository)
      })
    name, ["set", ..args] -> parse_status_map_set(name, args, None, None)
    _, _ -> Error(Usage(usage()))
  }
}

fn parse_status_map_repo(
  args: List(String),
) -> Result(Option(String), CliError) {
  case args {
    [] -> Ok(None)
    ["--repo", repo] ->
      case string.trim(repo) {
        "" -> Error(Usage(usage()))
        repo -> Ok(Some(repo))
      }
    _ -> Error(Usage(usage()))
  }
}

fn parse_status_map_set(
  name: String,
  args: List(String),
  role: Option(String),
  status_id: Option(String),
) -> Result(CliCommand, CliError) {
  case args {
    [] ->
      case role, status_id {
        Some(role), Some(status_id) ->
          Ok(TicketSystemStatusMapSet(name, role, status_id))
        _, _ -> Error(Usage(usage()))
      }
    ["--role", value, ..rest] ->
      parse_status_map_set(name, rest, non_empty_option(value), status_id)
    ["--status-id", value, ..rest] ->
      parse_status_map_set(name, rest, role, non_empty_option(value))
    _ -> Error(Usage(usage()))
  }
}

fn non_empty_option(value: String) -> Option(String) {
  case string.trim(value) {
    "" -> None
    value -> Some(value)
  }
}

fn capability_profile_create(
  root: String,
  name: String,
  ticket_system: String,
  forge: String,
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  use updated <- result.try(
    manager.create_profile(operator_config, name, ticket_system, forge)
    |> result.map_error(Capability),
  )
  use _ <- result.try(
    config.save(join(root, "config.toml"), updated) |> result.map_error(Config),
  )
  Ok(
    "created capability profile "
    <> name
    <> " with ticket-system "
    <> ticket_system
    <> " and forge "
    <> forge,
  )
}

fn ticket_system_status_map_show(
  root: String,
  name: String,
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  status_map.show(operator_config, name)
  |> result.map(render_status_map_view)
  |> result.map_error(StatusMap)
}

fn ticket_system_status_map_discover(
  root: String,
  name: String,
  repository: Option(String),
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  use statuses <- result.try(
    status_map.discover(
      operator_config,
      name,
      repository,
      run_status_map_command,
    )
    |> result.map_error(StatusMap),
  )
  Ok(render_discovered_statuses(
    name,
    config.provider_status_kind(name),
    statuses,
  ))
}

fn ticket_system_status_map_automatch(
  root: String,
  name: String,
  repository: Option(String),
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  use result <- result.try(
    status_map.automatch(
      operator_config,
      name,
      repository,
      run_status_map_command,
    )
    |> result.map_error(StatusMap),
  )
  let #(updated, view) = result
  use _ <- result.try(
    config.save(join(root, "config.toml"), updated) |> result.map_error(Config),
  )
  Ok(render_automatch_view(view))
}

fn ticket_system_status_map_validate(
  root: String,
  name: String,
  repository: Option(String),
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  use validation <- result.try(
    status_map.validate(
      operator_config,
      name,
      repository,
      run_status_map_command,
    )
    |> result.map_error(StatusMap),
  )
  let #(updated, statuses) = validation
  use _ <- result.try(
    config.save(join(root, "config.toml"), updated) |> result.map_error(Config),
  )
  Ok(
    "validated ticket-system status map "
    <> name
    <> "\n"
    <> render_status_list(statuses),
  )
}

fn ticket_system_status_map_set(
  root: String,
  name: String,
  role: String,
  status_id: String,
) -> Result(String, CliError) {
  use operator_config <- result.try(load_required_config(root))
  use updated <- result.try(
    status_map.set(operator_config, name, role, status_id)
    |> result.map_error(StatusMap),
  )
  use _ <- result.try(
    config.save(join(root, "config.toml"), updated) |> result.map_error(Config),
  )
  Ok(
    "updated ticket-system status map "
    <> name
    <> " "
    <> role
    <> "="
    <> status_id
    <> " (validation required)",
  )
}

fn run_status_map_command(
  command: String,
  args: List(String),
) -> Result(process.CommandResult, String) {
  process.run_command(command, args, [], None)
}

fn render_status_map_view(view: status_map.StatusMapView) -> String {
  string.join(
    [
      "ticket-system status map: " <> view.name,
      "provider_kind: " <> view.provider_kind,
      "validated: " <> bool_text(view.validated),
      "statuses:",
      render_role_statuses(view.statuses),
    ],
    with: "\n",
  )
}

fn render_discovered_statuses(
  name: String,
  provider_kind: String,
  statuses: List(registry_status.ExternalStatus),
) -> String {
  string.join(
    [
      "discovered ticket-system statuses: " <> name,
      "provider_kind: " <> provider_kind,
      "statuses:",
      render_status_list(statuses),
    ],
    with: "\n",
  )
}

fn render_automatch_view(view: status_map.AutomatchView) -> String {
  string.join(
    [
      "automatched ticket-system status map: " <> view.name,
      "provider_kind: " <> view.provider_kind,
      "matched:",
      render_role_statuses(view.matched),
      "ambiguous:",
      render_ambiguous_roles(view.ambiguous_roles),
      "unmatched:",
      render_unmatched_roles(view.unmatched_roles),
      "validation_required: true",
      "discovered:",
      render_status_list(view.discovered),
    ],
    with: "\n",
  )
}

fn render_ambiguous_roles(statuses: List(#(String, List(String)))) -> String {
  case statuses {
    [] -> "  (none)"
    _ ->
      statuses
      |> list.map(fn(entry) {
        "  " <> entry.0 <> " = " <> string.join(entry.1, ", ")
      })
      |> string.join(with: "\n")
  }
}

fn render_unmatched_roles(roles: List(String)) -> String {
  case roles {
    [] -> "  (none)"
    _ ->
      roles
      |> list.map(fn(role) { "  " <> role })
      |> string.join(with: "\n")
  }
}

fn render_role_statuses(statuses: List(#(String, String))) -> String {
  case statuses {
    [] -> "  (none)"
    _ ->
      statuses
      |> list.map(fn(entry) { "  " <> entry.0 <> " = " <> entry.1 })
      |> string.join(with: "\n")
  }
}

fn render_status_list(
  statuses: List(registry_status.ExternalStatus),
) -> String {
  case statuses {
    [] -> "  (none)"
    _ ->
      statuses
      |> list.map(fn(status) { "  " <> status.id <> " | " <> status.name })
      |> string.join(with: "\n")
  }
}

fn bool_text(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}

fn load_required_config(root: String) -> Result(config.Config, CliError) {
  use loaded <- result.try(
    config.load(join(root, "config.toml")) |> result.map_error(Config),
  )
  case loaded {
    Some(operator_config) -> Ok(operator_config)
    None ->
      Error(
        Config(config.InvalidConfig("missing config.toml; run tango init first")),
      )
  }
}

fn lifecycle_state(state) -> String {
  lifecycle.to_string(state)
}

fn parse_ticket_id(
  ticket_id: String,
  into: fn(String) -> CliCommand,
) -> Result(CliCommand, CliError) {
  case string.trim(ticket_id) {
    "" -> Error(Usage(usage()))
    id -> Ok(into(id))
  }
}

fn home_state_dir() -> Result(String, CliError) {
  case runtime.get_env("HOME") {
    Some(home) ->
      case string.trim(home) {
        "" -> Error(MissingHomeDirectory)
        _ -> Ok(join(home, ".tango"))
      }
    _ -> Error(MissingHomeDirectory)
  }
}

fn default_operator_id() -> String {
  case runtime.get_env("USER") {
    Some(user) ->
      case string.trim(user) {
        "" -> username_fallback()
        _ -> "local:" <> user
      }
    _ -> username_fallback()
  }
}

fn username_fallback() -> String {
  case runtime.get_env("USERNAME") {
    Some(user) ->
      case string.trim(user) {
        "" -> "local:unknown"
        _ -> "local:" <> user
      }
    _ -> "local:unknown"
  }
}

fn write_config(root: String, operator_id: String) -> Result(Nil, CliError) {
  let config_path = join(root, "config.toml")
  use existing <- result.try(
    config.load(config_path) |> result.map_error(Config),
  )
  case existing {
    Some(_) -> Ok(Nil)
    None ->
      config.save(config_path, config.defaults(root, Some(operator_id)))
      |> result.map_error(Config)
  }
}

fn parse_ticket_create(args: List(String)) -> Result(CliCommand, CliError) {
  parse_ticket_create_args(
    args,
    [],
    None,
    None,
    None,
    None,
    [],
    None,
    None,
    False,
  )
}

fn parse_ticket_create_args(
  args: List(String),
  repositories: List(String),
  ticket_ref: Option(String),
  ticket_system: Option(String),
  forge: Option(String),
  capability_profile: Option(String),
  labels: List(String),
  priority: Option(Int),
  lifecycle_policy: Option(String),
  queue: Bool,
) -> Result(CliCommand, CliError) {
  case args {
    [] ->
      case repositories, ticket_ref, ticket_system, forge, capability_profile {
        [], _, _, _, _
        | _, None, _, _, _
        | _, _, None, _, _
        | _, _, _, None, _
        | _, _, _, _, None
        -> Error(Usage(usage()))
        repositories,
          Some(ticket_ref),
          Some(ticket_system),
          Some(forge),
          Some(capability_profile)
        ->
          Ok(TicketCreate(
            onboarding.CreateTicketInput(
              repositories: list.reverse(repositories),
              external_ref: ticket_ref,
              registry_name: ticket_system,
              forge_name: forge,
              capability_profile_name: capability_profile,
              labels: list.reverse(labels),
              priority: priority,
              lifecycle_policy: lifecycle_policy,
            ),
            queue,
          ))
      }
    ["--repo", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        [value, ..repositories],
        ticket_ref,
        ticket_system,
        forge,
        capability_profile,
        labels,
        priority,
        lifecycle_policy,
        queue,
      )
    ["--ticket-ref", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        Some(value),
        ticket_system,
        forge,
        capability_profile,
        labels,
        priority,
        lifecycle_policy,
        queue,
      )
    ["--ticket-system", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        Some(value),
        forge,
        capability_profile,
        labels,
        priority,
        lifecycle_policy,
        queue,
      )
    ["--forge", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        ticket_system,
        Some(value),
        capability_profile,
        labels,
        priority,
        lifecycle_policy,
        queue,
      )
    ["--capability-profile", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        ticket_system,
        forge,
        Some(value),
        labels,
        priority,
        lifecycle_policy,
        queue,
      )
    ["--label", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        ticket_system,
        forge,
        capability_profile,
        [value, ..labels],
        priority,
        lifecycle_policy,
        queue,
      )
    ["--priority", value, ..rest] -> {
      use parsed <- result.try(
        int.parse(value)
        |> result.map(Some)
        |> result.map_error(fn(_) { Usage(usage()) }),
      )
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        ticket_system,
        forge,
        capability_profile,
        labels,
        parsed,
        lifecycle_policy,
        queue,
      )
    }
    ["--lifecycle-policy", value, ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        ticket_system,
        forge,
        capability_profile,
        labels,
        priority,
        Some(value),
        queue,
      )
    ["--queue", ..rest] ->
      parse_ticket_create_args(
        rest,
        repositories,
        ticket_ref,
        ticket_system,
        forge,
        capability_profile,
        labels,
        priority,
        lifecycle_policy,
        True,
      )
    _ -> Error(Usage(usage()))
  }
}

fn create_ticket(
  backend: store.Store(state),
  state: state,
  root: String,
  input: onboarding.CreateTicketInput,
  queue: Bool,
  operator_id: String,
  now: String,
  next_id: fn(String) -> String,
) -> Result(String, CliError) {
  use loaded <- result.try(
    config.load(join(root, "config.toml")) |> result.map_error(Config),
  )
  use operator_config <- result.try(case loaded {
    Some(config) -> Ok(config)
    None ->
      Error(
        Config(config.InvalidConfig(
          "missing config.toml; run tango init and configure onboarding",
        )),
      )
  })
  use created <- result.try(
    onboarding.create_ticket(
      backend,
      state,
      configured.adapter(operator_config),
      operator_config,
      input,
      now,
      next_id,
      runtime.sha256,
    )
    |> result.map_error(Onboarding),
  )
  let #(created_state, item) = created
  case queue {
    False -> Ok("created " <> item.identifier <> " (" <> item.id <> ")")
    True ->
      command.queue_ticket(
        backend,
        created_state,
        item.id,
        next_id("queue-event"),
        "human:" <> operator_id,
        now,
      )
      |> result.map(fn(result) {
        "created and queued "
        <> result.value.identifier
        <> " ("
        <> result.value.id
        <> ")"
      })
      |> map_command_error
  }
}

fn run_application(root: String) -> Result(String, CliError) {
  use loaded <- result.try(
    config.load(join(root, "config.toml")) |> result.map_error(Config),
  )
  let runtime_config = case loaded {
    Some(runtime_config) -> config.with_runtime_root(runtime_config, root)
    None -> config.defaults(root, None)
  }
  application.run_foreground(runtime_config) |> result.map_error(Runtime)
}

fn render_status(
  backend: store.Store(state),
  state: state,
  root: String,
  operator_id: String,
  now: String,
) -> Result(String, CliError) {
  dashboard.status_snapshot_with_runtime(
    backend,
    state,
    now,
    operator_id,
    Some(root),
  )
  |> result.map(dashboard.render_status)
  |> result.map_error(Store)
}

fn render_dashboard(
  backend: store.Store(state),
  state: state,
  root: String,
  operator_id: String,
  now: String,
) -> Result(String, CliError) {
  dashboard.dashboard_snapshot_with_runtime(
    backend,
    state,
    now,
    operator_id,
    Some(root),
  )
  |> result.map(dashboard.render_dashboard)
  |> result.map_error(Store)
}

fn render_dashboard_frame(
  backend: store.Store(state),
  state: state,
  root: String,
  operator_id: String,
  now: String,
  frame_index: Int,
) -> Result(String, CliError) {
  dashboard.dashboard_snapshot_with_runtime(
    backend,
    state,
    now,
    operator_id,
    Some(root),
  )
  |> result.map(fn(snapshot) {
    dashboard.render_dashboard_frame(snapshot, frame_index)
  })
  |> result.map_error(Store)
}

fn list_tickets(
  backend: store.Store(state),
  state: state,
) -> Result(String, CliError) {
  dashboard.ticket_list(backend, state)
  |> result.map(dashboard.render_ticket_list)
  |> result.map_error(Store)
}

fn show_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(String, CliError) {
  dashboard.ticket_detail(backend, state, ticket_id)
  |> result.map(dashboard.render_ticket_detail)
  |> result.map_error(Store)
}

fn list_reviews(
  backend: store.Store(state),
  state: state,
) -> Result(String, CliError) {
  dashboard.review_entries(backend, state)
  |> result.map(dashboard.render_review_list)
  |> result.map_error(Store)
}

fn show_reviews(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(String, CliError) {
  dashboard.review_detail(backend, state, ticket_id)
  |> result.map(fn(detail) {
    dashboard.render_review_detail(detail.0, detail.1)
  })
  |> result.map_error(Store)
}

fn resolve_runtime() -> Result(#(String, String), CliError) {
  use bootstrap_root <- result.try(state_dir())
  use loaded <- result.try(
    config.load(join(bootstrap_root, "config.toml")) |> result.map_error(Config),
  )

  let root = case runtime.get_env("TANGO_STATE_DIR"), loaded {
    Some(value), _ ->
      case string.trim(value) {
        "" -> config_state_dir_or_default(loaded, bootstrap_root)
        _ -> value
      }
    _, _ -> config_state_dir_or_default(loaded, bootstrap_root)
  }

  let operator_id = case runtime.get_env("TANGO_OPERATOR_ID"), loaded {
    Some(value), _ ->
      case string.trim(value) {
        "" -> config_operator_id_or_default(loaded)
        _ -> value
      }
    _, _ -> config_operator_id_or_default(loaded)
  }

  Ok(#(root, operator_id))
}

fn config_state_dir_or_default(
  loaded: Option(config.Config),
  fallback: String,
) -> String {
  case loaded {
    Some(config.Config(state_dir: state_dir, ..)) -> state_dir
    _ -> fallback
  }
}

fn config_operator_id_or_default(loaded: Option(config.Config)) -> String {
  case loaded {
    Some(config.Config(operator_id: Some(operator_id), ..)) -> operator_id
    _ -> default_operator_id()
  }
}

fn map_command_error(
  value: Result(String, command.CommandError),
) -> Result(String, CliError) {
  value |> result.map_error(Command)
}

fn approve_merge(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  operator_id: String,
  now: String,
  next_id: fn(String) -> String,
  confirm_merge: fn(MergeConfirmation) -> Bool,
) -> Result(String, CliError) {
  use item <- result.try(
    backend.get_ticket(state, ticket_id) |> result.map_error(Store),
  )
  use snapshot <- result.try(latest_merge_approval_snapshot(
    backend,
    state,
    ticket_id,
  ))
  case
    confirm_merge(MergeConfirmation(
      ticket_id: item.id,
      ticket_identifier: item.identifier,
      reviewed_commit_set: snapshot.reviewed_commit_set,
      reviewed_pull_request_set: snapshot.reviewed_pull_request_set,
    ))
  {
    False -> Error(MergeConfirmationDeclined)
    True ->
      command.approve_merge(
        backend,
        state,
        ticket_id,
        review.ReviewDecision(
          id: next_id("review"),
          ticket_id: ticket_id,
          reviewer_id: operator_id,
          decision: review.Approve,
          comments: "",
          reviewed_commit_set: snapshot.reviewed_commit_set,
          reviewed_pull_request_set: snapshot.reviewed_pull_request_set,
          authorization_mechanism: "tango review merge",
          created_at: now,
        ),
        session.AgentSession(
          id: next_id("session"),
          ticket_id: ticket_id,
          role: session.Aux,
          kind: session.Merge,
          context_session_ids: [],
          runtime_session_id: None,
          run_attempt_ids: [],
          created_at: now,
          updated_at: now,
        ),
        next_id("review-event"),
        next_id("merge-event"),
      )
      |> result.map(fn(result) {
        "merge approved "
        <> ticket_id
        <> " -> "
        <> lifecycle_state(review.target_state(result.value))
      })
      |> map_command_error
  }
}

fn latest_merge_approval_snapshot(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(MergeApprovalSnapshot, CliError) {
  use artifacts <- result.try(
    backend.list_artifacts(state, ticket_id) |> result.map_error(Store),
  )
  case latest_pull_request_set_artifact(artifacts) {
    None ->
      Ok(
        MergeApprovalSnapshot(
          reviewed_commit_set: [],
          reviewed_pull_request_set: [],
        ),
      )
    Some(pull_request_artifact) -> {
      use pull_request_set <- result.try(
        json.parse(pull_request_artifact.content, pull_request_set_decoder())
        |> result.map_error(fn(error) {
          Runtime(
            "stored pull request set is invalid: " <> string.inspect(error),
          )
        }),
      )
      Ok(MergeApprovalSnapshot(
        reviewed_commit_set: reviewed_commit_set(pull_request_set.entries),
        reviewed_pull_request_set: reviewed_pull_request_set(
          pull_request_set.entries,
        ),
      ))
    }
  }
}

fn latest_pull_request_set_artifact(
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

fn render_merge_confirmation(confirmation: MergeConfirmation) -> String {
  string.join(
    [
      "Approve merge for "
        <> confirmation.ticket_identifier
        <> " ("
        <> confirmation.ticket_id
        <> ")?",
      "",
      "Reviewed commits:",
      render_reviewed_commits(confirmation.reviewed_commit_set),
      "",
      "Reviewed pull requests:",
      render_reviewed_pull_requests(confirmation.reviewed_pull_request_set),
      "",
      "Type 'yes' to confirm: ",
    ],
    with: "\n",
  )
}

fn render_reviewed_commits(commits: List(review.ReviewedCommit)) -> String {
  case commits {
    [] -> "(none)"
    _ ->
      commits
      |> list.map(fn(commit) {
        "- " <> commit.repo_binding_id <> " @ " <> commit.commit_id
      })
      |> string.join(with: "\n")
  }
}

fn render_reviewed_pull_requests(
  pull_requests: List(review.ReviewedPullRequest),
) -> String {
  case pull_requests {
    [] -> "(none)"
    _ ->
      pull_requests
      |> list.map(fn(pull_request) {
        "- "
        <> pull_request.pull_request_ref
        <> " @ "
        <> pull_request.reviewed_head_commit_id
      })
      |> string.join(with: "\n")
  }
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
  case
    string.trim(repo_binding_id),
    string.trim(commit_id),
    string.trim(pull_request_ref),
    string.trim(head_commit_id)
  {
    "", _, _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty repo binding id",
      )
    _, "", _, _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty commit id",
      )
    _, _, "", _ ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty pull request ref",
      )
    _, _, _, "" ->
      decode.failure(
        invalid_pull_request_entry(),
        expected: "non-empty head commit id",
      )
    _, _, _, _ ->
      decode.success(PullRequestArtifactEntry(
        repo_binding_id: repo_binding_id,
        commit_id: commit_id,
        pull_request_ref: pull_request_ref,
        head_commit_id: head_commit_id,
      ))
  }
}

fn invalid_pull_request_entry() -> PullRequestArtifactEntry {
  PullRequestArtifactEntry(
    repo_binding_id: "",
    commit_id: "",
    pull_request_ref: "",
    head_commit_id: "",
  )
}
