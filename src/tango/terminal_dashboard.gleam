import gleam/erlang/process
import gleam/option.{Some}
import gleam/otp/actor
import gleam/otp/supervision
import tango/dashboard
import tango/runtime
import tango/store/store
import tango/store_server

pub type Message {
  Refresh
  GetSnapshot(
    process.Subject(Result(dashboard.DashboardSnapshot, store.StoreError)),
  )
}

pub type State {
  State(
    state_dir: String,
    store_name: process.Name(store_server.Message),
    operator_id: String,
    interval_ms: Int,
    latest: Result(dashboard.DashboardSnapshot, store.StoreError),
    subject: process.Subject(Message),
  )
}

pub fn new_name() -> process.Name(Message) {
  process.new_name("tango_terminal_dashboard")
}

pub fn start(
  name: process.Name(Message),
  state_dir: String,
  store_name: process.Name(store_server.Message),
  operator_id: String,
  interval_ms: Int,
) {
  actor.new_with_initialiser(5000, fn(subject) {
    let latest = snapshot(state_dir, store_name, operator_id)
    process.send_after(subject, interval_ms, Refresh)
    Ok(
      actor.initialised(State(
        state_dir: state_dir,
        store_name: store_name,
        operator_id: operator_id,
        interval_ms: interval_ms,
        latest: latest,
        subject: subject,
      )),
    )
  })
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  state_dir: String,
  store_name: process.Name(store_server.Message),
  operator_id: String,
  interval_ms: Int,
) {
  supervision.worker(fn() {
    start(name, state_dir, store_name, operator_id, interval_ms)
  })
}

pub fn get_snapshot(
  name: process.Name(Message),
) -> Result(dashboard.DashboardSnapshot, store.StoreError) {
  process.call(process.named_subject(name), waiting: 5000, sending: GetSnapshot)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Refresh -> {
      let latest =
        snapshot(state.state_dir, state.store_name, state.operator_id)
      process.send_after(state.subject, state.interval_ms, Refresh)
      actor.continue(State(..state, latest: latest))
    }
    GetSnapshot(reply) -> {
      process.send(reply, state.latest)
      actor.continue(state)
    }
  }
}

fn snapshot(
  state_dir: String,
  store_name: process.Name(store_server.Message),
  operator_id: String,
) -> Result(dashboard.DashboardSnapshot, store.StoreError) {
  dashboard.dashboard_snapshot_with_runtime(
    store_server.store(),
    store_name,
    runtime.now_rfc3339(),
    operator_id,
    Some(state_dir),
  )
}
