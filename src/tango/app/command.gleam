import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import tango/domain/block
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/review
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/store

pub type CommandError {
  StoreFailure(store.StoreError)
  LifecycleFailure(lifecycle.LifecycleError)
  SessionFailure(session.SessionError)
  BlockFailure(block.BlockError)
  ReviewFailure(review.ReviewError)
  MergeFailure(merge.MergeError)
  RunFailure(run.RunError)
  OnboardingIncomplete(List(ticket.DispatchIneligibility))
  SessionTicketMismatch(session_id: String, ticket_id: String)
  SessionReferenceMissing(String)
  BlockReferenceMissing(String)
  ReviewReferenceMissing(String)
  BlockRecordStateMismatch(
    expected: lifecycle.LifecycleState,
    got: lifecycle.LifecycleState,
  )
  ApprovalRequiresMergeCommand
}

pub type CommandResult(state, value) {
  CommandResult(state: state, value: value)
}

pub fn queue_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  event_id: String,
  actor: String,
  now: String,
) -> Result(CommandResult(state, ticket.Ticket), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  let onboarding_errors = ticket.onboarding_errors(current)
  case onboarding_errors {
    [_, ..] -> Error(OnboardingIncomplete(onboarding_errors))
    [] -> {
      use _ <- result.try(
        lifecycle.can_transition(
          from: current.state,
          to: lifecycle.Queued,
          context: lifecycle.TransitionContext(
            ..lifecycle.default_transition_context(),
            onboarding_valid: True,
          ),
        )
        |> result.map_error(LifecycleFailure),
      )
      let updated =
        ticket.Ticket(..current, state: lifecycle.Queued, updated_at: now)
      persist_transition(
        backend,
        state,
        updated,
        event_id,
        "ticket.queued",
        actor,
        now,
      )
    }
  }
}

pub fn ensure_main_session(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  new_session: session.AgentSession,
  event_id: String,
  actor: String,
  now: String,
) -> Result(CommandResult(state, session.AgentSession), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  case current.main_session_id {
    Some(id) -> {
      use existing <- result.try(load_session(backend, state, ticket_id, id))
      use _ <- result.try(
        session.put_main(session.empty_topology(), existing)
        |> result.map_error(SessionFailure),
      )
      Ok(CommandResult(state: state, value: existing))
    }
    None -> {
      use _ <- result.try(validate_session_ticket(new_session, ticket_id))
      use _ <- result.try(
        session.put_main(session.empty_topology(), new_session)
        |> result.map_error(SessionFailure),
      )
      use state <- result.try(
        backend.save_session(state, new_session)
        |> result.map_error(StoreFailure),
      )
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: event_id,
          ticket_id: Some(ticket_id),
          type_: "session.main_created",
          occurred_at: now,
          actor: actor,
          payload: dict.from_list([#("session_id", new_session.id)]),
        ),
      ))
      let updated =
        ticket.Ticket(
          ..current,
          main_session_id: Some(new_session.id),
          updated_at: now,
        )
      use state <- result.try(save_ticket(backend, state, updated))
      Ok(CommandResult(state: state, value: new_session))
    }
  }
}

pub fn append_aux_session(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  new_session: session.AgentSession,
  event_id: String,
  actor: String,
  now: String,
) -> Result(CommandResult(state, session.AgentSession), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  use _ <- result.try(validate_session_ticket(new_session, ticket_id))
  use sessions <- result.try(load_referenced_sessions(backend, state, current))
  use topology <- result.try(topology_from_sessions(sessions))
  use _ <- result.try(
    session.append_aux(topology, new_session)
    |> result.map_error(SessionFailure),
  )
  use state <- result.try(
    backend.save_session(state, new_session)
    |> result.map_error(StoreFailure),
  )
  use state <- result.try(append_event(
    backend,
    state,
    event.new(
      id: event_id,
      ticket_id: Some(ticket_id),
      type_: "session.aux_created",
      occurred_at: now,
      actor: actor,
      payload: dict.from_list([#("session_id", new_session.id)]),
    ),
  ))
  let updated =
    ticket.Ticket(
      ..current,
      aux_session_ids: list.append(current.aux_session_ids, [new_session.id]),
      updated_at: now,
    )
  use state <- result.try(save_ticket(backend, state, updated))
  Ok(CommandResult(state: state, value: new_session))
}

pub fn block_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  record: block.BlockRecord,
  event_id: String,
  actor: String,
  now: String,
) -> Result(CommandResult(state, ticket.Ticket), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  use record <- result.try(
    block.validate(record) |> result.map_error(BlockFailure),
  )
  case record.ticket_id == ticket_id {
    False -> Error(SessionTicketMismatch(record.id, ticket_id))
    True if record.blocked_from != current.state ->
      Error(BlockRecordStateMismatch(
        expected: current.state,
        got: record.blocked_from,
      ))
    True -> {
      use _ <- result.try(
        lifecycle.can_transition(
          from: current.state,
          to: lifecycle.Blocked,
          context: lifecycle.default_transition_context(),
        )
        |> result.map_error(LifecycleFailure),
      )
      use state <- result.try(
        backend.save_block(state, record)
        |> result.map_error(StoreFailure),
      )
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: event_id,
          ticket_id: Some(ticket_id),
          type_: "ticket.blocked",
          occurred_at: now,
          actor: actor,
          payload: dict.from_list([#("block_id", record.id)]),
        ),
      ))
      let updated =
        ticket.Ticket(
          ..current,
          state: lifecycle.Blocked,
          active_block_id: Some(record.id),
          updated_at: now,
        )
      use state <- result.try(save_ticket(backend, state, updated))
      Ok(CommandResult(state: state, value: updated))
    }
  }
}

