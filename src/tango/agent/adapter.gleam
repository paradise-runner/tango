import gleam/option.{type Option}
import tango/domain/run

pub type AgentRequest {
  AgentRequest(
    prompt: String,
    workspace_path: String,
    workpad_path: String,
    sandbox_paths: List(String),
    resume_session_id: Option(String),
    on_process_started: fn(Int) -> Nil,
  )
}

pub type AgentResponse {
  AgentResponse(
    exit_code: Int,
    output: String,
    runtime_session_id: Option(String),
    usage: Option(run.RunUsage),
  )
}

pub type AgentError {
  LaunchFailed(String)
}

pub type AgentAdapter {
  AgentAdapter(run: fn(AgentRequest) -> Result(AgentResponse, AgentError))
}
