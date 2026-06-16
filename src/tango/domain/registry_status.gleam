import gleam/list
import gleam/result
import gleam/string
import tango/domain/lifecycle

pub type RegistryBinding {
  RegistryBinding(
    registry_name: String,
    cli_command: String,
    registry_skill: String,
    external_ticket_ref: String,
    pinned_mapping_digest: String,
  )
}

pub type ExternalStatus {
  ExternalStatus(id: String, name: String)
}

pub type RegistryStatusMapping {
  RegistryStatusMapping(
    backlog: ExternalStatus,
    todo_status: ExternalStatus,
    in_progress: ExternalStatus,
    human_review: ExternalStatus,
    merging: ExternalStatus,
    blocked: ExternalStatus,
    done: ExternalStatus,
    wont_do: ExternalStatus,
    digest: String,
  )
}

pub type RegistryStatusError {
  EmptyRegistryName
  EmptyCliCommand
  EmptyRegistrySkill
  EmptyExternalTicketRef
  EmptyPinnedMappingDigest
  EmptyMappingDigest
  EmptyStatusId(String)
  EmptyStatusName(String)
  MappingDigestMismatch
}

pub fn validate_binding(
  binding: RegistryBinding,
) -> Result(RegistryBinding, RegistryStatusError) {
  case
    string.trim(binding.registry_name),
    string.trim(binding.cli_command),
    string.trim(binding.registry_skill),
    string.trim(binding.external_ticket_ref),
    string.trim(binding.pinned_mapping_digest)
  {
    "", _, _, _, _ -> Error(EmptyRegistryName)
    _, "", _, _, _ -> Error(EmptyCliCommand)
    _, _, "", _, _ -> Error(EmptyRegistrySkill)
    _, _, _, "", _ -> Error(EmptyExternalTicketRef)
    _, _, _, _, "" -> Error(EmptyPinnedMappingDigest)
    _, _, _, _, _ -> Ok(binding)
  }
}

pub fn validate_mapping(
  mapping: RegistryStatusMapping,
) -> Result(RegistryStatusMapping, RegistryStatusError) {
  case string.trim(mapping.digest) {
    "" -> Error(EmptyMappingDigest)
    _ -> {
      use _ <- result.try(
        statuses(mapping)
        |> list.try_each(fn(role_status) {
          let #(role, status) = role_status
          validate_status(role, status)
        }),
      )
      Ok(mapping)
    }
  }
}

pub fn validate_pair(
  binding: RegistryBinding,
  mapping: RegistryStatusMapping,
) -> Result(Nil, RegistryStatusError) {
  use binding <- result.try(validate_binding(binding))
  use mapping <- result.try(validate_mapping(mapping))
  case binding.pinned_mapping_digest == mapping.digest {
    True -> Ok(Nil)
    False -> Error(MappingDigestMismatch)
  }
}

pub fn statuses(
  mapping: RegistryStatusMapping,
) -> List(#(String, ExternalStatus)) {
  [
    #("backlog", mapping.backlog),
    #("todo", mapping.todo_status),
    #("in_progress", mapping.in_progress),
    #("human_review", mapping.human_review),
    #("merging", mapping.merging),
    #("blocked", mapping.blocked),
    #("done", mapping.done),
    #("wont_do", mapping.wont_do),
  ]
}

pub fn resolve(
  mapping: RegistryStatusMapping,
  role: lifecycle.RegistryStatusRole,
) -> ExternalStatus {
  case role {
    lifecycle.Backlog -> mapping.backlog
    lifecycle.Todo -> mapping.todo_status
    lifecycle.InProgress -> mapping.in_progress
    lifecycle.HumanReviewStatus -> mapping.human_review
    lifecycle.MergingStatus -> mapping.merging
    lifecycle.BlockedStatus -> mapping.blocked
    lifecycle.DoneStatus -> mapping.done
    lifecycle.WontDo -> mapping.wont_do
  }
}

fn validate_status(
  role: String,
  status: ExternalStatus,
) -> Result(Nil, RegistryStatusError) {
  case string.trim(status.id), string.trim(status.name) {
    "", _ -> Error(EmptyStatusId(role))
    _, "" -> Error(EmptyStatusName(role))
    _, _ -> Ok(Nil)
  }
}
