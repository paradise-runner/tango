import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/domain/run as run_domain
import tango/harness/adapter
import tango/log
import tango/process

pub type OpencodeConfig {
  OpencodeConfig(command: String, provider: String, default_model: String)
}

pub fn adapter(config: OpencodeConfig) -> adapter.HarnessAdapter {
  adapter.HarnessAdapter(run: fn(request) { run(request, config) })
}

pub fn run(
  request: adapter.HarnessRequest,
  config: OpencodeConfig,
) -> Result(adapter.HarnessResponse, adapter.HarnessError) {
  let args = command_args(request, config)
  log.info(
    "opencode run starting workspace_path="
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
      Some(request.workspace_path),
      request.on_process_started,
    )
    |> result.map_error(adapter.LaunchFailed),
  )
  log.info(
    "opencode run exited code=" <> int.to_string(command_result.exit_code),
  )
  Ok(adapter.HarnessResponse(
    exit_code: command_result.exit_code,
    output: command_result.output,
    runtime_session_id: extract_runtime_session_id(command_result.output),
    usage: extract_usage(command_result.output),
  ))
}

pub fn command_args(
  request: adapter.HarnessRequest,
  config: OpencodeConfig,
) -> List(String) {
  list.append(
    [
      "run",
      "--dir",
      request.workspace_path,
      "--format",
      "json",
    ],
    list.append(
      session_args(request.resume_session_id),
      list.append(model_args(config), [
        "--dangerously-skip-permissions",
        request.prompt,
      ]),
    ),
  )
}

fn session_args(resume_session_id: Option(String)) -> List(String) {
  case resume_session_id {
    Some(session_id) -> ["--session", session_id]
    None -> []
  }
}

fn model_args(config: OpencodeConfig) -> List(String) {
  let provider = string.trim(config.provider)
  let model = string.trim(config.default_model)
  case model {
    "" -> []
    _ -> ["--model", provider <> "/" <> model]
  }
}

fn resume_log_text(resume_session_id: Option(String)) -> String {
  case resume_session_id {
    Some(session_id) -> " resume_session_id=" <> session_id
    None -> ""
  }
}

pub fn extract_runtime_session_id(output: String) -> Option(String) {
  output
  |> string.split("\n")
  |> list.fold(None, fn(latest, line) {
    case json.parse(line, session_id_decoder()) {
      Ok(session_id) -> Some(session_id)
      Error(_) -> latest
    }
  })
}

fn session_id_decoder() -> decode.Decoder(String) {
  decode.one_of(decode.at(["sessionID"], decode.string), or: [
    decode.at(["sessionId"], decode.string),
    decode.at(["session_id"], decode.string),
  ])
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
    decode.at(["properties", "usage"], usage_decoder()),
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
