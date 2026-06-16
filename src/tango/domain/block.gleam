import gleam/option.{type Option, None, Some}
import tango/domain/lifecycle.{type LifecycleState, is_valid_resume_state}

pub type BlockRecord {
  BlockRecord(
    id: String,
    ticket_id: String,
    reason: String,
    resolution_instructions: Option(String),
    blocked_from: LifecycleState,
    resume_state: LifecycleState,
    created_by: String,
    created_at: String,
    resolved_by: Option(String),
    resolved_at: Option(String),
  )
}

pub type BlockError {
  InvalidResumeState(LifecycleState)
  AlreadyResolved
}

pub fn validate(record: BlockRecord) -> Result(BlockRecord, BlockError) {
  case is_valid_resume_state(record.resume_state) {
    True -> Ok(record)
    False -> Error(InvalidResumeState(record.resume_state))
  }
}

pub fn resolve(
  record: BlockRecord,
  resolved_by: String,
  resolved_at: String,
) -> Result(BlockRecord, BlockError) {
  case record.resolved_at {
    Some(_) -> Error(AlreadyResolved)
    None ->
      Ok(
        BlockRecord(
          ..record,
          resolved_by: Some(resolved_by),
          resolved_at: Some(resolved_at),
        ),
      )
  }
}
