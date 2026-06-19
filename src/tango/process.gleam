import gleam/option.{type Option}

pub type CommandResult {
  CommandResult(exit_code: Int, output: String)
}

@external(erlang, "tango_store_ffi", "run_command")
pub fn run_command(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cwd: Option(String),
) -> Result(CommandResult, String)

@external(erlang, "tango_store_ffi", "run_command_streaming")
pub fn run_command_streaming(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cwd: Option(String),
) -> Result(CommandResult, String)

@external(erlang, "tango_store_ffi", "run_command_streaming_observed")
pub fn run_command_streaming_observed(
  command: String,
  args: List(String),
  env: List(#(String, String)),
  cwd: Option(String),
  on_start: fn(Int) -> Nil,
) -> Result(CommandResult, String)

@external(erlang, "tango_store_ffi", "stable_hash")
pub fn stable_hash(value: String) -> String
