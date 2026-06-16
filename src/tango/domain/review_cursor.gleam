import gleam/string

pub type ReviewCommentCursor {
  ReviewCommentCursor(
    ticket_id: String,
    pull_request_ref: String,
    comment_count: Int,
    observed_at: String,
  )
}

pub type ReviewCommentCursorError {
  EmptyTicketId
  EmptyPullRequestRef
  NegativeCommentCount
  EmptyObservedAt
}

pub fn validate(
  cursor: ReviewCommentCursor,
) -> Result(ReviewCommentCursor, ReviewCommentCursorError) {
  case
    string.trim(cursor.ticket_id),
    string.trim(cursor.pull_request_ref),
    cursor.comment_count >= 0,
    string.trim(cursor.observed_at)
  {
    "", _, _, _ -> Error(EmptyTicketId)
    _, "", _, _ -> Error(EmptyPullRequestRef)
    _, _, False, _ -> Error(NegativeCommentCount)
    _, _, _, "" -> Error(EmptyObservedAt)
    _, _, True, _ -> Ok(cursor)
  }
}

pub fn advance(
  cursor: ReviewCommentCursor,
  final_count: Int,
  observed_at: String,
) -> Result(ReviewCommentCursor, ReviewCommentCursorError) {
  case validate(cursor) {
    Error(error) -> Error(error)
    Ok(cursor) ->
      case final_count >= 0, string.trim(observed_at) {
        False, _ -> Error(NegativeCommentCount)
        _, "" -> Error(EmptyObservedAt)
        True, _ ->
          Ok(
            ReviewCommentCursor(
              ..cursor,
              comment_count: case final_count > cursor.comment_count {
                True -> final_count
                False -> cursor.comment_count
              },
              observed_at: observed_at,
            ),
          )
      }
  }
}
