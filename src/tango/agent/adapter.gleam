import gleam/option.{type Option}

pub type AgentRequest {
  AgentRequest(
    prompt: String,
    workspace_path: String,
    workpad_path: String,
    resume_session_id: Option(String),
  )
}

pub type AgentResponse {
  AgentResponse(
    exit_code: Int,
    output: String,
    runtime_session_id: Option(String),
  )
}

pub type AgentError {
  LaunchFailed(String)
}

pub type AgentAdapter {
  AgentAdapter(run: fn(AgentRequest) -> Result(AgentResponse, AgentError))
}
