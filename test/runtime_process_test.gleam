import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
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
