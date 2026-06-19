import gleam/int
import gleam/option.{None}
import gleam/string
import gleeunit/should
import tango/process
import tango/store/file

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

pub fn run_command_streaming_captures_output_test() {
  let assert Ok(result) =
    process.run_command_streaming("printf", ["tango"], [], None)

  result.exit_code
  |> should.equal(0)
  result.output
  |> should.equal("tango")
}

pub fn run_command_streaming_observed_reports_child_pid_test() {
  let assert Ok(root) = file.temporary_directory("tango-process-observed")
  let marker = root <> "/pid"
  let assert Ok(result) =
    process.run_command_streaming_observed(
      "printf",
      ["tango"],
      [],
      None,
      fn(pid) {
        file.atomic_replace(marker, int.to_string(pid))
        |> should.be_ok()
      },
    )

  result.exit_code
  |> should.equal(0)
  result.output
  |> should.equal("tango")
  let assert Ok(pid_text) = file.read(marker)
  let assert Ok(pid) = int.parse(pid_text)
  let pid_is_positive = pid > 0
  pid_is_positive
  |> should.be_true()
  file.remove_tree(root)
  |> should.be_ok()
}

pub fn run_command_closes_child_stdin_test() {
  let assert Ok(result) =
    process.run_command(
      "sh",
      ["-c", "if read line; then exit 2; else exit 0; fi"],
      [],
      None,
    )

  result.exit_code
  |> should.equal(0)
}

pub fn run_command_streaming_closes_child_stdin_test() {
  let assert Ok(result) =
    process.run_command_streaming(
      "sh",
      ["-c", "if read line; then exit 2; else exit 0; fi"],
      [],
      None,
    )

  result.exit_code
  |> should.equal(0)
}
