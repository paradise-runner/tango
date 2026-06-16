import gleam/dict
import gleam/option.{None, Some}
import gleeunit/should
import tango/app/onboarding
import tango/config
import tango/domain/registry_status
import tango/registry/adapter as registry_adapter
import tango/store/memory_store

pub fn create_ticket_uses_discovered_status_names_test() {
  let backend = memory_store.store()
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["github-registry", "forge"],
            execution_tools: ["gh", "forge"],
            merge_tools: ["forge"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "forge", skill: "forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-registry",
            statuses: dict.from_list([
              #("backlog", "status-backlog"),
              #("todo", "status-todo"),
              #("in_progress", "status-active"),
              #("human_review", "status-review"),
              #("merging", "status-review"),
              #("blocked", "status-blocked"),
              #("done", "status-done"),
              #("wont_do", "status-canceled"),
            ]),
            status_map_validated: True,
          ),
        ),
      ]),
    )
  let registry =
    registry_adapter.RegistryAdapter(discover: fn(_) {
      Ok([
        registry_status.ExternalStatus(id: "status-backlog", name: "Backlog"),
        registry_status.ExternalStatus(id: "status-todo", name: "Todo"),
        registry_status.ExternalStatus(id: "status-active", name: "In Progress"),
        registry_status.ExternalStatus(id: "status-review", name: "In Review"),
        registry_status.ExternalStatus(id: "status-blocked", name: "Blocked"),
        registry_status.ExternalStatus(id: "status-done", name: "Done"),
        registry_status.ExternalStatus(id: "status-canceled", name: "Canceled"),
      ])
    })

  let assert Ok(#(_, item)) =
    onboarding.create_ticket(
      backend,
      memory_store.new(),
      registry,
      operator_config,
      onboarding.CreateTicketInput(
        repositories: ["https://github.com/example/tango.git"],
        external_ref: "TANGO-42",
        registry_name: "github",
        forge_name: "github",
        capability_profile_name: "default",
        labels: [],
        priority: None,
        lifecycle_policy: None,
      ),
      "2026-06-12T12:00:00Z",
      fn(prefix) { prefix <> "-1" },
      fn(value) { value },
    )

  let assert Some(mapping) = item.registry_status_mapping
  mapping.todo_status.name
  |> should.equal("Todo")
  mapping.human_review.name
  |> should.equal("In Review")
}

pub fn create_ticket_requires_registry_capability_support_test() {
  let backend = memory_store.store()
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["forge"],
            execution_tools: ["forge"],
            merge_tools: ["forge"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "forge", skill: "forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-registry",
            statuses: dict.from_list([
              #("backlog", "status-backlog"),
              #("todo", "status-todo"),
              #("in_progress", "status-active"),
              #("human_review", "status-review"),
              #("merging", "status-review"),
              #("blocked", "status-blocked"),
              #("done", "status-done"),
              #("wont_do", "status-canceled"),
            ]),
            status_map_validated: True,
          ),
        ),
      ]),
    )
  let registry = registry_adapter.RegistryAdapter(discover: fn(_) { Ok([]) })

  onboarding.create_ticket(
    backend,
    memory_store.new(),
    registry,
    operator_config,
    onboarding.CreateTicketInput(
      repositories: ["https://example.test/tango.git"],
      external_ref: "TANGO-42",
      registry_name: "github",
      forge_name: "github",
      capability_profile_name: "default",
      labels: [],
      priority: None,
      lifecycle_policy: None,
    ),
    "2026-06-12T12:00:00Z",
    fn(prefix) { prefix <> "-1" },
    fn(value) { value },
  )
  |> should.equal(Error(onboarding.MissingRegistrySkill("github-registry")))
}

