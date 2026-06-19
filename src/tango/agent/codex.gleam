import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/agent/adapter
import tango/domain/run as run_domain
import tango/log
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
  log.info(
    "codex exec starting workspace_path="
    <> request.workspace_path
    <> " workpad_path="
    <> request.workpad_path
    <> resume_log_text(request.resume_session_id),
  )
  use command_result <- result.try(
    process.run_command_streaming_observed(
      config.command,
      args,
      [],
      case request.resume_session_id {
        Some(_) -> None
        None -> Some(request.workspace_path)
      },
      request.on_process_started,
    )
    |> result.map_error(adapter.LaunchFailed),
  )
  log.info("codex exec exited code=" <> int.to_string(command_result.exit_code))
  Ok(adapter.AgentResponse(
    exit_code: command_result.exit_code,
    output: command_result.output,
    runtime_session_id: extract_runtime_session_id(command_result.output),
    usage: extract_usage(command_result.output),
  ))
}

pub fn command_args(request: adapter.AgentRequest) -> List(String) {
  case request.resume_session_id {
    Some(session_id) -> [
      "exec",
      "resume",
      session_id,
      "--json",
      "--skip-git-repo-check",
      "-c",
      "approval_policy=never",
      "-c",
      "sandbox_workspace_write.network_access=true",
      request.prompt,
    ]
    None ->
      list.append(
        [
          "exec",
          "--json",
          "--cd",
          request.workspace_path,
          "--sandbox",
          "workspace-write",
          "--add-dir",
          request.workpad_path,
        ],
        list.append(
          sandbox_path_args(request.sandbox_paths, request.workpad_path),
          [
            "--skip-git-repo-check",
            "-c",
            "approval_policy=never",
            "-c",
            "sandbox_workspace_write.network_access=true",
            request.prompt,
          ],
        ),
      )
  }
}

fn sandbox_path_args(
  paths: List(String),
  workpad_path: String,
) -> List(String) {
  paths
  |> unique_paths(workpad_path)
  |> list.flat_map(fn(path) { ["--add-dir", path] })
}

fn unique_paths(paths: List(String), workpad_path: String) -> List(String) {
  paths
  |> list.fold([], fn(acc, path) {
    let trimmed = string.trim(path)
    case trimmed == "", trimmed == workpad_path, list.contains(acc, trimmed) {
      True, _, _ | _, True, _ | _, _, True -> acc
      False, False, False -> list.append(acc, [trimmed])
    }
  })
}

fn resume_log_text(resume_session_id: Option(String)) -> String {
  case resume_session_id {
    Some(session_id) -> " resume_session_id=" <> session_id
    None -> ""
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

pub fn extract_usage(output: String) -> Option(run_domain.RunUsage) {
  output
  |> string.split("\n")
  |> list.fold(None, fn(latest, line) {
    case json.parse(line, usage_event_decoder()) {
      Ok(usage) -> Some(usage)
      Error(_) -> latest
    }
  })
}

fn usage_event_decoder() -> decode.Decoder(run_domain.RunUsage) {
  decode.one_of(decode.at(["usage"], usage_decoder()), or: [
    decode.at(["payload", "usage"], usage_decoder()),
    decode.at(["message", "usage"], usage_decoder()),
    decode.at(["response", "usage"], usage_decoder()),
    decode.at(["turn", "usage"], usage_decoder()),
    usage_decoder(),
  ])
}

fn usage_decoder() -> decode.Decoder(run_domain.RunUsage) {
  decode.one_of(input_output_usage_decoder(), or: [
    prompt_completion_usage_decoder(),
    total_usage_decoder(),
  ])
}

fn input_output_usage_decoder() -> decode.Decoder(run_domain.RunUsage) {
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  use cached_input_tokens <- decode.optional_field(
    "cached_input_tokens",
    0,
    decode.int,
  )
  use reasoning_output_tokens <- decode.optional_field(
    "reasoning_output_tokens",
    0,
    decode.int,
  )
  use total_tokens <- decode.optional_field(
    "total_tokens",
    input_tokens + output_tokens,
    decode.int,
  )
  decode.success(run_domain.RunUsage(
    input_tokens: non_negative(input_tokens),
    cached_input_tokens: non_negative(cached_input_tokens),
    output_tokens: non_negative(output_tokens),
    reasoning_output_tokens: non_negative(reasoning_output_tokens),
    total_tokens: non_negative(total_tokens),
  ))
}

fn prompt_completion_usage_decoder() -> decode.Decoder(run_domain.RunUsage) {
  use prompt_tokens <- decode.field("prompt_tokens", decode.int)
  use completion_tokens <- decode.field("completion_tokens", decode.int)
  use cached_tokens <- decode.optional_field("cached_tokens", 0, decode.int)
  use reasoning_tokens <- decode.optional_field(
    "reasoning_tokens",
    0,
    decode.int,
  )
  use total_tokens <- decode.optional_field(
    "total_tokens",
    prompt_tokens + completion_tokens,
    decode.int,
  )
  decode.success(run_domain.RunUsage(
    input_tokens: non_negative(prompt_tokens),
    cached_input_tokens: non_negative(cached_tokens),
    output_tokens: non_negative(completion_tokens),
    reasoning_output_tokens: non_negative(reasoning_tokens),
    total_tokens: non_negative(total_tokens),
  ))
}

fn total_usage_decoder() -> decode.Decoder(run_domain.RunUsage) {
  use total_tokens <- decode.field("total_tokens", decode.int)
  decode.success(run_domain.RunUsage(
    input_tokens: 0,
    cached_input_tokens: 0,
    output_tokens: 0,
    reasoning_output_tokens: 0,
    total_tokens: non_negative(total_tokens),
  ))
}

fn non_negative(value: Int) -> Int {
  int.max(value, 0)
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
