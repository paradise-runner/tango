import gleam/option.{None}
import gleeunit/should
import tango/domain/repo

fn binding(id: String, location: String) -> repo.RepoBinding {
  repo.RepoBinding(
    id: id,
    name: id,
    kind: repo.GitRemote,
    location: location,
    default_branch: None,
    base_ref: None,
    target_branch: None,
    work_branch: None,
    checkout_policy: repo.Clone,
  )
}

pub fn duplicate_checkout_names_are_rejected_test() {
  repo.validate_all([
    binding("one", "https://example.test/alpha/tango.git"),
    binding("two", "https://example.test/beta/tango.git"),
  ])
  |> should.equal(Error(repo.DuplicateCheckoutName("tango")))
}
