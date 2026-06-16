import fixtures
import gleam/option.{type Option, None, Some}
import gleeunit/should
import tango/domain/lifecycle
import tango/domain/repo
import tango/domain/run
import tango/domain/ticket
import tango/retry
import tango/scheduler

fn queued_ticket(
  id: String,
  location: String,
  priority: Option(Int),
) -> ticket.Ticket {
  ticket.Ticket(
    id: id,
    identifier: id,
    title: None,
    priority: priority,
    labels: [],
    lifecycle_policy: None,
    state: lifecycle.Queued,
    repo_bindings: [
      repo.RepoBinding(
        id: "repo-" <> id,
        name: id,
        kind: repo.GitRemote,
        location: location,
        default_branch: None,
        base_ref: None,
        target_branch: None,
        work_branch: None,
        checkout_policy: repo.Clone,
      ),
    ],
    external_ref: Some(id),
    registry_binding: Some(fixtures.registry_binding()),
    registry_status_mapping: Some(fixtures.registry_status_mapping()),
    forge_binding: Some(fixtures.forge_binding()),
    observed_external_status_id: None,
    capability_profile_digest: Some("digest"),
    main_session_id: None,
    aux_session_ids: [],
    active_block_id: None,
    blockers_clear: True,
    recently_unblocked: False,
    created_at: id,
    updated_at: id,
  )
}

pub fn scheduler_orders_and_claims_eligible_tickets_test() {
  let high = queued_ticket("TANGO-2", "repo-two", Some(1))
  let low = queued_ticket("TANGO-1", "repo-one", Some(2))
  let scheduler = scheduler.new(1)

  scheduler.dispatchable(scheduler, [low, high])
  |> should.equal([high, low])
  let assert Ok(claimed) = scheduler.claim(scheduler, high, "run-1")
  scheduler.dispatchable(claimed, [low])
  |> should.equal([])
}

pub fn scheduler_prevents_repository_overlap_test() {
  let first = queued_ticket("TANGO-1", "shared-repo", Some(1))
  let second = queued_ticket("TANGO-2", "shared-repo", Some(2))
  let assert Ok(claimed) = scheduler.claim(scheduler.new(2), first, "run-1")

  scheduler.claim(claimed, second, "run-2")
  |> should.be_error()
}

pub fn scheduler_does_not_dispatch_review_watch_without_watcher_signal_test() {
  let item =
    ticket.Ticket(
      ..queued_ticket("TANGO-3", "repo-three", Some(1)),
      state: lifecycle.AwaitingHumanReview,
      observed_external_status_id: Some("review"),
    )

  scheduler.dispatchable_runs(scheduler.new(1), [item])
  |> should.equal([])
}

pub fn scheduler_dispatches_registry_sync_for_pending_review_status_test() {
  let item =
    ticket.Ticket(
      ..queued_ticket("TANGO-3", "repo-three", Some(1)),
      state: lifecycle.AwaitingHumanReview,
    )

  scheduler.dispatchable_runs(scheduler.new(1), [item])
  |> should.equal([
    scheduler.DispatchPlan(ticket: item, run_kind: run.RegistrySync),
  ])
}

pub fn scheduler_dispatches_registry_sync_for_blocked_external_status_test() {
  let item =
    ticket.Ticket(
      ..queued_ticket("TANGO-5", "repo-five", Some(1)),
      state: lifecycle.Blocked,
      blockers_clear: False,
      observed_external_status_id: Some("active"),
    )

  scheduler.dispatchable_runs(scheduler.new(1), [item])
  |> should.equal([
    scheduler.DispatchPlan(ticket: item, run_kind: run.RegistrySync),
  ])
}

pub fn scheduler_dispatches_merge_run_for_merging_ticket_test() {
  let item =
    ticket.Ticket(
      ..queued_ticket("TANGO-4", "repo-four", Some(1)),
      state: lifecycle.Merging,
      aux_session_ids: ["merge-session"],
    )

  scheduler.dispatchable_runs(scheduler.new(1), [item])
  |> should.equal([
    scheduler.DispatchPlan(ticket: item, run_kind: run.MergeRun),
  ])
}

pub fn retry_policy_distinguishes_human_and_failure_retries_test() {
  let policy =
    retry.RetryPolicy(base_delay_ms: 1000, max_delay_ms: 5000, max_attempts: 4)

  retry.decide(policy, retry.HumanRequestedChanges, 1)
  |> should.equal(retry.NewImplementationAttempt)
  retry.decide(policy, retry.TransientAdapter, 3)
  |> should.equal(retry.RetryAfter(4000))
  retry.decide(policy, retry.AgentRuntime, 4)
  |> should.equal(retry.DoNotRetry)
}