pub fn unblock_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  resolved_by: String,
  now: String,
  event_id: String,
) -> Result(CommandResult(state, ticket.Ticket), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  use block_id <- result.try(case current.active_block_id {
    Some(id) -> Ok(id)
    None -> Error(BlockReferenceMissing(ticket_id))
  })
  use record <- result.try(load_block(backend, state, ticket_id, block_id))
  use resolved <- result.try(
    block.resolve(record, resolved_by, now) |> result.map_error(BlockFailure),
  )
  use _ <- result.try(
    lifecycle.can_transition(
      from: current.state,
      to: resolved.resume_state,
      context: lifecycle.TransitionContext(
        ..lifecycle.default_transition_context(),
        active_block_resume_state: Some(resolved.resume_state),
      ),
    )
    |> result.map_error(LifecycleFailure),
  )
  use state <- result.try(
    backend.save_block(state, resolved)
    |> result.map_error(StoreFailure),
  )
  use state <- result.try(append_event(
    backend,
    state,
    event.new(
      id: event_id,
      ticket_id: Some(ticket_id),
      type_: "ticket.unblocked",
      occurred_at: now,
      actor: "human:" <> resolved_by,
      payload: dict.from_list([#("block_id", block_id)]),
    ),
  ))
  let updated =
    ticket.Ticket(
      ..current,
      state: resolved.resume_state,
      active_block_id: None,
      blockers_clear: True,
      recently_unblocked: True,
      updated_at: now,
    )
  use state <- result.try(save_ticket(backend, state, updated))
  Ok(CommandResult(state: state, value: updated))
}

pub fn submit_review(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  decision: review.ReviewDecision,
  event_id: String,
) -> Result(CommandResult(state, review.ReviewDecision), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  use decision <- result.try(
    review.validate(decision) |> result.map_error(ReviewFailure),
  )
  use _ <- result.try(validate_review_ticket(decision, ticket_id))
  case review.is_approval(decision) {
    True -> Error(ApprovalRequiresMergeCommand)
    False -> {
      use _ <- result.try(validate_review_transition(current, decision))
      use state <- result.try(
        backend.save_review(state, decision) |> result.map_error(StoreFailure),
      )
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: event_id,
          ticket_id: Some(ticket_id),
          type_: "review.submitted",
          occurred_at: decision.created_at,
          actor: "human:" <> decision.reviewer_id,
          payload: dict.from_list([
            #("decision", review.to_string(decision.decision)),
          ]),
        ),
      ))
      let updated =
        ticket.Ticket(
          ..current,
          state: review.target_state(decision),
          updated_at: decision.created_at,
        )
      use state <- result.try(save_ticket(backend, state, updated))
      Ok(CommandResult(state: state, value: decision))
    }
  }
}

