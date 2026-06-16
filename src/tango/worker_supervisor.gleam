import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import tango/domain/run
import tango/store_server
import tango/worker

pub type WorkerMessage {
  WorkerExited(ticket_id: String, run_id: String, result: Result(Nil, Nil))
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
        worker.execute(
          store_server.store(),
          start.store_name,
          start.state_dir,
          start.dependencies,
          start.attempt,
        )
        |> collapse_result
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

fn collapse_result(result: Result(a, b)) -> Result(Nil, Nil) {
  case result {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}
