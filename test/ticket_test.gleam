import fixtures
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleeunit/should
import tango/domain/lifecycle
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/ticket

fn binding() -> repo.RepoBinding {
  repo.RepoBinding(
    id: "repo-1",
    name: "tango",
    kind: repo.GitRemote,
    location: "https://example.test/tango.git",
    default_branch: None,
    base_ref: None,
    target_branch: None,
    work_branch: None,
    checkout_policy: repo.Clone,
  )
}

fn dispatchable_ticket(
  identifier: String,
  priority: Option(Int),
  recently_unblocked: Bool,
  created_at: String,
) -> ticket.Ticket {
  ticket.Ticket(
    id: identifier,
    identifier: identifier,
    title: None,
    priority: priority,
    labels: [],
    lifecycle_policy: None,
    state: lifecycle.Queued,
    repo_bindings: [binding()],
    external_ref: Some("ticket-ref"),
    registry_binding: Some(fixtures.registry_binding()),
    registry_status_mapping: Some(fixtures.registry_status_mapping()),
    forge_binding: Some(fixtures.forge_binding()),
    observed_external_status_id: None,
    capability_profile_digest: Some("digest"),
    main_session_id: None,
    aux_session_ids: [],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: recently_unblocked,
    created_at: created_at,
    updated_at: created_at,
  )
}

fn available_dispatch_context() -> ticket.DispatchContext {
  ticket.DispatchContext(
    already_claimed: False,
    concurrency_available: True,
    repos_valid: True,
  )
}

pub fn complete_queued_ticket_is_dispatchable_test() {
  dispatchable_ticket("TANGO-1", Some(1), False, "2026-06-07T00:00:00Z")
  |> ticket.dispatch_eligibility(available_dispatch_context())
  |> should.be_ok()
}

pub fn missing_onboarding_fields_are_reported_together_test() {
  let incomplete =
    ticket.Ticket(
      ..dispatchable_ticket("TANGO-1", None, False, "2026-06-07T00:00:00Z"),
      repo_bindings: [],
      external_ref: None,
      registry_binding: None,
      registry_status_mapping: None,
      forge_binding: None,
      capability_profile_digest: None,
    )

  incomplete
  |> ticket.dispatch_eligibility(available_dispatch_context())
  |> should.be_error()
}

pub fn missing_forge_binding_is_not_dispatchable_test() {
  let incomplete =
    ticket.Ticket(
      ..dispatchable_ticket("TANGO-1", None, False, "2026-06-07T00:00:00Z"),
      forge_binding: None,
    )

  incomplete
  |> ticket.onboarding_errors
  |> list.contains(ticket.MissingForgeBinding)
  |> should.be_true()
}

pub fn mismatched_registry_mapping_is_not_dispatchable_test() {
  let mismatched_binding =
    registry_status.RegistryBinding(
      ..fixtures.registry_binding(),
      pinned_mapping_digest: "sha256:different",
    )
  let incomplete =
    ticket.Ticket(
      ..dispatchable_ticket("TANGO-1", None, False, "2026-06-07T00:00:00Z"),
      registry_binding: Some(mismatched_binding),
    )

  incomplete
  |> ticket.dispatch_eligibility(available_dispatch_context())
  |> should.be_error()
}

pub fn dispatch_order_uses_priority_then_unblocked_status_test() {
  let normal =
    dispatchable_ticket("TANGO-2", Some(1), False, "2026-06-07T00:00:00Z")
  let recently_unblocked =
    dispatchable_ticket("TANGO-1", Some(1), True, "2026-06-06T00:00:00Z")
  let no_priority =
    dispatchable_ticket("TANGO-0", None, False, "2026-06-05T00:00:00Z")

  ticket.compare_for_dispatch(normal, recently_unblocked)
  |> should.equal(order.Lt)

  ticket.compare_for_dispatch(recently_unblocked, no_priority)
  |> should.equal(order.Lt)
}
