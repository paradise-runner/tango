import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/domain/forge
import tango/domain/registry_status
import tango/domain/repo

pub type TicketRequest {
  TicketRequest(
    binding: registry_status.RegistryBinding,
    expected_status: registry_status.ExternalStatus,
    repository_path: Option(String),
    require_comment: Bool,
  )
}

pub type TicketSnapshot {
  TicketSnapshot(
    external_ref: String,
    description_revision: String,
    comments: List(String),
    status_ids: List(String),
  )
}

pub type PullRequestState {
  Open
  Closed
  Merged
}

type RepositoryIdentity {
  RepositoryIdentity(host: Option(String), path: String)
}

pub type PullRequestRequest {
  PullRequestRequest(
    binding: forge.ForgeBinding,
    repository: repo.RepoBinding,
    pull_request_ref: String,
    expected_source_branch: Option(String),
    expected_target_branch: Option(String),
    expected_head_commit_id: String,
    require_merged: Bool,
    repository_path: Option(String),
  )
}

pub type PullRequestSnapshot {
  PullRequestSnapshot(
    pull_request_ref: String,
    repository_location: String,
    source_branch: String,
    target_branch: String,
    head_commit_id: String,
    state: PullRequestState,
  )
}

pub type PullRequestCommentsRequest {
  PullRequestCommentsRequest(
    binding: forge.ForgeBinding,
    repository: repo.RepoBinding,
    pull_request_ref: String,
    repository_path: Option(String),
  )
}

pub type PullRequestCommentsSnapshot {
  PullRequestCommentsSnapshot(
    pull_request_ref: String,
    comments: List(String),
    final_comment_count: Int,
  )
}

pub type AttestationError {
  ReadFailed(String)
  TicketNotFound(String)
  TicketDescriptionRevisionMissing(String)
  TicketCommentsMissing(String)
  TicketStatusMismatch(expected: String, observed: List(String))
  PullRequestNotFound(String)
  PullRequestRepositoryMismatch(expected: String, observed: String)
  PullRequestSourceBranchMismatch(expected: String, observed: String)
  PullRequestTargetBranchMismatch(expected: String, observed: String)
  PullRequestHeadMismatch(expected: String, observed: String)
  PullRequestNotMerged(String)
  PullRequestCommentCountInvalid(String)
}

pub type TicketAdapter {
  TicketAdapter(
    read: fn(TicketRequest) -> Result(TicketSnapshot, AttestationError),
  )
}

pub type ForgeAdapter {
  ForgeAdapter(
    read: fn(PullRequestRequest) ->
      Result(PullRequestSnapshot, AttestationError),
    read_comments: fn(PullRequestCommentsRequest) ->
      Result(PullRequestCommentsSnapshot, AttestationError),
  )
}

pub type Adapters {
  Adapters(ticket_system: TicketAdapter, forge: ForgeAdapter)
}

pub fn attest_ticket(
  adapter: TicketAdapter,
  request: TicketRequest,
) -> Result(TicketSnapshot, AttestationError) {
  use snapshot <- result.try(adapter.read(request))
  case
    snapshot.external_ref == request.binding.external_ticket_ref,
    string.trim(snapshot.description_revision),
    list.contains(snapshot.status_ids, request.expected_status.id),
    !request.require_comment || snapshot.comments != []
  {
    False, _, _, _ -> Error(TicketNotFound(request.binding.external_ticket_ref))
    _, "", _, _ ->
      Error(TicketDescriptionRevisionMissing(
        request.binding.external_ticket_ref,
      ))
    _, _, False, _ ->
      Error(TicketStatusMismatch(
        expected: request.expected_status.id,
        observed: snapshot.status_ids,
      ))
    _, _, _, False ->
      Error(TicketCommentsMissing(request.binding.external_ticket_ref))
    True, _, True, True -> Ok(snapshot)
  }
}

pub fn attest_pull_request(
  adapter: ForgeAdapter,
  request: PullRequestRequest,
) -> Result(PullRequestSnapshot, AttestationError) {
  use snapshot <- result.try(adapter.read(request))
  use _ <- result.try(
    case snapshot.pull_request_ref == request.pull_request_ref {
      True -> Ok(Nil)
      False -> Error(PullRequestNotFound(request.pull_request_ref))
    },
  )
  use _ <- result.try(
    case
      same_repository(snapshot.repository_location, request.repository.location)
    {
      True -> Ok(Nil)
      False ->
        Error(PullRequestRepositoryMismatch(
          expected: request.repository.location,
          observed: snapshot.repository_location,
        ))
    },
  )
  use _ <- result.try(match_optional_branch(
    request.expected_source_branch,
    snapshot.source_branch,
    PullRequestSourceBranchMismatch,
  ))
  use _ <- result.try(match_optional_branch(
    request.expected_target_branch,
    snapshot.target_branch,
    PullRequestTargetBranchMismatch,
  ))
  use _ <- result.try(
    case snapshot.head_commit_id == request.expected_head_commit_id {
      True -> Ok(Nil)
      False ->
        Error(PullRequestHeadMismatch(
          expected: request.expected_head_commit_id,
          observed: snapshot.head_commit_id,
        ))
    },
  )
  case request.require_merged, snapshot.state {
    True, Merged -> Ok(snapshot)
    True, _ -> Error(PullRequestNotMerged(request.pull_request_ref))
    False, _ -> Ok(snapshot)
  }
}

