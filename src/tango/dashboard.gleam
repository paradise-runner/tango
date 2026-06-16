import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import tango/domain/block
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/review
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/store

pub type StatusSnapshot {
  StatusSnapshot(
    generated_at: String,
    operator_id: String,
    total_tickets: Int,
    queued_tickets: List(ticket.Ticket),
    awaiting_review_tickets: List(ticket.Ticket),
    blocked_tickets: List(BlockedTicket),
    active_runs: List(ActiveRun),
  )
}

pub type DashboardSnapshot {
  DashboardSnapshot(
    generated_at: String,
    operator_id: String,
    tickets: List(DashboardTicket),
    active_runs: List(ActiveRun),
  )
}

pub type TicketDetail {
  TicketDetail(
    ticket: ticket.Ticket,
    sessions: List(session.AgentSession),
    runs: List(run.RunAttempt),
    blocks: List(block.BlockRecord),
    reviews: List(review.ReviewDecision),
    merges: List(merge.MergeRecord),
  )
}

pub type ReviewEntry {
  ReviewEntry(ticket: ticket.Ticket, decision: review.ReviewDecision)
}

pub type ActiveRun {
  ActiveRun(ticket: ticket.Ticket, attempt: run.RunAttempt)
}

pub type BlockedTicket {
  BlockedTicket(ticket: ticket.Ticket, active_block: Option(block.BlockRecord))
}

pub type DashboardTicket {
  DashboardTicket(
    ticket: ticket.Ticket,
    active_run: Option(run.RunAttempt),
    active_block: Option(block.BlockRecord),
    latest_review: Option(review.ReviewDecision),
  )
}

pub fn status_snapshot(
  backend: store.Store(state),
  state: state,
  generated_at: String,
  operator_id: String,
) -> Result(StatusSnapshot, store.StoreError) {
  use tickets <- result.try(backend.list_tickets(state))
  let sorted = sort_tickets(tickets)
  use blocked_tickets <- result.try(blocked_tickets(backend, state, sorted))
  use active_runs <- result.try(active_runs(backend, state, sorted))
  Ok(StatusSnapshot(
    generated_at: generated_at,
    operator_id: operator_id,
    total_tickets: list.length(sorted),
    queued_tickets: list.filter(sorted, fn(item) {
      item.state == lifecycle.Queued
    }),
    awaiting_review_tickets: list.filter(sorted, fn(item) {
      item.state == lifecycle.AwaitingHumanReview
    }),
    blocked_tickets: blocked_tickets,
    active_runs: active_runs,
  ))
}

pub fn dashboard_snapshot(
  backend: store.Store(state),
  state: state,
  generated_at: String,
  operator_id: String,
) -> Result(DashboardSnapshot, store.StoreError) {
  use tickets <- result.try(backend.list_tickets(state))
  let sorted = sort_tickets(tickets)
  use rows <- result.try(dashboard_rows(backend, state, sorted))
  use active_runs <- result.try(active_runs(backend, state, sorted))
  Ok(DashboardSnapshot(
    generated_at: generated_at,
    operator_id: operator_id,
    tickets: rows,
    active_runs: active_runs,
  ))
}

pub fn ticket_list(
  backend: store.Store(state),
  state: state,
) -> Result(List(ticket.Ticket), store.StoreError) {
  backend.list_tickets(state) |> result.map(sort_tickets)
}

