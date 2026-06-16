import gleam/list
import gleam/option.{type Option, None, Some}

pub type SessionRole {
  Main
  Aux
}

pub type SessionKind {
  Implementation
  PrFeedback
  RegistrySync
  Merge
}

pub type AgentSession {
  AgentSession(
    id: String,
    ticket_id: String,
    role: SessionRole,
    kind: SessionKind,
    context_session_ids: List(String),
    runtime_session_id: Option(String),
    run_attempt_ids: List(String),
    created_at: String,
    updated_at: String,
  )
}

pub type SessionTopology {
  SessionTopology(main: Option(AgentSession), auxiliary: List(AgentSession))
}

pub type SessionError {
  MainSessionMustBeImplementation
  AuxiliarySessionCannotBeImplementation
  DuplicateSessionId(String)
  MainSessionAlreadyExists
  MainSessionCannotHaveContext
  AuxiliaryImplementationRequiresContext
  InvalidContextSessionIds
}

pub fn empty_topology() -> SessionTopology {
  SessionTopology(main: None, auxiliary: [])
}

pub fn put_main(
  topology: SessionTopology,
  session: AgentSession,
) -> Result(SessionTopology, SessionError) {
  case topology.main, session.role, session.kind, session.context_session_ids {
    Some(_), _, _, _ -> Error(MainSessionAlreadyExists)
    None, Main, Implementation, [] ->
      Ok(SessionTopology(..topology, main: Some(session)))
    None, Main, Implementation, _ -> Error(MainSessionCannotHaveContext)
    None, _, _, _ -> Error(MainSessionMustBeImplementation)
  }
}

pub fn append_aux(
  topology: SessionTopology,
  session: AgentSession,
) -> Result(SessionTopology, SessionError) {
  case session.role, session.kind, session.context_session_ids {
    Aux, Implementation, [] -> Error(AuxiliaryImplementationRequiresContext)
    Aux, Implementation, context_session_ids ->
      case valid_implementation_context(topology, context_session_ids) {
        False -> Error(InvalidContextSessionIds)
        True -> append_unique_aux(topology, session)
      }
    Aux, _, _ -> append_unique_aux(topology, session)
    _, _, _ -> Error(AuxiliarySessionCannotBeImplementation)
  }
}

fn append_unique_aux(
  topology: SessionTopology,
  session: AgentSession,
) -> Result(SessionTopology, SessionError) {
  case contains_id(topology, session.id) {
    True -> Error(DuplicateSessionId(session.id))
    False ->
      Ok(
        SessionTopology(
          ..topology,
          auxiliary: list.append(topology.auxiliary, [session]),
        ),
      )
  }
}

fn valid_implementation_context(
  topology: SessionTopology,
  context_session_ids: List(String),
) -> Bool {
  case topology.main, context_session_ids {
    Some(main), [first, ..rest] ->
      first == main.id && list.all(rest, fn(id) { contains_id(topology, id) })
    _, _ -> False
  }
}

fn contains_id(topology: SessionTopology, id: String) -> Bool {
  let main_has_id = case topology.main {
    Some(main) -> main.id == id
    None -> False
  }
  main_has_id || list.any(topology.auxiliary, fn(session) { session.id == id })
}
