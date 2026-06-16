import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/otp/supervision
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
import tango/store/json_store
import tango/store/store

const call_timeout_ms = 30_000

pub type Message {
  SaveTicket(process.Subject(Result(Nil, store.StoreError)), Ticket)
  GetTicket(process.Subject(Result(Ticket, store.StoreError)), String)
  ListTickets(process.Subject(Result(List(Ticket), store.StoreError)))
  SaveSession(process.Subject(Result(Nil, store.StoreError)), AgentSession)
  GetSession(
    process.Subject(Result(AgentSession, store.StoreError)),
    String,
    String,
  )
  ListSessions(
    process.Subject(Result(List(AgentSession), store.StoreError)),
    String,
  )
  SaveBlock(process.Subject(Result(Nil, store.StoreError)), BlockRecord)
  GetBlock(
    process.Subject(Result(BlockRecord, store.StoreError)),
    String,
    String,
  )
  ListBlocks(
    process.Subject(Result(List(BlockRecord), store.StoreError)),
    String,
  )
  SaveArtifact(process.Subject(Result(Nil, store.StoreError)), ArtifactRecord)
  GetArtifact(
    process.Subject(Result(ArtifactRecord, store.StoreError)),
    String,
    String,
  )
  ListArtifacts(
    process.Subject(Result(List(ArtifactRecord), store.StoreError)),
    String,
  )
  SaveRun(process.Subject(Result(Nil, store.StoreError)), RunAttempt)
  GetRun(process.Subject(Result(RunAttempt, store.StoreError)), String, String)
  ListRuns(process.Subject(Result(List(RunAttempt), store.StoreError)), String)
  SaveReview(process.Subject(Result(Nil, store.StoreError)), ReviewDecision)
  GetReview(
    process.Subject(Result(ReviewDecision, store.StoreError)),
    String,
    String,
  )
  ListReviews(
    process.Subject(Result(List(ReviewDecision), store.StoreError)),
    String,
  )
  SaveReviewCursor(
    process.Subject(Result(Nil, store.StoreError)),
    ReviewCommentCursor,
  )
  GetReviewCursor(
    process.Subject(Result(ReviewCommentCursor, store.StoreError)),
    String,
    String,
  )
  ListReviewCursors(
    process.Subject(Result(List(ReviewCommentCursor), store.StoreError)),
    String,
  )
  SaveMerge(process.Subject(Result(Nil, store.StoreError)), MergeRecord)
  GetMerge(
    process.Subject(Result(MergeRecord, store.StoreError)),
    String,
    String,
  )
  ListMerges(
    process.Subject(Result(List(MergeRecord), store.StoreError)),
    String,
  )
  AppendEvent(process.Subject(Result(Nil, store.StoreError)), TangoEvent)
  ListEvents(
    process.Subject(Result(List(TangoEvent), store.StoreError)),
    Option(String),
  )
}

pub fn new_name() -> process.Name(Message) {
  process.new_name("tango_store_server")
}

