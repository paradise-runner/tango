import gleam/option.{type Option, None, Some}

pub type LifecycleState {
  Onboarded
  Queued
  Researching
  Planning
  Implementing
  AwaitingHumanReview
  ChangesRequested
  Merging
  Done
  Blocked
  Failed
  Canceled
}

pub type Stage {
  Research
  Plan
  Implement
  HumanReview
  Merge
}

pub type RegistryStatusRole {
  Backlog
  Todo
  InProgress
  HumanReviewStatus
  MergingStatus
  BlockedStatus
  DoneStatus
  WontDo
}

pub type TransitionContext {
  TransitionContext(
    onboarding_valid: Bool,
    execution_complete: Bool,
    human_merge_approval: Bool,
    merge_complete: Bool,
    active_block_resume_state: Option(LifecycleState),
  )
}

pub type LifecycleError {
  InvalidTransition(from: LifecycleState, to: LifecycleState)
  OnboardingIncomplete
  ExecutionIncomplete
  HumanMergeApprovalRequired
  MergeIncomplete
  InvalidBlockResumeState(LifecycleState)
}

pub fn default_transition_context() -> TransitionContext {
  TransitionContext(
    onboarding_valid: False,
    execution_complete: False,
    human_merge_approval: False,
    merge_complete: False,
    active_block_resume_state: None,
  )
}

pub fn can_transition(
  from from: LifecycleState,
  to next: LifecycleState,
  context context: TransitionContext,
) -> Result(Nil, LifecycleError) {
  case from, next {
    Onboarded, Queued ->
      case context.onboarding_valid {
        True -> Ok(Nil)
        False -> Error(OnboardingIncomplete)
      }

    Queued, Researching -> Ok(Nil)
    Researching, Planning -> Ok(Nil)
    Planning, Implementing -> Ok(Nil)

    Implementing, AwaitingHumanReview ->
      case context.execution_complete {
        True -> Ok(Nil)
        False -> Error(ExecutionIncomplete)
      }

    AwaitingHumanReview, ChangesRequested -> Ok(Nil)
    ChangesRequested, Implementing -> Ok(Nil)

    AwaitingHumanReview, Merging ->
      case context.human_merge_approval {
        True -> Ok(Nil)
        False -> Error(HumanMergeApprovalRequired)
      }

    Merging, Done ->
      case context.merge_complete {
        True -> Ok(Nil)
        False -> Error(MergeIncomplete)
      }

    Blocked, Failed | Blocked, Canceled -> Ok(Nil)

    Blocked, resume_state ->
      case context.active_block_resume_state {
        Some(expected) ->
          case expected == resume_state && is_valid_resume_state(expected) {
            True -> Ok(Nil)
            False -> Error(InvalidBlockResumeState(expected))
          }
        None -> Error(InvalidTransition(from: from, to: next))
      }

    _, _ -> fallback_transition(from, next)
  }
}

pub fn record_execution_progress(
  state state: LifecycleState,
  stage stage: Stage,
) -> Result(LifecycleState, LifecycleError) {
  case state, stage {
    Researching, Research -> Ok(Researching)
    Researching, Plan -> Ok(Planning)
    Planning, Plan -> Ok(Planning)
    Planning, Implement -> Ok(Implementing)
    Implementing, Implement -> Ok(Implementing)
    _, _ -> Error(InvalidTransition(from: state, to: state_for_stage(stage)))
  }
}

pub fn registry_status_role(state: LifecycleState) -> RegistryStatusRole {
  case state {
    Onboarded -> Backlog
    Queued -> Todo
    Researching | Planning | Implementing | ChangesRequested -> InProgress
    AwaitingHumanReview -> HumanReviewStatus
    Merging -> MergingStatus
    Blocked | Failed -> BlockedStatus
    Done -> DoneStatus
    Canceled -> WontDo
  }
}

pub fn is_terminal(state: LifecycleState) -> Bool {
  state == Done || state == Failed || state == Canceled
}

pub fn is_non_terminal(state: LifecycleState) -> Bool {
  !is_terminal(state)
}

pub fn is_dispatch_state(state: LifecycleState) -> Bool {
  state == Queued || state == ChangesRequested
}

pub fn is_valid_resume_state(state: LifecycleState) -> Bool {
  state == Queued || state == ChangesRequested || state == AwaitingHumanReview
}

pub fn to_string(state: LifecycleState) -> String {
  case state {
    Onboarded -> "onboarded"
    Queued -> "queued"
    Researching -> "researching"
    Planning -> "planning"
    Implementing -> "implementing"
    AwaitingHumanReview -> "awaiting_human_review"
    ChangesRequested -> "changes_requested"
    Merging -> "merging"
    Done -> "done"
    Blocked -> "blocked"
    Failed -> "failed"
    Canceled -> "canceled"
  }
}

fn state_for_stage(stage: Stage) -> LifecycleState {
  case stage {
    Research -> Researching
    Plan -> Planning
    Implement -> Implementing
    HumanReview -> AwaitingHumanReview
    Merge -> Merging
  }
}

fn fallback_transition(
  from: LifecycleState,
  next: LifecycleState,
) -> Result(Nil, LifecycleError) {
  case is_non_terminal(from), next {
    True, Blocked | True, Failed | True, Canceled -> Ok(Nil)
    _, _ -> Error(InvalidTransition(from: from, to: next))
  }
}
