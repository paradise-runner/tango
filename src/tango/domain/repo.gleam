import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type RepositoryKind {
  LocalPath
  GitRemote
  ExternalRepo(String)
}

pub type CheckoutPolicy {
  Clone
}

pub type RepoBinding {
  RepoBinding(
    id: String,
    name: String,
    kind: RepositoryKind,
    location: String,
    default_branch: Option(String),
    base_ref: Option(String),
    target_branch: Option(String),
    work_branch: Option(String),
    checkout_policy: CheckoutPolicy,
  )
}

pub type RepoBindingError {
  EmptyBindingId
  EmptyName
  EmptyLocation
  DuplicateBindingId(String)
  DuplicateCheckoutName(String)
}

pub fn validate(binding: RepoBinding) -> Result(RepoBinding, RepoBindingError) {
  case
    string.trim(binding.id),
    string.trim(binding.name),
    string.trim(binding.location)
  {
    "", _, _ -> Error(EmptyBindingId)
    _, "", _ -> Error(EmptyName)
    _, _, "" -> Error(EmptyLocation)
    _, _, _ -> Ok(binding)
  }
}

pub fn validate_all(
  bindings: List(RepoBinding),
) -> Result(List(RepoBinding), RepoBindingError) {
  use _ <- result.try(list.try_map(bindings, validate))
  validate_unique(bindings, [], [])
}

fn validate_unique(
  remaining: List(RepoBinding),
  ids: List(String),
  names: List(String),
) -> Result(List(RepoBinding), RepoBindingError) {
  case remaining {
    [] -> Ok([])
    [binding, ..rest] -> {
      let checkout_name = checkout_name(binding.location)
      case list.contains(ids, binding.id), list.contains(names, checkout_name) {
        True, _ -> Error(DuplicateBindingId(binding.id))
        _, True -> Error(DuplicateCheckoutName(checkout_name))
        False, False -> {
          use validated_rest <- result.try(
            validate_unique(rest, [binding.id, ..ids], [checkout_name, ..names]),
          )
          Ok([binding, ..validated_rest])
        }
      }
    }
  }
}

pub fn checkout_name(location: String) -> String {
  location
  |> trim_suffix("/")
  |> string.split("/")
  |> list.last
  |> result.unwrap(location)
  |> trim_suffix(".git")
}

fn trim_suffix(value: String, suffix: String) -> String {
  case string.ends_with(value, suffix) {
    True -> string.drop_end(value, string.length(suffix))
    False -> value
  }
}
