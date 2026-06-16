import tango/domain/registry_status.{type ExternalStatus}

pub type DiscoverRequest {
  DiscoverRequest(
    registry_name: String,
    cli_command: String,
    registry_skill: String,
  )
}

pub type RegistryError {
  DiscoverFailed(String)
}

pub type RegistryAdapter {
  RegistryAdapter(
    discover: fn(DiscoverRequest) -> Result(List(ExternalStatus), RegistryError),
  )
}
