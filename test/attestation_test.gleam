import fixtures
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import tango/attestation/adapter
import tango/attestation/configured
import tango/domain/forge
import tango/domain/registry_status
import tango/domain/repo
import tango/process
import tango/runtime

fn repository() -> repo.RepoBinding {
  repo.RepoBinding(
    id: "repo-1",
    name: "tango",
    kind: repo.GitRemote,
    location: "https://github.com/example/tango.git",
    default_branch: Some("main"),
    base_ref: None,
    target_branch: Some("main"),
    work_branch: Some("tango/ticket-1"),
    checkout_policy: repo.Clone,
  )
}

fn ticket_request() -> adapter.TicketRequest {
  adapter.TicketRequest(
    binding: fixtures.registry_binding(),
    expected_status: fixtures.registry_status_mapping().human_review,
    repository_path: Some("/tmp/workspace/tango"),
    require_comment: True,
  )
}

fn pull_request_request(require_merged: Bool) -> adapter.PullRequestRequest {
  adapter.PullRequestRequest(
    binding: fixtures.forge_binding(),
    repository: repository(),
    pull_request_ref: "https://github.com/example/tango/pull/1",
    expected_source_branch: Some("tango/ticket-1"),
    expected_target_branch: Some("main"),
    expected_head_commit_id: "abc123",
    require_merged: require_merged,
    repository_path: Some("/tmp/workspace/tango"),
  )
}

pub fn ticket_attestation_requires_status_description_and_comment_test() {
  let ticket_adapter =
    adapter.TicketAdapter(read: fn(request) {
      Ok(
        adapter.TicketSnapshot(
          external_ref: request.binding.external_ticket_ref,
          description_revision: "sha256:body",
          comments: [],
          status_ids: [request.expected_status.id],
        ),
      )
    })

  adapter.attest_ticket(ticket_adapter, ticket_request())
  |> should.equal(Error(adapter.TicketCommentsMissing("TANGO-1")))
}

pub fn pull_request_attestation_rejects_unmerged_or_wrong_head_test() {
  let forge_adapter =
    adapter.ForgeAdapter(
      read: fn(request) {
        Ok(adapter.PullRequestSnapshot(
          pull_request_ref: request.pull_request_ref,
          repository_location: request.repository.location,
          source_branch: "tango/ticket-1",
          target_branch: "main",
          head_commit_id: "changed",
          state: adapter.Open,
        ))
      },
      read_comments: fn(request) {
        Ok(adapter.PullRequestCommentsSnapshot(
          pull_request_ref: request.pull_request_ref,
          comments: [],
          final_comment_count: 0,
        ))
      },
    )

  adapter.attest_pull_request(forge_adapter, pull_request_request(True))
  |> should.equal(
    Error(adapter.PullRequestHeadMismatch(
      expected: "abc123",
      observed: "changed",
    )),
  )
}

pub fn pull_request_attestation_accepts_github_owner_repo_shorthand_test() {
  let request =
    adapter.PullRequestRequest(
      ..pull_request_request(False),
      repository: repo.RepoBinding(
        ..repository(),
        location: "paradise-runner/tango",
      ),
      pull_request_ref: "https://github.com/paradise-runner/tango/pull/7",
      expected_source_branch: Some("ticket-1781639616139261084-1-126883838"),
      expected_head_commit_id: "a7a487b7a064ba61a183a0db7cb6f991d203f659",
    )
  let forge_adapter =
    adapter.ForgeAdapter(
      read: fn(request) {
        Ok(adapter.PullRequestSnapshot(
          pull_request_ref: request.pull_request_ref,
          repository_location: "https://github.com/paradise-runner/tango",
          source_branch: "ticket-1781639616139261084-1-126883838",
          target_branch: "main",
          head_commit_id: "a7a487b7a064ba61a183a0db7cb6f991d203f659",
          state: adapter.Open,
        ))
      },
      read_comments: fn(request) {
        Ok(adapter.PullRequestCommentsSnapshot(
          pull_request_ref: request.pull_request_ref,
          comments: [],
          final_comment_count: 0,
        ))
      },
    )

  adapter.attest_pull_request(forge_adapter, request)
  |> should.be_ok()
}

pub fn github_configured_adapter_parses_structured_read_responses_test() {
  let adapters =
    configured.with_runner(fn(command, args, cwd) {
      command
      |> should.equal("forge")
      cwd
      |> should.equal(None)
      case args {
        ["issue", "view", "TANGO-1", ..] ->
          Ok(process.CommandResult(
            exit_code: 0,
            output: "{\"body\":\"description\",\"comments\":[{\"body\":\"handoff\"}],\"labels\":[{\"name\":\"review\"}],\"state\":\"OPEN\",\"url\":\"https://github.com/example/tango/issues/1\"}",
          ))
        _ -> panic as "unexpected GitHub attestation command"
      }
    })

  let request =
    adapter.TicketRequest(
      ..ticket_request(),
      binding: registry_status.RegistryBinding(
        ..fixtures.registry_binding(),
        registry_name: "github",
        cli_command: "forge",
      ),
    )
  adapter.attest_ticket(adapters.ticket_system, request)
  |> should.be_ok()
}

