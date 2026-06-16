import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import tango/config
import tango/store/file

pub fn config_round_trips_minimal_toml_test() {
  let value =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:operator")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["ticket-skill"],
            execution_tools: ["forge"],
            merge_tools: ["forge"],
          ),
        ),
      ]),
      registries: dict.from_list([
        #(
          "linear",
          config.RegistryConfig(
            cli: "linear",
            skill: "linear-registry",
            statuses: statuses(),
            status_map_validated: True,
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "gh", skill: "github-forge")),
        #("forgejo", config.ForgeConfig(cli: "fj", skill: "forgejo-forge")),
      ]),
    )

  value
  |> config.encode
  |> config.parse
  |> should.equal(Ok(value))
}

fn statuses() {
  dict.from_list([
    #("backlog", "status-backlog"),
    #("todo", "status-todo"),
    #("in_progress", "status-active"),
    #("human_review", "status-review"),
    #("merging", "status-review"),
    #("blocked", "status-blocked"),
    #("done", "status-done"),
    #("wont_do", "status-canceled"),
  ])
}

pub fn load_missing_config_returns_none_test() {
  let assert Ok(root) = file.temporary_directory("tango-config-missing")

  config.load(root <> "/config.toml")
  |> should.equal(Ok(None))

  file.remove_tree(root)
  |> should.be_ok()
}

pub fn parse_rejects_invalid_runtime_settings_test() {
  config.parse(
    "[state]\n"
    <> "dir = \"/tmp/tango\"\n\n"
    <> "[workspace.aicasa]\n"
    <> "command = \"aicasa\"\n"
    <> "root = \"\"\n",
  )
  |> should.equal(
    Error(config.InvalidConfig("workspace.aicasa.root must not be empty")),
  )
}

pub fn runtime_root_rebases_default_workspace_root_test() {
  let loaded =
    config.Config(
      ..config.defaults("/persisted/tango", None),
      workspace_aicasa: config.WorkspaceConfig(
        command: "aicasa",
        root: "/persisted/tango/workspaces",
      ),
    )

  config.with_runtime_root(loaded, "/runtime/tango")
  |> should.equal(
    config.Config(
      ..loaded,
      state_dir: "/runtime/tango",
      workspace_aicasa: config.WorkspaceConfig(
        command: "aicasa",
        root: "/runtime/tango/workspaces",
      ),
    ),
  )
}
