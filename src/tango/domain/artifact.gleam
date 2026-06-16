import gleam/string

pub type ArtifactKind {
  NormalizedTicket
  ResearchNotes
  Plan
  DiffSummary
  ImplementationNotes
  ValidationReport
  PullRequestSet
  ReviewCommentsReport
  MergeReport
  ExternalUpdates
}

pub type ArtifactRecord {
  ArtifactRecord(
    id: String,
    ticket_id: String,
    run_id: String,
    kind: ArtifactKind,
    filename: String,
    content_type: String,
    sha256: String,
    content: String,
    created_at: String,
  )
}

pub type ArtifactError {
  EmptyArtifactId
  EmptyTicketId
  EmptyRunId
  EmptyFilename
  EmptyContentType
  EmptySha256
  EmptyCreatedAt
}

pub fn validate(
  record: ArtifactRecord,
) -> Result(ArtifactRecord, ArtifactError) {
  case
    string.trim(record.id),
    string.trim(record.ticket_id),
    string.trim(record.run_id),
    string.trim(record.filename),
    string.trim(record.content_type),
    string.trim(record.sha256),
    string.trim(record.created_at)
  {
    "", _, _, _, _, _, _ -> Error(EmptyArtifactId)
    _, "", _, _, _, _, _ -> Error(EmptyTicketId)
    _, _, "", _, _, _, _ -> Error(EmptyRunId)
    _, _, _, "", _, _, _ -> Error(EmptyFilename)
    _, _, _, _, "", _, _ -> Error(EmptyContentType)
    _, _, _, _, _, "", _ -> Error(EmptySha256)
    _, _, _, _, _, _, "" -> Error(EmptyCreatedAt)
    _, _, _, _, _, _, _ -> Ok(record)
  }
}

pub fn kind_to_string(kind: ArtifactKind) -> String {
  case kind {
    NormalizedTicket -> "normalized_ticket"
    ResearchNotes -> "research_notes"
    Plan -> "plan"
    DiffSummary -> "diff_summary"
    ImplementationNotes -> "implementation_notes"
    ValidationReport -> "validation_report"
    PullRequestSet -> "pull_request_set"
    ReviewCommentsReport -> "review_comments_report"
    MergeReport -> "merge_report"
    ExternalUpdates -> "external_updates"
  }
}
