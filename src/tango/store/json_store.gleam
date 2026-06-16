import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/domain/artifact.{type ArtifactRecord}
import tango/domain/block.{type BlockRecord}
import tango/domain/event.{type TangoEvent}
import tango/domain/merge.{type MergeRecord}
import tango/domain/review.{type ReviewDecision}
import tango/domain/review_cursor.{type ReviewCommentCursor}
import tango/domain/run.{type RunAttempt}
import tango/domain/session.{type AgentSession, Aux, Main}
import tango/domain/ticket.{type Ticket}
import tango/store/codec
import tango/store/file
import tango/store/store

pub type JsonStore {
  JsonStore(root: String)
}

pub fn new(root: String) -> JsonStore {
  JsonStore(root: string.trim_end(root))
}

pub fn store() -> store.Store(JsonStore) {
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
  state: JsonStore,
  ticket: Ticket,
) -> Result(JsonStore, store.StoreError) {
  ticket_path(state, ticket.id)
  |> file.atomic_replace(codec.encode_ticket(ticket))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

pub fn get_ticket(
  state: JsonStore,
  id: String,
) -> Result(Ticket, store.StoreError) {
  use source <- result.try(
    ticket_path(state, id)
    |> file.read
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(id)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_ticket(source)
}

pub fn list_tickets(
  state: JsonStore,
) -> Result(List(Ticket), store.StoreError) {
  use entries <- result.try(
    file.list_dir(join(state.root, "tickets"))
    |> result.map_error(store.IoFailed),
  )

  entries
  |> list.map(fn(id) { get_ticket(state, id) })
  |> list.try_map(fn(result) { result })
}

pub fn save_session(
  state: JsonStore,
  agent_session: AgentSession,
) -> Result(JsonStore, store.StoreError) {
  session_path(state, agent_session)
  |> file.atomic_replace(codec.encode_session(agent_session))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

pub fn get_session(
  state: JsonStore,
  ticket_id: String,
  session_id: String,
) -> Result(AgentSession, store.StoreError) {
  case load_session(main_session_path(state, ticket_id)) {
    Ok(agent_session) ->
      case agent_session.id == session_id {
        True -> Ok(agent_session)
        False -> load_session(aux_session_path(state, ticket_id, session_id))
      }
    Error(store.NotFound(_)) ->
      load_session(aux_session_path(state, ticket_id, session_id))
    Error(error) -> Error(error)
  }
}

pub fn list_sessions(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(AgentSession), store.StoreError) {
  use main <- result.try(load_optional_main_session(state, ticket_id))
  use aux <- result.try(list_aux_sessions(state, ticket_id))
  Ok(list.append(main, aux))
}

pub fn save_block(
  state: JsonStore,
  block: BlockRecord,
) -> Result(JsonStore, store.StoreError) {
  block_path(state, block.ticket_id, block.id)
  |> file.atomic_replace(codec.encode_block(block))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

pub fn get_block(
  state: JsonStore,
  ticket_id: String,
  block_id: String,
) -> Result(BlockRecord, store.StoreError) {
  load_block(block_path(state, ticket_id, block_id))
}

pub fn list_blocks(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(BlockRecord), store.StoreError) {
  let directory = blocks_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_block(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

pub fn save_artifact(
  state: JsonStore,
  artifact: ArtifactRecord,
) -> Result(JsonStore, store.StoreError) {
  artifact_path(state, artifact.ticket_id, artifact.id)
  |> file.atomic_create(codec.encode_artifact(artifact))
  |> result.map(fn(_) { state })
  |> result.map_error(fn(error) {
    case error {
      "eexist" -> store.ImmutableArtifactAlreadyExists(artifact.id)
      other -> store.IoFailed(other)
    }
  })
}

pub fn get_artifact(
  state: JsonStore,
  ticket_id: String,
  artifact_id: String,
) -> Result(ArtifactRecord, store.StoreError) {
  load_artifact(artifact_path(state, ticket_id, artifact_id))
}

pub fn list_artifacts(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(ArtifactRecord), store.StoreError) {
  let directory = artifacts_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_artifact(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

pub fn save_run(
  state: JsonStore,
  run: RunAttempt,
) -> Result(JsonStore, store.StoreError) {
  run_path(state, run.ticket_id, run.id)
  |> file.atomic_replace(codec.encode_run(run))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

pub fn get_run(
  state: JsonStore,
  ticket_id: String,
  run_id: String,
) -> Result(RunAttempt, store.StoreError) {
  load_run(run_path(state, ticket_id, run_id))
}

pub fn list_runs(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(RunAttempt), store.StoreError) {
  let directory = runs_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_run(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

pub fn append_event(
  state: JsonStore,
  event: TangoEvent,
) -> Result(JsonStore, store.StoreError) {
  event_path(state, event)
  |> file.atomic_create(codec.encode_event(event))
  |> result.map(fn(_) { state })
  |> result.map_error(fn(error) {
    case error {
      "eexist" -> store.ImmutableEventAlreadyExists(event.id)
      error -> store.IoFailed(error)
    }
  })
}

pub fn list_events(
  state: JsonStore,
  ticket_id: Option(String),
) -> Result(List(TangoEvent), store.StoreError) {
  let directory = events_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_event(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

pub fn save_review(
  state: JsonStore,
  review: ReviewDecision,
) -> Result(JsonStore, store.StoreError) {
  review_path(state, review.ticket_id, review.id)
  |> file.atomic_replace(codec.encode_review(review))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

pub fn get_review(
  state: JsonStore,
  ticket_id: String,
  review_id: String,
) -> Result(ReviewDecision, store.StoreError) {
  load_review(review_path(state, ticket_id, review_id))
}

pub fn list_reviews(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(ReviewDecision), store.StoreError) {
  let directory = reviews_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_review(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

pub fn save_review_cursor(
  state: JsonStore,
  cursor: ReviewCommentCursor,
) -> Result(JsonStore, store.StoreError) {
  case list_review_cursors(state, cursor.ticket_id) {
    Ok(cursors) -> write_review_cursors(state, cursor, cursors)
    Error(store.NotFound(_)) -> write_review_cursors(state, cursor, [])
    Error(error) -> Error(error)
  }
}

pub fn get_review_cursor(
  state: JsonStore,
  ticket_id: String,
  pull_request_ref: String,
) -> Result(ReviewCommentCursor, store.StoreError) {
  use cursors <- result.try(list_review_cursors(state, ticket_id))
  case
    list.find(cursors, fn(cursor) {
      cursor.pull_request_ref == pull_request_ref
    })
  {
    Ok(cursor) -> Ok(cursor)
    Error(_) -> Error(store.NotFound(pull_request_ref))
  }
}

pub fn list_review_cursors(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(ReviewCommentCursor), store.StoreError) {
  use source <- result.try(
    review_cursors_path(state, ticket_id)
    |> file.read
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(ticket_id)
        other -> store.IoFailed(other)
      }
    }),
  )
  codec.decode_review_cursor_file(source)
}

pub fn save_merge(
  state: JsonStore,
  merge: MergeRecord,
) -> Result(JsonStore, store.StoreError) {
  merge_path(state, merge.ticket_id, merge.id)
  |> file.atomic_replace(codec.encode_merge(merge))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

pub fn get_merge(
  state: JsonStore,
  ticket_id: String,
  merge_id: String,
) -> Result(MergeRecord, store.StoreError) {
  load_merge(merge_path(state, ticket_id, merge_id))
}

pub fn list_merges(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(MergeRecord), store.StoreError) {
  let directory = merges_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_merge(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

fn load_event(path: String) -> Result(TangoEvent, store.StoreError) {
  use source <- result.try(file.read(path) |> result.map_error(store.IoFailed))
  codec.decode_event(source)
}

fn load_session(path: String) -> Result(AgentSession, store.StoreError) {
  use source <- result.try(
    file.read(path)
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(path)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_session(source)
}

fn load_block(path: String) -> Result(BlockRecord, store.StoreError) {
  use source <- result.try(
    file.read(path)
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(path)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_block(source)
}

fn load_artifact(path: String) -> Result(ArtifactRecord, store.StoreError) {
  use source <- result.try(
    file.read(path)
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(path)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_artifact(source)
}

fn load_run(path: String) -> Result(RunAttempt, store.StoreError) {
  use source <- result.try(
    file.read(path)
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(path)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_run(source)
}

fn load_review(path: String) -> Result(ReviewDecision, store.StoreError) {
  use source <- result.try(
    file.read(path)
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(path)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_review(source)
}

fn load_merge(path: String) -> Result(MergeRecord, store.StoreError) {
  use source <- result.try(
    file.read(path)
    |> result.map_error(fn(error) {
      case error {
        "enoent" -> store.NotFound(path)
        error -> store.IoFailed(error)
      }
    }),
  )
  codec.decode_merge(source)
}

fn load_optional_main_session(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(AgentSession), store.StoreError) {
  case load_session(main_session_path(state, ticket_id)) {
    Ok(agent_session) -> Ok([agent_session])
    Error(store.NotFound(_)) -> Ok([])
    Error(error) -> Error(error)
  }
}

fn list_aux_sessions(
  state: JsonStore,
  ticket_id: String,
) -> Result(List(AgentSession), store.StoreError) {
  let directory = aux_sessions_directory(state, ticket_id)
  use entries <- result.try(
    file.list_dir(directory) |> result.map_error(store.IoFailed),
  )

  entries
  |> list.filter(fn(name) { string.ends_with(name, ".json") })
  |> list.map(fn(name) { load_session(join(directory, name)) })
  |> list.try_map(fn(result) { result })
}

fn ticket_path(state: JsonStore, id: String) -> String {
  join(join(join(state.root, "tickets"), id), "ticket.json")
}

fn session_path(state: JsonStore, agent_session: AgentSession) -> String {
  case agent_session.role {
    Main -> main_session_path(state, agent_session.ticket_id)
    Aux -> aux_session_path(state, agent_session.ticket_id, agent_session.id)
  }
}

fn main_session_path(state: JsonStore, ticket_id: String) -> String {
  join(
    join(join(join(state.root, "tickets"), ticket_id), "sessions"),
    "main.json",
  )
}

fn aux_session_path(
  state: JsonStore,
  ticket_id: String,
  session_id: String,
) -> String {
  join(aux_sessions_directory(state, ticket_id), session_id <> ".json")
}

fn aux_sessions_directory(state: JsonStore, ticket_id: String) -> String {
  join(join(join(join(state.root, "tickets"), ticket_id), "sessions"), "aux")
}

fn block_path(state: JsonStore, ticket_id: String, block_id: String) -> String {
  join(blocks_directory(state, ticket_id), block_id <> ".json")
}

fn blocks_directory(state: JsonStore, ticket_id: String) -> String {
  join(join(join(state.root, "tickets"), ticket_id), "blocks")
}

fn artifact_path(
  state: JsonStore,
  ticket_id: String,
  artifact_id: String,
) -> String {
  join(artifacts_directory(state, ticket_id), artifact_id <> ".json")
}

fn artifacts_directory(state: JsonStore, ticket_id: String) -> String {
  join(join(join(state.root, "tickets"), ticket_id), "artifacts")
}

fn run_path(state: JsonStore, ticket_id: String, run_id: String) -> String {
  join(runs_directory(state, ticket_id), run_id <> ".json")
}

fn runs_directory(state: JsonStore, ticket_id: String) -> String {
  join(join(join(state.root, "tickets"), ticket_id), "runs")
}

fn event_path(state: JsonStore, event: TangoEvent) -> String {
  join(events_directory(state, event.ticket_id), event.id <> ".json")
}

fn review_path(
  state: JsonStore,
  ticket_id: String,
  review_id: String,
) -> String {
  join(reviews_directory(state, ticket_id), review_id <> ".json")
}

fn reviews_directory(state: JsonStore, ticket_id: String) -> String {
  join(join(join(state.root, "tickets"), ticket_id), "reviews")
}

fn review_cursors_path(state: JsonStore, ticket_id: String) -> String {
  join(join(join(state.root, "tickets"), ticket_id), "review-cursors.json")
}

fn merge_path(state: JsonStore, ticket_id: String, merge_id: String) -> String {
  join(merges_directory(state, ticket_id), merge_id <> ".json")
}

fn merges_directory(state: JsonStore, ticket_id: String) -> String {
  join(join(join(state.root, "tickets"), ticket_id), "merges")
}

fn write_review_cursors(
  state: JsonStore,
  cursor: ReviewCommentCursor,
  cursors: List(ReviewCommentCursor),
) -> Result(JsonStore, store.StoreError) {
  let remaining =
    cursors
    |> list.filter(fn(item) { item.pull_request_ref != cursor.pull_request_ref })
    |> list.append([cursor])
  review_cursors_path(state, cursor.ticket_id)
  |> file.atomic_replace(codec.encode_review_cursor_file(remaining))
  |> result.map(fn(_) { state })
  |> result.map_error(store.IoFailed)
}

fn events_directory(state: JsonStore, ticket_id: Option(String)) -> String {
  case ticket_id {
    Some(id) -> join(join(join(state.root, "tickets"), id), "events")
    None -> join(state.root, "events")
  }
}

fn join(left: String, right: String) -> String {
  case string.ends_with(left, "/") {
    True -> left <> right
    False -> left <> "/" <> right
  }
}
