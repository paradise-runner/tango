import gleam/dict
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/store

pub type RunCommandError {
  StoreFailure(store.StoreError)
  RunFailure(run.RunError)
  SessionNotFound(String)
  SessionRunMismatch
  TicketStateMismatch
  RunAlreadyReferenced(String)
  RunAlreadyExists(String)
}

pub type RunCommandResult(state) {
  RunCommandResult(state: state, ticket: ticket.Ticket, run: run.RunAttempt)
}

pub fn start(
  backend: store.Store(state),
  state: state,
  attempt: run.RunAttempt,
  event_id: String,
  now: String,
) -> Result(RunCommandResult(state), RunCommandError) {
  use attempt <- result.try(
    run.validate(attempt) |> result.map_error(RunFailure),
  )
  use item <- result.try(
    backend.get_ticket(state, attempt.ticket_id)
    |> result.map_error(StoreFailure),
  )
  use owner <- result.try(
    backend.get_session(state, attempt.ticket_id, attempt.session_id)
    |> result.map_error(fn(error) {
      case error {
        store.NotFound(_) -> SessionNotFound(attempt.session_id)
        error -> StoreFailure(error)
      }
    }),
  )
  use _ <- result.try(validate_start(item, owner, attempt))
  use _ <- result.try(ensure_new_run_id(backend, state, attempt))
  case list.contains(owner.run_attempt_ids, attempt.id) {
    True -> Error(RunAlreadyReferenced(attempt.id))
    False -> {
      use state <- result.try(
        backend.save_run(state, attempt)
        |> result.map_error(StoreFailure),
      )
      let owner =
        session.AgentSession(
          ..owner,
          run_attempt_ids: list.append(owner.run_attempt_ids, [attempt.id]),
          updated_at: now,
        )
      use state <- result.try(
        backend.save_session(state, owner)
        |> result.map_error(StoreFailure),
      )
      use state <- result.try(
        backend.append_event(
          state,
          event.new(
            id: event_id,
            ticket_id: Some(item.id),
            type_: "run.started",
            occurred_at: now,
            actor: "orchestrator",
            payload: dict.from_list([
              #("run_id", attempt.id),
              #("session_id", attempt.session_id),
            ]),
          ),
        )
        |> result.map_error(StoreFailure),
      )
      let item = active_ticket_projection(item, attempt, now)
      use state <- result.try(
        backend.save_ticket(state, item)
        |> result.map_error(StoreFailure),
      )
      Ok(RunCommandResult(state: state, ticket: item, run: attempt))
    }
  }
}

pub fn update_status(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  run_id: String,
  status: run.RunStatus,
  ended_at: Option(String),
  error: Option(String),
) -> Result(#(state, run.RunAttempt), RunCommandError) {
  use attempt <- result.try(
    backend.get_run(state, ticket_id, run_id)
    |> result.map_error(StoreFailure),
  )
  use updated <- result.try(
    run.transition(attempt, status, ended_at, error)
    |> result.map_error(RunFailure),
  )
  use state <- result.try(
    backend.save_run(state, updated)
    |> result.map_error(StoreFailure),
  )
  Ok(#(state, updated))
}

fn validate_start(
  item: ticket.Ticket,
  owner: session.AgentSession,
  attempt: run.RunAttempt,
) -> Result(Nil, RunCommandError) {
  case
    owner.ticket_id == item.id,
    owner.id == attempt.session_id,
    attempt.resume_state == item.state,
    session_matches_run(owner, attempt.kind),
    state_allows_run(item.state, attempt.kind),
    attempt.status == run.PreparingWorkspace
  {
    True, True, True, True, True, True -> Ok(Nil)
    False, _, _, _, _, _ | _, False, _, _, _, _ | _, _, _, False, _, _ ->
      Error(SessionRunMismatch)
    _, _, False, _, _, _ | _, _, _, _, False, _ | _, _, _, _, _, False ->
      Error(TicketStateMismatch)
  }
}

fn ensure_new_run_id(
  backend: store.Store(state),
  state: state,
  attempt: run.RunAttempt,
) -> Result(Nil, RunCommandError) {
  case backend.get_run(state, attempt.ticket_id, attempt.id) {
    Error(store.NotFound(_)) -> Ok(Nil)
    Error(error) -> Error(StoreFailure(error))
    Ok(_) -> Error(RunAlreadyExists(attempt.id))
  }
}

fn session_matches_run(owner: session.AgentSession, kind: run.RunKind) -> Bool {
  case owner.role, owner.kind, kind {
    session.Main, session.Implementation, run.Execution
    | session.Aux, session.Implementation, run.Execution
    -> True
    session.Aux, session.PrFeedback, run.ReviewWatch -> True
    session.Aux, session.RegistrySync, run.RegistrySync -> True
    session.Aux, session.Merge, run.MergeRun -> True
    _, _, _ -> False
  }
}

fn state_allows_run(
  state: lifecycle.LifecycleState,
  kind: run.RunKind,
) -> Bool {
  case kind, state {
    run.Execution, lifecycle.Queued
    | run.Execution, lifecycle.ChangesRequested
    -> True
    run.ReviewWatch, lifecycle.AwaitingHumanReview -> True
    run.RegistrySync, lifecycle.Done | run.RegistrySync, lifecycle.Canceled ->
      False
    run.RegistrySync, _ -> True
    run.MergeRun, lifecycle.Merging -> True
    _, _ -> False
  }
}

fn active_ticket_projection(
  item: ticket.Ticket,
  attempt: run.RunAttempt,
  now: String,
) -> ticket.Ticket {
  let state = case attempt.kind, item.state {
    run.Execution, lifecycle.Queued -> lifecycle.Researching
    run.Execution, lifecycle.ChangesRequested -> lifecycle.Implementing
    _, state -> state
  }
  ticket.Ticket(..item, state: state, updated_at: now)
}