pub fn passthrough() -> Adapters {
  Adapters(
    ticket_system: TicketAdapter(read: fn(request) {
      Ok(
        TicketSnapshot(
          external_ref: request.binding.external_ticket_ref,
          description_revision: "passthrough",
          comments: ["attested"],
          status_ids: [request.expected_status.id],
        ),
      )
    }),
    forge: ForgeAdapter(
      read: fn(request) {
        Ok(
          PullRequestSnapshot(
            pull_request_ref: request.pull_request_ref,
            repository_location: request.repository.location,
            source_branch: option_value(request.expected_source_branch),
            target_branch: option_value(request.expected_target_branch),
            head_commit_id: request.expected_head_commit_id,
            state: case request.require_merged {
              True -> Merged
              False -> Open
            },
          ),
        )
      },
      read_comments: fn(request) {
        Ok(PullRequestCommentsSnapshot(
          pull_request_ref: request.pull_request_ref,
          comments: [],
          final_comment_count: 0,
        ))
      },
    ),
  )
}

fn match_optional_branch(
  expected: Option(String),
  observed: String,
  mismatch: fn(String, String) -> AttestationError,
) -> Result(Nil, AttestationError) {
  case expected {
    None ->
      case string.trim(observed) {
        "" -> Error(mismatch("non-empty branch", observed))
        _ -> Ok(Nil)
      }
    Some(value) ->
      case value == observed {
        True -> Ok(Nil)
        False -> Error(mismatch(value, observed))
      }
  }
}

fn same_repository(left: String, right: String) -> Bool {
  case repository_identity(left), repository_identity(right) {
    RepositoryIdentity(Some(left_host), left_path),
      RepositoryIdentity(Some(right_host), right_path)
    -> left_host == right_host && left_path == right_path
    RepositoryIdentity(_, left_path), RepositoryIdentity(_, right_path) ->
      left_path == right_path
  }
}

fn repository_identity(value: String) -> RepositoryIdentity {
  let cleaned =
    value
    |> string.trim
    |> string.lowercase
    |> trim_suffix("/")
    |> trim_suffix(".git")

  let #(host, path) = split_repository_identity(cleaned)

  RepositoryIdentity(
    host: host,
    path: path |> trim_suffix("/") |> trim_suffix(".git"),
  )
}

fn split_repository_identity(value: String) -> #(Option(String), String) {
  case string.split(value, "://") {
    [_, rest] -> split_host_path(rest)
    _ -> {
      case string.starts_with(value, "git@") {
        True -> split_git_host_path(value)
        False -> split_optional_plain_host_path(value)
      }
    }
  }
}

fn split_git_host_path(value: String) -> #(Option(String), String) {
  case value |> string.drop_start(4) |> string.split(":") {
    [host, path] -> #(Some(host), path)
    _ -> #(None, value)
  }
}

fn split_optional_plain_host_path(value: String) -> #(Option(String), String) {
  case string.split(value, "/") {
    [host, owner, name, ..rest] -> {
      case looks_like_host(host) {
        True -> #(Some(host), string.join([owner, name, ..rest], with: "/"))
        False -> #(None, value)
      }
    }
    _ -> #(None, value)
  }
}

fn split_host_path(value: String) -> #(Option(String), String) {
  case string.split(value, "/") {
    [host, owner, name, ..rest] -> #(
      Some(host),
      string.join([owner, name, ..rest], with: "/"),
    )
    _ -> #(None, value)
  }
}

fn looks_like_host(value: String) -> Bool {
  let host =
    value
    |> string.trim
    |> string.lowercase

  host == "localhost"
  || string.contains(host, ".")
  || string.contains(host, ":")
}

fn trim_suffix(value: String, suffix: String) -> String {
  case string.ends_with(value, suffix) {
    True -> string.drop_end(value, string.length(suffix))
    False -> value
  }
}

fn option_value(value: Option(String)) -> String {
  case value {
    Some(inner) -> inner
    None -> "observed-branch"
  }
}
