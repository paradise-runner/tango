import gleam/dict
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/attestation/configured as configured_attestation
import tango/config
import tango/process
import tango/runtime
import tango/store/file

pub type InstalledBundle {
  InstalledBundle(
    kind: CapabilityKind,
    name: String,
    cli_command: String,
    cli_path: String,
    skill_path: String,
  )
}

pub type CapabilityKind {
  TicketSystem
  Forge
}

pub type CapabilityError {
  UnsupportedBundle(String)
  MissingAttestationAdapter(String)
  CliNotFound(String)
  InstallerNotFound
  InstallFailed(String)
  Io(String)
  ConfigFailure(config.ConfigError)
}

pub type InstallMode {
  VerifyOrInstallCli
  SkillOnly
}

type Bundle {
  Bundle(
    kind: CapabilityKind,
    name: String,
    cli: String,
    formula: String,
    skill: String,
  )
}

pub fn install(
  root: String,
  operator_config: config.Config,
  kind: CapabilityKind,
  name: String,
  mode: InstallMode,
) -> Result(#(config.Config, InstalledBundle), CapabilityError) {
  install_with(
    root,
    operator_config,
    kind,
    name,
    mode,
    runtime.find_executable,
    fn(command, args) { process.run_command(command, args, [], None) },
  )
}

pub fn install_with(
  root: String,
  operator_config: config.Config,
  kind: CapabilityKind,
  name: String,
  mode: InstallMode,
  find_executable: fn(String) -> Option(String),
  run_command: fn(String, List(String)) -> Result(process.CommandResult, String),
) -> Result(#(config.Config, InstalledBundle), CapabilityError) {
  use bundle <- result.try(resolve_bundle(kind, name))
  use _ <- result.try(require_attestation(bundle))
  use cli_path <- result.try(case mode {
    VerifyOrInstallCli -> ensure_cli(bundle, find_executable, run_command)
    SkillOnly -> Ok("")
  })
  let bundle_root =
    join(join(join(root, "capabilities"), kind_directory(kind)), bundle.name)
  let skill_path = join(bundle_root, "SKILL.md")
  use _ <- result.try(runtime.ensure_dir(bundle_root) |> result.map_error(Io))
  use _ <- result.try(
    file.atomic_replace(skill_path, skill_contents(bundle))
    |> result.map_error(Io),
  )
  use _ <- result.try(
    file.atomic_replace(join(bundle_root, "bundle.toml"), manifest(bundle))
    |> result.map_error(Io),
  )
  let updated = case kind {
    TicketSystem ->
      config.Config(
        ..operator_config,
        registries: dict.insert(
          operator_config.registries,
          bundle.name,
          config.RegistryConfig(
            cli: bundle.cli,
            skill: skill_path,
            statuses: ticket_system_statuses(bundle.name),
            status_map_validated: False,
          ),
        ),
      )
    Forge ->
      config.Config(
        ..operator_config,
        forges: dict.insert(
          operator_config.forges,
          bundle.name,
          config.ForgeConfig(cli: bundle.cli, skill: skill_path),
        ),
      )
  }
  Ok(#(
    updated,
    InstalledBundle(
      kind: kind,
      name: bundle.name,
      cli_command: bundle.cli,
      cli_path: cli_path,
      skill_path: skill_path,
    ),
  ))
}

fn require_attestation(bundle: Bundle) -> Result(Nil, CapabilityError) {
  require_attestation_name(bundle.kind, bundle.name)
}

fn require_attestation_name(
  kind: CapabilityKind,
  name: String,
) -> Result(Nil, CapabilityError) {
  let supported = case kind {
    TicketSystem -> configured_attestation.supports_ticket_system(name)
    Forge -> configured_attestation.supports_forge(name)
  }
  case supported {
    True -> Ok(Nil)
    False -> Error(MissingAttestationAdapter(name))
  }
}

