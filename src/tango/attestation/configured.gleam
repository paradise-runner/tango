import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/attestation/adapter
import tango/process
import tango/runtime

pub type CommandRunner =
  fn(String, List(String), Option(String)) ->
    Result(process.CommandResult, String)

type GithubTicket {
  GithubTicket(body: String, comments: List(String), status_ids: List(String))
}

type GithubPullRequest {
  GithubPullRequest(
    url: String,
    source_branch: String,
    target_branch: String,
    head_commit_id: String,
    state: adapter.PullRequestState,
  )
}

type Provider {
  Github
  Forgejo
}

pub fn adapters() -> adapter.Adapters {
  with_runner(fn(command, args, cwd) {
    process.run_command(command, args, [], cwd)
  })
}

pub fn supports_ticket_system(name: String) -> Bool {
  provider(name) != None
}

pub fn supports_forge(name: String) -> Bool {
  provider(name) != None
}

pub fn with_runner(run: CommandRunner) -> adapter.Adapters {
  adapter.Adapters(
    ticket_system: adapter.TicketAdapter(read: fn(request) {
      read_ticket(run, request)
    }),
    forge: adapter.ForgeAdapter(
      read: fn(request) { read_pull_request(run, request) },
      read_comments: fn(request) { read_pull_request_comments(run, request) },
    ),
  )
}

fn read_ticket(
  run: CommandRunner,
  request: adapter.TicketRequest,
) -> Result(adapter.TicketSnapshot, adapter.AttestationError) {
  case provider(request.binding.registry_name) {
    Some(Github) -> read_github_ticket(run, request)
    Some(Forgejo) -> read_forgejo_ticket(run, request)
    None ->
      Error(adapter.ReadFailed(
        "unsupported ticket-system adapter: " <> request.binding.registry_name,
      ))
  }
}

fn read_pull_request(
  run: CommandRunner,
  request: adapter.PullRequestRequest,
) -> Result(adapter.PullRequestSnapshot, adapter.AttestationError) {
  case provider(request.binding.forge_name) {
    Some(Github) -> read_github_pull_request(run, request)
    Some(Forgejo) -> read_forgejo_pull_request(run, request)
    None ->
      Error(adapter.ReadFailed(
        "unsupported forge adapter: " <> request.binding.forge_name,
      ))
  }
}

fn read_pull_request_comments(
  run: CommandRunner,
  request: adapter.PullRequestCommentsRequest,
) -> Result(adapter.PullRequestCommentsSnapshot, adapter.AttestationError) {
  case provider(request.binding.forge_name) {
    Some(Github) -> read_github_pull_request_comments(run, request)
    Some(Forgejo) -> read_forgejo_pull_request_comments(run, request)
    None ->
      Error(adapter.ReadFailed(
        "unsupported forge adapter: " <> request.binding.forge_name,
      ))
  }
}

fn read_github_ticket(
  run: CommandRunner,
  request: adapter.TicketRequest,
) -> Result(adapter.TicketSnapshot, adapter.AttestationError) {
  use response <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "issue",
      "view",
      request.binding.external_ticket_ref,
      "--json",
      "body,comments,labels,state,url",
    ],
    None,
  ))
  use observed <- result.try(
    json.parse(response.output, github_ticket_decoder())
    |> result.map_error(fn(error) {
      adapter.ReadFailed(
        "invalid GitHub issue response: " <> string.inspect(error),
      )
    }),
  )
  Ok(adapter.TicketSnapshot(
    external_ref: request.binding.external_ticket_ref,
    description_revision: runtime.sha256(observed.body),
    comments: observed.comments,
    status_ids: observed.status_ids,
  ))
}

fn read_github_pull_request(
  run: CommandRunner,
  request: adapter.PullRequestRequest,
) -> Result(adapter.PullRequestSnapshot, adapter.AttestationError) {
  use response <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "pr",
      "view",
      request.pull_request_ref,
      "--json",
      "baseRefName,headRefName,headRefOid,state,mergedAt,url",
    ],
    None,
  ))
  use observed <- result.try(
    json.parse(response.output, github_pull_request_decoder())
    |> result.map_error(fn(error) {
      adapter.ReadFailed(
        "invalid GitHub pull-request response: " <> string.inspect(error),
      )
    }),
  )
  Ok(adapter.PullRequestSnapshot(
    pull_request_ref: request.pull_request_ref,
    repository_location: repository_from_pull_request_url(observed.url),
    source_branch: observed.source_branch,
    target_branch: observed.target_branch,
    head_commit_id: observed.head_commit_id,
    state: observed.state,
  ))
}

