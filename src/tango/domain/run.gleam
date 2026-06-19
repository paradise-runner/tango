import gleam/option.{type Option, Some}
import tango/domain/lifecycle.{type LifecycleState, type Stage}

pub type RunKind {
  Execution
  ReviewWatch
  RegistrySync
  MergeRun
}

pub type RunStatus {
  PreparingWorkspace
  BuildingPrompt
  LaunchingAgent
  Streaming
  CollectingArtifacts
  Succeeded
  Failed
  TimedOut
  Stalled
  Canceled
}

pub type RunUsage {
  RunUsage(
    input_tokens: Int,
    cached_input_tokens: Int,
    output_tokens: Int,
    reasoning_output_tokens: Int,
    total_tokens: Int,
  )
}

pub type RunAttempt {
  RunAttempt(
    id: String,
    ticket_id: String,
    session_id: String,
    kind: RunKind,
    current_stage: Option(Stage),
    stages: List(Stage),
    attempt: Int,
    workspace_path: String,
    agent_runtime: String,
    capability_profile_digest: Option(String),
    effective_capabilities: List(String),
    resume_state: LifecycleState,
    started_at: String,
    ended_at: Option(String),
    status: RunStatus,
    usage: Option(RunUsage),
    error: Option(String),
  )
}

pub type RunError {
  AttemptMustBePositive
  TerminalRunCannotStart
  InvalidStatusTransition(from: RunStatus, to: RunStatus)
}

pub fn validate(run: RunAttempt) -> Result(RunAttempt, RunError) {
  case run.attempt > 0 {
    True -> Ok(run)
    False -> Error(AttemptMustBePositive)
  }
}

pub fn is_terminal(status: RunStatus) -> Bool {
  case status {
    Succeeded | Failed | TimedOut | Stalled | Canceled -> True
    _ -> False
  }
}

pub fn is_active(status: RunStatus) -> Bool {
  !is_terminal(status)
}

pub fn transition(
  run: RunAttempt,
  status: RunStatus,
  ended_at: Option(String),
  error: Option(String),
) -> Result(RunAttempt, RunError) {
  case can_transition(run.status, status) {
    True ->
      Ok(RunAttempt(..run, status: status, ended_at: ended_at, error: error))
    False -> Error(InvalidStatusTransition(from: run.status, to: status))
  }
}

pub fn interrupt(
  run: RunAttempt,
  ended_at: String,
) -> Result(RunAttempt, RunError) {
  case is_active(run.status) {
    True ->
      transition(
        run,
        Failed,
        Some(ended_at),
        Some("Interrupted by Tango process restart"),
      )
    False -> Error(TerminalRunCannotStart)
  }
}

fn can_transition(from: RunStatus, to: RunStatus) -> Bool {
  case is_terminal(from), from, to {
    True, _, _ -> False
    False, PreparingWorkspace, BuildingPrompt -> True
    False, BuildingPrompt, LaunchingAgent -> True
    False, LaunchingAgent, Streaming -> True
    False, Streaming, CollectingArtifacts -> True
    False, CollectingArtifacts, Succeeded -> True
    False, _, Failed
    | False, _, TimedOut
    | False, _, Stalled
    | False, _, Canceled
    -> True
    _, _, _ -> False
  }
}