pub fn create_profile(
  operator_config: config.Config,
  name: String,
  ticket_system_name: String,
  forge_name: String,
) -> Result(config.Config, CapabilityError) {
  use _ <- result.try(require_attestation_name(TicketSystem, ticket_system_name))
  use _ <- result.try(require_attestation_name(Forge, forge_name))
  use ticket_system <- result.try(
    config.get_registry(operator_config, ticket_system_name)
    |> result.map_error(ConfigFailure),
  )
  use forge <- result.try(
    config.get_forge(operator_config, forge_name)
    |> result.map_error(ConfigFailure),
  )
  let profile =
    config.CapabilityProfile(
      skills: unique([ticket_system.skill, forge.skill]),
      execution_tools: unique([ticket_system.cli, forge.cli]),
      merge_tools: [forge.cli],
    )
  Ok(
    config.Config(
      ..operator_config,
      capability_profiles: dict.insert(
        operator_config.capability_profiles,
        name,
        profile,
      ),
    ),
  )
}

pub fn installed(operator_config: config.Config) -> List(InstalledBundle) {
  let ticket_systems =
    operator_config.registries
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(name, ticket_system) = entry
      InstalledBundle(
        kind: TicketSystem,
        name: name,
        cli_command: ticket_system.cli,
        cli_path: option_value(runtime.find_executable(ticket_system.cli)),
        skill_path: ticket_system.skill,
      )
    })
  let forges =
    operator_config.forges
    |> dict.to_list
    |> list.map(fn(entry) {
      let #(name, forge) = entry
      InstalledBundle(
        kind: Forge,
        name: name,
        cli_command: forge.cli,
        cli_path: option_value(runtime.find_executable(forge.cli)),
        skill_path: forge.skill,
      )
    })
  list.append(ticket_systems, forges)
  |> list.sort(fn(left, right) {
    string.compare(
      kind_name(left.kind) <> left.name,
      kind_name(right.kind) <> right.name,
    )
  })
}

fn ensure_cli(
  bundle: Bundle,
  find_executable: fn(String) -> Option(String),
  run_command: fn(String, List(String)) -> Result(process.CommandResult, String),
) -> Result(String, CapabilityError) {
  case find_executable(bundle.cli) {
    Some(path) -> Ok(path)
    None -> {
      use brew <- result.try(
        find_executable("brew")
        |> option_result(InstallerNotFound),
      )
      use installed <- result.try(
        run_command(brew, ["install", bundle.formula])
        |> result.map_error(InstallFailed),
      )
      case installed.exit_code, find_executable(bundle.cli) {
        0, Some(path) -> Ok(path)
        0, None -> Error(CliNotFound(bundle.cli))
        _, _ -> Error(InstallFailed(installed.output))
      }
    }
  }
}

fn resolve_bundle(
  kind: CapabilityKind,
  name: String,
) -> Result(Bundle, CapabilityError) {
  case kind, name {
    TicketSystem, "github" ->
      Ok(Bundle(kind, "github", "gh", "gh", "github-ticket-system"))
    TicketSystem, "forgejo" ->
      Ok(Bundle(kind, "forgejo", "fj", "forgejo-cli", "forgejo-ticket-system"))
    Forge, "github" -> Ok(Bundle(kind, "github", "gh", "gh", "github-forge"))
    Forge, "forgejo" ->
      Ok(Bundle(kind, "forgejo", "fj", "forgejo-cli", "forgejo-forge"))
    _, _ -> Error(UnsupportedBundle(name))
  }
}

fn manifest(bundle: Bundle) -> String {
  string.join(
    [
      "schema_version = 1",
      "name = \"" <> bundle.name <> "\"",
      "kind = \"" <> kind_name(bundle.kind) <> "\"",
      "cli = \"" <> bundle.cli <> "\"",
      "skill = \"" <> bundle.skill <> "\"",
    ],
    with: "\n",
  )
  <> "\n"
}

fn skill_contents(bundle: Bundle) -> String {
  case bundle.kind {
    TicketSystem -> ticket_system_skill_contents(bundle)
    Forge -> forge_skill_contents(bundle)
  }
}

fn forge_skill_contents(bundle: Bundle) -> String {
  string.join(
    list.append(
      [
        "---",
        "name: " <> bundle.skill,
        "description: Manage pull requests and forge state using the "
          <> bundle.cli
          <> " CLI for Tango's selected "
          <> bundle.name
          <> " forge.",
        "---",
        "",
        "# " <> bundle.skill,
        "",
        "Use `" <> bundle.cli <> "` for all repository-hosting operations.",
      ],
      list.append(provider_instructions(bundle), [
        "Inspect existing pull requests, comments, checks, and merge state before mutating them.",
        "During implementation, create or update pull requests and stop before merge.",
        "During merge runs, merge only Tango-approved pull-request heads and report partial progress.",
        "Write normalized pull-request and merge artifacts to the Tango workpad.",
      ]),
    ),
    with: "\n",
  )
  <> "\n"
}

