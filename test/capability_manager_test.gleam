import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import tango/capability/manager
import tango/config
import tango/process
import tango/store/file

pub fn install_builtin_bundle_persists_skill_and_forge_config_test() {
  let assert Ok(root) = file.temporary_directory("tango-capability")
  let operator_config = config.defaults(root, None)
  let assert Ok(#(updated, installed)) =
    manager.install_with(
      root,
      operator_config,
      manager.Forge,
      "github",
      manager.VerifyOrInstallCli,
      fn(name) {
        case name {
          "gh" -> Some("/tools/gh")
          _ -> None
        }
      },
      fn(_, _) { Ok(process.CommandResult(exit_code: 0, output: "")) },
    )

  installed.cli_path
  |> should.equal("/tools/gh")
  installed.skill_path
  |> should.equal(root <> "/capabilities/forges/github/SKILL.md")
  file.read(installed.skill_path)
  |> should.be_ok()
  let assert Ok(skill) = file.read(installed.skill_path)
  skill
  |> string.contains("gh pr merge")
  |> should.be_true()
  file.read(root <> "/capabilities/forges/github/bundle.toml")
  |> should.be_ok()
  updated.forges
  |> dict.get("github")
  |> should.equal(
    Ok(config.ForgeConfig(
      cli: "gh",
      skill: root <> "/capabilities/forges/github/SKILL.md",
    )),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn missing_cli_and_failed_homebrew_install_fails_without_config_test() {
  manager.install_with(
    "/tmp/tango",
    config.defaults("/tmp/tango", None),
    manager.Forge,
    "forgejo",
    manager.VerifyOrInstallCli,
    fn(name) {
      case name {
        "brew" -> Some("/tools/brew")
        _ -> None
      }
    },
    fn(command, args) {
      command
      |> should.equal("/tools/brew")
      args
      |> should.equal(["install", "forgejo-cli"])
      Ok(process.CommandResult(exit_code: 1, output: "install failed"))
    },
  )
  |> should.equal(Error(manager.InstallFailed("install failed")))
}

pub fn skill_only_install_skips_cli_discovery_and_install_test() {
  let assert Ok(root) = file.temporary_directory("tango-capability-skill-only")
  let assert Ok(#(updated, installed)) =
    manager.install_with(
      root,
      config.defaults(root, None),
      manager.Forge,
      "forgejo",
      manager.SkillOnly,
      fn(_) { panic as "skill-only install must not discover executables" },
      fn(_, _) { panic as "skill-only install must not run package installers" },
    )

  installed.cli_path
  |> should.equal("")
  file.read(installed.skill_path)
  |> should.be_ok()
  updated.forges
  |> dict.get("forgejo")
  |> should.equal(
    Ok(config.ForgeConfig(
      cli: "fj",
      skill: root <> "/capabilities/forges/forgejo/SKILL.md",
    )),
  )

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn profile_creation_uses_installed_bundle_test() {
  let root = "/tmp/tango"
  let operator_config =
    config.Config(
      ..config.defaults(root, None),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: root <> "/capabilities/ticket-systems/github/SKILL.md",
            statuses: dict.new(),
            status_map_validated: False,
          ),
        ),
      ]),
      forges: dict.from_list([
        #(
          "forgejo",
          config.ForgeConfig(
            cli: "fj",
            skill: root <> "/capabilities/forges/forgejo/SKILL.md",
          ),
        ),
      ]),
    )
  let assert Ok(updated) =
    manager.create_profile(operator_config, "default", "github", "forgejo")

  updated.capability_profiles
  |> dict.get("default")
  |> should.equal(
    Ok(
      config.CapabilityProfile(
        skills: [
          root <> "/capabilities/ticket-systems/github/SKILL.md",
          root <> "/capabilities/forges/forgejo/SKILL.md",
        ],
        execution_tools: ["gh", "fj"],
        merge_tools: ["fj"],
      ),
    ),
  )
}

pub fn profile_creation_rejects_provider_without_attestation_adapter_test() {
  let root = "/tmp/tango"
  let operator_config =
    config.Config(
      ..config.defaults(root, None),
      registries: dict.from_list([
        #(
          "linear",
          config.RegistryConfig(
            cli: "linear",
            skill: root <> "/linear/SKILL.md",
            statuses: dict.new(),
            status_map_validated: False,
          ),
        ),
      ]),
      forges: dict.from_list([
        #(
          "github",
          config.ForgeConfig(cli: "gh", skill: root <> "/github/SKILL.md"),
        ),
      ]),
    )

  manager.create_profile(operator_config, "default", "linear", "github")
  |> should.equal(Error(manager.MissingAttestationAdapter("linear")))
}

pub fn ticket_system_install_is_independent_from_forge_config_test() {
  let assert Ok(root) = file.temporary_directory("tango-ticket-system")
  let assert Ok(#(updated, installed)) =
    manager.install_with(
      root,
      config.defaults(root, None),
      manager.TicketSystem,
      "github",
      manager.SkillOnly,
      fn(_) { None },
      fn(_, _) { Ok(process.CommandResult(exit_code: 0, output: "")) },
    )

  installed.skill_path
  |> should.equal(root <> "/capabilities/ticket-systems/github/SKILL.md")
  updated.registries
  |> dict.get("github")
  |> should.be_ok()
  let assert Ok(registry) = dict.get(updated.registries, "github")
  registry.status_map_validated
  |> should.equal(False)
  dict.get(registry.statuses, "todo")
  |> should.equal(Ok("tango:todo"))
  dict.get(registry.statuses, "done")
  |> should.equal(Ok("closed"))
  let assert Ok(skill) = file.read(installed.skill_path)
  skill
  |> string.contains("Use labels for Tango lifecycle roles except `done`.")
  |> should.be_true()
  skill
  |> string.contains("For `done`, close the issue with `gh issue close`")
  |> should.be_true()
  skill
  |> string.contains(
    "Do not close the issue during implementation or review handoff.",
  )
  |> should.be_true()
  updated.forges
  |> dict.get("github")
  |> should.be_error()

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn unsupported_bundle_fails_closed_test() {
  manager.install_with(
    "/tmp/tango",
    config.defaults("/tmp/tango", None),
    manager.Forge,
    "gitlab",
    manager.VerifyOrInstallCli,
    fn(_) { None },
    fn(_, _) { Ok(process.CommandResult(exit_code: 0, output: "")) },
  )
  |> should.equal(Error(manager.UnsupportedBundle("gitlab")))
}
