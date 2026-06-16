import gleam/option.{type Option, None, Some}
import gleam/string

pub type ForgeBinding {
  ForgeBinding(forge_name: String, cli_command: String, forge_skill: String)
}

pub type ForgeError {
  EmptyForgeName
  EmptyCliCommand
  EmptyForgeSkill
}

pub type RemoteCompatibilityError {
  IncompatibleRemote(forge_name: String, location: String)
}

pub fn validate(binding: ForgeBinding) -> Result(ForgeBinding, ForgeError) {
  case
    string.trim(binding.forge_name),
    string.trim(binding.cli_command),
    string.trim(binding.forge_skill)
  {
    "", _, _ -> Error(EmptyForgeName)
    _, "", _ -> Error(EmptyCliCommand)
    _, _, "" -> Error(EmptyForgeSkill)
    _, _, _ -> Ok(binding)
  }
}

pub fn validate_remote(
  forge_name: String,
  location: String,
) -> Result(Nil, RemoteCompatibilityError) {
  let normalized = location |> string.trim |> string.lowercase
  case explicit_remote_host(normalized), forge_name {
    None, "github" -> Ok(Nil)
    None, _ -> Error(IncompatibleRemote(forge_name, location))
    Some("github.com"), "github" -> Ok(Nil)
    Some("github.com"), "forgejo" ->
      Error(IncompatibleRemote(forge_name, location))
    Some(_), "github" -> Error(IncompatibleRemote(forge_name, location))
    Some(_), "forgejo" -> Ok(Nil)
    Some(_), _ -> Error(IncompatibleRemote(forge_name, location))
  }
}

fn explicit_remote_host(location: String) -> Option(String) {
  case
    string.starts_with(location, "/"),
    string.starts_with(location, "./"),
    string.starts_with(location, "../"),
    string.contains(location, "://"),
    string.contains(location, "@")
  {
    True, _, _, _, _ | _, True, _, _, _ | _, _, True, _, _ -> None
    _, _, _, True, _ ->
      location
      |> string.split("://")
      |> drop_first
      |> first_segment
      |> strip_user
    _, _, _, _, True ->
      location
      |> string.split("@")
      |> drop_first
      |> first_colon_segment
    _, _, _, _, _ -> None
  }
}

fn drop_first(parts: List(String)) -> List(String) {
  case parts {
    [_, ..rest] -> rest
    _ -> []
  }
}

fn first_segment(parts: List(String)) -> Option(String) {
  case parts {
    [value, ..] ->
      value
      |> string.split("/")
      |> first
    _ -> None
  }
}

fn first_colon_segment(parts: List(String)) -> Option(String) {
  case parts {
    [value, ..] ->
      value
      |> string.split(":")
      |> first
    _ -> None
  }
}

fn strip_user(host: Option(String)) -> Option(String) {
  case host {
    Some(value) ->
      value
      |> string.split("@")
      |> last
      |> strip_port
    None -> None
  }
}

fn strip_port(host: Option(String)) -> Option(String) {
  case host {
    Some(value) ->
      value
      |> string.split(":")
      |> first
    None -> None
  }
}

fn first(values: List(String)) -> Option(String) {
  case values {
    [value, ..] -> Some(value)
    [] -> None
  }
}

fn last(values: List(String)) -> Option(String) {
  case values {
    [] -> None
    [value] -> Some(value)
    [_, ..rest] -> last(rest)
  }
}
