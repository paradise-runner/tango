import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/domain/repo
import tango/process
import tango/workspace/workspace

pub type ExpectedHead {
  ExpectedHead(binding_id: String, commit_id: String)
}

pub type GitError {
  RepositoryMissing(String)
  DirtyWorktree(String)
  WrongHead(binding_id: String, expected: String, actual: String)
  CommandFailed(binding_id: String, output: String)
}

pub type GitAdapter {
  GitAdapter(
    validate: fn(workspace.Workspace, List(ExpectedHead)) ->
      Result(Nil, GitError),
    changed_repositories: fn(workspace.Workspace, List(repo.RepoBinding)) ->
      Result(List(String), GitError),
  )
}

pub fn adapter(command: String) -> GitAdapter {
  GitAdapter(
    validate: fn(current, expected_heads) {
      validate_workspace(current, expected_heads, command)
    },
    changed_repositories: fn(current, bindings) {
      changed_repositories(current, bindings, command)
    },
  )
}

pub fn passthrough() -> GitAdapter {
  GitAdapter(validate: fn(_, _) { Ok(Nil) }, changed_repositories: fn(_, _) {
    Ok([])
  })
}

fn validate_workspace(
  current: workspace.Workspace,
  expected_heads: List(ExpectedHead),
  command: String,
) -> Result(Nil, GitError) {
  use _ <- result.try(
    current.repos
    |> list.try_each(fn(repo) { validate_clean(repo, command) }),
  )
  expected_heads
  |> list.try_each(fn(expected) {
    use repo <- result.try(find_repo(current.repos, expected.binding_id))
    validate_head(repo, expected, command)
  })
}

fn find_repo(
  repos: List(workspace.WorkspaceRepo),
  binding_id: String,
) -> Result(workspace.WorkspaceRepo, GitError) {
  repos
  |> list.find(fn(repo) { repo.binding_id == binding_id })
  |> result.map_error(fn(_) { RepositoryMissing(binding_id) })
}

fn validate_clean(
  repo: workspace.WorkspaceRepo,
  command: String,
) -> Result(Nil, GitError) {
  use command_result <- result.try(
    process.run_command(command, ["status", "--porcelain"], [], Some(repo.path))
    |> result.map_error(fn(output) { CommandFailed(repo.binding_id, output) }),
  )
  case command_result.exit_code, string.trim(command_result.output) {
    0, "" -> Ok(Nil)
    0, _ -> Error(DirtyWorktree(repo.binding_id))
    _, _ -> Error(CommandFailed(repo.binding_id, command_result.output))
  }
}

fn validate_head(
  repo: workspace.WorkspaceRepo,
  expected: ExpectedHead,
  command: String,
) -> Result(Nil, GitError) {
  use command_result <- result.try(
    process.run_command(command, ["rev-parse", "HEAD"], [], Some(repo.path))
    |> result.map_error(fn(output) { CommandFailed(repo.binding_id, output) }),
  )
  let actual = string.trim(command_result.output)
  case command_result.exit_code, actual == expected.commit_id {
    0, True -> Ok(Nil)
    0, False ->
      Error(WrongHead(expected.binding_id, expected.commit_id, actual))
    _, _ -> Error(CommandFailed(repo.binding_id, command_result.output))
  }
}

fn changed_repositories(
  current: workspace.Workspace,
  bindings: List(repo.RepoBinding),
  command: String,
) -> Result(List(String), GitError) {
  bindings
  |> list.try_fold([], fn(acc, binding) {
    use changed <- result.try(repository_changed(current, binding, command))
    case changed {
      True -> Ok([binding.id, ..acc])
      False -> Ok(acc)
    }
  })
}

fn repository_changed(
  current: workspace.Workspace,
  binding: repo.RepoBinding,
  command: String,
) -> Result(Bool, GitError) {
  case comparison_ref(binding) {
    Some(ref) -> {
      use repo_info <- result.try(find_repo(current.repos, binding.id))
      use command_result <- result.try(
        process.run_command(
          command,
          ["rev-list", "--count", ref <> "..HEAD"],
          [],
          Some(repo_info.path),
        )
        |> result.map_error(fn(output) { CommandFailed(binding.id, output) }),
      )
      case command_result.exit_code, string.trim(command_result.output) {
        0, "0" -> Ok(False)
        0, _ -> Ok(True)
        _, _ -> Error(CommandFailed(binding.id, command_result.output))
      }
    }
    _ -> Ok(False)
  }
}

fn comparison_ref(binding: repo.RepoBinding) -> Option(String) {
  case binding.base_ref, binding.target_branch, binding.default_branch {
    Some(value), _, _ -> Some(value)
    _, Some(value), _ -> Some(value)
    _, _, Some(value) -> Some(value)
    _, _, _ -> None
  }
}
