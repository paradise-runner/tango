import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import tango/app/status_map
import tango/config
import tango/domain/registry_status
import tango/process

pub fn github_discover_lists_repository_labels_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", None),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: statuses(),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  status_map.discover(
    operator_config,
    "github",
    Some("example/tango"),
    fn(command, args) {
      command
      |> should.equal("gh")
      args
      |> should.equal([
        "label",
        "list",
        "--repo",
        "example/tango",
        "--json",
        "name",
        "--limit",
        "500",
      ])
      Ok(process.CommandResult(
        exit_code: 0,
        output: "[{\"name\":\"todo\"},{\"name\":\"done\"}]",
      ))
    },
  )
  |> should.equal(
    Ok([
      registry_status.ExternalStatus(id: "done", name: "done"),
      registry_status.ExternalStatus(id: "todo", name: "todo"),
    ]),
  )
}

pub fn validate_marks_complete_github_mapping_validated_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", None),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: statuses(),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  let assert Ok(#(updated, _)) =
    status_map.validate(
      operator_config,
      "github",
      Some("example/tango"),
      fn(_, _) {
        Ok(process.CommandResult(exit_code: 0, output: github_labels()))
      },
    )

  let assert Ok(registry) = dict.get(updated.registries, "github")
  registry.status_map_validated
  |> should.be_true()
}

pub fn validate_rejects_missing_configured_status_id_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", None),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: statuses(),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  status_map.validate(
    operator_config,
    "github",
    Some("example/tango"),
    fn(_, _) {
      Ok(process.CommandResult(
        exit_code: 0,
        output: "[{\"name\":\"status-backlog\"},{\"name\":\"status-todo\"},{\"name\":\"status-active\"},{\"name\":\"status-review\"},{\"name\":\"status-blocked\"},{\"name\":\"status-done\"}]",
      ))
    },
  )
  |> should.equal(
    Error(status_map.MissingMappedStatus("wont_do", "status-canceled")),
  )
}

pub fn set_marks_existing_mapping_unvalidated_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", None),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: statuses(),
            status_map_validated: True,
          ),
        ),
      ]),
    )

  let assert Ok(updated) =
    status_map.set(operator_config, "github", "in_progress", "working")
  let assert Ok(registry) = dict.get(updated.registries, "github")

  dict.get(registry.statuses, "in_progress")
  |> should.equal(Ok("working"))
  registry.status_map_validated
  |> should.equal(False)
}

pub fn forgejo_discover_validates_configured_labels_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", None),
      registries: dict.from_list([
        #(
          "forgejo",
          config.RegistryConfig(
            cli: "fj",
            skill: "forgejo-ticket-system",
            statuses: dict.from_list([
              #("todo", "tango:todo"),
              #("done", "tango:done"),
            ]),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  status_map.discover(
    operator_config,
    "forgejo",
    Some("example/tango"),
    fn(command, args) {
      command
      |> should.equal("fj")
      case args {
        [
          "--style",
          "minimal",
          "issue",
          "search",
          "--repo",
          "example/tango",
          "--labels",
          _,
          "--state",
          "all",
        ] -> Ok(process.CommandResult(exit_code: 0, output: ""))
        _ -> panic as "unexpected Forgejo status-map command"
      }
    },
  )
  |> should.equal(
    Ok([
      registry_status.ExternalStatus(id: "tango:done", name: "tango:done"),
      registry_status.ExternalStatus(id: "tango:todo", name: "tango:todo"),
    ]),
  )
}

pub fn discover_requires_repository_for_label_backed_systems_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", None),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: statuses(),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  status_map.discover(operator_config, "github", None, fn(_, _) {
    panic as "repository validation should happen before CLI calls"
  })
  |> should.equal(Error(status_map.MissingRepository("github")))
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

fn github_labels() -> String {
  "[{\"name\":\"status-backlog\"},{\"name\":\"status-todo\"},{\"name\":\"status-active\"},{\"name\":\"status-review\"},{\"name\":\"status-blocked\"},{\"name\":\"status-done\"},{\"name\":\"status-canceled\"}]"
}
