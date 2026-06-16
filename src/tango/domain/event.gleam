import gleam/dict.{type Dict}
import gleam/option.{type Option}

pub type TangoEvent {
  TangoEvent(
    schema_version: Int,
    id: String,
    ticket_id: Option(String),
    type_: String,
    occurred_at: String,
    actor: String,
    payload: Dict(String, String),
  )
}

pub fn new(
  id id: String,
  ticket_id ticket_id: Option(String),
  type_ type_: String,
  occurred_at occurred_at: String,
  actor actor: String,
  payload payload: Dict(String, String),
) -> TangoEvent {
  TangoEvent(
    schema_version: 1,
    id: id,
    ticket_id: ticket_id,
    type_: type_,
    occurred_at: occurred_at,
    actor: actor,
    payload: payload,
  )
}