pub fn start(name: process.Name(Message), state_dir: String) {
  actor.new(json_store.new(state_dir))
  |> actor.named(name)
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(name: process.Name(Message), state_dir: String) {
  supervision.worker(fn() { start(name, state_dir) })
}

pub fn store() -> store.Store(process.Name(Message)) {
  store.Store(
    save_ticket: fn(name, item) {
      call(name, fn(reply) { SaveTicket(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_ticket: fn(name, id) { call(name, fn(reply) { GetTicket(reply, id) }) },
    list_tickets: fn(name) { call(name, ListTickets) },
    save_session: fn(name, item) {
      call(name, fn(reply) { SaveSession(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_session: fn(name, ticket_id, session_id) {
      call(name, fn(reply) { GetSession(reply, ticket_id, session_id) })
    },
    list_sessions: fn(name, ticket_id) {
      call(name, fn(reply) { ListSessions(reply, ticket_id) })
    },
    save_block: fn(name, item) {
      call(name, fn(reply) { SaveBlock(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_block: fn(name, ticket_id, block_id) {
      call(name, fn(reply) { GetBlock(reply, ticket_id, block_id) })
    },
    list_blocks: fn(name, ticket_id) {
      call(name, fn(reply) { ListBlocks(reply, ticket_id) })
    },
    save_artifact: fn(name, item) {
      call(name, fn(reply) { SaveArtifact(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_artifact: fn(name, ticket_id, artifact_id) {
      call(name, fn(reply) { GetArtifact(reply, ticket_id, artifact_id) })
    },
    list_artifacts: fn(name, ticket_id) {
      call(name, fn(reply) { ListArtifacts(reply, ticket_id) })
    },
    save_run: fn(name, item) {
      call(name, fn(reply) { SaveRun(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_run: fn(name, ticket_id, run_id) {
      call(name, fn(reply) { GetRun(reply, ticket_id, run_id) })
    },
    list_runs: fn(name, ticket_id) {
      call(name, fn(reply) { ListRuns(reply, ticket_id) })
    },
    save_review: fn(name, item) {
      call(name, fn(reply) { SaveReview(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_review: fn(name, ticket_id, review_id) {
      call(name, fn(reply) { GetReview(reply, ticket_id, review_id) })
    },
    list_reviews: fn(name, ticket_id) {
      call(name, fn(reply) { ListReviews(reply, ticket_id) })
    },
    save_review_cursor: fn(name, item) {
      call(name, fn(reply) { SaveReviewCursor(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_review_cursor: fn(name, ticket_id, pull_request_ref) {
      call(name, fn(reply) {
        GetReviewCursor(reply, ticket_id, pull_request_ref)
      })
    },
    list_review_cursors: fn(name, ticket_id) {
      call(name, fn(reply) { ListReviewCursors(reply, ticket_id) })
    },
    save_merge: fn(name, item) {
      call(name, fn(reply) { SaveMerge(reply, item) })
      |> result.map(fn(_) { name })
    },
    get_merge: fn(name, ticket_id, merge_id) {
      call(name, fn(reply) { GetMerge(reply, ticket_id, merge_id) })
    },
    list_merges: fn(name, ticket_id) {
      call(name, fn(reply) { ListMerges(reply, ticket_id) })
    },
    append_event: fn(name, item) {
      call(name, fn(reply) { AppendEvent(reply, item) })
      |> result.map(fn(_) { name })
    },
    list_events: fn(name, ticket_id) {
      call(name, fn(reply) { ListEvents(reply, ticket_id) })
    },
  )
}

fn call(
  name: process.Name(Message),
  make_message: fn(process.Subject(Result(value, store.StoreError))) -> Message,
) -> Result(value, store.StoreError) {
  process.call(
    process.named_subject(name),
    waiting: call_timeout_ms,
    sending: make_message,
  )
}

fn handle_message(
  state: json_store.JsonStore,
  message: Message,
) -> actor.Next(json_store.JsonStore, Message) {
  let backend = json_store.store()
  case message {
    SaveTicket(reply, item) ->
      write_reply(state, reply, backend.save_ticket(state, item))
    GetTicket(reply, id) ->
      read_reply(state, reply, backend.get_ticket(state, id))
    ListTickets(reply) -> read_reply(state, reply, backend.list_tickets(state))
    SaveSession(reply, item) ->
      write_reply(state, reply, backend.save_session(state, item))
    GetSession(reply, ticket_id, session_id) ->
      read_reply(
        state,
        reply,
        backend.get_session(state, ticket_id, session_id),
      )
    ListSessions(reply, ticket_id) ->
      read_reply(state, reply, backend.list_sessions(state, ticket_id))
    SaveBlock(reply, item) ->
      write_reply(state, reply, backend.save_block(state, item))
    GetBlock(reply, ticket_id, block_id) ->
      read_reply(state, reply, backend.get_block(state, ticket_id, block_id))
    ListBlocks(reply, ticket_id) ->
      read_reply(state, reply, backend.list_blocks(state, ticket_id))
    SaveArtifact(reply, item) ->
      write_reply(state, reply, backend.save_artifact(state, item))
    GetArtifact(reply, ticket_id, artifact_id) ->
      read_reply(
        state,
        reply,
        backend.get_artifact(state, ticket_id, artifact_id),
      )
    ListArtifacts(reply, ticket_id) ->
      read_reply(state, reply, backend.list_artifacts(state, ticket_id))
    SaveRun(reply, item) ->
      write_reply(state, reply, backend.save_run(state, item))
    GetRun(reply, ticket_id, run_id) ->
      read_reply(state, reply, backend.get_run(state, ticket_id, run_id))
    ListRuns(reply, ticket_id) ->
      read_reply(state, reply, backend.list_runs(state, ticket_id))
    SaveReview(reply, item) ->
      write_reply(state, reply, backend.save_review(state, item))
    GetReview(reply, ticket_id, review_id) ->
      read_reply(state, reply, backend.get_review(state, ticket_id, review_id))
    ListReviews(reply, ticket_id) ->
      read_reply(state, reply, backend.list_reviews(state, ticket_id))
    SaveReviewCursor(reply, item) ->
      write_reply(state, reply, backend.save_review_cursor(state, item))
    GetReviewCursor(reply, ticket_id, pull_request_ref) ->
      read_reply(
        state,
        reply,
        backend.get_review_cursor(state, ticket_id, pull_request_ref),
      )
    ListReviewCursors(reply, ticket_id) ->
      read_reply(state, reply, backend.list_review_cursors(state, ticket_id))
    SaveMerge(reply, item) ->
      write_reply(state, reply, backend.save_merge(state, item))
    GetMerge(reply, ticket_id, merge_id) ->
      read_reply(state, reply, backend.get_merge(state, ticket_id, merge_id))
    ListMerges(reply, ticket_id) ->
      read_reply(state, reply, backend.list_merges(state, ticket_id))
    AppendEvent(reply, item) ->
      write_reply(state, reply, backend.append_event(state, item))
    ListEvents(reply, ticket_id) ->
      read_reply(state, reply, backend.list_events(state, ticket_id))
  }
}

fn write_reply(
  state: json_store.JsonStore,
  reply: process.Subject(Result(Nil, store.StoreError)),
  operation: Result(json_store.JsonStore, store.StoreError),
) -> actor.Next(json_store.JsonStore, Message) {
  case operation {
    Ok(next) -> {
      process.send(reply, Ok(Nil))
      actor.continue(next)
    }
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
  }
}

fn read_reply(
  state: json_store.JsonStore,
  reply: process.Subject(Result(value, store.StoreError)),
  operation: Result(value, store.StoreError),
) -> actor.Next(json_store.JsonStore, Message) {
  process.send(reply, operation)
  actor.continue(state)
}
