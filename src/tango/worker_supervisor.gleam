import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import gleam/result
import tango/domain/run
import tango/runtime
import tango/store_server
import tango/worker

pub type WorkerMessage {
  WorkerExited(ticket_id: String, run_id: String, result: Result(Nil, String))
}

pub type WorkerStart(message) {
  WorkerStart(
    state_dir: String,
    store_name: process.Name(store_server.Message),
    dependencies: worker.WorkerDependencies,
    attempt: run.RunAttempt,
    notify: process.Subject(message),
    into_message: fn(WorkerMessage) -> message,
  )
}

pub fn new_name() {
  process.new_name("tango_worker_supervisor")
}

pub fn start(
  name: process.Name(factory_supervisor.Message(WorkerStart(message), Nil)),
) {
  factory_supervisor.worker_child(start_worker)
  |> factory_supervisor.named(name)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.start
}

pub fn supervised(
  name: process.Name(factory_supervisor.Message(WorkerStart(message), Nil)),
) {
  factory_supervisor.worker_child(start_worker)
  |> factory_supervisor.named(name)
  |> factory_supervisor.restart_strategy(supervision.Temporary)
  |> factory_supervisor.supervised
}

pub fn start_child(
  name: process.Name(factory_supervisor.Message(WorkerStart(message), Nil)),
  start: WorkerStart(message),
) {
  factory_supervisor.get_by_name(name)
  |> factory_supervisor.start_child(start)
}

fn start_worker(start: WorkerStart(message)) -> actor.StartResult(Nil) {
  let pid =
    process.spawn(fn() {
      let result =
        runtime.run_guarded(fn() {
          worker.execute(
            store_server.store(),
            start.store_name,
            start.state_dir,
            start.dependencies,
            start.attempt,
          )
          |> result.map(fn(_) { Nil })
          |> result.map_error(worker.error_text)
        })
        |> flatten_guarded_result
      process.send(
        start.notify,
        start.into_message(WorkerExited(
          start.attempt.ticket_id,
          start.attempt.id,
          result,
        )),
      )
    })
  Ok(actor.Started(pid: pid, data: Nil))
}

fn flatten_guarded_result(
  guarded: Result(Result(Nil, String), String),
) -> Result(Nil, String) {
  case guarded {
    Ok(result) -> result
    Error(reason) -> Error("worker crashed: " <> reason)
  }
}