pub fn approve_merge(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  approval: review.ReviewDecision,
  merge_session: session.AgentSession,
  review_event_id: String,
  merge_event_id: String,
) -> Result(CommandResult(state, review.ReviewDecision), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  use approval <- result.try(
    review.validate(approval) |> result.map_error(ReviewFailure),
  )
  use _ <- result.try(validate_review_ticket(approval, ticket_id))
  use _ <- result.try(validate_session_ticket(merge_session, ticket_id))
  use _ <- result.try(
    session.append_aux(session.empty_topology(), merge_session)
    |> result.map_error(SessionFailure),
  )
  case review.is_approval(approval) {
    False -> Error(ApprovalRequiresMergeCommand)
    True -> {
      use _ <- result.try(
        lifecycle.can_transition(
          from: current.state,
          to: lifecycle.Merging,
          context: lifecycle.TransitionContext(
            ..lifecycle.default_transition_context(),
            human_merge_approval: True,
          ),
        )
        |> result.map_error(LifecycleFailure),
      )
      use sessions <- result.try(load_referenced_sessions(
        backend,
        state,
        current,
      ))
      use topology <- result.try(topology_from_sessions(sessions))
      use _ <- result.try(
        session.append_aux(topology, merge_session)
        |> result.map_error(SessionFailure),
      )
      use state <- result.try(
        backend.save_review(state, approval) |> result.map_error(StoreFailure),
      )
      use state <- result.try(
        backend.save_session(state, merge_session)
        |> result.map_error(StoreFailure),
      )
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: review_event_id,
          ticket_id: Some(ticket_id),
          type_: "review.submitted",
          occurred_at: approval.created_at,
          actor: "human:" <> approval.reviewer_id,
          payload: dict.from_list([
            #("decision", review.to_string(approval.decision)),
          ]),
        ),
      ))
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: merge_event_id,
          ticket_id: Some(ticket_id),
          type_: "merge.started",
          occurred_at: approval.created_at,
          actor: "human:" <> approval.reviewer_id,
          payload: dict.from_list([#("session_id", merge_session.id)]),
        ),
      ))
      let updated =
        ticket.Ticket(
          ..current,
          state: lifecycle.Merging,
          aux_session_ids: list.append(current.aux_session_ids, [
            merge_session.id,
          ]),
          updated_at: approval.created_at,
        )
      use state <- result.try(save_ticket(backend, state, updated))
      Ok(CommandResult(state: state, value: approval))
    }
  }
}

