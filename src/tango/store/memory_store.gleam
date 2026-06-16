import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tango/domain/artifact.{type ArtifactRecord}
import tango/domain/block.{type BlockRecord}
import tango/domain/event.{type TangoEvent}
import tango/domain/merge.{type MergeRecord}
import tango/domain/review.{type ReviewDecision}
import tango/domain/review_cursor.{type ReviewCommentCursor}
import tango/domain/run.{type RunAttempt}
import tango/domain/session.{type AgentSession}
import tango/domain/ticket.{type Ticket}
import tango/store/store

pub type MemoryStore {
  MemoryStore(
    tickets: Dict(String, Ticket),
    sessions: Dict(String, AgentSession),
    blocks: Dict(String, BlockRecord),
    artifacts: Dict(String, ArtifactRecord),
    runs: Dict(String, RunAttempt),
    reviews: Dict(String, ReviewDecision),
    review_cursors: Dict(String, ReviewCommentCursor),
    merges: Dict(String, MergeRecord),
    events: Dict(String, TangoEvent),
  )
}

pub fn new() -> MemoryStore {
  MemoryStore(
    tickets: dict.new(),
    sessions: dict.new(),
    blocks: dict.new(),
    artifacts: dict.new(),
    runs: dict.new(),
    reviews: dict.new(),
    review_cursors: dict.new(),
    merges: dict.new(),
    events: dict.new(),
  )
}

pub fn store() -> store.Store(MemoryStore) {
  store.Store(
    save_ticket: save_ticket,
    get_ticket: get_ticket,
    list_tickets: list_tickets,
    save_session: save_session,
    get_session: get_session,
    list_sessions: list_sessions,
    save_block: save_block,
    get_block: get_block,
    list_blocks: list_blocks,
    save_artifact: save_artifact,
    get_artifact: get_artifact,
    list_artifacts: list_artifacts,
    save_run: save_run,
    get_run: get_run,
    list_runs: list_runs,
    save_review: save_review,
    get_review: get_review,
    list_reviews: list_reviews,
    save_review_cursor: save_review_cursor,
    get_review_cursor: get_review_cursor,
    list_review_cursors: list_review_cursors,
    save_merge: save_merge,
    get_merge: get_merge,
    list_merges: list_merges,
    append_event: append_event,
    list_events: list_events,
  )
}

pub fn save_ticket(
  state: MemoryStore,
  ticket: Ticket,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(..state, tickets: dict.insert(state.tickets, ticket.id, ticket)),
  )
}

pub fn get_ticket(
  state: MemoryStore,
  id: String,
) -> Result(Ticket, store.StoreError) {
  state.tickets
  |> dict.get(id)
  |> result.map_error(fn(_) { store.NotFound(id) })
}

pub fn list_tickets(
  state: MemoryStore,
) -> Result(List(Ticket), store.StoreError) {
  state.tickets
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> Ok
}

pub fn save_session(
  state: MemoryStore,
  session: AgentSession,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(
      ..state,
      sessions: dict.insert(
        state.sessions,
        session_key(session.ticket_id, session.id),
        session,
      ),
    ),
  )
}

pub fn get_session(
  state: MemoryStore,
  ticket_id: String,
  session_id: String,
) -> Result(AgentSession, store.StoreError) {
  state.sessions
  |> dict.get(session_key(ticket_id, session_id))
  |> result.map_error(fn(_) { store.NotFound(session_id) })
}

pub fn list_sessions(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(AgentSession), store.StoreError) {
  state.sessions
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(session) { session.ticket_id == ticket_id })
  |> Ok
}

pub fn save_block(
  state: MemoryStore,
  block: BlockRecord,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(
      ..state,
      blocks: dict.insert(
        state.blocks,
        record_key(block.ticket_id, block.id),
        block,
      ),
    ),
  )
}

pub fn get_block(
  state: MemoryStore,
  ticket_id: String,
  block_id: String,
) -> Result(BlockRecord, store.StoreError) {
  state.blocks
  |> dict.get(record_key(ticket_id, block_id))
  |> result.map_error(fn(_) { store.NotFound(block_id) })
}

pub fn list_blocks(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(BlockRecord), store.StoreError) {
  state.blocks
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(block) { block.ticket_id == ticket_id })
  |> Ok
}

pub fn save_artifact(
  state: MemoryStore,
  artifact: ArtifactRecord,
) -> Result(MemoryStore, store.StoreError) {
  case
    dict.has_key(state.artifacts, record_key(artifact.ticket_id, artifact.id))
  {
    True -> Error(store.ImmutableArtifactAlreadyExists(artifact.id))
    False ->
      Ok(
        MemoryStore(
          ..state,
          artifacts: dict.insert(
            state.artifacts,
            record_key(artifact.ticket_id, artifact.id),
            artifact,
          ),
        ),
      )
  }
}

