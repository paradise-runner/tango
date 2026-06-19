import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import tango/attestation/configured as configured_attestation
import tango/config
import tango/git/adapter as git
import tango/harness/codex
import tango/log
import tango/orchestrator
import tango/review_watcher
import tango/runtime
import tango/store_server
import tango/terminal_dashboard
import tango/worker
import tango/worker_supervisor
import tango/workspace/aicasa

pub type Runtime {
  Runtime(
    supervisor: static_supervisor.Supervisor,
    store_name: process.Name(store_server.Message),
    orchestrator_name: process.Name(orchestrator.Message),
    dashboard_name: process.Name(terminal_dashboard.Message),
  )
}

pub fn start(runtime_config: config.Config) -> actor.StartResult(Runtime) {
  let workspace_command =
    resolve_workspace_command(runtime_config.workspace_aicasa.command)
  let dependencies =
    worker.WorkerDependencies(
      workspace: aicasa.adapter(aicasa.AicasaConfig(
        command: workspace_command,
        root: runtime_config.workspace_aicasa.root,
      )),
      git: git.adapter("git"),
      attestation: configured_attestation.adapters(),
      harness: codex.adapter(codex.CodexConfig(
        command: runtime_config.agent_codex.command,
      )),
    )
  let worker_supervisor_name = worker_supervisor.new_name()
  let store_server_name = store_server.new_name()
  let orchestrator_name = orchestrator.new_name()
  let dashboard_name = terminal_dashboard.new_name()
  let operator_id =
    runtime_config.operator_id
    |> option.unwrap("local:unknown")

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(store_server.supervised(
    store_server_name,
    runtime_config.state_dir,
  ))
  |> static_supervisor.add(worker_supervisor.supervised(worker_supervisor_name))
  |> static_supervisor.add(orchestrator.supervised(
    orchestrator_name,
    runtime_config.state_dir,
    store_server_name,
    dependencies,
    runtime_config.orchestrator.max_concurrent_workers,
    runtime_config.orchestrator.poll_interval_ms,
    worker_supervisor_name,
  ))
  |> static_supervisor.add(review_watcher.supervised(
    runtime_config.state_dir,
    store_server_name,
    review_watcher.Dependencies(
      workspace: dependencies.workspace,
      forge: dependencies.attestation.forge,
    ),
    runtime_config.review.watch_interval_ms,
    process.named_subject(orchestrator_name),
    orchestrator.ReviewWatchDue,
  ))
  |> static_supervisor.add(terminal_dashboard.supervised(
    dashboard_name,
    runtime_config.state_dir,
    store_server_name,
    operator_id,
    runtime_config.orchestrator.poll_interval_ms,
  ))
  |> static_supervisor.start
  |> result.map(fn(started) {
    actor.Started(
      pid: started.pid,
      data: Runtime(
        supervisor: started.data,
        store_name: store_server_name,
        orchestrator_name: orchestrator_name,
        dashboard_name: dashboard_name,
      ),
    )
  })
}

pub fn run_foreground(runtime_config: config.Config) -> Result(String, String) {
  use _ <- result.try(validate_runtime_commands(runtime_config))
  log.info(
    "tango runtime starting state_dir="
    <> runtime_config.state_dir
    <> " workspace_root="
    <> runtime_config.workspace_aicasa.root
    <> " poll_interval_ms="
    <> int.to_string(runtime_config.orchestrator.poll_interval_ms)
    <> " max_concurrent_workers="
    <> int.to_string(runtime_config.orchestrator.max_concurrent_workers),
  )
  case start(runtime_config) {
    Ok(_) -> {
      log.info("tango runtime started")
      process.sleep_forever()
      Ok("tango stopped")
    }
    Error(error) -> {
      let reason =
        "failed to start Tango OTP application: " <> string.inspect(error)
      log.error(reason)
      Error(reason)
    }
  }
}

fn validate_runtime_commands(
  runtime_config: config.Config,
) -> Result(Nil, String) {
  let base = [
    #(
      "workspace.aicasa.command",
      resolve_workspace_command(runtime_config.workspace_aicasa.command),
    ),
    #("agent.codex.command", runtime_config.agent_codex.command),
  ]
  let registries =
    runtime_config.registries
    |> dict.to_list
    |> list.map(fn(entry) { #("registries." <> entry.0 <> ".cli", entry.1.cli) })
  let forges =
    runtime_config.forges
    |> dict.to_list
    |> list.map(fn(entry) { #("forges." <> entry.0 <> ".cli", entry.1.cli) })
  let missing =
    list.append(base, list.append(registries, forges))
    |> list.filter(fn(command) {
      runtime.find_executable(command.1) |> option.is_none
    })

  case missing {
    [] -> Ok(Nil)
    _ ->
      Error(
        "startup preflight failed; missing command(s): "
        <> render_missing_commands(missing)
        <> ". Run tango capability install for ticket-system/forge CLIs, or install/update the configured runtime command.",
      )
  }
}

fn resolve_workspace_command(command: String) -> String {
  case
    command,
    runtime.find_executable(command),
    runtime.find_executable("casa")
  {
    "aicasa", option.None, option.Some(_) -> "casa"
    _, _, _ -> command
  }
}

fn render_missing_commands(commands: List(#(String, String))) -> String {
  commands
  |> group_command_paths
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(command) {
    command.0 <> " (" <> string.join(list.reverse(command.1), ", ") <> ")"
  })
  |> string.join(with: ", ")
}

fn group_command_paths(
  commands: List(#(String, String)),
) -> Dict(String, List(String)) {
  commands
  |> list.fold(dict.new(), fn(groups, command) {
    let #(path, executable) = command
    let paths = case dict.get(groups, executable) {
      Ok(existing) -> [path, ..existing]
      Error(_) -> [path]
    }
    dict.insert(groups, executable, paths)
  })
}
