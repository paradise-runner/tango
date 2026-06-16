import gleeunit/should
import tango/domain/forge

pub fn github_accepts_github_https_remote_test() {
  forge.validate_remote("github", "https://github.com/example/tango.git")
  |> should.be_ok()
}

pub fn github_rejects_non_github_remote_test() {
  forge.validate_remote("github", "https://code.example.test/example/tango.git")
  |> should.be_error()
}

pub fn forgejo_rejects_github_remote_test() {
  forge.validate_remote("forgejo", "git@github.com:example/tango.git")
  |> should.be_error()
}

pub fn forgejo_accepts_self_hosted_remote_test() {
  forge.validate_remote(
    "forgejo",
    "ssh://git@code.example.test/example/tango.git",
  )
  |> should.be_ok()
}

pub fn github_shorthand_is_only_compatible_with_github_test() {
  forge.validate_remote("github", "example/tango")
  |> should.be_ok()

  forge.validate_remote("forgejo", "example/tango")
  |> should.be_error()
}
