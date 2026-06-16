import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor
import gleam/otp/supervision
import gleam/result
import tango/app/command
import tango/app/reconcile
import tango/app/run_reconcile
import tango/domain/block
import tango/domain/event
import tango/domain/lifecycle
import tango/domain/review
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/runtime
import tango/scheduler
import tango/store/store
import tango/store_server
import tango/worker
import tango/worker_supervisor

pub type Message {
  Tick
  ReviewWatchDue(String)
  WorkerFinished(worker_supervisor.WorkerMessage)
}

pub type State {
  State(
    state_dir: String,
    store_name: process.Name(store_server.Message),
    dependencies: worker.WorkerDependencies,
    scheduler: scheduler.Scheduler,
    poll_interval_ms: Int,
    subject: process.Subject(Message),
    worker_supervisor_name: process.Name(
      factory_supervisor.Message(worker_supervisor.WorkerStart(Message), Nil),
    ),
  )
}

pub fn new_name() -> process.Name(Message) {
  process.new_name("tango_orchestrator")
}

pub fn start(
  name: process.Name(Message),
  state_dir: String,
  store_name: process.Name(store_server.Message),
  dependencies: worker.WorkerDependencies,
  max_concurrent_workers: Int,
  poll_interval_ms: Int,
  worker_supervisor_name: process.Name(
    factory_supervisor.Message(worker_supervisor.WorkerStart(Message), Nil),
  ),
) {
  actor.new_with_initialiser(5000, fn(subject) {
    let state =
      State(
        state_dir: state_dir,
        store_name: store_name,
        dependencies: dependencies,
        scheduler: scheduler.new(max_concurrent_workers),
        poll_interval_ms: poll_interval_ms,
        subject: subject,
        worker_supervisor_name: worker_supervisor_name,
      )
    reconcile_startup(store_name)
    process.send(subject, Tick)
    Ok(actor.initialised(state) |> actor.returning(subject))
  })
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(
  name: process.Name(Message),
  state_dir: String,
  store_name: process.Name(store_server.Message),
  dependencies: worker.WorkerDependencies,
  max_concurrent_workers: Int,
  poll_interval_ms: Int,
  worker_supervisor_name: process.Name(
    factory_supervisor.Message(worker_supervisor.WorkerStart(Message), Nil),
  ),
) {
  supervision.worker(fn() {
    start(
      name,
      state_dir,
      store_name,
      dependencies,
      max_concurrent_workers,
      poll_interval_ms,
      worker_supervisor_name,
    )
  })
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Tick -> {
      let state = dispatch_available(state)
      process.send_after(state.subject, state.poll_interval_ms, Tick)
      actor.continue(state)
    }
    ReviewWatchDue(ticket_id) ->
      actor.continue(dispatch_review_watch(state, ticket_id))
    WorkerFinished(worker_supervisor.WorkerExited(ticket_id, run_id, _)) -> {
      reconcile_finished_worker(state.store_name, ticket_id, run_id)
      actor.continue(
        State(..state, scheduler: scheduler.release(state.scheduler, ticket_id)),
      )
    }
  }
}

fn dispatch_available(state: State) -> State {
  let backend = store_server.store()
  case backend.list_tickets(state.store_name) {
    Error(_) -> state
    Ok(tickets) ->
      dispatch_plans(
        state,
        scheduler.dispatchable_runs(state.scheduler, tickets),
        backend,
        state.store_name,
      )
  }
}

fn dispatch_review_watch(state: State, ticket_id: String) -> State {
  let backend = store_server.store()
  case backend.get_ticket(state.store_name, ticket_id) {
    Ok(item) ->
      dispatch_plans(
        state,
        [scheduler.DispatchPlan(ticket: item, run_kind: run.ReviewWatch)],
        backend,
        state.store_name,
      )
    Error(_) -> state
  }
}

