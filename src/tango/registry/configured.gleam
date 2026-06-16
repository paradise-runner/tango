import gleam/dict
import gleam/list
import gleam/result
import gleam/string
import tango/config
import tango/domain/registry_status
import tango/registry/adapter

pub fn adapter(operator_config: config.Config) -> adapter.RegistryAdapter {
  adapter.RegistryAdapter(discover: fn(request) {
    discover(operator_config, request)
  })
}

fn discover(
  operator_config: config.Config,
  request: adapter.DiscoverRequest,
) -> Result(List(registry_status.ExternalStatus), adapter.RegistryError) {
  use registry <- result.try(
    config.get_registry(operator_config, request.registry_name)
    |> result.map_error(fn(error) {
      adapter.DiscoverFailed(string.inspect(error))
    }),
  )
  case
    registry.cli == request.cli_command,
    registry.skill == request.registry_skill,
    registry.status_map_validated
  {
    True, True, True ->
      registry.statuses
      |> dict.to_list
      |> list.map(fn(entry) {
        registry_status.ExternalStatus(id: entry.1, name: entry.1)
      })
      |> dedupe_statuses
      |> Ok
    True, True, False ->
      Error(adapter.DiscoverFailed(
        "registry status map is not validated for " <> request.registry_name,
      ))
    False, _, _ ->
      Error(adapter.DiscoverFailed(
        "registry CLI mismatch for " <> request.registry_name,
      ))
    _, False, _ ->
      Error(adapter.DiscoverFailed(
        "registry skill mismatch for " <> request.registry_name,
      ))
  }
}

fn dedupe_statuses(
  statuses: List(registry_status.ExternalStatus),
) -> List(registry_status.ExternalStatus) {
  statuses
  |> list.sort(fn(left, right) { string.compare(left.id, right.id) })
  |> list.fold([], fn(acc: List(registry_status.ExternalStatus), status) {
    case
      list.any(acc, fn(existing: registry_status.ExternalStatus) {
        existing.id == status.id
      })
    {
      True -> acc
      False -> list.append(acc, [status])
    }
  })
}
