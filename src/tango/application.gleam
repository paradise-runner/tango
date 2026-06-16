import gleam/erlang/process
import gleam/option
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import tango/agent/codex
import tango/attestation/configured as configured_attestation
import tango/config
import tango/git/adapter as git
import tango/orchestrator
import tango/review_watcher
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
  let dependencies =
    worker.WorkerDependencies(
      workspace: aicasa.adapter(aicasa.AicasaConfig(
        command: runtime_config.workspace_aicasa.command,
        root: runtime_config.workspace_aicasa.root,
      )),
      git: git.adapter("git"),
      attestation: configured_attestation.adapters(),
      agent: codex.adapter(codex.CodexConfig(
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
  case start(runtime_config) {
    Ok(_) -> {
      process.sleep_forever()
      Ok("tango stopped")
    }
    Error(_) -> Error("failed to start Tango OTP application")
  }
}