fn dispatch_plans(
  state: State,
  plans: List(scheduler.DispatchPlan),
  backend: store.Store(process.Name(store_server.Message)),
  store_state: process.Name(store_server.Message),
) -> State {
  case plans {
    [] -> state
    [plan, ..rest] -> {
      let item = plan.ticket
      let run_id = runtime.unique_id("run")
      case scheduler.claim_run(state.scheduler, item, plan.run_kind, run_id) {
        Error(_) -> dispatch_plans(state, rest, backend, store_state)
        Ok(claimed) ->
          case
            prepare_attempt(backend, store_state, item, plan.run_kind, run_id)
          {
            Error(_) ->
              dispatch_plans(
                State(..state, scheduler: scheduler.release(claimed, item.id)),
                rest,
                backend,
                store_state,
              )
            Ok(attempt) -> {
              case
                worker_supervisor.start_child(
                  state.worker_supervisor_name,
                  worker_supervisor.WorkerStart(
                    state_dir: state.state_dir,
                    store_name: state.store_name,
                    dependencies: state.dependencies,
                    attempt: attempt,
                    notify: state.subject,
                    into_message: WorkerFinished,
                  ),
                )
              {
                Ok(_) ->
                  dispatch_plans(
                    State(..state, scheduler: claimed),
                    rest,
                    backend,
                    store_state,
                  )
                Error(_) ->
                  dispatch_plans(
                    State(
                      ..state,
                      scheduler: scheduler.release(claimed, item.id),
                    ),
                    rest,
                    backend,
                    store_state,
                  )
              }
            }
          }
      }
    }
  }
}

fn prepare_attempt(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  item: ticket.Ticket,
  run_kind: run.RunKind,
  run_id: String,
) -> Result(run.RunAttempt, Nil) {
  let now = runtime.now_rfc3339()
  use owner <- result.try(
    ensure_run_session(backend, state, item, run_kind, now)
    |> result.map_error(fn(_) { Nil }),
  )
  let attempt_number = case backend.list_runs(state, item.id) {
    Ok(runs) -> list.length(runs) + 1
    Error(_) -> 1
  }
  case run_kind {
    run.Execution ->
      Ok(run.RunAttempt(
        id: run_id,
        ticket_id: item.id,
        session_id: owner.id,
        kind: run.Execution,
        current_stage: Some(lifecycle.Research),
        stages: [lifecycle.Research, lifecycle.Plan, lifecycle.Implement],
        attempt: attempt_number,
        workspace_path: "",
        agent_runtime: "codex",
        capability_profile_digest: item.capability_profile_digest,
        effective_capabilities: effective_capabilities(item, run.Execution),
        resume_state: item.state,
        started_at: now,
        ended_at: None,
        status: run.PreparingWorkspace,
        error: None,
      ))
    run.ReviewWatch ->
      case backend.list_review_cursors(state, item.id) {
        Ok([]) | Error(store.NotFound(_)) -> Error(Nil)
        Ok(_) ->
          Ok(run.RunAttempt(
            id: run_id,
            ticket_id: item.id,
            session_id: owner.id,
            kind: run.ReviewWatch,
            current_stage: Some(lifecycle.HumanReview),
            stages: [lifecycle.HumanReview],
            attempt: attempt_number,
            workspace_path: "",
            agent_runtime: "codex",
            capability_profile_digest: item.capability_profile_digest,
            effective_capabilities: effective_capabilities(
              item,
              run.ReviewWatch,
            ),
            resume_state: item.state,
            started_at: now,
            ended_at: None,
            status: run.PreparingWorkspace,
            error: None,
          ))
        Error(_) -> Error(Nil)
      }
    run.MergeRun ->
      case has_merge_approval(backend, state, item.id) {
        False -> Error(Nil)
        True ->
          Ok(run.RunAttempt(
            id: run_id,
            ticket_id: item.id,
            session_id: owner.id,
            kind: run.MergeRun,
            current_stage: Some(lifecycle.Merge),
            stages: [lifecycle.Merge],
            attempt: attempt_number,
            workspace_path: "",
            agent_runtime: "codex",
            capability_profile_digest: item.capability_profile_digest,
            effective_capabilities: effective_capabilities(item, run.MergeRun),
            resume_state: item.state,
            started_at: now,
            ended_at: None,
            status: run.PreparingWorkspace,
            error: None,
          ))
      }
    run.RegistrySync ->
      Ok(run.RunAttempt(
        id: run_id,
        ticket_id: item.id,
        session_id: owner.id,
        kind: run.RegistrySync,
        current_stage: None,
        stages: [],
        attempt: attempt_number,
        workspace_path: "",
        agent_runtime: "registry",
        capability_profile_digest: item.capability_profile_digest,
        effective_capabilities: effective_capabilities(item, run.RegistrySync),
        resume_state: item.state,
        started_at: now,
        ended_at: None,
        status: run.PreparingWorkspace,
        error: None,
      ))
  }
}

