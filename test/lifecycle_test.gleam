import gleam/option.{Some}
import gleeunit/should
import tango/domain/lifecycle

pub fn onboarding_requires_validation_test() {
  lifecycle.can_transition(
    from: lifecycle.Onboarded,
    to: lifecycle.Queued,
    context: lifecycle.default_transition_context(),
  )
  |> should.equal(Error(lifecycle.OnboardingIncomplete))
}

pub fn merge_requires_human_approval_test() {
  lifecycle.can_transition(
    from: lifecycle.AwaitingHumanReview,
    to: lifecycle.Merging,
    context: lifecycle.default_transition_context(),
  )
  |> should.equal(Error(lifecycle.HumanMergeApprovalRequired))
}

pub fn execution_progress_is_monotonic_test() {
  lifecycle.record_execution_progress(
    state: lifecycle.Researching,
    stage: lifecycle.Plan,
  )
  |> should.equal(Ok(lifecycle.Planning))

  lifecycle.record_execution_progress(
    state: lifecycle.Planning,
    stage: lifecycle.Research,
  )
  |> should.be_error()
}

pub fn blocked_ticket_only_resumes_to_recorded_state_test() {
  let context =
    lifecycle.TransitionContext(
      ..lifecycle.default_transition_context(),
      active_block_resume_state: Some(lifecycle.ChangesRequested),
    )

  lifecycle.can_transition(
    from: lifecycle.Blocked,
    to: lifecycle.ChangesRequested,
    context: context,
  )
  |> should.be_ok()

  lifecycle.can_transition(
    from: lifecycle.Blocked,
    to: lifecycle.Queued,
    context: context,
  )
  |> should.be_error()
}

pub fn blocked_ticket_can_be_canceled_test() {
  lifecycle.can_transition(
    from: lifecycle.Blocked,
    to: lifecycle.Canceled,
    context: lifecycle.default_transition_context(),
  )
  |> should.be_ok()
}

pub fn failed_maps_to_external_blocked_test() {
  lifecycle.registry_status_role(lifecycle.Failed)
  |> should.equal(lifecycle.BlockedStatus)
}
