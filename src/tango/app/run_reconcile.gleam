import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tango/app/command
import tango/domain/block
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/run
import tango/domain/ticket
import tango/store/store

pub type InterruptedResult(state) {
  InterruptedResult(
    state: state,
    ticket: ticket.Ticket,
    interrupted_runs: List(run.RunAttempt),
  )
}

pub fn reconcile_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  now: String,
  event_id: fn(run.RunAttempt) -> String,
  merge_block_id: fn(run.RunAttempt) -> String,
) -> Result(InterruptedResult(state), command.CommandError) {
  use item <- result.try(
    backend.get_ticket(state, ticket_id)
    |> result.map_error(command.StoreFailure),
  )
  use runs <- result.try(
    backend.list_runs(state, ticket_id)
    |> result.map_error(command.StoreFailure),
  )
  let active = list.filter(runs, fn(attempt) { run.is_active(attempt.status) })
  reconcile_runs(
    backend,
    state,
    item,
    active,
    now,
    event_id,
    merge_block_id,
    [],
  )
}

fn reconcile_runs(
  backend: store.Store(state),
  state: state,
  item: ticket.Ticket,
  remaining: List(run.RunAttempt),
  now: String,
  event_id: fn(run.RunAttempt) -> String,
  merge_block_id: fn(run.RunAttempt) -> String,
  interrupted: List(run.RunAttempt),
) -> Result(InterruptedResult(state), command.CommandError) {
  case remaining {
    [] ->
      Ok(InterruptedResult(
        state: state,
        ticket: item,
        interrupted_runs: list.reverse(interrupted),
      ))
    [attempt, ..rest] -> {
      use failed <- result.try(
        run.interrupt(attempt, now)
        |> result.map_error(command.RunFailure),
      )
      use state <- result.try(
        backend.save_run(state, failed)
        |> result.map_error(command.StoreFailure),
      )
      use state <- result.try(
        backend.append_event(
          state,
          event.new(
            id: event_id(attempt),
            ticket_id: Some(item.id),
            type_: "run.interrupted",
            occurred_at: now,
            actor: "orchestrator",
            payload: dict.from_list([#("run_id", attempt.id)]),
          ),
        )
        |> result.map_error(command.StoreFailure),
      )
      case attempt.kind {
        run.MergeRun -> {
          let record =
            block.BlockRecord(
              id: merge_block_id(attempt),
              ticket_id: item.id,
              reason: "Merge run was interrupted; external merge progress may be uncertain.",
              resolution_instructions: Some(
                "Inspect pull requests and external ticket state, then unblock and invoke merge again.",
              ),
              blocked_from: item.state,
              resume_state: lifecycle.AwaitingHumanReview,
              created_by: "orchestrator",
              created_at: now,
              resolved_by: None,
              resolved_at: None,
            )
          use blocked <- result.try(command.block_ticket(
            backend,
            state,
            item.id,
            record,
            merge_block_id(attempt) <> "-event",
            "orchestrator",
            now,
          ))
          reconcile_runs(
            backend,
            blocked.state,
            blocked.value,
            rest,
            now,
            event_id,
            merge_block_id,
            [failed, ..interrupted],
          )
        }
        run.Execution -> {
          let item =
            ticket.Ticket(..item, state: attempt.resume_state, updated_at: now)
          use state <- result.try(
            backend.save_ticket(state, item)
            |> result.map_error(command.StoreFailure),
          )
          reconcile_runs(
            backend,
            state,
            item,
            rest,
            now,
            event_id,
            merge_block_id,
            [failed, ..interrupted],
          )
        }
        run.ReviewWatch | run.RegistrySync ->
          reconcile_runs(
            backend,
            state,
            item,
            rest,
            now,
            event_id,
            merge_block_id,
            [failed, ..interrupted],
          )
      }
    }
  }
}