fn effective_capabilities(
  item: ticket.Ticket,
  run_kind: run.RunKind,
) -> List(String) {
  let registry = case item.registry_binding {
    Some(binding) -> [
      "ticket_system_cli:" <> binding.cli_command,
      "ticket_system_skill:" <> binding.registry_skill,
    ]
    None -> []
  }
  let forge = case item.forge_binding {
    Some(binding) -> [
      "forge_cli:" <> binding.cli_command,
      "forge_skill:" <> binding.forge_skill,
    ]
    None -> []
  }
  case run_kind {
    run.Execution ->
      list.append(["workspace_write"], list.append(registry, forge))
    run.ReviewWatch -> forge
    run.RegistrySync -> registry
    run.MergeRun -> list.append(registry, forge)
  }
}

fn has_merge_approval(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  ticket_id: String,
) -> Bool {
  case backend.list_reviews(state, ticket_id) {
    Ok(reviews) -> list.any(reviews, review.is_approval)
    Error(_) -> False
  }
}

fn ensure_run_session(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  item: ticket.Ticket,
  run_kind: run.RunKind,
  now: String,
) -> Result(session.AgentSession, command.CommandError) {
  case run_kind {
    run.Execution -> {
      case item.state {
        lifecycle.ChangesRequested ->
          append_requested_changes_session(backend, state, item, now)
        _ -> {
          let new_session =
            session.AgentSession(
              id: runtime.unique_id("session"),
              ticket_id: item.id,
              role: session.Main,
              kind: session.Implementation,
              context_session_ids: [],
              runtime_session_id: None,
              run_attempt_ids: [],
              created_at: now,
              updated_at: now,
            )
          command.ensure_main_session(
            backend,
            state,
            item.id,
            new_session,
            runtime.unique_id("event"),
            "orchestrator",
            now,
          )
          |> result.map(fn(command_result) { command_result.value })
        }
      }
    }
    run.ReviewWatch -> {
      let aux_session =
        session.AgentSession(
          id: runtime.unique_id("session"),
          ticket_id: item.id,
          role: session.Aux,
          kind: session.PrFeedback,
          context_session_ids: [],
          runtime_session_id: None,
          run_attempt_ids: [],
          created_at: now,
          updated_at: now,
        )
      command.append_aux_session(
        backend,
        state,
        item.id,
        aux_session,
        runtime.unique_id("event"),
        "orchestrator",
        now,
      )
      |> result.map(fn(command_result) { command_result.value })
    }
    run.MergeRun -> latest_merge_session(backend, state, item)
    run.RegistrySync -> {
      let aux_session =
        session.AgentSession(
          id: runtime.unique_id("session"),
          ticket_id: item.id,
          role: session.Aux,
          kind: session.RegistrySync,
          context_session_ids: [],
          runtime_session_id: None,
          run_attempt_ids: [],
          created_at: now,
          updated_at: now,
        )
      command.append_aux_session(
        backend,
        state,
        item.id,
        aux_session,
        runtime.unique_id("event"),
        "orchestrator",
        now,
      )
      |> result.map(fn(command_result) { command_result.value })
    }
  }
}

fn append_requested_changes_session(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  item: ticket.Ticket,
  now: String,
) -> Result(session.AgentSession, command.CommandError) {
  let context_session_ids =
    implementation_context_session_ids(backend, state, item)
  let aux_session =
    session.AgentSession(
      id: runtime.unique_id("session"),
      ticket_id: item.id,
      role: session.Aux,
      kind: session.Implementation,
      context_session_ids: context_session_ids,
      runtime_session_id: None,
      run_attempt_ids: [],
      created_at: now,
      updated_at: now,
    )
  command.append_aux_session(
    backend,
    state,
    item.id,
    aux_session,
    runtime.unique_id("event"),
    "orchestrator",
    now,
  )
  |> result.map(fn(command_result) { command_result.value })
}

fn implementation_context_session_ids(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  item: ticket.Ticket,
) -> List(String) {
  let main = case item.main_session_id {
    Some(id) -> [id]
    None -> []
  }
  list.append(
    main,
    item.aux_session_ids
      |> list.filter(fn(id) {
        case backend.get_session(state, item.id, id) {
          Ok(agent_session) -> agent_session.kind == session.Implementation
          Error(_) -> False
        }
      }),
  )
}

fn latest_merge_session(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  item: ticket.Ticket,
) -> Result(session.AgentSession, command.CommandError) {
  find_merge_session(
    backend,
    state,
    item.id,
    list.reverse(item.aux_session_ids),
  )
}