fn read_github_pull_request_comments(
  run: CommandRunner,
  request: adapter.PullRequestCommentsRequest,
) -> Result(adapter.PullRequestCommentsSnapshot, adapter.AttestationError) {
  use response <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "pr",
      "view",
      request.pull_request_ref,
      "--json",
      "comments",
    ],
    None,
  ))
  use comments <- result.try(
    json.parse(response.output, github_comments_decoder())
    |> result.map_error(fn(error) {
      adapter.ReadFailed(
        "invalid GitHub pull-request comments response: "
        <> string.inspect(error),
      )
    }),
  )
  Ok(adapter.PullRequestCommentsSnapshot(
    pull_request_ref: request.pull_request_ref,
    comments: comments,
    final_comment_count: list.length(comments),
  ))
}

fn read_forgejo_ticket(
  run: CommandRunner,
  request: adapter.TicketRequest,
) -> Result(adapter.TicketSnapshot, adapter.AttestationError) {
  use issue <- result.try(run_success(
    run,
    request.binding.cli_command,
    ["--style", "minimal", "issue", "view", request.binding.external_ticket_ref],
    request.repository_path,
  ))
  use comments <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "--style",
      "minimal",
      "issue",
      "view",
      request.binding.external_ticket_ref,
      "comments",
    ],
    request.repository_path,
  ))
  let expected = request.expected_status.id
  use status <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "--style",
      "minimal",
      "issue",
      "search",
      "--labels",
      expected,
      "--state",
      "all",
    ],
    request.repository_path,
  ))
  let status_ids = case
    contains_case_insensitive(
      status.output,
      request.binding.external_ticket_ref,
    )
  {
    True -> [expected]
    False -> []
  }
  Ok(adapter.TicketSnapshot(
    external_ref: request.binding.external_ticket_ref,
    description_revision: runtime.sha256(issue.output),
    comments: non_empty_lines(comments.output),
    status_ids: status_ids,
  ))
}

fn read_forgejo_pull_request(
  run: CommandRunner,
  request: adapter.PullRequestRequest,
) -> Result(adapter.PullRequestSnapshot, adapter.AttestationError) {
  use details <- result.try(run_success(
    run,
    request.binding.cli_command,
    ["--style", "minimal", "pr", "view", request.pull_request_ref],
    request.repository_path,
  ))
  use commits <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "--style",
      "minimal",
      "pr",
      "view",
      request.pull_request_ref,
      "commits",
    ],
    request.repository_path,
  ))
  use source <- result.try(expected_branch_in_output(
    request.expected_source_branch,
    details.output,
    "source",
  ))
  use target <- result.try(expected_branch_in_output(
    request.expected_target_branch,
    details.output,
    "target",
  ))
  use _ <- result.try(
    case string.contains(commits.output, request.expected_head_commit_id) {
      True -> Ok(Nil)
      False ->
        Error(adapter.ReadFailed(
          "Forgejo pull-request commits did not contain expected head",
        ))
    },
  )
  let state = case
    contains_case_insensitive(details.output, "merged"),
    contains_case_insensitive(details.output, "closed")
  {
    True, _ -> adapter.Merged
    _, True -> adapter.Closed
    _, _ -> adapter.Open
  }
  Ok(adapter.PullRequestSnapshot(
    pull_request_ref: request.pull_request_ref,
    repository_location: request.repository.location,
    source_branch: source,
    target_branch: target,
    head_commit_id: request.expected_head_commit_id,
    state: state,
  ))
}

fn read_forgejo_pull_request_comments(
  run: CommandRunner,
  request: adapter.PullRequestCommentsRequest,
) -> Result(adapter.PullRequestCommentsSnapshot, adapter.AttestationError) {
  use response <- result.try(run_success(
    run,
    request.binding.cli_command,
    [
      "--style",
      "minimal",
      "pr",
      "view",
      request.pull_request_ref,
      "comments",
    ],
    request.repository_path,
  ))
  let comments = non_empty_lines(response.output)
  Ok(adapter.PullRequestCommentsSnapshot(
    pull_request_ref: request.pull_request_ref,
    comments: comments,
    final_comment_count: list.length(comments),
  ))
}

fn run_success(
  run: CommandRunner,
  command: String,
  args: List(String),
  cwd: Option(String),
) -> Result(process.CommandResult, adapter.AttestationError) {
  use response <- result.try(
    run(command, args, cwd) |> result.map_error(adapter.ReadFailed),
  )
  case response.exit_code {
    0 -> Ok(response)
    _ -> Error(adapter.ReadFailed(response.output))
  }
}

