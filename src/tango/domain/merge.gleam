import gleam/list
import gleam/result
import gleam/string

pub type MergeEntryStatus {
  Completed
  Pending
  FailedEntry
}

pub type MergeEntry {
  MergeEntry(
    repo_binding_id: String,
    pull_request_ref: String,
    approved_head_commit_id: String,
    status: MergeEntryStatus,
  )
}

pub type MergeRecord {
  MergeRecord(
    id: String,
    ticket_id: String,
    review_decision_id: String,
    entries: List(MergeEntry),
    created_at: String,
    completed_at: String,
  )
}

pub type MergeError {
  EmptyMergeId
  EmptyTicketId
  EmptyReviewDecisionId
  EmptyRepoBindingId
  EmptyPullRequestRef
  EmptyApprovedHeadCommitId
}

pub fn validate(record: MergeRecord) -> Result(MergeRecord, MergeError) {
  case
    string.trim(record.id),
    string.trim(record.ticket_id),
    string.trim(record.review_decision_id)
  {
    "", _, _ -> Error(EmptyMergeId)
    _, "", _ -> Error(EmptyTicketId)
    _, _, "" -> Error(EmptyReviewDecisionId)
    _, _, _ -> {
      use _ <- result.try(record.entries |> list.try_each(validate_entry))
      Ok(record)
    }
  }
}

pub fn is_successful(record: MergeRecord) -> Bool {
  list.all(record.entries, fn(entry) { entry.status == Completed })
}

fn validate_entry(entry: MergeEntry) -> Result(Nil, MergeError) {
  case
    string.trim(entry.repo_binding_id),
    string.trim(entry.pull_request_ref),
    string.trim(entry.approved_head_commit_id)
  {
    "", _, _ -> Error(EmptyRepoBindingId)
    _, "", _ -> Error(EmptyPullRequestRef)
    _, _, "" -> Error(EmptyApprovedHeadCommitId)
    _, _, _ -> Ok(Nil)
  }
}