pub fn record_merge_result(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  record: merge.MergeRecord,
  event_id: String,
  block_id: String,
) -> Result(CommandResult(state, merge.MergeRecord), CommandError) {
  use current <- result.try(load_ticket(backend, state, ticket_id))
  use record <- result.try(
    merge.validate(record) |> result.map_error(MergeFailure),
  )
  use _ <- result.try(validate_merge_ticket(record, ticket_id))
  use _ <- result.try(load_review(
    backend,
    state,
    ticket_id,
    record.review_decision_id,
  ))
  use _ <- result.try(
    lifecycle.can_transition(
      from: current.state,
      to: case merge.is_successful(record) {
        True -> lifecycle.Done
        False -> lifecycle.Blocked
      },
      context: lifecycle.TransitionContext(
        ..lifecycle.default_transition_context(),
        merge_complete: merge.is_successful(record),
      ),
    )
    |> result.map_error(LifecycleFailure),
  )
  use state <- result.try(
    backend.save_merge(state, record) |> result.map_error(StoreFailure),
  )
  case merge.is_successful(record) {
    True -> {
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: event_id,
          ticket_id: Some(ticket_id),
          type_: "merge.succeeded",
          occurred_at: record.completed_at,
          actor: "orchestrator",
          payload: dict.from_list([#("merge_id", record.id)]),
        ),
      ))
      let updated =
        ticket.Ticket(
          ..current,
          state: lifecycle.Done,
          updated_at: record.completed_at,
        )
      use state <- result.try(save_ticket(backend, state, updated))
      Ok(CommandResult(state: state, value: record))
    }
    False -> {
      let block_record =
        block.BlockRecord(
          id: block_id,
          ticket_id: ticket_id,
          reason: "Merge record contains pending or failed pull-request entries.",
          resolution_instructions: Some(
            "Inspect partial merge progress, unblock the ticket, and invoke merge again.",
          ),
          blocked_from: current.state,
          resume_state: lifecycle.AwaitingHumanReview,
          created_by: "orchestrator",
          created_at: record.completed_at,
          resolved_by: None,
          resolved_at: None,
        )
      use state <- result.try(append_event(
        backend,
        state,
        event.new(
          id: event_id,
          ticket_id: Some(ticket_id),
          type_: "merge.blocked",
          occurred_at: record.completed_at,
          actor: "orchestrator",
          payload: dict.from_list([#("merge_id", record.id)]),
        ),
      ))
      use blocked <- result.try(block_ticket(
        backend,
        state,
        ticket_id,
        block_record,
        block_id <> "-event",
        "orchestrator",
        record.completed_at,
      ))
      Ok(CommandResult(state: blocked.state, value: record))
    }
  }
}

fn persist_transition(
  backend: store.Store(state),
  state: state,
  updated: ticket.Ticket,
  event_id: String,
  event_type: String,
  actor: String,
  now: String,
) -> Result(CommandResult(state, ticket.Ticket), CommandError) {
  use state <- result.try(append_event(
    backend,
    state,
    event.new(
      id: event_id,
      ticket_id: Some(updated.id),
      type_: event_type,
      occurred_at: now,
      actor: actor,
      payload: dict.from_list([#("state", lifecycle.to_string(updated.state))]),
    ),
  ))
  use state <- result.try(save_ticket(backend, state, updated))
  Ok(CommandResult(state: state, value: updated))
}

fn topology_from_sessions(
  sessions: List(session.AgentSession),
) -> Result(session.SessionTopology, CommandError) {
  add_sessions_to_topology(sessions, session.empty_topology())
}

fn add_sessions_to_topology(
  remaining: List(session.AgentSession),
  topology: session.SessionTopology,
) -> Result(session.SessionTopology, CommandError) {
  case remaining {
    [] -> Ok(topology)
    [agent_session, ..rest] -> {
      let next = case agent_session.role {
        session.Main -> session.put_main(topology, agent_session)
        session.Aux -> session.append_aux(topology, agent_session)
      }
      use topology <- result.try(next |> result.map_error(SessionFailure))
      add_sessions_to_topology(rest, topology)
    }
  }
}

fn validate_session_ticket(
  agent_session: session.AgentSession,
  ticket_id: String,
) -> Result(Nil, CommandError) {
  case agent_session.ticket_id == ticket_id {
    True -> Ok(Nil)
    False -> Error(SessionTicketMismatch(agent_session.id, ticket_id))
  }
}

fn validate_review_ticket(
  decision: review.ReviewDecision,
  ticket_id: String,
) -> Result(Nil, CommandError) {
  case decision.ticket_id == ticket_id {
    True -> Ok(Nil)
    False -> Error(SessionTicketMismatch(decision.id, ticket_id))
  }
}

fn validate_merge_ticket(
  record: merge.MergeRecord,
  ticket_id: String,
) -> Result(Nil, CommandError) {
  case record.ticket_id == ticket_id {
    True -> Ok(Nil)
    False -> Error(SessionTicketMismatch(record.id, ticket_id))
  }
}

fn validate_review_transition(
  current: ticket.Ticket,
  decision: review.ReviewDecision,
) -> Result(Nil, CommandError) {
  case decision.decision {
    review.Defer ->
      case current.state == lifecycle.AwaitingHumanReview {
        True -> Ok(Nil)
        False ->
          Error(
            LifecycleFailure(lifecycle.InvalidTransition(
              from: current.state,
              to: lifecycle.AwaitingHumanReview,
            )),
          )
      }
    _ ->
      lifecycle.can_transition(
        from: current.state,
        to: review.target_state(decision),
        context: lifecycle.default_transition_context(),
      )
      |> result.map_error(LifecycleFailure)
  }
}

fn load_ticket(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(ticket.Ticket, CommandError) {
  backend.get_ticket(state, ticket_id)
  |> result.map_error(StoreFailure)
}

fn save_ticket(
  backend: store.Store(state),
  state: state,
  ticket: ticket.Ticket,
) -> Result(state, CommandError) {
  backend.save_ticket(state, ticket)
  |> result.map_error(StoreFailure)
}

fn load_session(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  session_id: String,
) -> Result(session.AgentSession, CommandError) {
  backend.get_session(state, ticket_id, session_id)
  |> result.map_error(fn(error) {
    case error {
      store.NotFound(_) -> SessionReferenceMissing(session_id)
      error -> StoreFailure(error)
    }
  })
}

fn load_referenced_sessions(
  backend: store.Store(state),
  state: state,
  ticket: ticket.Ticket,
) -> Result(List(session.AgentSession), CommandError) {
  let main = case ticket.main_session_id {
    Some(id) -> [id]
    None -> []
  }
  use sessions <- result.try(
    list.append(main, ticket.aux_session_ids)
    |> list.map(fn(id) { load_session(backend, state, ticket.id, id) })
    |> result.all,
  )
  Ok(sessions)
}

fn load_block(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  block_id: String,
) -> Result(block.BlockRecord, CommandError) {
  backend.get_block(state, ticket_id, block_id)
  |> result.map_error(fn(error) {
    case error {
      store.NotFound(_) -> BlockReferenceMissing(block_id)
      error -> StoreFailure(error)
    }
  })
}

fn load_review(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
  review_id: String,
) -> Result(review.ReviewDecision, CommandError) {
  backend.get_review(state, ticket_id, review_id)
  |> result.map_error(fn(error) {
    case error {
      store.NotFound(_) -> ReviewReferenceMissing(review_id)
      error -> StoreFailure(error)
    }
  })
}

fn append_event(
  backend: store.Store(state),
  state: state,
  item: event.TangoEvent,
) -> Result(state, CommandError) {
  backend.append_event(state, item)
  |> result.map_error(StoreFailure)
}