fn github_ticket_decoder() -> decode.Decoder(GithubTicket) {
  use body <- decode.field("body", decode.string)
  use comments <- decode.field(
    "comments",
    decode.list(of: github_comment_decoder()),
  )
  use labels <- decode.field("labels", decode.list(of: github_label_decoder()))
  use state <- decode.field("state", decode.string)
  decode.success(
    GithubTicket(body: body, comments: comments, status_ids: [
      string.lowercase(state),
      ..labels
    ]),
  )
}

fn github_comment_decoder() -> decode.Decoder(String) {
  use body <- decode.field("body", decode.string)
  decode.success(body)
}

fn github_comments_decoder() -> decode.Decoder(List(String)) {
  use comments <- decode.field(
    "comments",
    decode.list(of: github_comment_decoder()),
  )
  decode.success(comments)
}

fn github_label_decoder() -> decode.Decoder(String) {
  use name <- decode.field("name", decode.string)
  decode.success(name)
}

fn github_pull_request_decoder() -> decode.Decoder(GithubPullRequest) {
  use url <- decode.field("url", decode.string)
  use source <- decode.field("headRefName", decode.string)
  use target <- decode.field("baseRefName", decode.string)
  use head <- decode.field("headRefOid", decode.string)
  use state <- decode.field("state", decode.string)
  use merged_at <- decode.field("mergedAt", decode.optional(decode.string))
  let normalized_state = case merged_at, string.lowercase(state) {
    Some(_), _ | _, "merged" -> adapter.Merged
    _, "closed" -> adapter.Closed
    _, _ -> adapter.Open
  }
  decode.success(GithubPullRequest(
    url: url,
    source_branch: source,
    target_branch: target,
    head_commit_id: head,
    state: normalized_state,
  ))
}

fn expected_branch_in_output(
  expected: Option(String),
  output: String,
  label: String,
) -> Result(String, adapter.AttestationError) {
  case expected {
    Some(branch) ->
      case string.contains(output, branch) {
        True -> Ok(branch)
        False ->
          Error(adapter.ReadFailed(
            "Forgejo pull-request output did not contain expected "
            <> label
            <> " branch",
          ))
      }
    None -> observed_branch(output, label)
  }
}

fn observed_branch(
  output: String,
  label: String,
) -> Result(String, adapter.AttestationError) {
  let lines = non_empty_lines(output)
  let arrow_value = case lines, label {
    [first, ..], "source" ->
      first
      |> string.split(" -> ")
      |> list.first
    [first, ..], "target" ->
      first
      |> string.split(" -> ")
      |> list.last
    _, _ -> Error(Nil)
  }
  case arrow_value {
    Ok(value) -> non_empty_branch(value, label)
    Error(_) -> {
      use line <- result.try(
        lines
        |> list.find(fn(line) {
          let normalized = string.lowercase(line)
          string.contains(normalized, label)
          || label == "source"
          && string.contains(normalized, "head")
        })
        |> result.map_error(fn(_) {
          adapter.ReadFailed(
            "Forgejo pull-request output did not expose " <> label <> " branch",
          )
        }),
      )
      use value <- result.try(
        line
        |> string.split(":")
        |> list.last
        |> result.map_error(fn(_) {
          adapter.ReadFailed(
            "Forgejo pull-request output did not expose " <> label <> " branch",
          )
        }),
      )
      non_empty_branch(value, label)
    }
  }
}

fn non_empty_branch(
  value: String,
  label: String,
) -> Result(String, adapter.AttestationError) {
  case string.trim(value) {
    "" ->
      Error(adapter.ReadFailed(
        "Forgejo pull-request output exposed an empty " <> label <> " branch",
      ))
    branch -> Ok(branch)
  }
}

fn provider(name: String) -> Option(Provider) {
  case name {
    "github" -> Some(Github)
    "forgejo" -> Some(Forgejo)
    _ -> None
  }
}

fn repository_from_pull_request_url(value: String) -> String {
  value
  |> split_before("/pull/")
  |> split_before("/pulls/")
}

fn split_before(value: String, separator: String) -> String {
  case string.split(value, separator) {
    [prefix, ..] -> prefix
    _ -> value
  }
}

fn non_empty_lines(value: String) -> List(String) {
  value
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(fn(line) { line != "" })
}

fn contains_case_insensitive(value: String, expected: String) -> Bool {
  string.contains(string.lowercase(value), string.lowercase(expected))
}
