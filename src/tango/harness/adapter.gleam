import gleam/option.{type Option}
import tango/domain/run

pub type HarnessRequest {
  HarnessRequest(
    prompt: String,
    workspace_path: String,
    workpad_path: String,
    sandbox_paths: List(String),
    resume_session_id: Option(String),
    on_process_started: fn(Int) -> Nil,
  )
}

pub type HarnessResponse {
  HarnessResponse(
    exit_code: Int,
    output: String,
    runtime_session_id: Option(String),
    usage: Option(run.RunUsage),
  )
}

pub type HarnessError {
  LaunchFailed(String)
}

pub type HarnessAdapter {
  HarnessAdapter(
    run: fn(HarnessRequest) -> Result(HarnessResponse, HarnessError),
  )
}
