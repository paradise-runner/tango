import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tango/domain/lifecycle
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/run
import tango/domain/ticket

pub type Claim {
  Claim(ticket_id: String, run_id: String, repository_keys: List(String))
}

pub type DispatchPlan {
  DispatchPlan(ticket: ticket.Ticket, run_kind: run.RunKind)
}

pub type Scheduler {
  Scheduler(max_concurrent_workers: Int, claims: Dict(String, Claim))
}

pub type ClaimError {
  AlreadyClaimed(String)
  ConcurrencyLimitReached
  RepositoryAlreadyClaimed(String)
  TicketIneligible(List(ticket.DispatchIneligibility))
}

pub fn new(max_concurrent_workers: Int) -> Scheduler {
  Scheduler(max_concurrent_workers: max_concurrent_workers, claims: dict.new())
}

pub fn claim(
  scheduler: Scheduler,
  item: ticket.Ticket,
  run_id: String,
) -> Result(Scheduler, ClaimError) {
  claim_run(scheduler, item, run.Execution, run_id)
}

pub fn claim_run(
  scheduler: Scheduler,
  item: ticket.Ticket,
  run_kind: run.RunKind,
  run_id: String,
) -> Result(Scheduler, ClaimError) {
  let already_claimed = dict.has_key(scheduler.claims, item.id)
  let concurrency_available =
    dict.size(scheduler.claims) < scheduler.max_concurrent_workers
  case
    ticket.dispatch_eligibility_for(
      item,
      run_kind,
      ticket.DispatchContext(
        already_claimed: already_claimed,
        concurrency_available: concurrency_available,
        repos_valid: repo.validate_all(item.repo_bindings) |> result.is_ok,
      ),
    )
  {
    Error(errors) -> Error(TicketIneligible(errors))
    Ok(_) -> claim_if_repositories_available(scheduler, item, run_id)
  }
}

pub fn release(scheduler: Scheduler, ticket_id: String) -> Scheduler {
  Scheduler(..scheduler, claims: dict.delete(scheduler.claims, ticket_id))
}

pub fn dispatchable(
  scheduler: Scheduler,
  tickets: List(ticket.Ticket),
) -> List(ticket.Ticket) {
  dispatchable_runs(scheduler, tickets)
  |> list.map(fn(plan) { plan.ticket })
}

pub fn dispatchable_runs(
  scheduler: Scheduler,
  tickets: List(ticket.Ticket),
) -> List(DispatchPlan) {
  collect_dispatchable_runs(scheduler, tickets, [])
  |> list.sort(fn(left: DispatchPlan, right: DispatchPlan) {
    ticket.compare_for_dispatch(left.ticket, right.ticket)
  })
}

pub fn should_release(item: ticket.Ticket) -> Bool {
  !lifecycle.is_dispatch_state(item.state)
}

fn claim_if_repositories_available(
  scheduler: Scheduler,
  item: ticket.Ticket,
  run_id: String,
) -> Result(Scheduler, ClaimError) {
  let repository_keys = repository_keys(item)
  case first_claimed_repository(scheduler, repository_keys) {
    Ok(_) -> {
      let claim =
        Claim(
          ticket_id: item.id,
          run_id: run_id,
          repository_keys: repository_keys,
        )
      Ok(
        Scheduler(
          ..scheduler,
          claims: dict.insert(scheduler.claims, item.id, claim),
        ),
      )
    }
    Error(repository_id) -> Error(RepositoryAlreadyClaimed(repository_id))
  }
}

fn repositories_available(
  scheduler: Scheduler,
  repository_ids: List(String),
) -> Bool {
  first_claimed_repository(scheduler, repository_ids) |> result.is_ok
}

fn first_claimed_repository(
  scheduler: Scheduler,
  repository_ids: List(String),
) -> Result(Nil, String) {
  case repository_ids {
    [] -> Ok(Nil)
    [id, ..rest] ->
      case
        scheduler.claims
        |> dict.to_list
        |> list.any(fn(entry) { list.contains(entry.1.repository_keys, id) })
      {
        True -> Error(id)
        False -> first_claimed_repository(scheduler, rest)
      }
  }
}

fn repository_keys(item: ticket.Ticket) -> List(String) {
  item.repo_bindings
  |> list.map(fn(binding) { binding.location })
}

fn desired_run_kind(item: ticket.Ticket) -> Option(run.RunKind) {
  case registry_sync_pending(item), item.state {
    True, _ -> Some(run.RegistrySync)
    False, lifecycle.Queued | False, lifecycle.ChangesRequested ->
      Some(run.Execution)
    False, lifecycle.Merging -> Some(run.MergeRun)
    _, _ -> None
  }
}

fn registry_sync_pending(item: ticket.Ticket) -> Bool {
  case
    needs_dedicated_registry_sync(item.state),
    item.registry_status_mapping,
    item.observed_external_status_id
  {
    True, Some(mapping), Some(observed) ->
      registry_status.resolve(
        mapping,
        lifecycle.registry_status_role(item.state),
      ).id
      != observed
    True, Some(_), None -> True
    _, _, _ -> False
  }
}

fn needs_dedicated_registry_sync(state: lifecycle.LifecycleState) -> Bool {
  state == lifecycle.Onboarded
  || state == lifecycle.AwaitingHumanReview
  || state == lifecycle.Blocked
  || state == lifecycle.Failed
}

fn collect_dispatchable_runs(
  scheduler: Scheduler,
  tickets: List(ticket.Ticket),
  acc: List(DispatchPlan),
) -> List(DispatchPlan) {
  case tickets {
    [] -> list.reverse(acc)
    [item, ..rest] ->
      case desired_run_kind(item) {
        None -> collect_dispatchable_runs(scheduler, rest, acc)
        Some(run_kind) ->
          case
            ticket.dispatch_eligibility_for(
              item,
              run_kind,
              ticket.DispatchContext(
                already_claimed: dict.has_key(scheduler.claims, item.id),
                concurrency_available: dict.size(scheduler.claims)
                  < scheduler.max_concurrent_workers,
                repos_valid: repo.validate_all(item.repo_bindings)
                  |> result.is_ok,
              ),
            )
            |> result.is_ok
            && repositories_available(scheduler, repository_keys(item))
          {
            True ->
              collect_dispatchable_runs(scheduler, rest, [
                DispatchPlan(ticket: item, run_kind: run_kind),
                ..acc
              ])
            False -> collect_dispatchable_runs(scheduler, rest, acc)
          }
      }
  }
}
