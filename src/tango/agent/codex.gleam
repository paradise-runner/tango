import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/agent/adapter
import tango/process

pub type CodexConfig {
  CodexConfig(command: String)
}

pub fn adapter(config: CodexConfig) -> adapter.AgentAdapter {
  adapter.AgentAdapter(run: fn(request) { run(request, config) })
}

pub fn run(
  request: adapter.AgentRequest,
  config: CodexConfig,
) -> Result(adapter.AgentResponse, adapter.AgentError) {
  let args = command_args(request)
  use command_result <- result.try(
    process.run_command(
      config.command,
      args,
      [],
      case request.resume_session_id {
        Some(_) -> None
        None -> Some(request.workspace_path)
      },
    )
    |> result.map_error(adapter.LaunchFailed),
  )
  Ok(adapter.AgentResponse(
    exit_code: command_result.exit_code,
    output: command_result.output,
    runtime_session_id: extract_runtime_session_id(command_result.output),
  ))
}

pub fn command_args(request: adapter.AgentRequest) -> List(String) {
  case request.resume_session_id {
    Some(session_id) -> ["exec", "resume", session_id, "--json", request.prompt]
    None -> [
      "exec",
      "--json",
      "--cd",
      request.workspace_path,
      "--sandbox",
      "workspace-write",
      "--add-dir",
      request.workpad_path,
      "-c",
      "approval_policy=never",
      request.prompt,
    ]
  }
}

fn extract_runtime_session_id(output: String) -> Option(String) {
  case
    extract_after(output, "\"thread_id\":\""),
    extract_after(output, "\"session_id\":\"")
  {
    Some(id), _ -> Some(id)
    None, Some(id) -> Some(id)
    None, None -> None
  }
}

fn extract_after(source: String, prefix: String) -> Option(String) {
  case string.split_once(source, prefix) {
    Ok(#(_, rest)) ->
      case rest |> string.split("\"") |> list.first {
        Ok(value) -> Some(value)
        Error(_) -> None
      }
    Error(_) -> None
  }
}
