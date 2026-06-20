import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import tango/application
import tango/config
import tango/runtime
import tango/store/file
import tango/store_server
import tango/terminal_dashboard

pub fn application_starts_complete_runtime_supervision_tree_test() {
  let assert Ok(root) = file.temporary_directory("tango-runtime-processes")
  [root <> "/tickets", root <> "/workpads", root <> "/workspaces"]
  |> list.each(fn(path) {
    runtime.ensure_dir(path)
    |> should.be_ok()
  })
  let runtime_config =
    config.defaults(root, None)
    |> fn(config) {
      config.Config(
        ..config,
        orchestrator: config.OrchestratorConfig(
          ..config.orchestrator,
          poll_interval_ms: 60_000,
        ),
        review: config.ReviewConfig(..config.review, watch_interval_ms: 60_000),
      )
    }

  let assert Ok(started) = application.start(runtime_config)
  process.unlink(started.pid)
  process.sleep(50)

  process.is_alive(started.pid)
  |> should.be_true()
  process.named(started.data.store_name)
  |> should.be_ok()
  process.named(started.data.orchestrator_name)
  |> should.be_ok()
  process.named(started.data.dashboard_name)
  |> should.be_ok()

  let backend = store_server.store()
  backend.list_tickets(started.data.store_name)
  |> should.equal(Ok([]))
  let assert Ok(snapshot) =
    terminal_dashboard.get_snapshot(started.data.dashboard_name)
  snapshot.tickets
  |> should.equal([])

  process.send_abnormal_exit(started.pid, atom.create("shutdown"))
  process.sleep(20)
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn run_foreground_fails_when_workspace_command_is_missing_test() {
  let base = config.defaults("/tmp/tango", None)
  let runtime_config =
    config.Config(
      ..base,
      agent_codex: config.AgentConfig(..base.agent_codex, command: "erl"),
      workspace_aicasa: config.WorkspaceConfig(
        ..base.workspace_aicasa,
        command: "tango-definitely-missing-casa",
      ),
    )

  let result = application.run_foreground(runtime_config)

  result
  |> should.be_error()
  let assert Error(reason) = result
  reason
  |> string.contains("startup preflight failed")
  |> should.be_true()
  reason
  |> string.contains("tango-definitely-missing-casa (workspace.aicasa.command)")
  |> should.be_true()
}

pub fn run_foreground_preflights_configured_provider_clis_test() {
  let base = config.defaults("/tmp/tango", None)
  let runtime_config =
    config.Config(
      ..base,
      agent_codex: config.AgentConfig(..base.agent_codex, command: "erl"),
      workspace_aicasa: config.WorkspaceConfig(
        ..base.workspace_aicasa,
        command: "erl",
      ),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "tango-definitely-missing-provider-cli",
            skill: "/tmp/github-ticket-system-skill.md",
            statuses: dict.new(),
            status_map_validated: True,
          ),
        ),
      ]),
      forges: dict.from_list([
        #(
          "github",
          config.ForgeConfig(
            cli: "tango-definitely-missing-provider-cli",
            skill: "/tmp/github-forge-skill.md",
          ),
        ),
      ]),
    )

  let result = application.run_foreground(runtime_config)

  result
  |> should.be_error()
  let assert Error(reason) = result
  reason
  |> string.contains(
    "tango-definitely-missing-provider-cli (registries.github.cli, forges.github.cli)",
  )
  |> should.be_true()
  reason
  |> string.contains("Run tango capability install")
  |> should.be_true()
}

pub fn run_foreground_preflights_selected_opencode_command_test() {
  let base = config.defaults("/tmp/tango", None)
  let runtime_config =
    config.Config(
      ..base,
      agent_runtime: config.OpencodeRuntime,
      agent_codex: config.AgentConfig(
        ..base.agent_codex,
        command: "tango-definitely-missing-codex",
      ),
      agent_opencode: config.OpencodeAgentConfig(
        ..base.agent_opencode,
        command: "tango-definitely-missing-opencode",
      ),
      workspace_aicasa: config.WorkspaceConfig(
        ..base.workspace_aicasa,
        command: "erl",
      ),
    )

  let result = application.run_foreground(runtime_config)

  result
  |> should.be_error()
  let assert Error(reason) = result
  reason
  |> string.contains(
    "tango-definitely-missing-opencode (agent.opencode.command)",
  )
  |> should.be_true()
  reason
  |> string.contains("agent.codex.command")
  |> should.be_false()
}
