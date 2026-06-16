import gleam/option.{None}
import gleeunit/should
import tango/domain/session

fn make_session(
  id: String,
  role: session.SessionRole,
  kind: session.SessionKind,
) -> session.AgentSession {
  session.AgentSession(
    id: id,
    ticket_id: "ticket-1",
    role: role,
    kind: kind,
    context_session_ids: case role, kind {
      session.Aux, session.Implementation -> ["main"]
      _, _ -> []
    },
    runtime_session_id: None,
    run_attempt_ids: [],
    created_at: "2026-06-07T00:00:00Z",
    updated_at: "2026-06-07T00:00:00Z",
  )
}

pub fn topology_allows_one_main_implementation_session_test() {
  let main = make_session("main", session.Main, session.Implementation)
  let assert Ok(topology) = session.put_main(session.empty_topology(), main)

  session.put_main(topology, main)
  |> should.equal(Error(session.MainSessionAlreadyExists))
}

pub fn auxiliary_sessions_are_appended_in_order_test() {
  let first = make_session("feedback", session.Aux, session.PrFeedback)
  let second = make_session("merge", session.Aux, session.Merge)
  let assert Ok(topology) = session.append_aux(session.empty_topology(), first)
  let assert Ok(topology) = session.append_aux(topology, second)

  topology.auxiliary
  |> should.equal([first, second])
}

pub fn auxiliary_implementation_session_requires_context_test() {
  let invalid =
    session.AgentSession(
      ..make_session("invalid", session.Aux, session.Implementation),
      context_session_ids: [],
    )

  session.append_aux(session.empty_topology(), invalid)
  |> should.equal(Error(session.AuxiliaryImplementationRequiresContext))
}

pub fn auxiliary_implementation_context_starts_with_main_session_test() {
  let main = make_session("main", session.Main, session.Implementation)
  let follow_up = make_session("follow-up", session.Aux, session.Implementation)
  let assert Ok(topology) = session.put_main(session.empty_topology(), main)

  let assert Ok(topology) = session.append_aux(topology, follow_up)
  topology.auxiliary
  |> should.equal([follow_up])
}
