import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tango/app/command
import tango/domain/block
import tango/domain/lifecycle
import tango/domain/session
import tango/domain/ticket
import tango/store/store

pub type ProjectionIssue {
  MissingMainSession(String)
  InvalidMainSession(String)
  MissingAuxSession(String)
  InvalidAuxSession(String)
  DuplicateAuxSessionReference(String)
  MissingActiveBlock(String)
  InvalidActiveBlock(String)
}

pub type ReconcileResult(state) {
  ReconcileResult(
    state: state,
    ticket: ticket.Ticket,
    issues: List(ProjectionIssue),
    changed: Bool,
  )
}

pub fn reconcile_all(
  backend: store.Store(state),
  state: state,
  now: String,
  block_id: fn(ticket.Ticket) -> String,
  event_id: fn(ticket.Ticket) -> String,
) -> Result(#(state, List(ReconcileResult(state))), command.CommandError) {
  use tickets <- result.try(
    backend.list_tickets(state)
    |> result.map_error(command.StoreFailure),
  )
  reconcile_remaining(backend, state, tickets, now, block_id, event_id, [])
}

pub fn inspect_ticket(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
) -> Result(List(ProjectionIssue), store.StoreError) {
  use main_issues <- result.try(inspect_main_session(backend, state, item))
  use aux_issues <- result.try(inspect_aux_sessions(backend, state, item))
  use block_issues <- result.try(inspect_active_block(backend, state, item))
  Ok(list.append(main_issues, list.append(aux_issues, block_issues)))
}

pub fn reconcile_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  block_id: String,
  event_id: String,
  now: String,
) -> Result(ReconcileResult(state), command.CommandError) {
  use item <- result.try(
    backend.get_ticket(state, ticket_id)
    |> result.map_error(command.StoreFailure),
  )
  use issues <- result.try(
    inspect_ticket(backend, state, item)
    |> result.map_error(command.StoreFailure),
  )
  case
    issues,
    lifecycle.is_terminal(item.state),
    item.state == lifecycle.Blocked
  {
    [], _, _ ->
      Ok(ReconcileResult(state: state, ticket: item, issues: [], changed: False))
    _, True, _ | _, _, True ->
      Ok(ReconcileResult(
        state: state,
        ticket: item,
        issues: issues,
        changed: False,
      ))
    _, False, False -> {
      let record =
        block.BlockRecord(
          id: block_id,
          ticket_id: ticket_id,
          reason: "Startup reconciliation found invalid projection references: "
            <> string.inspect(issues),
          resolution_instructions: Some(
            "Restore or repair the referenced durable records, then unblock the ticket.",
          ),
          blocked_from: item.state,
          resume_state: resume_state(item.state),
          created_by: "orchestrator",
          created_at: now,
          resolved_by: None,
          resolved_at: None,
        )
      use blocked <- result.try(command.block_ticket(
        backend,
        state,
        ticket_id,
        record,
        event_id,
        "orchestrator",
        now,
      ))
      Ok(ReconcileResult(
        state: blocked.state,
        ticket: blocked.value,
        issues: issues,
        changed: True,
      ))
    }
  }
}

fn inspect_main_session(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
) -> Result(List(ProjectionIssue), store.StoreError) {
  case item.main_session_id {
    None -> Ok([])
    Some(id) ->
      case backend.get_session(state, item.id, id) {
        Error(store.NotFound(_)) -> Ok([MissingMainSession(id)])
        Error(error) -> Error(error)
        Ok(agent_session) ->
          case
            agent_session.ticket_id == item.id,
            agent_session.role,
            agent_session.kind
          {
            True, session.Main, session.Implementation -> Ok([])
            _, _, _ -> Ok([InvalidMainSession(id)])
          }
      }
  }
}

fn inspect_aux_sessions(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
) -> Result(List(ProjectionIssue), store.StoreError) {
  inspect_aux_ids(backend, state, item.id, item.aux_session_ids, [], [])
}

fn inspect_aux_ids(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  remaining: List(String),
  seen: List(String),
  issues: List(ProjectionIssue),
) -> Result(List(ProjectionIssue), store.StoreError) {
  case remaining {
    [] -> Ok(list.reverse(issues))
    [id, ..rest] ->
      case list.contains(seen, id) {
        True ->
          inspect_aux_ids(backend, state, ticket_id, rest, seen, [
            DuplicateAuxSessionReference(id),
            ..issues
          ])
        False ->
          case backend.get_session(state, ticket_id, id) {
            Error(store.NotFound(_)) ->
              inspect_aux_ids(backend, state, ticket_id, rest, [id, ..seen], [
                MissingAuxSession(id),
                ..issues
              ])
            Error(error) -> Error(error)
            Ok(agent_session) -> {
              let valid =
                agent_session.ticket_id == ticket_id
                && agent_session.role == session.Aux
              let issues = case valid {
                True -> issues
                False -> [InvalidAuxSession(id), ..issues]
              }
              inspect_aux_ids(
                backend,
                state,
                ticket_id,
                rest,
                [id, ..seen],
                issues,
              )
            }
          }
      }
  }
}

fn inspect_active_block(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
) -> Result(List(ProjectionIssue), store.StoreError) {
  case item.active_block_id {
    None ->
      case item.state == lifecycle.Blocked {
        True -> Ok([MissingActiveBlock("")])
        False -> Ok([])
      }
    Some(id) ->
      case backend.get_block(state, item.id, id) {
        Error(store.NotFound(_)) -> Ok([MissingActiveBlock(id)])
        Error(error) -> Error(error)
        Ok(record) ->
          case
            item.state == lifecycle.Blocked,
            record.ticket_id == item.id,
            record.resolved_at == None
          {
            True, True, True -> Ok([])
            _, _, _ -> Ok([InvalidActiveBlock(id)])
          }
      }
  }
}

fn reconcile_remaining(
  backend: store.Store(state),
  state: state,
  remaining: List(ticket.Ticket),
  now: String,
  block_id: fn(ticket.Ticket) -> String,
  event_id: fn(ticket.Ticket) -> String,
  reconciled: List(ReconcileResult(state)),
) -> Result(#(state, List(ReconcileResult(state))), command.CommandError) {
  case remaining {
    [] -> Ok(#(state, list.reverse(reconciled)))
    [item, ..rest] -> {
      use result <- result.try(reconcile_ticket(
        backend,
        state,
        item.id,
        block_id(item),
        event_id(item),
        now,
      ))
      reconcile_remaining(backend, result.state, rest, now, block_id, event_id, [
        result,
        ..reconciled
      ])
    }
  }
}

fn resume_state(state: lifecycle.LifecycleState) -> lifecycle.LifecycleState {
  case state {
    lifecycle.ChangesRequested -> lifecycle.ChangesRequested
    lifecycle.AwaitingHumanReview | lifecycle.Merging ->
      lifecycle.AwaitingHumanReview
    _ -> lifecycle.Queued
  }
}