pub fn get_artifact(
  state: MemoryStore,
  ticket_id: String,
  artifact_id: String,
) -> Result(ArtifactRecord, store.StoreError) {
  state.artifacts
  |> dict.get(record_key(ticket_id, artifact_id))
  |> result.map_error(fn(_) { store.NotFound(artifact_id) })
}

pub fn list_artifacts(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(ArtifactRecord), store.StoreError) {
  state.artifacts
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(artifact) { artifact.ticket_id == ticket_id })
  |> Ok
}

pub fn save_run(
  state: MemoryStore,
  run: RunAttempt,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(
      ..state,
      runs: dict.insert(state.runs, record_key(run.ticket_id, run.id), run),
    ),
  )
}

pub fn get_run(
  state: MemoryStore,
  ticket_id: String,
  run_id: String,
) -> Result(RunAttempt, store.StoreError) {
  state.runs
  |> dict.get(record_key(ticket_id, run_id))
  |> result.map_error(fn(_) { store.NotFound(run_id) })
}

pub fn list_runs(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(RunAttempt), store.StoreError) {
  state.runs
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(run) { run.ticket_id == ticket_id })
  |> Ok
}

pub fn append_event(
  state: MemoryStore,
  event: TangoEvent,
) -> Result(MemoryStore, store.StoreError) {
  case dict.has_key(state.events, event.id) {
    True -> Error(store.ImmutableEventAlreadyExists(event.id))
    False ->
      Ok(
        MemoryStore(..state, events: dict.insert(state.events, event.id, event)),
      )
  }
}

pub fn save_review(
  state: MemoryStore,
  review: ReviewDecision,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(
      ..state,
      reviews: dict.insert(
        state.reviews,
        record_key(review.ticket_id, review.id),
        review,
      ),
    ),
  )
}

pub fn get_review(
  state: MemoryStore,
  ticket_id: String,
  review_id: String,
) -> Result(ReviewDecision, store.StoreError) {
  state.reviews
  |> dict.get(record_key(ticket_id, review_id))
  |> result.map_error(fn(_) { store.NotFound(review_id) })
}

pub fn list_reviews(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(ReviewDecision), store.StoreError) {
  state.reviews
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(review) { review.ticket_id == ticket_id })
  |> Ok
}

pub fn save_review_cursor(
  state: MemoryStore,
  cursor: ReviewCommentCursor,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(
      ..state,
      review_cursors: dict.insert(
        state.review_cursors,
        record_key(cursor.ticket_id, cursor.pull_request_ref),
        cursor,
      ),
    ),
  )
}

pub fn get_review_cursor(
  state: MemoryStore,
  ticket_id: String,
  pull_request_ref: String,
) -> Result(ReviewCommentCursor, store.StoreError) {
  state.review_cursors
  |> dict.get(record_key(ticket_id, pull_request_ref))
  |> result.map_error(fn(_) { store.NotFound(pull_request_ref) })
}

pub fn list_review_cursors(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(ReviewCommentCursor), store.StoreError) {
  state.review_cursors
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(cursor) { cursor.ticket_id == ticket_id })
  |> Ok
}

pub fn save_merge(
  state: MemoryStore,
  merge: MergeRecord,
) -> Result(MemoryStore, store.StoreError) {
  Ok(
    MemoryStore(
      ..state,
      merges: dict.insert(
        state.merges,
        record_key(merge.ticket_id, merge.id),
        merge,
      ),
    ),
  )
}

pub fn get_merge(
  state: MemoryStore,
  ticket_id: String,
  merge_id: String,
) -> Result(MergeRecord, store.StoreError) {
  state.merges
  |> dict.get(record_key(ticket_id, merge_id))
  |> result.map_error(fn(_) { store.NotFound(merge_id) })
}

pub fn list_merges(
  state: MemoryStore,
  ticket_id: String,
) -> Result(List(MergeRecord), store.StoreError) {
  state.merges
  |> dict.to_list
  |> list.map(fn(entry) { entry.1 })
  |> list.filter(fn(merge) { merge.ticket_id == ticket_id })
  |> Ok
}

fn session_key(ticket_id: String, session_id: String) -> String {
  record_key(ticket_id, session_id)
}

fn record_key(ticket_id: String, record_id: String) -> String {
  ticket_id <> "\n" <> record_id
}

pub fn list_events(
  state: MemoryStore,
  ticket_id: Option(String),
) -> Result(List(TangoEvent), store.StoreError) {
  let events =
    state.events
    |> dict.to_list
    |> list.map(fn(entry) { entry.1 })

  case ticket_id {
    None -> Ok(events)
    Some(id) ->
      events
      |> list.filter(fn(event) { event.ticket_id == Some(id) })
      |> Ok
  }
}