pub fn ticket_detail(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(TicketDetail, store.StoreError) {
  use item <- result.try(backend.get_ticket(state, ticket_id))
  use sessions <- result.try(safe_list(backend.list_sessions(state, ticket_id)))
  use runs <- result.try(safe_list(backend.list_runs(state, ticket_id)))
  use blocks <- result.try(safe_list(backend.list_blocks(state, ticket_id)))
  use reviews <- result.try(safe_list(backend.list_reviews(state, ticket_id)))
  use merges <- result.try(safe_list(backend.list_merges(state, ticket_id)))
  Ok(TicketDetail(
    ticket: item,
    sessions: sort_sessions(sessions),
    runs: sort_runs(runs),
    blocks: sort_blocks(blocks),
    reviews: sort_reviews(reviews),
    merges: sort_merges(merges),
  ))
}

pub fn review_entries(
  backend: store.Store(state),
  state: state,
) -> Result(List(ReviewEntry), store.StoreError) {
  use tickets <- result.try(backend.list_tickets(state))
  let sorted = sort_tickets(tickets)
  sorted
  |> list.fold(Ok([]), fn(acc, item) {
    case acc, safe_list(backend.list_reviews(state, item.id)) {
      Ok(entries), Ok(reviews) ->
        Ok(list.append(
          entries,
          reviews
            |> sort_reviews
            |> list.map(fn(decision) {
              ReviewEntry(ticket: item, decision: decision)
            }),
        ))
      Error(error), _ -> Error(error)
      _, Error(error) -> Error(error)
    }
  })
}

pub fn review_detail(
  backend: store.Store(state),
  state: state,
  ticket_id: String,
) -> Result(#(ticket.Ticket, List(review.ReviewDecision)), store.StoreError) {
  use item <- result.try(backend.get_ticket(state, ticket_id))
  use reviews <- result.try(safe_list(backend.list_reviews(state, ticket_id)))
  Ok(#(item, sort_reviews(reviews)))
}

pub fn render_status(snapshot: StatusSnapshot) -> String {
  string.join(
    list.flatten([
      [
        "operator: " <> snapshot.operator_id,
        "generated_at: " <> snapshot.generated_at,
        "tickets_total: " <> int.to_string(snapshot.total_tickets),
        "queued: " <> int.to_string(list.length(snapshot.queued_tickets)),
        "awaiting_human_review: "
          <> int.to_string(list.length(snapshot.awaiting_review_tickets)),
        "blocked: " <> int.to_string(list.length(snapshot.blocked_tickets)),
        "active_runs: " <> int.to_string(list.length(snapshot.active_runs)),
        "",
      ],
      render_ticket_section("queued tickets", snapshot.queued_tickets),
      [""],
      render_ticket_section(
        "awaiting human review",
        snapshot.awaiting_review_tickets,
      ),
      [""],
      render_blocked_section(snapshot.blocked_tickets),
      [""],
      render_active_runs_section(snapshot.active_runs),
    ]),
    with: "\n",
  )
}

pub fn render_dashboard(snapshot: DashboardSnapshot) -> String {
  string.join(
    list.flatten([
      [
        "dashboard: terminal",
        "operator: " <> snapshot.operator_id,
        "generated_at: " <> snapshot.generated_at,
        "tickets: " <> int.to_string(list.length(snapshot.tickets)),
        "active_runs: " <> int.to_string(list.length(snapshot.active_runs)),
        "",
        "tickets:",
      ],
      case snapshot.tickets {
        [] -> ["  (none)"]
        tickets ->
          tickets
          |> list.map(fn(row) { "  " <> dashboard_ticket_line(row) })
      },
    ]),
    with: "\n",
  )
}

pub fn render_ticket_list(tickets: List(ticket.Ticket)) -> String {
  string.join(
    case tickets {
      [] -> ["tickets:", "  (none)"]
      tickets -> [
        "tickets:",
        ..tickets
        |> list.map(fn(item) { "  " <> ticket_line(item) })
      ]
    },
    with: "\n",
  )
}

pub fn render_ticket_detail(detail: TicketDetail) -> String {
  let item = detail.ticket
  string.join(
    list.flatten([
      [
        "ticket: " <> item.identifier <> " (" <> item.id <> ")",
        "state: " <> lifecycle.to_string(item.state),
        "priority: " <> optional_int(item.priority),
        "external_ref: " <> optional_text(item.external_ref),
        "forge: " <> forge_name(item),
        "repos: " <> int.to_string(list.length(item.repo_bindings)),
        "main_session_id: " <> optional_text(item.main_session_id),
        "aux_sessions: " <> int.to_string(list.length(item.aux_session_ids)),
        "active_block_id: " <> optional_text(item.active_block_id),
        "observed_external_status_id: "
          <> optional_text(item.observed_external_status_id),
        "created_at: " <> item.created_at,
        "updated_at: " <> item.updated_at,
        "",
      ],
      render_session_section(detail.sessions),
      [""],
      render_run_section(detail.runs),
      [""],
      render_block_history(detail.blocks),
      [""],
      render_review_history(detail.reviews),
      [""],
      render_merge_history(detail.merges),
    ]),
    with: "\n",
  )
}

fn forge_name(item: ticket.Ticket) -> String {
  case item.forge_binding {
    Some(binding) -> binding.forge_name
    None -> "-"
  }
}

pub fn render_review_list(entries: List(ReviewEntry)) -> String {
  string.join(
    case entries {
      [] -> ["reviews:", "  (none)"]
      entries -> [
        "reviews:",
        ..entries
        |> list.map(fn(entry) { "  " <> review_entry_line(entry) })
      ]
    },
    with: "\n",
  )
}

pub fn render_review_detail(
  item: ticket.Ticket,
  decisions: List(review.ReviewDecision),
) -> String {
  string.join(
    list.flatten([
      [
        "review history: " <> item.identifier <> " (" <> item.id <> ")",
        "state: " <> lifecycle.to_string(item.state),
        "",
      ],
      render_review_history(decisions),
    ]),
    with: "\n",
  )
}

fn dashboard_rows(
  backend: store.Store(state),
  state: state,
  tickets: List(ticket.Ticket),
) -> Result(List(DashboardTicket), store.StoreError) {
  tickets
  |> list.fold(Ok([]), fn(acc, item) {
    case
      acc,
      safe_list(backend.list_runs(state, item.id)),
      safe_list(backend.list_blocks(state, item.id)),
      safe_list(backend.list_reviews(state, item.id))
    {
      Ok(rows), Ok(runs), Ok(blocks), Ok(reviews) ->
        Ok(
          list.append(rows, [
            DashboardTicket(
              ticket: item,
              active_run: latest_active_run(runs),
              active_block: active_block(item, blocks),
              latest_review: latest_review(reviews),
            ),
          ]),
        )
      Error(error), _, _, _ -> Error(error)
      _, Error(error), _, _ -> Error(error)
      _, _, Error(error), _ -> Error(error)
      _, _, _, Error(error) -> Error(error)
    }
  })
}

fn blocked_tickets(
  backend: store.Store(state),
  state: state,
  tickets: List(ticket.Ticket),
) -> Result(List(BlockedTicket), store.StoreError) {
  tickets
  |> list.filter(fn(item) { item.state == lifecycle.Blocked })
  |> list.fold(Ok([]), fn(acc, item) {
    case acc, safe_list(backend.list_blocks(state, item.id)) {
      Ok(rows), Ok(blocks) ->
        Ok(
          list.append(rows, [
            BlockedTicket(
              ticket: item,
              active_block: active_block(item, blocks),
            ),
          ]),
        )
      Error(error), _ -> Error(error)
      _, Error(error) -> Error(error)
    }
  })
}

fn active_runs(
  backend: store.Store(state),
  state: state,
  tickets: List(ticket.Ticket),
) -> Result(List(ActiveRun), store.StoreError) {
  tickets
  |> list.fold(Ok([]), fn(acc, item) {
    case acc, safe_list(backend.list_runs(state, item.id)) {
      Ok(rows), Ok(runs) -> {
        let next =
          runs
          |> sort_runs
          |> list.filter(fn(attempt) { run.is_active(attempt.status) })
          |> list.map(fn(attempt) { ActiveRun(ticket: item, attempt: attempt) })
        Ok(list.append(rows, next))
      }
      Error(error), _ -> Error(error)
      _, Error(error) -> Error(error)
    }
  })
}

fn safe_list(
  items: Result(List(a), store.StoreError),
) -> Result(List(a), store.StoreError) {
  case items {
    Ok(items) -> Ok(items)
    Error(store.NotFound(_)) -> Ok([])
    Error(store.IoFailed("enoent")) -> Ok([])
    Error(other) -> Error(other)
  }
}

fn sort_tickets(tickets: List(ticket.Ticket)) -> List(ticket.Ticket) {
  list.sort(tickets, ticket.compare_for_dispatch)
}

fn sort_sessions(
  sessions: List(session.AgentSession),
) -> List(session.AgentSession) {
  list.sort(sessions, fn(left, right) {
    case string.compare(left.created_at, right.created_at) {
      order.Eq -> string.compare(left.id, right.id)
      other -> other
    }
  })
}

fn sort_runs(runs: List(run.RunAttempt)) -> List(run.RunAttempt) {
  list.sort(runs, fn(left, right) {
    compare_desc_then_id(left.started_at, right.started_at, left.id, right.id)
  })
}

fn sort_blocks(blocks: List(block.BlockRecord)) -> List(block.BlockRecord) {
  list.sort(blocks, fn(left, right) {
    compare_desc_then_id(left.created_at, right.created_at, left.id, right.id)
  })
}

fn sort_reviews(
  reviews: List(review.ReviewDecision),
) -> List(review.ReviewDecision) {
  list.sort(reviews, fn(left, right) {
    compare_desc_then_id(left.created_at, right.created_at, left.id, right.id)
  })
}

fn sort_merges(merges: List(merge.MergeRecord)) -> List(merge.MergeRecord) {
  list.sort(merges, fn(left, right) {
    compare_desc_then_id(left.created_at, right.created_at, left.id, right.id)
  })
}

fn compare_desc_then_id(
  left: String,
  right: String,
  left_id: String,
  right_id: String,
) -> order.Order {
  case string.compare(left, right) {
    order.Lt -> order.Gt
    order.Gt -> order.Lt
    order.Eq -> string.compare(left_id, right_id)
  }
}

fn latest_active_run(runs: List(run.RunAttempt)) -> Option(run.RunAttempt) {
  runs
  |> sort_runs
  |> list.find(fn(attempt) { run.is_active(attempt.status) })
  |> result_to_option
}

fn latest_review(
  reviews: List(review.ReviewDecision),
) -> Option(review.ReviewDecision) {
  case reviews |> sort_reviews {
    [first, ..] -> Some(first)
    [] -> None
  }
}

fn active_block(
  item: ticket.Ticket,
  blocks: List(block.BlockRecord),
) -> Option(block.BlockRecord) {
  case item.active_block_id {
    None -> None
    Some(id) ->
      blocks
      |> list.find(fn(record) { record.id == id })
      |> result_to_option
  }
}

fn render_ticket_section(
  title: String,
  tickets: List(ticket.Ticket),
) -> List(String) {
  case tickets {
    [] -> [title <> ":", "  (none)"]
    tickets -> [
      title <> ":",
      ..tickets
      |> list.map(fn(item) { "  " <> ticket_line(item) })
    ]
  }
}

fn render_blocked_section(entries: List(BlockedTicket)) -> List(String) {
  case entries {
    [] -> ["blocked tickets:", "  (none)"]
    entries -> [
      "blocked tickets:",
      ..entries
      |> list.map(fn(entry) {
        "  "
        <> entry.ticket.identifier
        <> " | "
        <> block_summary(entry.active_block)
      })
    ]
  }
}

fn render_active_runs_section(entries: List(ActiveRun)) -> List(String) {
  case entries {
    [] -> ["active runs:", "  (none)"]
    entries -> [
      "active runs:",
      ..entries
      |> list.map(fn(entry) {
        "  " <> entry.ticket.identifier <> " | " <> run_line(entry.attempt)
      })
    ]
  }
}

fn render_session_section(
  sessions: List(session.AgentSession),
) -> List(String) {
  case sessions {
    [] -> ["sessions:", "  (none)"]
    sessions -> [
      "sessions:",
      ..sessions
      |> list.map(fn(current) {
        "  "
        <> current.id
        <> " | "
        <> session_role_text(current.role)
        <> "/"
        <> session_kind_text(current.kind)
        <> " | runs="
        <> int.to_string(list.length(current.run_attempt_ids))
        <> " | runtime_session_id="
        <> optional_text(current.runtime_session_id)
      })
    ]
  }
}

fn render_run_section(runs: List(run.RunAttempt)) -> List(String) {
  case runs {
    [] -> ["runs:", "  (none)"]
    runs -> [
      "runs:",
      ..runs
      |> list.map(fn(attempt) { "  " <> run_line(attempt) })
    ]
  }
}

fn render_block_history(blocks: List(block.BlockRecord)) -> List(String) {
  case blocks {
    [] -> ["blocks:", "  (none)"]
    blocks -> [
      "blocks:",
      ..blocks
      |> list.map(fn(record) {
        "  "
        <> record.id
        <> " | "
        <> lifecycle.to_string(record.blocked_from)
        <> " -> "
        <> lifecycle.to_string(record.resume_state)
        <> " | "
        <> record.reason
        <> " | resolved_by="
        <> optional_text(record.resolved_by)
      })
    ]
  }
}

fn render_review_history(reviews: List(review.ReviewDecision)) -> List(String) {
  case reviews {
    [] -> ["reviews:", "  (none)"]
    reviews -> [
      "reviews:",
      ..reviews
      |> list.map(fn(decision) {
        "  "
        <> decision.id
        <> " | "
        <> review.to_string(decision.decision)
        <> " | reviewer="
        <> decision.reviewer_id
        <> " | commits="
        <> int.to_string(list.length(decision.reviewed_commit_set))
        <> " | prs="
        <> int.to_string(list.length(decision.reviewed_pull_request_set))
        <> " | at="
        <> decision.created_at
      })
    ]
  }
}

fn render_merge_history(merges: List(merge.MergeRecord)) -> List(String) {
  case merges {
    [] -> ["merges:", "  (none)"]
    merges -> [
      "merges:",
      ..merges
      |> list.map(fn(record) {
        "  "
        <> record.id
        <> " | review="
        <> record.review_decision_id
        <> " | entries="
        <> int.to_string(list.length(record.entries))
        <> " | completed_at="
        <> record.completed_at
      })
    ]
  }
}

fn dashboard_ticket_line(row: DashboardTicket) -> String {
  row.ticket.identifier
  <> " | "
  <> lifecycle.to_string(row.ticket.state)
  <> " | priority="
  <> optional_int(row.ticket.priority)
  <> " | active_run="
  <> maybe_run_summary(row.active_run)
  <> " | latest_review="
  <> maybe_review_summary(row.latest_review)
  <> " | block="
  <> block_summary(row.active_block)
}

fn ticket_line(item: ticket.Ticket) -> String {
  item.identifier
  <> " | "
  <> lifecycle.to_string(item.state)
  <> " | priority="
  <> optional_int(item.priority)
  <> " | external_ref="
  <> optional_text(item.external_ref)
}

fn review_entry_line(entry: ReviewEntry) -> String {
  entry.ticket.identifier
  <> " | "
  <> review.to_string(entry.decision.decision)
  <> " | reviewer="
  <> entry.decision.reviewer_id
  <> " | at="
  <> entry.decision.created_at
}

fn run_line(attempt: run.RunAttempt) -> String {
  attempt.id
  <> " | "
  <> run_kind_text(attempt.kind)
  <> " | "
  <> run_status_text(attempt.status)
  <> " | attempt="
  <> int.to_string(attempt.attempt)
  <> " | session="
  <> attempt.session_id
  <> " | started_at="
  <> attempt.started_at
}

fn run_kind_text(kind: run.RunKind) -> String {
  case kind {
    run.Execution -> "execution"
    run.ReviewWatch -> "review_watch"
    run.RegistrySync -> "registry_sync"
    run.MergeRun -> "merge"
  }
}

fn run_status_text(status: run.RunStatus) -> String {
  case status {
    run.PreparingWorkspace -> "preparing_workspace"
    run.BuildingPrompt -> "building_prompt"
    run.LaunchingAgent -> "launching_agent"
    run.Streaming -> "streaming"
    run.CollectingArtifacts -> "collecting_artifacts"
    run.Succeeded -> "succeeded"
    run.Failed -> "failed"
    run.TimedOut -> "timed_out"
    run.Stalled -> "stalled"
    run.Canceled -> "canceled"
  }
}

fn session_role_text(role: session.SessionRole) -> String {
  case role {
    session.Main -> "main"
    session.Aux -> "aux"
  }
}

fn session_kind_text(kind: session.SessionKind) -> String {
  case kind {
    session.Implementation -> "implementation"
    session.PrFeedback -> "pr_feedback"
    session.RegistrySync -> "registry_sync"
    session.Merge -> "merge"
  }
}

fn block_summary(record: Option(block.BlockRecord)) -> String {
  case record {
    None -> "-"
    Some(record) ->
      record.id
      <> ":"
      <> record.reason
      <> "->"
      <> lifecycle.to_string(record.resume_state)
  }
}

fn maybe_run_summary(value: Option(run.RunAttempt)) -> String {
  case value {
    None -> "-"
    Some(attempt) ->
      run_kind_text(attempt.kind) <> ":" <> run_status_text(attempt.status)
  }
}

fn maybe_review_summary(value: Option(review.ReviewDecision)) -> String {
  case value {
    None -> "-"
    Some(decision) ->
      review.to_string(decision.decision) <> "@" <> decision.created_at
  }
}

fn optional_text(value: Option(String)) -> String {
  case value {
    Some(value) -> value
    None -> "-"
  }
}

fn optional_int(value: Option(Int)) -> String {
  case value {
    Some(value) -> int.to_string(value)
    None -> "-"
  }
}

fn result_to_option(result: Result(a, b)) -> Option(a) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}
