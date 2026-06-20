import gleam/option.{type Option, None, Some}
import gleeunit/should
import tango/domain/run
import tango/harness/adapter
import tango/harness/opencode

fn request(
  prompt: String,
  resume_session_id: Option(String),
) -> adapter.HarnessRequest {
  adapter.HarnessRequest(
    prompt: prompt,
    workspace_path: "/tmp/workspace",
    workpad_path: "/tmp/workpad",
    sandbox_paths: ["/tmp/capabilities"],
    resume_session_id: resume_session_id,
    on_process_started: fn(_) { Nil },
  )
}

pub fn opencode_run_command_uses_json_dir_permissions_and_openrouter_model_test() {
  let config =
    opencode.OpencodeConfig(
      command: "opencode",
      provider: "openrouter",
      default_model: "anthropic/claude-sonnet-4-5",
    )

  opencode.command_args(request("hello", None), config)
  |> should.equal([
    "run",
    "--dir",
    "/tmp/workspace",
    "--format",
    "json",
    "--model",
    "openrouter/anthropic/claude-sonnet-4-5",
    "--dangerously-skip-permissions",
    "hello",
  ])
}

pub fn opencode_resume_command_uses_session_id_test() {
  let config =
    opencode.OpencodeConfig(
      command: "opencode",
      provider: "openrouter",
      default_model: "anthropic/claude-sonnet-4-5",
    )

  opencode.command_args(request("resume", Some("session-123")), config)
  |> should.equal([
    "run",
    "--dir",
    "/tmp/workspace",
    "--format",
    "json",
    "--session",
    "session-123",
    "--model",
    "openrouter/anthropic/claude-sonnet-4-5",
    "--dangerously-skip-permissions",
    "resume",
  ])
}

pub fn opencode_omits_model_when_default_model_is_empty_test() {
  let config =
    opencode.OpencodeConfig(
      command: "opencode",
      provider: "openrouter",
      default_model: "",
    )

  opencode.command_args(request("hello", None), config)
  |> should.equal([
    "run",
    "--dir",
    "/tmp/workspace",
    "--format",
    "json",
    "--dangerously-skip-permissions",
    "hello",
  ])
}

pub fn opencode_json_output_extracts_session_id_and_latest_usage_test() {
  let output =
    "{\"type\":\"message.updated\",\"sessionID\":\"session-1\",\"usage\":{\"input_tokens\":3,\"cached_input_tokens\":1,\"output_tokens\":2,\"reasoning_output_tokens\":0,\"total_tokens\":5}}\n"
    <> "{\"type\":\"session.status\",\"sessionID\":\"session-1\",\"status\":{\"type\":\"idle\"}}\n"
    <> "{\"type\":\"message.updated\",\"sessionID\":\"session-1\",\"usage\":{\"prompt_tokens\":10,\"cached_tokens\":4,\"completion_tokens\":8,\"reasoning_tokens\":2,\"total_tokens\":18}}"

  opencode.extract_runtime_session_id(output)
  |> should.equal(Some("session-1"))
  opencode.extract_usage(output)
  |> should.equal(
    Some(run.RunUsage(
      input_tokens: 10,
      cached_input_tokens: 4,
      output_tokens: 8,
      reasoning_output_tokens: 2,
      total_tokens: 18,
    )),
  )
}
