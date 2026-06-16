import gleam/list
import gleam/result
import gleam/string
import tango/domain/lifecycle

pub type ReviewedCommit {
  ReviewedCommit(repo_binding_id: String, commit_id: String)
}

pub type ReviewedPullRequest {
  ReviewedPullRequest(pull_request_ref: String, reviewed_head_commit_id: String)
}

pub type ReviewOutcome {
  Approve
  RequestChanges
  Reject
  Cancel
  Defer
}

pub type ReviewDecision {
  ReviewDecision(
    id: String,
    ticket_id: String,
    reviewer_id: String,
    decision: ReviewOutcome,
    comments: String,
    reviewed_commit_set: List(ReviewedCommit),
    reviewed_pull_request_set: List(ReviewedPullRequest),
    authorization_mechanism: String,
    created_at: String,
  )
}

pub type ReviewError {
  EmptyReviewId
  EmptyTicketId
  EmptyReviewerId
  EmptyAuthorizationMechanism
  EmptyCommitRepoBindingId
  EmptyCommitId
  EmptyPullRequestRef
  EmptyPullRequestHeadCommitId
}

pub fn validate(
  decision: ReviewDecision,
) -> Result(ReviewDecision, ReviewError) {
  case
    string.trim(decision.id),
    string.trim(decision.ticket_id),
    string.trim(decision.reviewer_id),
    string.trim(decision.authorization_mechanism)
  {
    "", _, _, _ -> Error(EmptyReviewId)
    _, "", _, _ -> Error(EmptyTicketId)
    _, _, "", _ -> Error(EmptyReviewerId)
    _, _, _, "" -> Error(EmptyAuthorizationMechanism)
    _, _, _, _ -> {
      use _ <- result.try(
        decision.reviewed_commit_set
        |> list.try_each(validate_commit),
      )
      use _ <- result.try(
        decision.reviewed_pull_request_set
        |> list.try_each(validate_pull_request),
      )
      Ok(decision)
    }
  }
}

pub fn target_state(decision: ReviewDecision) -> lifecycle.LifecycleState {
  case decision.decision {
    Approve -> lifecycle.Merging
    RequestChanges -> lifecycle.ChangesRequested
    Reject -> lifecycle.Failed
    Cancel -> lifecycle.Canceled
    Defer -> lifecycle.AwaitingHumanReview
  }
}

pub fn is_approval(decision: ReviewDecision) -> Bool {
  case decision.decision {
    Approve -> True
    _ -> False
  }
}

pub fn to_string(outcome: ReviewOutcome) -> String {
  case outcome {
    Approve -> "approve"
    RequestChanges -> "request_changes"
    Reject -> "reject"
    Cancel -> "cancel"
    Defer -> "defer"
  }
}

fn validate_commit(commit: ReviewedCommit) -> Result(Nil, ReviewError) {
  case string.trim(commit.repo_binding_id), string.trim(commit.commit_id) {
    "", _ -> Error(EmptyCommitRepoBindingId)
    _, "" -> Error(EmptyCommitId)
    _, _ -> Ok(Nil)
  }
}

fn validate_pull_request(
  pull_request: ReviewedPullRequest,
) -> Result(Nil, ReviewError) {
  case
    string.trim(pull_request.pull_request_ref),
    string.trim(pull_request.reviewed_head_commit_id)
  {
    "", _ -> Error(EmptyPullRequestRef)
    _, "" -> Error(EmptyPullRequestHeadCommitId)
    _, _ -> Ok(Nil)
  }
}