pub fn github_done_attestation_uses_closed_issue_state_not_label_test() {
  let request =
    adapter.TicketRequest(
      ..ticket_request(),
      binding: registry_status.RegistryBinding(
        ..fixtures.registry_binding(),
        registry_name: "github",
        cli_command: "gh",
      ),
      expected_status: registry_status.ExternalStatus(
        id: "closed",
        name: "Closed issue state",
      ),
      require_comment: False,
    )
  let open_issue_with_closed_label =
    configured.with_runner(fn(_, args, cwd) {
      cwd
      |> should.equal(None)
      case args {
        ["issue", "view", "TANGO-1", ..] ->
          Ok(process.CommandResult(
            exit_code: 0,
            output: "{\"body\":\"description\",\"comments\":[],\"labels\":[{\"name\":\"closed\"}],\"state\":\"OPEN\",\"url\":\"https://github.com/example/tango/issues/1\"}",
          ))
        _ -> panic as "unexpected GitHub attestation command"
      }
    })

  adapter.attest_ticket(open_issue_with_closed_label.ticket_system, request)
  |> should.equal(
    Error(adapter.TicketStatusMismatch(expected: "closed", observed: [])),
  )
}

pub fn github_done_attestation_accepts_closed_issue_without_done_label_test() {
  let request =
    adapter.TicketRequest(
      ..ticket_request(),
      binding: registry_status.RegistryBinding(
        ..fixtures.registry_binding(),
        registry_name: "github",
        cli_command: "gh",
      ),
      expected_status: registry_status.ExternalStatus(
        id: "closed",
        name: "Closed issue state",
      ),
      require_comment: False,
    )
  let closed_issue =
    configured.with_runner(fn(_, args, cwd) {
      cwd
      |> should.equal(None)
      case args {
        ["issue", "view", "TANGO-1", ..] ->
          Ok(process.CommandResult(
            exit_code: 0,
            output: "{\"body\":\"description\",\"comments\":[],\"labels\":[],\"state\":\"CLOSED\",\"url\":\"https://github.com/example/tango/issues/1\"}",
          ))
        _ -> panic as "unexpected GitHub attestation command"
      }
    })

  adapter.attest_ticket(closed_issue.ticket_system, request)
  |> should.be_ok()
}

pub fn github_comment_reader_uses_comments_only_json_field_test() {
  let adapters =
    configured.with_runner(fn(_, args, cwd) {
      cwd
      |> should.equal(None)
      args
      |> should.equal([
        "pr",
        "view",
        "https://github.com/example/tango/pull/1",
        "--json",
        "comments",
      ])
      Ok(process.CommandResult(
        exit_code: 0,
        output: "{\"comments\":[{\"body\":\"please update tests\"},{\"body\":\"thanks\"}]}",
      ))
    })

  adapters.forge.read_comments(adapter.PullRequestCommentsRequest(
    binding: fixtures.forge_binding(),
    repository: repository(),
    pull_request_ref: "https://github.com/example/tango/pull/1",
    repository_path: None,
  ))
  |> should.equal(
    Ok(adapter.PullRequestCommentsSnapshot(
      pull_request_ref: "https://github.com/example/tango/pull/1",
      comments: ["please update tests", "thanks"],
      final_comment_count: 2,
    )),
  )
}

pub fn forgejo_configured_adapter_uses_repository_worktree_test() {
  let request =
    adapter.PullRequestRequest(
      ..pull_request_request(True),
      pull_request_ref: "1",
    )
  let adapters =
    configured.with_runner(fn(_, args, cwd) {
      cwd
      |> should.equal(Some("/tmp/workspace/tango"))
      case args {
        ["--style", "minimal", "pr", "view", "1"] ->
          Ok(process.CommandResult(
            exit_code: 0,
            output: "tango/ticket-1 -> main\nmerged\n",
          ))
        ["--style", "minimal", "pr", "view", "1", "commits"] ->
          Ok(process.CommandResult(exit_code: 0, output: "abc123\n"))
        _ -> panic as "unexpected Forgejo attestation command"
      }
    })
  let forgejo_binding =
    fixtures.forge_binding()
    |> fn(binding) {
      forge.ForgeBinding(..binding, forge_name: "forgejo", cli_command: "fj")
    }

  adapter.attest_pull_request(
    adapters.forge,
    adapter.PullRequestRequest(..request, binding: forgejo_binding),
  )
  |> should.be_ok()
}