pub fn create_ticket_requires_validated_status_map_test() {
  let backend = memory_store.store()
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["github-registry", "github-forge"],
            execution_tools: ["gh"],
            merge_tools: ["gh"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "gh", skill: "github-forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-registry",
            statuses: dict.from_list([
              #("backlog", "status-backlog"),
              #("todo", "status-todo"),
              #("in_progress", "status-active"),
              #("human_review", "status-review"),
              #("merging", "status-review"),
              #("blocked", "status-blocked"),
              #("done", "status-done"),
              #("wont_do", "status-canceled"),
            ]),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  onboarding.create_ticket(
    backend,
    memory_store.new(),
    registry_adapter.RegistryAdapter(discover: fn(_) {
      panic as "unvalidated status maps must fail before registry discovery"
    }),
    operator_config,
    onboarding.CreateTicketInput(
      repositories: ["https://github.com/example/tango.git"],
      external_ref: "TANGO-42",
      registry_name: "github",
      forge_name: "github",
      capability_profile_name: "default",
      labels: [],
      priority: None,
      lifecycle_policy: None,
    ),
    "2026-06-12T12:00:00Z",
    fn(prefix) { prefix <> "-1" },
    fn(value) { value },
  )
  |> should.equal(Error(onboarding.MissingValidatedStatusMap("github")))
}

pub fn create_ticket_rejects_manually_configured_provider_without_attestation_test() {
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:test")),
      registries: dict.from_list([
        #(
          "linear",
          config.RegistryConfig(
            cli: "linear",
            skill: "linear",
            statuses: dict.new(),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  onboarding.create_ticket(
    memory_store.store(),
    memory_store.new(),
    registry_adapter.RegistryAdapter(discover: fn(_) { Ok([]) }),
    operator_config,
    onboarding.CreateTicketInput(
      repositories: ["https://github.com/example/tango.git"],
      external_ref: "TANGO-42",
      registry_name: "linear",
      forge_name: "github",
      capability_profile_name: "default",
      labels: [],
      priority: None,
      lifecycle_policy: None,
    ),
    "2026-06-12T12:00:00Z",
    fn(prefix) { prefix <> "-1" },
    fn(value) { value },
  )
  |> should.equal(Error(onboarding.MissingTicketAttestationAdapter("linear")))
}

pub fn create_ticket_rejects_remote_from_another_forge_test() {
  let backend = memory_store.store()
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["github-registry", "github-forge"],
            execution_tools: ["gh"],
            merge_tools: ["gh"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "gh", skill: "github-forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-registry",
            statuses: dict.new(),
            status_map_validated: False,
          ),
        ),
      ]),
    )
  let registry = registry_adapter.RegistryAdapter(discover: fn(_) { Ok([]) })

  onboarding.create_ticket(
    backend,
    memory_store.new(),
    registry,
    operator_config,
    onboarding.CreateTicketInput(
      repositories: ["https://code.example.test/example/tango.git"],
      external_ref: "TANGO-42",
      registry_name: "github",
      forge_name: "github",
      capability_profile_name: "default",
      labels: [],
      priority: None,
      lifecycle_policy: None,
    ),
    "2026-06-12T12:00:00Z",
    fn(prefix) { prefix <> "-1" },
    fn(value) { value },
  )
  |> should.equal(
    Error(onboarding.IncompatibleForgeRemote(
      "github",
      "https://code.example.test/example/tango.git",
    )),
  )
}

pub fn create_ticket_rejects_local_repository_source_test() {
  let backend = memory_store.store()
  let operator_config =
    config.Config(
      ..config.defaults("/tmp/tango", Some("local:test")),
      capability_profiles: dict.from_list([
        #(
          "default",
          config.CapabilityProfile(
            skills: ["github-ticket-system", "github-forge"],
            execution_tools: ["gh"],
            merge_tools: ["gh"],
          ),
        ),
      ]),
      forges: dict.from_list([
        #("github", config.ForgeConfig(cli: "gh", skill: "github-forge")),
      ]),
      registries: dict.from_list([
        #(
          "github",
          config.RegistryConfig(
            cli: "gh",
            skill: "github-ticket-system",
            statuses: dict.new(),
            status_map_validated: False,
          ),
        ),
      ]),
    )

  onboarding.create_ticket(
    backend,
    memory_store.new(),
    registry_adapter.RegistryAdapter(discover: fn(_) { Ok([]) }),
    operator_config,
    onboarding.CreateTicketInput(
      repositories: ["/work/tango"],
      external_ref: "42",
      registry_name: "github",
      forge_name: "github",
      capability_profile_name: "default",
      labels: [],
      priority: None,
      lifecycle_policy: None,
    ),
    "2026-06-15T12:00:00Z",
    fn(prefix) { prefix <> "-1" },
    fn(value) { value },
  )
  |> should.equal(Error(onboarding.LocalRepositorySource("/work/tango")))
}
