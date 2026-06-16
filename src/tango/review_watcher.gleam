import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleam/string
import tango/attestation/adapter as attestation
import tango/domain/artifact
import tango/domain/forge
import tango/domain/lifecycle
import tango/domain/repo
import tango/domain/review_cursor
import tango/domain/ticket
import tango/runtime
import tango/store/store
import tango/store_server
import tango/workspace/workspace

pub type Dependencies {
  Dependencies(
    workspace: workspace.WorkspaceAdapter,
    forge: attestation.ForgeAdapter,
  )
}

pub type Message {
  Tick
}

pub type State(message) {
  State(
    state_dir: String,
    store_name: process.Name(store_server.Message),
    dependencies: Dependencies,
    interval_ms: Int,
    notify: process.Subject(message),
    into_message: fn(String) -> message,
    subject: process.Subject(Message),
  )
}

type PullRequestSetArtifact {
  PullRequestSetArtifact(entries: List(PullRequestArtifactEntry))
}

type PullRequestArtifactEntry {
  PullRequestArtifactEntry(repo_binding_id: String, pull_request_ref: String)
}

type WatchDecision {
  NoConversationComments
  NewConversationComments
}

pub fn start(
  state_dir: String,
  store_name: process.Name(store_server.Message),
  dependencies: Dependencies,
  interval_ms: Int,
  notify: process.Subject(message),
  into_message: fn(String) -> message,
) {
  actor.new_with_initialiser(5000, fn(subject) {
    process.send(subject, Tick)
    Ok(
      actor.initialised(State(
        state_dir: state_dir,
        store_name: store_name,
        dependencies: dependencies,
        interval_ms: interval_ms,
        notify: notify,
        into_message: into_message,
        subject: subject,
      )),
    )
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn supervised(
  state_dir: String,
  store_name: process.Name(store_server.Message),
  dependencies: Dependencies,
  interval_ms: Int,
  notify: process.Subject(message),
  into_message: fn(String) -> message,
) {
  supervision.worker(fn() {
    start(
      state_dir,
      store_name,
      dependencies,
      interval_ms,
      notify,
      into_message,
    )
  })
}

fn handle_message(
  state: State(message),
  message: Message,
) -> actor.Next(State(message), Message) {
  case message {
    Tick -> {
      emit_due_tickets(state)
      process.send_after(state.subject, state.interval_ms, Tick)
      actor.continue(state)
    }
  }
}

fn emit_due_tickets(state: State(message)) -> Nil {
  let backend = store_server.store()
  case backend.list_tickets(state.store_name) {
    Error(_) -> Nil
    Ok(tickets) ->
      tickets
      |> list.filter(fn(item) { item.state == lifecycle.AwaitingHumanReview })
      |> list.each(fn(item) {
        case inspect_ticket(backend, state, item) {
          Ok(NewConversationComments) ->
            process.send(state.notify, state.into_message(item.id))
          Ok(NoConversationComments) | Error(_) -> Nil
        }
      })
  }
}

fn inspect_ticket(
  backend: store.Store(process.Name(store_server.Message)),
  state: State(message),
  item: ticket.Ticket,
) -> Result(WatchDecision, Nil) {
  use cursors <- result.try(
    backend.list_review_cursors(state.store_name, item.id)
    |> result.map_error(fn(_) { Nil }),
  )
  case cursors {
    [] -> Ok(NoConversationComments)
    _ -> {
      use pull_requests <- result.try(
        latest_pull_request_set(backend, state.store_name, item.id)
        |> result.map_error(fn(_) { Nil }),
      )
      use current_workspace <- result.try(
        state.dependencies.workspace.ensure(state.state_dir, item)
        |> result.map_error(fn(_) { Nil }),
      )
      use forge_binding <- result.try(case item.forge_binding {
        Some(binding) -> Ok(binding)
        None -> Error(Nil)
      })
      let observed_at = runtime.now_rfc3339()
      cursors
      |> list.fold(Ok(NoConversationComments), fn(acc, cursor) {
        use decision <- result.try(acc)
        case decision {
          NewConversationComments -> Ok(NewConversationComments)
          NoConversationComments ->
            inspect_cursor(
              backend,
              state.store_name,
              state.dependencies.forge,
              item,
              current_workspace,
              forge_binding,
              pull_requests,
              cursor,
              observed_at,
            )
        }
      })
    }
  }
}

fn inspect_cursor(
  backend: store.Store(process.Name(store_server.Message)),
  store_name: process.Name(store_server.Message),
  forge_adapter: attestation.ForgeAdapter,
  item: ticket.Ticket,
  current_workspace: workspace.Workspace,
  forge_binding: forge.ForgeBinding,
  pull_requests: PullRequestSetArtifact,
  cursor: review_cursor.ReviewCommentCursor,
  observed_at: String,
) -> Result(WatchDecision, Nil) {
  use pull_request <- result.try(
    find_pull_request(pull_requests.entries, cursor.pull_request_ref)
    |> result.map_error(fn(_) { Nil }),
  )
  use repository <- result.try(
    find_repository(item, pull_request.repo_binding_id)
    |> result.map_error(fn(_) { Nil }),
  )
  use snapshot <- result.try(
    forge_adapter.read_comments(attestation.PullRequestCommentsRequest(
      binding: forge_binding,
      repository: repository,
      pull_request_ref: cursor.pull_request_ref,
      repository_path: repository_path(
        current_workspace,
        pull_request.repo_binding_id,
      ),
    ))
    |> result.map_error(fn(_) { Nil }),
  )
  case
    snapshot.pull_request_ref == cursor.pull_request_ref,
    snapshot.final_comment_count >= 0,
    snapshot.final_comment_count > cursor.comment_count
  {
    False, _, _ -> Error(Nil)
    _, False, _ -> Error(Nil)
    _, _, True -> Ok(NewConversationComments)
    True, True, False -> {
      use updated <- result.try(
        review_cursor.advance(cursor, snapshot.final_comment_count, observed_at)
        |> result.map_error(fn(_) { Nil }),
      )
      backend.save_review_cursor(store_name, updated)
      |> result.map(fn(_) { NoConversationComments })
      |> result.map_error(fn(_) { Nil })
    }
  }
}

fn latest_pull_request_set(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(PullRequestSetArtifact, Nil) {
  use artifacts <- result.try(
    backend.list_artifacts(state, ticket_id) |> result.map_error(fn(_) { Nil }),
  )
  case latest_pull_request_artifact(artifacts) {
    Some(record) ->
      json.parse(record.content, pull_request_set_decoder())
      |> result.map_error(fn(_) { Nil })
    None -> Error(Nil)
  }
}

fn latest_pull_request_artifact(
  artifacts: List(artifact.ArtifactRecord),
) -> Option(artifact.ArtifactRecord) {
  case
    artifacts
    |> list.filter(fn(item) { item.kind == artifact.PullRequestSet })
    |> list.sort(fn(left, right) {
      case string.compare(left.created_at, right.created_at) {
        order.Lt -> order.Gt
        order.Gt -> order.Lt
        order.Eq -> order.Eq
      }
    })
    |> list.first
  {
    Ok(record) -> Some(record)
    Error(_) -> None
  }
}

fn find_pull_request(
  entries: List(PullRequestArtifactEntry),
  pull_request_ref: String,
) -> Result(PullRequestArtifactEntry, Nil) {
  entries
  |> list.find(fn(entry) { entry.pull_request_ref == pull_request_ref })
  |> result.map_error(fn(_) { Nil })
}

fn find_repository(
  item: ticket.Ticket,
  binding_id: String,
) -> Result(repo.RepoBinding, Nil) {
  item.repo_bindings
  |> list.find(fn(binding) { binding.id == binding_id })
  |> result.map_error(fn(_) { Nil })
}

fn repository_path(
  current_workspace: workspace.Workspace,
  binding_id: String,
) -> Option(String) {
  case
    current_workspace.repos
    |> list.find(fn(repository) { repository.binding_id == binding_id })
  {
    Ok(repository) -> Some(repository.path)
    Error(_) -> None
  }
}

fn pull_request_set_decoder() -> decode.Decoder(PullRequestSetArtifact) {
  use version <- decode.field("schema_version", decode.int)
  use entries <- decode.field(
    "pull_requests",
    decode.list(of: pull_request_entry_decoder()),
  )
  case version {
    1 -> decode.success(PullRequestSetArtifact(entries: entries))
    _ ->
      decode.failure(
        PullRequestSetArtifact(entries: []),
        expected: "pull request set schema version 1",
      )
  }
}

fn pull_request_entry_decoder() -> decode.Decoder(PullRequestArtifactEntry) {
  use repo_binding_id <- decode.field("repo_binding_id", decode.string)
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  case string.trim(repo_binding_id), string.trim(pull_request_ref) {
    "", _ ->
      decode.failure(
        PullRequestArtifactEntry(repo_binding_id: "", pull_request_ref: ""),
        expected: "non-empty repo binding id",
      )
    _, "" ->
      decode.failure(
        PullRequestArtifactEntry(repo_binding_id: "", pull_request_ref: ""),
        expected: "non-empty pull request ref",
      )
    _, _ ->
      decode.success(PullRequestArtifactEntry(
        repo_binding_id: repo_binding_id,
        pull_request_ref: pull_request_ref,
      ))
  }
}
