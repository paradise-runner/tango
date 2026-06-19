import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/runtime
import tango/store/file

const schema_version = 1

pub type AgentProcessMarker {
  AgentProcessMarker(
    ticket_id: String,
    run_id: String,
    pid: Int,
    started_at: String,
    ended_at: Option(String),
  )
}

pub type AgentLiveness {
  AgentUnknown
  AgentNotStarted
  AgentAlive(pid: Int, started_at: String)
  AgentExited(pid: Int, started_at: String, ended_at: String)
  AgentMissing(pid: Int, started_at: String)
  AgentMarkerInvalid(reason: String)
}

pub fn mark_started(
  state_dir: String,
  ticket_id: String,
  run_id: String,
  pid: Int,
  started_at: String,
) -> Result(Nil, String) {
  use _ <- result.try(runtime.ensure_dir(marker_dir(state_dir, ticket_id)))
  file.atomic_replace(
    marker_path(state_dir, ticket_id, run_id),
    encode_marker(AgentProcessMarker(
      ticket_id: ticket_id,
      run_id: run_id,
      pid: pid,
      started_at: started_at,
      ended_at: None,
    )),
  )
}

pub fn mark_ended(
  state_dir: String,
  ticket_id: String,
  run_id: String,
  ended_at: String,
) -> Result(Nil, String) {
  case read_marker(state_dir, ticket_id, run_id) {
    Ok(marker) ->
      file.atomic_replace(
        marker_path(state_dir, ticket_id, run_id),
        encode_marker(AgentProcessMarker(..marker, ended_at: Some(ended_at))),
      )
    Error("enoent") -> Ok(Nil)
    Error(reason) -> Error(reason)
  }
}

pub fn liveness(
  state_dir: String,
  ticket_id: String,
  run_id: String,
) -> AgentLiveness {
  case read_marker(state_dir, ticket_id, run_id) {
    Error("enoent") -> AgentNotStarted
    Error(reason) -> AgentMarkerInvalid(reason)
    Ok(marker) ->
      case marker.ended_at {
        Some(ended_at) ->
          AgentExited(
            pid: marker.pid,
            started_at: marker.started_at,
            ended_at: ended_at,
          )
        None ->
          case runtime.is_pid_alive(marker.pid) {
            True -> AgentAlive(pid: marker.pid, started_at: marker.started_at)
            False ->
              AgentMissing(pid: marker.pid, started_at: marker.started_at)
          }
      }
  }
}

fn read_marker(
  state_dir: String,
  ticket_id: String,
  run_id: String,
) -> Result(AgentProcessMarker, String) {
  use source <- result.try(file.read(marker_path(state_dir, ticket_id, run_id)))
  json.parse(source, marker_decoder())
  |> result.map_error(string.inspect)
}

fn encode_marker(marker: AgentProcessMarker) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("ticket_id", json.string(marker.ticket_id)),
    #("run_id", json.string(marker.run_id)),
    #("pid", json.int(marker.pid)),
    #("started_at", json.string(marker.started_at)),
    #("ended_at", json.nullable(marker.ended_at, json.string)),
  ])
  |> json.to_string
}

fn marker_decoder() -> decode.Decoder(AgentProcessMarker) {
  use version <- decode.field("schema_version", decode.int)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use run_id <- decode.field("run_id", decode.string)
  use pid <- decode.field("pid", decode.int)
  use started_at <- decode.field("started_at", decode.string)
  use ended_at <- decode.field("ended_at", decode.optional(decode.string))
  case version {
    1 ->
      decode.success(AgentProcessMarker(
        ticket_id: ticket_id,
        run_id: run_id,
        pid: pid,
        started_at: started_at,
        ended_at: ended_at,
      ))
    _ ->
      decode.failure(
        invalid_marker(),
        expected: "supported run process marker schema",
      )
  }
}

fn invalid_marker() -> AgentProcessMarker {
  AgentProcessMarker(
    ticket_id: "",
    run_id: "",
    pid: 0,
    started_at: "",
    ended_at: None,
  )
}

fn marker_dir(state_dir: String, ticket_id: String) -> String {
  state_dir <> "/run-processes/" <> ticket_id
}

fn marker_path(state_dir: String, ticket_id: String, run_id: String) -> String {
  marker_dir(state_dir, ticket_id) <> "/" <> run_id <> ".json"
}
