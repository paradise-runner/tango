import fixtures
import gleeunit/should
import tango/domain/lifecycle
import tango/domain/registry_status

pub fn complete_mapping_and_binding_validate_test() {
  registry_status.validate_pair(
    fixtures.registry_binding(),
    fixtures.registry_status_mapping(),
  )
  |> should.be_ok()
}

pub fn roles_may_share_external_status_id_test() {
  let mapping = fixtures.registry_status_mapping()

  mapping.human_review.id
  |> should.equal(mapping.merging.id)
  registry_status.validate_mapping(mapping)
  |> should.be_ok()
}

pub fn missing_required_status_id_fails_validation_test() {
  let mapping =
    registry_status.RegistryStatusMapping(
      ..fixtures.registry_status_mapping(),
      blocked: registry_status.ExternalStatus(id: "", name: "Blocked"),
    )

  registry_status.validate_mapping(mapping)
  |> should.equal(Error(registry_status.EmptyStatusId("blocked")))
}

pub fn pinned_mapping_digest_must_match_test() {
  let binding =
    registry_status.RegistryBinding(
      ..fixtures.registry_binding(),
      pinned_mapping_digest: "sha256:different",
    )

  registry_status.validate_pair(binding, fixtures.registry_status_mapping())
  |> should.equal(Error(registry_status.MappingDigestMismatch))
}

pub fn failed_lifecycle_resolves_to_external_blocked_status_test() {
  let role = lifecycle.registry_status_role(lifecycle.Failed)

  registry_status.resolve(fixtures.registry_status_mapping(), role).id
  |> should.equal("blocked")
}
