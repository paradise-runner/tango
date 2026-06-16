import tango/domain/forge
import tango/domain/registry_status

pub fn forge_binding() -> forge.ForgeBinding {
  forge.ForgeBinding(
    forge_name: "github",
    cli_command: "forge",
    forge_skill: "forge",
  )
}

pub fn registry_binding() -> registry_status.RegistryBinding {
  registry_status.RegistryBinding(
    registry_name: "test-registry",
    cli_command: "test-registry",
    registry_skill: "test-registry-skill",
    external_ticket_ref: "TANGO-1",
    pinned_mapping_digest: "sha256:statuses",
  )
}

pub fn registry_status_mapping() -> registry_status.RegistryStatusMapping {
  let backlog = registry_status.ExternalStatus(id: "backlog", name: "Backlog")
  let todo_status = registry_status.ExternalStatus(id: "todo", name: "Todo")
  let active = registry_status.ExternalStatus(id: "active", name: "In Progress")
  let review = registry_status.ExternalStatus(id: "review", name: "Review")
  let blocked = registry_status.ExternalStatus(id: "blocked", name: "Blocked")
  let done = registry_status.ExternalStatus(id: "done", name: "Done")
  let canceled =
    registry_status.ExternalStatus(id: "canceled", name: "Canceled")

  registry_status.RegistryStatusMapping(
    backlog: backlog,
    todo_status: todo_status,
    in_progress: active,
    human_review: review,
    merging: review,
    blocked: blocked,
    done: done,
    wont_do: canceled,
    digest: "sha256:statuses",
  )
}
