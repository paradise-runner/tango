import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import tango/domain/forge.{type ForgeBinding}
import tango/domain/lifecycle.{type LifecycleState}
import tango/domain/registry_status.{
  type RegistryBinding, type RegistryStatusMapping,
}
import tango/domain/repo.{type RepoBinding, validate_all}
import tango/domain/run

pub type Ticket {
  Ticket(
    id: String,
    identifier: String,
    title: Option(String),
    priority: Option(Int),
    labels: List(String),
    lifecycle_policy: Option(String),
    state: LifecycleState,
    repo_bindings: List(RepoBinding),
    external_ref: Option(String),
    registry_binding: Option(RegistryBinding),
    registry_status_mapping: Option(RegistryStatusMapping),
    forge_binding: Option(ForgeBinding),
    observed_external_status_id: Option(String),
    capability_profile_digest: Option(String),
    main_session_id: Option(String),
    aux_session_ids: List(String),
    active_block_id: Option(String),
    blockers_clear: Bool,
    recently_unblocked: Bool,
    created_at: String,
    updated_at: String,
  )
}

pub type DispatchContext {
  DispatchContext(
    already_claimed: Bool,
    concurrency_available: Bool,
    repos_valid: Bool,
  )
}

pub type DispatchIneligibility {
  InactiveState
  MissingRepositoryBinding
  MissingExternalReference
  MissingRegistryBinding
  MissingRegistryStatusMapping
  MissingForgeBinding
  InvalidRegistryBinding
  InvalidRegistryStatusMapping
  InvalidForgeBinding
  MissingCapabilityProfile
  InvalidRepositoryBinding
  Blocked
  AlreadyClaimed
  ConcurrencyUnavailable
}

pub fn onboarding_errors(ticket: Ticket) -> List(DispatchIneligibility) {
  let errors = []
  let errors =
    append_if(errors, ticket.repo_bindings == [], MissingRepositoryBinding)
  let errors =
    append_if(errors, ticket.external_ref == None, MissingExternalReference)
  let errors = case ticket.registry_binding, ticket.registry_status_mapping {
    None, None -> [
      MissingRegistryStatusMapping,
      MissingRegistryBinding,
      ..errors
    ]
    None, Some(mapping) ->
      case registry_status.validate_mapping(mapping) {
        Ok(_) -> [MissingRegistryBinding, ..errors]
        Error(_) -> [
          InvalidRegistryStatusMapping,
          MissingRegistryBinding,
          ..errors
        ]
      }
    Some(binding), None ->
      case registry_status.validate_binding(binding) {
        Ok(_) -> [MissingRegistryStatusMapping, ..errors]
        Error(_) -> [
          InvalidRegistryBinding,
          MissingRegistryStatusMapping,
          ..errors
        ]
      }
    Some(binding), Some(mapping) ->
      case registry_status.validate_pair(binding, mapping) {
        Ok(_) -> errors
        Error(_) -> [InvalidRegistryStatusMapping, ..errors]
      }
  }
  let errors = case ticket.forge_binding {
    None -> [MissingForgeBinding, ..errors]
    Some(binding) ->
      case forge.validate(binding) {
        Ok(_) -> errors
        Error(_) -> [InvalidForgeBinding, ..errors]
      }
  }
  let errors =
    append_if(
      errors,
      ticket.capability_profile_digest == None,
      MissingCapabilityProfile,
    )
  case validate_all(ticket.repo_bindings) {
    Ok(_) -> errors
    Error(_) -> [InvalidRepositoryBinding, ..errors]
  }
}

pub fn dispatch_eligibility(
  ticket: Ticket,
  context: DispatchContext,
) -> Result(Nil, List(DispatchIneligibility)) {
  dispatch_eligibility_for(ticket, run.Execution, context)
}

pub fn dispatch_eligibility_for(
  ticket: Ticket,
  run_kind: run.RunKind,
  context: DispatchContext,
) -> Result(Nil, List(DispatchIneligibility)) {
  let errors = []
  let errors =
    append_if(
      errors,
      !state_allows_dispatch(ticket.state, run_kind),
      InactiveState,
    )
  let errors = list.append(onboarding_errors(ticket), errors)
  let errors = append_if(errors, !context.repos_valid, InvalidRepositoryBinding)
  let errors =
    append_if(
      errors,
      !ticket.blockers_clear && run_kind != run.RegistrySync,
      Blocked,
    )
  let errors = append_if(errors, context.already_claimed, AlreadyClaimed)
  let errors =
    append_if(errors, !context.concurrency_available, ConcurrencyUnavailable)

  case errors {
    [] -> Ok(Nil)
    errors -> Error(errors)
  }
}

pub fn compare_for_dispatch(left: Ticket, right: Ticket) -> order.Order {
  case compare_priority(left.priority, right.priority) {
    order.Eq ->
      case
        compare_recently_unblocked(
          left.recently_unblocked,
          right.recently_unblocked,
        )
      {
        order.Eq ->
          case string.compare(left.created_at, right.created_at) {
            order.Eq -> string.compare(left.identifier, right.identifier)
            other -> other
          }
        other -> other
      }
    other -> other
  }
}

fn compare_recently_unblocked(left: Bool, right: Bool) -> order.Order {
  case left, right {
    False, True -> order.Lt
    True, False -> order.Gt
    _, _ -> order.Eq
  }
}

fn compare_priority(left: Option(Int), right: Option(Int)) -> order.Order {
  case left, right {
    Some(left), Some(right) -> int.compare(left, right)
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> order.Eq
  }
}

fn append_if(
  errors: List(DispatchIneligibility),
  condition: Bool,
  error: DispatchIneligibility,
) -> List(DispatchIneligibility) {
  case condition {
    True -> [error, ..errors]
    False -> errors
  }
}

fn state_allows_dispatch(state: LifecycleState, run_kind: run.RunKind) -> Bool {
  case run_kind, state {
    run.Execution, lifecycle.Queued
    | run.Execution, lifecycle.ChangesRequested
    | run.ReviewWatch, lifecycle.AwaitingHumanReview
    | run.MergeRun, lifecycle.Merging
    -> True
    run.RegistrySync, lifecycle.Done | run.RegistrySync, lifecycle.Canceled ->
      False
    run.RegistrySync, _ -> True
    _, _ -> False
  }
}