pub fn forgejo_comment_reader_uses_pr_comments_subcommand_test() {
  let adapters =
    configured.with_runner(fn(_, args, cwd) {
      cwd
      |> should.equal(Some("/tmp/workspace/tango"))
      args
      |> should.equal([
        "--style",
        "minimal",
        "pr",
        "view",
        "1",
        "comments",
      ])
      Ok(process.CommandResult(
        exit_code: 0,
        output: "please update tests\n\nthanks\n",
      ))
    })

  adapters.forge.read_comments(adapter.PullRequestCommentsRequest(
    binding: forge.ForgeBinding(
      forge_name: "forgejo",
      cli_command: "fj",
      forge_skill: "forgejo-forge",
    ),
    repository: repository(),
    pull_request_ref: "1",
    repository_path: Some("/tmp/workspace/tango"),
  ))
  |> should.equal(
    Ok(adapter.PullRequestCommentsSnapshot(
      pull_request_ref: "1",
      comments: ["please update tests", "thanks"],
      final_comment_count: 2,
    )),
  )
}

pub fn forgejo_ticket_status_attestation_uses_label_filtered_search_test() {
  let request =
    adapter.TicketRequest(
      ..ticket_request(),
      binding: registry_status.RegistryBinding(
        ..fixtures.registry_binding(),
        registry_name: "forgejo",
        cli_command: "fj",
        external_ticket_ref: "42",
      ),
    )
  let adapters =
    configured.with_runner(fn(_, args, cwd) {
      cwd
      |> should.equal(Some("/tmp/workspace/tango"))
      case args {
        ["--style", "minimal", "issue", "view", "42"] ->
          Ok(process.CommandResult(exit_code: 0, output: "Issue 42\nBody\n"))
        ["--style", "minimal", "issue", "view", "42", "comments"] ->
          Ok(process.CommandResult(exit_code: 0, output: "handoff\n"))
        [
          "--style",
          "minimal",
          "issue",
          "search",
          "--labels",
          "review",
          "--state",
          "all",
        ] -> Ok(process.CommandResult(exit_code: 0, output: "42 Issue title\n"))
        _ -> panic as "unexpected Forgejo ticket attestation command"
      }
    })

  adapter.attest_ticket(adapters.ticket_system, request)
  |> should.be_ok()
}

pub fn unknown_providers_are_not_attestation_capable_test() {
  configured.supports_ticket_system("linear")
  |> should.be_false()
  configured.supports_forge("gitlab")
  |> should.be_false()
}

pub fn github_live_attestation_is_opt_in_test() {
  case
    runtime.get_env("TANGO_GITHUB_ATTESTATION_TICKET_REF"),
    runtime.get_env("TANGO_GITHUB_ATTESTATION_STATUS")
  {
    Some(external_ref), Some(status) -> {
      let binding =
        registry_status.RegistryBinding(
          ..fixtures.registry_binding(),
          registry_name: "github",
          cli_command: "gh",
          external_ticket_ref: external_ref,
        )
      configured.adapters().ticket_system.read(adapter.TicketRequest(
        binding: binding,
        expected_status: registry_status.ExternalStatus(
          id: status,
          name: status,
        ),
        repository_path: None,
        require_comment: False,
      ))
      |> result.map(fn(_) { Nil })
      |> should.equal(Ok(Nil))
    }
    _, _ -> Nil
  }
}

pub fn forgejo_live_attestation_is_opt_in_test() {
  case
    runtime.get_env("TANGO_FORGEJO_ATTESTATION_PR"),
    runtime.get_env("TANGO_FORGEJO_ATTESTATION_REPO_PATH"),
    runtime.get_env("TANGO_FORGEJO_ATTESTATION_HEAD"),
    runtime.get_env("TANGO_FORGEJO_ATTESTATION_SOURCE"),
    runtime.get_env("TANGO_FORGEJO_ATTESTATION_TARGET")
  {
    Some(reference), Some(path), Some(head), Some(source), Some(target) -> {
      let request =
        adapter.PullRequestRequest(
          ..pull_request_request(False),
          binding: forge.ForgeBinding(
            forge_name: "forgejo",
            cli_command: "fj",
            forge_skill: "forgejo-forge",
          ),
          pull_request_ref: reference,
          expected_source_branch: Some(source),
          expected_target_branch: Some(target),
          expected_head_commit_id: head,
          repository_path: Some(path),
        )
      configured.adapters().forge.read(request)
      |> result.map(fn(_) { Nil })
      |> should.equal(Ok(Nil))
    }
    _, _, _, _, _ -> Nil
  }
}