fn ticket_system_skill_contents(bundle: Bundle) -> String {
  string.join(
    list.append(
      [
        "---",
        "name: " <> bundle.skill,
        "description: Manage external issues using the "
          <> bundle.cli
          <> " CLI for Tango's selected "
          <> bundle.name
          <> " ticket system.",
        "---",
        "",
        "# " <> bundle.skill,
        "",
        "Use `" <> bundle.cli <> "` for all external ticket operations.",
      ],
      list.append(ticket_system_provider_instructions(bundle), [
        "Fetch the issue before acting and reconcile existing labels, comments, and state.",
        "Follow the provider-specific Tango status contract for external status identifiers.",
        "Post useful progress and handoff comments.",
      ]),
    ),
    with: "\n",
  )
  <> "\n"
}

fn ticket_system_provider_instructions(bundle: Bundle) -> List(String) {
  case bundle.name {
    "github" -> [
      "Use `gh issue view`, `gh issue edit`, `gh issue comment`, and `gh issue close` for issue work.",
      "Use labels for Tango lifecycle roles except `done`.",
      "For non-`done` roles, use `gh issue edit --add-label` and `--remove-label` to reconcile only the requested lifecycle label.",
      "For `done`, close the issue with `gh issue close`; do not create or require a `closed`, `done`, or `tango:done` label.",
      "Do not close the issue during implementation or review handoff.",
      "Close the issue only after Tango-authorized merge completion.",
    ]
    "forgejo" -> [
      "Use `fj issue` commands for issue work and inspect `fj issue --help` before provider mutations.",
      "Reconcile the requested Tango lifecycle label without removing unrelated issue labels.",
    ]
    _ -> []
  }
}

fn provider_instructions(bundle: Bundle) -> List(String) {
  case bundle.name {
    "github" -> [
      "Run commands from the target checkout or pass `-R OWNER/REPO`.",
      "Use `gh pr view`, `gh pr create`, `gh pr comment`, `gh pr checks`, and `gh pr merge` for pull-request work.",
      "Use `gh pr list --head <branch>` to discover existing pull requests before creating one.",
    ]
    "forgejo" -> [
      "Run commands from the target checkout and pass `-R origin` where supported.",
      "Use `fj pr view`, `fj pr create`, `fj pr comment`, `fj pr status`, and `fj pr merge` for pull-request work.",
      "Use `fj pr -R origin search` to discover existing pull requests before creating one.",
    ]
    _ -> []
  }
}

fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/") {
    True -> left <> right
    False -> left <> "/" <> right
  }
}

pub fn kind_name(kind: CapabilityKind) -> String {
  case kind {
    TicketSystem -> "ticket-system"
    Forge -> "forge"
  }
}

fn kind_directory(kind: CapabilityKind) -> String {
  case kind {
    TicketSystem -> "ticket-systems"
    Forge -> "forges"
  }
}

fn ticket_system_statuses(name: String) {
  let done_status = case name {
    "github" -> "closed"
    _ -> "tango:done"
  }

  dict.from_list([
    #("backlog", "tango:backlog"),
    #("todo", "tango:todo"),
    #("in_progress", "tango:in-progress"),
    #("human_review", "tango:human-review"),
    #("merging", "tango:merging"),
    #("blocked", "tango:blocked"),
    #("done", done_status),
    #("wont_do", "tango:wont-do"),
  ])
}

fn unique(values: List(String)) -> List(String) {
  values
  |> list.fold([], fn(acc, value) {
    case list.contains(acc, value) {
      True -> acc
      False -> list.append(acc, [value])
    }
  })
}

fn option_result(value: Option(a), error: e) -> Result(a, e) {
  case value {
    Some(value) -> Ok(value)
    None -> Error(error)
  }
}

fn option_value(value: Option(String)) -> String {
  case value {
    Some(value) -> value
    None -> ""
  }
}
