import gleam/option.{type Option}
import tango/domain/artifact.{type ArtifactRecord}
import tango/domain/block.{type BlockRecord}
import tango/domain/event.{type TangoEvent}
import tango/domain/merge.{type MergeRecord}
import tango/domain/review.{type ReviewDecision}
import tango/domain/review_cursor.{type ReviewCommentCursor}
import tango/domain/run.{type RunAttempt}
import tango/domain/session.{type AgentSession}
import tango/domain/ticket.{type Ticket}

pub type StoreError {
  NotFound(String)
  DecodeFailed(String)
  SchemaVersionUnsupported(Int)
  IoFailed(String)
  ImmutableArtifactAlreadyExists(String)
  ImmutableEventAlreadyExists(String)
}

pub type Store(state) {
  Store(
    save_ticket: fn(state, Ticket) -> Result(state, StoreError),
    get_ticket: fn(state, String) -> Result(Ticket, StoreError),
    list_tickets: fn(state) -> Result(List(Ticket), StoreError),
    save_session: fn(state, AgentSession) -> Result(state, StoreError),
    get_session: fn(state, String, String) -> Result(AgentSession, StoreError),
    list_sessions: fn(state, String) -> Result(List(AgentSession), StoreError),
    save_block: fn(state, BlockRecord) -> Result(state, StoreError),
    get_block: fn(state, String, String) -> Result(BlockRecord, StoreError),
    list_blocks: fn(state, String) -> Result(List(BlockRecord), StoreError),
    save_artifact: fn(state, ArtifactRecord) -> Result(state, StoreError),
    get_artifact: fn(state, String, String) ->
      Result(ArtifactRecord, StoreError),
    list_artifacts: fn(state, String) ->
      Result(List(ArtifactRecord), StoreError),
    save_run: fn(state, RunAttempt) -> Result(state, StoreError),
    get_run: fn(state, String, String) -> Result(RunAttempt, StoreError),
    list_runs: fn(state, String) -> Result(List(RunAttempt), StoreError),
    save_review: fn(state, ReviewDecision) -> Result(state, StoreError),
    get_review: fn(state, String, String) -> Result(ReviewDecision, StoreError),
    list_reviews: fn(state, String) -> Result(List(ReviewDecision), StoreError),
    save_review_cursor: fn(state, ReviewCommentCursor) ->
      Result(state, StoreError),
    get_review_cursor: fn(state, String, String) ->
      Result(ReviewCommentCursor, StoreError),
    list_review_cursors: fn(state, String) ->
      Result(List(ReviewCommentCursor), StoreError),
    save_merge: fn(state, MergeRecord) -> Result(state, StoreError),
    get_merge: fn(state, String, String) -> Result(MergeRecord, StoreError),
    list_merges: fn(state, String) -> Result(List(MergeRecord), StoreError),
    append_event: fn(state, TangoEvent) -> Result(state, StoreError),
    list_events: fn(state, Option(String)) ->
      Result(List(TangoEvent), StoreError),
  )
}
