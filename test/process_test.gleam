import gleam/option.{None}
import gleam/string
import gleeunit/should
import tango/process

pub fn run_command_resolves_bare_command_from_path_test() {
  let assert Ok(result) = process.run_command("printf", ["tango"], [], None)

  result.exit_code
  |> should.equal(0)
  result.output
  |> should.equal("tango")
}

pub fn run_command_reports_missing_executable_test() {
  let result =
    process.run_command("tango-definitely-missing-command", [], [], None)

  result
  |> should.be_error()
  let assert Error(reason) = result
  reason
  |> string.contains("executable not found: tango-definitely-missing-command")
  |> should.be_true()
}