fn find_merge_session(
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  ticket_id: String,
  remaining_ids: List(String),
) -> Result(session.AgentSession, command.CommandError) {
  case remaining_ids {
    [] -> Error(command.SessionReferenceMissing("merge-session"))
    [session_id, ..rest] ->
      case backend.get_session(state, ticket_id, session_id) {
        Ok(found) ->
          case found.kind == session.Merge {
            True -> Ok(found)
            False -> find_merge_session(backend, state, ticket_id, rest)
          }
        Error(store.NotFound(_)) ->
          Error(command.SessionReferenceMissing(session_id))
        Error(error) -> Error(command.StoreFailure(error))
      }
  }
}

fn reconcile_startup(state: process.Name(store_server.Message)) -> Nil {
  let backend = store_server.store()
  let now = runtime.now_rfc3339()
  reconcile.reconcile_all(
    backend,
    state,
    now,
    fn(_) { runtime.unique_id("block") },
    fn(_) { runtime.unique_id("event") },
  )
  |> result.map(fn(_) { Nil })
  |> result.unwrap(Nil)
  case backend.list_tickets(state) {
    Error(_) -> Nil
    Ok(tickets) -> {
      tickets
      |> list.each(fn(item) {
        run_reconcile.reconcile_ticket(
          backend,
          state,
          item.id,
          now,
          fn(_) { runtime.unique_id("event") },
          fn(_) { runtime.unique_id("block") },
        )
        |> result.map(fn(_) { Nil })
        |> result.unwrap(Nil)
      })
    }
  }
}

fn reconcile_finished_worker(
  state: process.Name(store_server.Message),
  ticket_id: String,
  run_id: String,
) -> Nil {
  let backend = store_server.store()
  let now = runtime.now_rfc3339()
  run_reconcile.reconcile_ticket(
    backend,
    state,
    ticket_id,
    now,
    fn(_) { runtime.unique_id("event") },
    fn(_) { runtime.unique_id("block") },
  )
  |> result.map(fn(_) { Nil })
  |> result.unwrap(Nil)
  case
    backend.get_ticket(state, ticket_id),
    backend.get_run(state, ticket_id, run_id)
  {
    Ok(item), Ok(attempt) ->
      case
        attempt.status == run.Failed
        || attempt.status == run.TimedOut
        || attempt.status == run.Stalled
        || attempt.status == run.Canceled
      {
        True ->
          recover_failed_projection(Some(attempt), backend, state, item, now)
        False -> Nil
      }
    _, _ -> Nil
  }
}

fn recover_failed_projection(
  attempt: Option(run.RunAttempt),
  backend: store.Store(process.Name(store_server.Message)),
  state: process.Name(store_server.Message),
  item: ticket.Ticket,
  now: String,
) -> Nil {
  case attempt, item.state {
    Some(attempt), lifecycle.Researching
    | Some(attempt), lifecycle.Planning
    | Some(attempt), lifecycle.Implementing
      if attempt.kind == run.Execution
    -> {
      case
        backend.save_ticket(
          state,
          ticket.Ticket(..item, state: attempt.resume_state, updated_at: now),
        )
      {
        Error(_) -> Nil
        Ok(state) ->
          backend.append_event(
            state,
            event.new(
              id: runtime.unique_id("event"),
              ticket_id: Some(item.id),
              type_: "run.retry_scheduled",
              occurred_at: now,
              actor: "orchestrator",
              payload: dict.from_list([#("run_id", attempt.id)]),
            ),
          )
          |> result.map(fn(_) { Nil })
          |> result.unwrap(Nil)
      }
    }
    Some(attempt), lifecycle.Merging if attempt.kind == run.MergeRun -> {
      let block_id = runtime.unique_id("block")
      command.block_ticket(
        backend,
        state,
        item.id,
        block.BlockRecord(
          id: block_id,
          ticket_id: item.id,
          reason: "Merge worker failed; external merge progress may be uncertain.",
          resolution_instructions: Some(
            "Inspect pull requests and external ticket state, then unblock and invoke merge again.",
          ),
          blocked_from: item.state,
          resume_state: lifecycle.AwaitingHumanReview,
          created_by: "orchestrator",
          created_at: now,
          resolved_by: None,
          resolved_at: None,
        ),
        runtime.unique_id("event"),
        "orchestrator",
        now,
      )
      |> result.map(fn(_) { Nil })
      |> result.unwrap(Nil)
    }
    _, _ -> Nil
  }
}
