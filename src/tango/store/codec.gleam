import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import tango/domain/artifact
import tango/domain/block
import tango/domain/event
import tango/domain/forge
import tango/domain/lifecycle
import tango/domain/merge
import tango/domain/registry_status
import tango/domain/repo
import tango/domain/review
import tango/domain/review_cursor
import tango/domain/run
import tango/domain/session
import tango/domain/ticket
import tango/store/store

const schema_version = 1

const ticket_schema_version = 4

pub fn encode_ticket(ticket: ticket.Ticket) -> String {
  json.object([
    #("schema_version", json.int(ticket_schema_version)),
    #("id", json.string(ticket.id)),
    #("identifier", json.string(ticket.identifier)),
    #("title", json.nullable(ticket.title, json.string)),
    #("priority", json.nullable(ticket.priority, json.int)),
    #("labels", json.array(ticket.labels, json.string)),
    #("lifecycle_policy", json.nullable(ticket.lifecycle_policy, json.string)),
    #("state", json.string(lifecycle.to_string(ticket.state))),
    #("repo_bindings", json.array(ticket.repo_bindings, encode_repo_binding)),
    #("external_ref", json.nullable(ticket.external_ref, json.string)),
    #(
      "registry_binding",
      json.nullable(ticket.registry_binding, encode_registry_binding),
    ),
    #(
      "registry_status_mapping",
      json.nullable(
        ticket.registry_status_mapping,
        encode_registry_status_mapping,
      ),
    ),
    #(
      "forge_binding",
      json.nullable(ticket.forge_binding, encode_forge_binding),
    ),
    #(
      "observed_external_status_id",
      json.nullable(ticket.observed_external_status_id, json.string),
    ),
    #(
      "capability_profile_digest",
      json.nullable(ticket.capability_profile_digest, json.string),
    ),
    #("main_session_id", json.nullable(ticket.main_session_id, json.string)),
    #("aux_session_ids", json.array(ticket.aux_session_ids, json.string)),
    #("active_block_id", json.nullable(ticket.active_block_id, json.string)),
    #("blockers_clear", json.bool(ticket.blockers_clear)),
    #("recently_unblocked", json.bool(ticket.recently_unblocked)),
    #("created_at", json.string(ticket.created_at)),
    #("updated_at", json.string(ticket.updated_at)),
  ])
  |> json.to_string
}

pub fn decode_ticket(
  source: String,
) -> Result(ticket.Ticket, store.StoreError) {
  json.parse(source, ticket_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_event(event: event.TangoEvent) -> String {
  json.object([
    #("schema_version", json.int(event.schema_version)),
    #("id", json.string(event.id)),
    #("ticket_id", json.nullable(event.ticket_id, json.string)),
    #("type", json.string(event.type_)),
    #("occurred_at", json.string(event.occurred_at)),
    #("actor", json.string(event.actor)),
    #("payload", json.dict(event.payload, fn(value) { value }, json.string)),
  ])
  |> json.to_string
}

pub fn decode_event(
  source: String,
) -> Result(event.TangoEvent, store.StoreError) {
  json.parse(source, event_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_session(session: session.AgentSession) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(session.id)),
    #("ticket_id", json.string(session.ticket_id)),
    #("role", json.string(session_role_to_string(session.role))),
    #("kind", json.string(session_kind_to_string(session.kind))),
    #(
      "context_session_ids",
      json.array(session.context_session_ids, json.string),
    ),
    #(
      "runtime_session_id",
      json.nullable(session.runtime_session_id, json.string),
    ),
    #("run_attempt_ids", json.array(session.run_attempt_ids, json.string)),
    #("created_at", json.string(session.created_at)),
    #("updated_at", json.string(session.updated_at)),
  ])
  |> json.to_string
}

pub fn decode_session(
  source: String,
) -> Result(session.AgentSession, store.StoreError) {
  json.parse(source, session_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_block(record: block.BlockRecord) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(record.id)),
    #("ticket_id", json.string(record.ticket_id)),
    #("reason", json.string(record.reason)),
    #(
      "resolution_instructions",
      json.nullable(record.resolution_instructions, json.string),
    ),
    #("blocked_from", json.string(lifecycle.to_string(record.blocked_from))),
    #("resume_state", json.string(lifecycle.to_string(record.resume_state))),
    #("created_by", json.string(record.created_by)),
    #("created_at", json.string(record.created_at)),
    #("resolved_by", json.nullable(record.resolved_by, json.string)),
    #("resolved_at", json.nullable(record.resolved_at, json.string)),
  ])
  |> json.to_string
}

pub fn decode_block(
  source: String,
) -> Result(block.BlockRecord, store.StoreError) {
  json.parse(source, block_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_artifact(record: artifact.ArtifactRecord) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(record.id)),
    #("ticket_id", json.string(record.ticket_id)),
    #("run_id", json.string(record.run_id)),
    #("kind", json.string(artifact.kind_to_string(record.kind))),
    #("filename", json.string(record.filename)),
    #("content_type", json.string(record.content_type)),
    #("sha256", json.string(record.sha256)),
    #("content", json.string(record.content)),
    #("created_at", json.string(record.created_at)),
  ])
  |> json.to_string
}

pub fn decode_artifact(
  source: String,
) -> Result(artifact.ArtifactRecord, store.StoreError) {
  json.parse(source, artifact_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_run(run: run.RunAttempt) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(run.id)),
    #("ticket_id", json.string(run.ticket_id)),
    #("session_id", json.string(run.session_id)),
    #("kind", json.string(run_kind_to_string(run.kind))),
    #("current_stage", json.nullable(run.current_stage, encode_stage)),
    #("stages", json.array(run.stages, encode_stage)),
    #("attempt", json.int(run.attempt)),
    #("workspace_path", json.string(run.workspace_path)),
    #("agent_runtime", json.string(run.agent_runtime)),
    #(
      "capability_profile_digest",
      json.nullable(run.capability_profile_digest, json.string),
    ),
    #(
      "effective_capabilities",
      json.array(run.effective_capabilities, json.string),
    ),
    #("resume_state", json.string(lifecycle.to_string(run.resume_state))),
    #("started_at", json.string(run.started_at)),
    #("ended_at", json.nullable(run.ended_at, json.string)),
    #("status", json.string(run_status_to_string(run.status))),
    #("error", json.nullable(run.error, json.string)),
  ])
  |> json.to_string
}

pub fn decode_run(source: String) -> Result(run.RunAttempt, store.StoreError) {
  json.parse(source, run_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_review(review: review.ReviewDecision) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(review.id)),
    #("ticket_id", json.string(review.ticket_id)),
    #("reviewer_id", json.string(review.reviewer_id)),
    #("decision", json.string(review.to_string(review.decision))),
    #("comments", json.string(review.comments)),
    #(
      "reviewed_commit_set",
      json.array(review.reviewed_commit_set, encode_reviewed_commit),
    ),
    #(
      "reviewed_pull_request_set",
      json.array(review.reviewed_pull_request_set, encode_reviewed_pull_request),
    ),
    #("authorization_mechanism", json.string(review.authorization_mechanism)),
    #("created_at", json.string(review.created_at)),
  ])
  |> json.to_string
}

pub fn decode_review(
  source: String,
) -> Result(review.ReviewDecision, store.StoreError) {
  json.parse(source, review_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_merge(merge_record: merge.MergeRecord) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("id", json.string(merge_record.id)),
    #("ticket_id", json.string(merge_record.ticket_id)),
    #("review_decision_id", json.string(merge_record.review_decision_id)),
    #("entries", json.array(merge_record.entries, encode_merge_entry)),
    #("created_at", json.string(merge_record.created_at)),
    #("completed_at", json.string(merge_record.completed_at)),
  ])
  |> json.to_string
}

pub fn decode_merge(
  source: String,
) -> Result(merge.MergeRecord, store.StoreError) {
  json.parse(source, merge_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

pub fn encode_review_cursor_file(
  cursors: List(review_cursor.ReviewCommentCursor),
) -> String {
  json.object([
    #("schema_version", json.int(schema_version)),
    #("cursors", json.array(cursors, encode_review_cursor)),
  ])
  |> json.to_string
}

pub fn decode_review_cursor_file(
  source: String,
) -> Result(List(review_cursor.ReviewCommentCursor), store.StoreError) {
  json.parse(source, review_cursor_file_decoder())
  |> result.map_error(fn(error) { store.DecodeFailed(string.inspect(error)) })
}

fn encode_repo_binding(binding: repo.RepoBinding) -> json.Json {
  json.object([
    #("id", json.string(binding.id)),
    #("name", json.string(binding.name)),
    #("kind", json.string(repo_kind_to_string(binding.kind))),
    #("location", json.string(binding.location)),
    #("default_branch", json.nullable(binding.default_branch, json.string)),
    #("base_ref", json.nullable(binding.base_ref, json.string)),
    #("target_branch", json.nullable(binding.target_branch, json.string)),
    #("work_branch", json.nullable(binding.work_branch, json.string)),
    #("checkout_policy", json.string("clone")),
  ])
}

fn encode_registry_binding(
  binding: registry_status.RegistryBinding,
) -> json.Json {
  json.object([
    #("registry_name", json.string(binding.registry_name)),
    #("cli_command", json.string(binding.cli_command)),
    #("registry_skill", json.string(binding.registry_skill)),
    #("external_ticket_ref", json.string(binding.external_ticket_ref)),
    #("pinned_mapping_digest", json.string(binding.pinned_mapping_digest)),
  ])
}

fn encode_forge_binding(binding: forge.ForgeBinding) -> json.Json {
  json.object([
    #("forge_name", json.string(binding.forge_name)),
    #("cli_command", json.string(binding.cli_command)),
    #("forge_skill", json.string(binding.forge_skill)),
  ])
}

fn encode_external_status(status: registry_status.ExternalStatus) -> json.Json {
  json.object([
    #("id", json.string(status.id)),
    #("name", json.string(status.name)),
  ])
}

fn encode_registry_status_mapping(
  mapping: registry_status.RegistryStatusMapping,
) -> json.Json {
  json.object([
    #("backlog", encode_external_status(mapping.backlog)),
    #("todo", encode_external_status(mapping.todo_status)),
    #("in_progress", encode_external_status(mapping.in_progress)),
    #("human_review", encode_external_status(mapping.human_review)),
    #("merging", encode_external_status(mapping.merging)),
    #("blocked", encode_external_status(mapping.blocked)),
    #("done", encode_external_status(mapping.done)),
    #("wont_do", encode_external_status(mapping.wont_do)),
    #("digest", json.string(mapping.digest)),
  ])
}

fn encode_reviewed_commit(commit: review.ReviewedCommit) -> json.Json {
  json.object([
    #("repo_binding_id", json.string(commit.repo_binding_id)),
    #("commit_id", json.string(commit.commit_id)),
  ])
}

fn encode_reviewed_pull_request(
  pull_request: review.ReviewedPullRequest,
) -> json.Json {
  json.object([
    #("pull_request_ref", json.string(pull_request.pull_request_ref)),
    #(
      "reviewed_head_commit_id",
      json.string(pull_request.reviewed_head_commit_id),
    ),
  ])
}

fn encode_merge_entry(entry: merge.MergeEntry) -> json.Json {
  json.object([
    #("repo_binding_id", json.string(entry.repo_binding_id)),
    #("pull_request_ref", json.string(entry.pull_request_ref)),
    #("approved_head_commit_id", json.string(entry.approved_head_commit_id)),
    #("status", json.string(merge_entry_status_to_string(entry.status))),
  ])
}

fn encode_review_cursor(
  cursor: review_cursor.ReviewCommentCursor,
) -> json.Json {
  json.object([
    #("ticket_id", json.string(cursor.ticket_id)),
    #("pull_request_ref", json.string(cursor.pull_request_ref)),
    #("comment_count", json.int(cursor.comment_count)),
    #("observed_at", json.string(cursor.observed_at)),
  ])
}

fn ticket_decoder() -> decode.Decoder(ticket.Ticket) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use identifier <- decode.field("identifier", decode.string)
  use title <- decode.field("title", decode.optional(decode.string))
  use priority <- decode.field("priority", decode.optional(decode.int))
  use labels <- decode.field("labels", decode.list(of: decode.string))
  use lifecycle_policy <- decode.field(
    "lifecycle_policy",
    decode.optional(decode.string),
  )
  use state_text <- decode.field("state", decode.string)
  use repo_bindings <- decode.field(
    "repo_bindings",
    decode.list(of: repo_binding_decoder()),
  )
  use external_ref <- decode.field(
    "external_ref",
    decode.optional(decode.string),
  )
  use registry_binding <- decode.field(
    "registry_binding",
    decode.optional(registry_binding_decoder()),
  )
  use registry_status_mapping <- decode.field(
    "registry_status_mapping",
    decode.optional(registry_status_mapping_decoder()),
  )
  use forge_binding <- decode.field(
    "forge_binding",
    decode.optional(forge_binding_decoder()),
  )
  use observed_external_status_id <- decode.field(
    "observed_external_status_id",
    decode.optional(decode.string),
  )
  use capability_profile_digest <- decode.field(
    "capability_profile_digest",
    decode.optional(decode.string),
  )
  use main_session_id <- decode.field(
    "main_session_id",
    decode.optional(decode.string),
  )
  use aux_session_ids <- decode.field(
    "aux_session_ids",
    decode.list(of: decode.string),
  )
  use active_block_id <- decode.field(
    "active_block_id",
    decode.optional(decode.string),
  )
  use blockers_clear <- decode.field("blockers_clear", decode.bool)
  use recently_unblocked <- decode.field("recently_unblocked", decode.bool)
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)

  case
    version,
    parse_lifecycle_state(state_text),
    repo.validate_all(repo_bindings),
    validate_registry_pair(registry_binding, registry_status_mapping),
    validate_forge_binding(forge_binding)
  {
    4, Ok(state), Ok(repo_bindings), Ok(_), Ok(_) ->
      decode.success(ticket.Ticket(
        id: id,
        identifier: identifier,
        title: title,
        priority: priority,
        labels: labels,
        lifecycle_policy: lifecycle_policy,
        state: state,
        repo_bindings: repo_bindings,
        external_ref: external_ref,
        registry_binding: registry_binding,
        registry_status_mapping: registry_status_mapping,
        forge_binding: forge_binding,
        observed_external_status_id: observed_external_status_id,
        capability_profile_digest: capability_profile_digest,
        main_session_id: main_session_id,
        aux_session_ids: aux_session_ids,
        active_block_id: active_block_id,
        blockers_clear: blockers_clear,
        recently_unblocked: recently_unblocked,
        created_at: created_at,
        updated_at: updated_at,
      ))
    version, _, _, _, _ ->
      decode.failure(
        ticket.Ticket(
          id: "",
          identifier: "",
          title: None,
          priority: None,
          labels: [],
          lifecycle_policy: None,
          state: lifecycle.Blocked,
          repo_bindings: [],
          external_ref: None,
          registry_binding: None,
          registry_status_mapping: None,
          forge_binding: None,
          observed_external_status_id: None,
          capability_profile_digest: None,
          main_session_id: None,
          aux_session_ids: [],
          active_block_id: None,
          blockers_clear: False,
          recently_unblocked: False,
          created_at: "",
          updated_at: "",
        ),
        expected: "ticket schema version "
          <> int.to_string(ticket_schema_version)
          <> ", known lifecycle state, valid repository bindings, and valid registry mapping; got version "
          <> int.to_string(version),
      )
  }
}

fn forge_binding_decoder() -> decode.Decoder(forge.ForgeBinding) {
  use forge_name <- decode.field("forge_name", decode.string)
  use cli_command <- decode.field("cli_command", decode.string)
  use forge_skill <- decode.field("forge_skill", decode.string)
  decode.success(forge.ForgeBinding(
    forge_name: forge_name,
    cli_command: cli_command,
    forge_skill: forge_skill,
  ))
}

fn registry_binding_decoder() -> decode.Decoder(registry_status.RegistryBinding) {
  use registry_name <- decode.field("registry_name", decode.string)
  use cli_command <- decode.field("cli_command", decode.string)
  use registry_skill <- decode.field("registry_skill", decode.string)
  use external_ticket_ref <- decode.field("external_ticket_ref", decode.string)
  use pinned_mapping_digest <- decode.field(
    "pinned_mapping_digest",
    decode.string,
  )
  decode.success(registry_status.RegistryBinding(
    registry_name: registry_name,
    cli_command: cli_command,
    registry_skill: registry_skill,
    external_ticket_ref: external_ticket_ref,
    pinned_mapping_digest: pinned_mapping_digest,
  ))
}

fn external_status_decoder() -> decode.Decoder(registry_status.ExternalStatus) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  decode.success(registry_status.ExternalStatus(id: id, name: name))
}

fn registry_status_mapping_decoder() -> decode.Decoder(
  registry_status.RegistryStatusMapping,
) {
  use backlog <- decode.field("backlog", external_status_decoder())
  use todo_status <- decode.field("todo", external_status_decoder())
  use in_progress <- decode.field("in_progress", external_status_decoder())
  use human_review <- decode.field("human_review", external_status_decoder())
  use merging <- decode.field("merging", external_status_decoder())
  use blocked <- decode.field("blocked", external_status_decoder())
  use done <- decode.field("done", external_status_decoder())
  use wont_do <- decode.field("wont_do", external_status_decoder())
  use digest <- decode.field("digest", decode.string)
  decode.success(registry_status.RegistryStatusMapping(
    backlog: backlog,
    todo_status: todo_status,
    in_progress: in_progress,
    human_review: human_review,
    merging: merging,
    blocked: blocked,
    done: done,
    wont_do: wont_do,
    digest: digest,
  ))
}

fn validate_registry_pair(binding, mapping) {
  case binding, mapping {
    None, None -> Ok(Nil)
    None, Some(mapping) ->
      registry_status.validate_mapping(mapping)
      |> result.map(fn(_) { Nil })
    Some(binding), None ->
      registry_status.validate_binding(binding)
      |> result.map(fn(_) { Nil })
    Some(binding), Some(mapping) ->
      registry_status.validate_pair(binding, mapping)
  }
}

fn validate_forge_binding(binding) {
  case binding {
    None -> Ok(Nil)
    Some(binding) -> forge.validate(binding) |> result.map(fn(_) { Nil })
  }
}

fn review_decoder() -> decode.Decoder(review.ReviewDecision) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use reviewer_id <- decode.field("reviewer_id", decode.string)
  use decision_text <- decode.field("decision", decode.string)
  use comments <- decode.field("comments", decode.string)
  use reviewed_commit_set <- decode.field(
    "reviewed_commit_set",
    decode.list(of: reviewed_commit_decoder()),
  )
  use reviewed_pull_request_set <- decode.field(
    "reviewed_pull_request_set",
    decode.list(of: reviewed_pull_request_decoder()),
  )
  use authorization_mechanism <- decode.field(
    "authorization_mechanism",
    decode.string,
  )
  use created_at <- decode.field("created_at", decode.string)

  case
    version,
    parse_review_outcome(decision_text),
    review.validate(review.ReviewDecision(
      id: id,
      ticket_id: ticket_id,
      reviewer_id: reviewer_id,
      decision: review.Defer,
      comments: comments,
      reviewed_commit_set: reviewed_commit_set,
      reviewed_pull_request_set: reviewed_pull_request_set,
      authorization_mechanism: authorization_mechanism,
      created_at: created_at,
    ))
  {
    1, Ok(outcome), Ok(_) ->
      review.ReviewDecision(
        id: id,
        ticket_id: ticket_id,
        reviewer_id: reviewer_id,
        decision: outcome,
        comments: comments,
        reviewed_commit_set: reviewed_commit_set,
        reviewed_pull_request_set: reviewed_pull_request_set,
        authorization_mechanism: authorization_mechanism,
        created_at: created_at,
      )
      |> decode.success
    _, _, _ ->
      decode.failure(
        review.ReviewDecision(
          id: "",
          ticket_id: "",
          reviewer_id: "",
          decision: review.Defer,
          comments: "",
          reviewed_commit_set: [],
          reviewed_pull_request_set: [],
          authorization_mechanism: "",
          created_at: "",
        ),
        expected: "review schema version 1 and valid review decision",
      )
  }
}

fn artifact_decoder() -> decode.Decoder(artifact.ArtifactRecord) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use run_id <- decode.field("run_id", decode.string)
  use kind_text <- decode.field("kind", decode.string)
  use filename <- decode.field("filename", decode.string)
  use content_type <- decode.field("content_type", decode.string)
  use sha256 <- decode.field("sha256", decode.string)
  use content <- decode.field("content", decode.string)
  use created_at <- decode.field("created_at", decode.string)

  case
    version,
    parse_artifact_kind(kind_text),
    artifact.validate(artifact.ArtifactRecord(
      id: id,
      ticket_id: ticket_id,
      run_id: run_id,
      kind: artifact.NormalizedTicket,
      filename: filename,
      content_type: content_type,
      sha256: sha256,
      content: content,
      created_at: created_at,
    ))
  {
    1, Ok(kind), Ok(_) ->
      decode.success(artifact.ArtifactRecord(
        id: id,
        ticket_id: ticket_id,
        run_id: run_id,
        kind: kind,
        filename: filename,
        content_type: content_type,
        sha256: sha256,
        content: content,
        created_at: created_at,
      ))
    _, _, _ ->
      decode.failure(
        artifact.ArtifactRecord(
          id: "",
          ticket_id: "",
          run_id: "",
          kind: artifact.NormalizedTicket,
          filename: "",
          content_type: "",
          sha256: "",
          content: "",
          created_at: "",
        ),
        expected: "artifact schema version 1 and valid artifact record",
      )
  }
}

fn merge_decoder() -> decode.Decoder(merge.MergeRecord) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use review_decision_id <- decode.field("review_decision_id", decode.string)
  use entries <- decode.field("entries", decode.list(of: merge_entry_decoder()))
  use created_at <- decode.field("created_at", decode.string)
  use completed_at <- decode.field("completed_at", decode.string)

  case
    version,
    merge.validate(merge.MergeRecord(
      id: id,
      ticket_id: ticket_id,
      review_decision_id: review_decision_id,
      entries: entries,
      created_at: created_at,
      completed_at: completed_at,
    ))
  {
    1, Ok(record) -> decode.success(record)
    _, _ ->
      decode.failure(
        merge.MergeRecord(
          id: "",
          ticket_id: "",
          review_decision_id: "",
          entries: [],
          created_at: "",
          completed_at: "",
        ),
        expected: "merge schema version 1 and valid merge record",
      )
  }
}

fn review_cursor_file_decoder() -> decode.Decoder(
  List(review_cursor.ReviewCommentCursor),
) {
  use version <- decode.field("schema_version", decode.int)
  use cursors <- decode.field(
    "cursors",
    decode.list(of: review_cursor_decoder()),
  )

  case version {
    1 -> decode.success(cursors)
    _ ->
      decode.failure(
        [],
        expected: "review cursor schema version "
          <> int.to_string(schema_version),
      )
  }
}

fn review_cursor_decoder() -> decode.Decoder(review_cursor.ReviewCommentCursor) {
  use ticket_id <- decode.field("ticket_id", decode.string)
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  use comment_count <- decode.field("comment_count", decode.int)
  use observed_at <- decode.field("observed_at", decode.string)
  let cursor =
    review_cursor.ReviewCommentCursor(
      ticket_id: ticket_id,
      pull_request_ref: pull_request_ref,
      comment_count: comment_count,
      observed_at: observed_at,
    )
  case review_cursor.validate(cursor) {
    Ok(valid) -> decode.success(valid)
    Error(_) -> decode.failure(cursor, expected: "valid review comment cursor")
  }
}

fn reviewed_commit_decoder() -> decode.Decoder(review.ReviewedCommit) {
  use repo_binding_id <- decode.field("repo_binding_id", decode.string)
  use commit_id <- decode.field("commit_id", decode.string)
  decode.success(review.ReviewedCommit(
    repo_binding_id: repo_binding_id,
    commit_id: commit_id,
  ))
}

fn reviewed_pull_request_decoder() -> decode.Decoder(review.ReviewedPullRequest) {
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  use reviewed_head_commit_id <- decode.field(
    "reviewed_head_commit_id",
    decode.string,
  )
  decode.success(review.ReviewedPullRequest(
    pull_request_ref: pull_request_ref,
    reviewed_head_commit_id: reviewed_head_commit_id,
  ))
}

fn merge_entry_decoder() -> decode.Decoder(merge.MergeEntry) {
  use repo_binding_id <- decode.field("repo_binding_id", decode.string)
  use pull_request_ref <- decode.field("pull_request_ref", decode.string)
  use approved_head_commit_id <- decode.field(
    "approved_head_commit_id",
    decode.string,
  )
  use status_text <- decode.field("status", decode.string)
  case parse_merge_entry_status(status_text) {
    Ok(status) ->
      decode.success(merge.MergeEntry(
        repo_binding_id: repo_binding_id,
        pull_request_ref: pull_request_ref,
        approved_head_commit_id: approved_head_commit_id,
        status: status,
      ))
    Error(_) ->
      decode.failure(
        merge.MergeEntry(
          repo_binding_id: "",
          pull_request_ref: "",
          approved_head_commit_id: "",
          status: merge.Pending,
        ),
        expected: "supported merge entry status",
      )
  }
}

fn event_decoder() -> decode.Decoder(event.TangoEvent) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.optional(decode.string))
  use type_ <- decode.field("type", decode.string)
  use occurred_at <- decode.field("occurred_at", decode.string)
  use actor <- decode.field("actor", decode.string)
  use payload <- decode.field(
    "payload",
    decode.dict(decode.string, decode.string),
  )

  case version {
    1 ->
      decode.success(event.TangoEvent(
        schema_version: version,
        id: id,
        ticket_id: ticket_id,
        type_: type_,
        occurred_at: occurred_at,
        actor: actor,
        payload: payload,
      ))
    _ ->
      decode.failure(
        event.TangoEvent(
          schema_version: version,
          id: "",
          ticket_id: None,
          type_: "",
          occurred_at: "",
          actor: "",
          payload: dict.new(),
        ),
        expected: "event schema version " <> int.to_string(schema_version),
      )
  }
}

fn session_decoder() -> decode.Decoder(session.AgentSession) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use role <- decode.field("role", decode.string)
  use kind <- decode.field("kind", decode.string)
  use context_session_ids <- decode.optional_field(
    "context_session_ids",
    [],
    decode.list(of: decode.string),
  )
  use runtime_session_id <- decode.field(
    "runtime_session_id",
    decode.optional(decode.string),
  )
  use run_attempt_ids <- decode.field(
    "run_attempt_ids",
    decode.list(of: decode.string),
  )
  use created_at <- decode.field("created_at", decode.string)
  use updated_at <- decode.field("updated_at", decode.string)

  case version, parse_session_role(role), parse_session_kind(kind) {
    1, Ok(role), Ok(kind) ->
      decode.success(session.AgentSession(
        id: id,
        ticket_id: ticket_id,
        role: role,
        kind: kind,
        context_session_ids: context_session_ids,
        runtime_session_id: runtime_session_id,
        run_attempt_ids: run_attempt_ids,
        created_at: created_at,
        updated_at: updated_at,
      ))
    _, _, _ ->
      decode.failure(
        session.AgentSession(
          id: "",
          ticket_id: "",
          role: session.Aux,
          kind: session.RegistrySync,
          context_session_ids: [],
          runtime_session_id: None,
          run_attempt_ids: [],
          created_at: "",
          updated_at: "",
        ),
        expected: "supported agent session schema, role, and kind",
      )
  }
}

fn block_decoder() -> decode.Decoder(block.BlockRecord) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use reason <- decode.field("reason", decode.string)
  use resolution_instructions <- decode.field(
    "resolution_instructions",
    decode.optional(decode.string),
  )
  use blocked_from <- decode.field("blocked_from", decode.string)
  use resume_state <- decode.field("resume_state", decode.string)
  use created_by <- decode.field("created_by", decode.string)
  use created_at <- decode.field("created_at", decode.string)
  use resolved_by <- decode.field("resolved_by", decode.optional(decode.string))
  use resolved_at <- decode.field("resolved_at", decode.optional(decode.string))

  case
    version,
    parse_lifecycle_state(blocked_from),
    parse_lifecycle_state(resume_state)
  {
    1, Ok(blocked_from), Ok(resume_state) -> {
      let record =
        block.BlockRecord(
          id: id,
          ticket_id: ticket_id,
          reason: reason,
          resolution_instructions: resolution_instructions,
          blocked_from: blocked_from,
          resume_state: resume_state,
          created_by: created_by,
          created_at: created_at,
          resolved_by: resolved_by,
          resolved_at: resolved_at,
        )
      case block.validate(record) {
        Ok(record) -> decode.success(record)
        Error(_) -> decode.failure(record, expected: "valid block resume state")
      }
    }
    _, _, _ ->
      decode.failure(
        block.BlockRecord(
          id: "",
          ticket_id: "",
          reason: "",
          resolution_instructions: None,
          blocked_from: lifecycle.Blocked,
          resume_state: lifecycle.Queued,
          created_by: "",
          created_at: "",
          resolved_by: None,
          resolved_at: None,
        ),
        expected: "supported block record schema and lifecycle states",
      )
  }
}

fn run_decoder() -> decode.Decoder(run.RunAttempt) {
  use version <- decode.field("schema_version", decode.int)
  use id <- decode.field("id", decode.string)
  use ticket_id <- decode.field("ticket_id", decode.string)
  use session_id <- decode.field("session_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use current_stage <- decode.field(
    "current_stage",
    decode.optional(stage_decoder()),
  )
  use stages <- decode.field("stages", decode.list(of: stage_decoder()))
  use attempt_number <- decode.field("attempt", decode.int)
  use workspace_path <- decode.field("workspace_path", decode.string)
  use agent_runtime <- decode.field("agent_runtime", decode.string)
  use capability_profile_digest <- decode.field(
    "capability_profile_digest",
    decode.optional(decode.string),
  )
  use effective_capabilities <- decode.field(
    "effective_capabilities",
    decode.list(of: decode.string),
  )
  use resume_state <- decode.field("resume_state", decode.string)
  use started_at <- decode.field("started_at", decode.string)
  use ended_at <- decode.field("ended_at", decode.optional(decode.string))
  use status <- decode.field("status", decode.string)
  use error <- decode.field("error", decode.optional(decode.string))

  case
    version,
    parse_run_kind(kind),
    parse_lifecycle_state(resume_state),
    parse_run_status(status)
  {
    1, Ok(kind), Ok(resume_state), Ok(status) -> {
      let attempt =
        run.RunAttempt(
          id: id,
          ticket_id: ticket_id,
          session_id: session_id,
          kind: kind,
          current_stage: current_stage,
          stages: stages,
          attempt: attempt_number,
          workspace_path: workspace_path,
          agent_runtime: agent_runtime,
          capability_profile_digest: capability_profile_digest,
          effective_capabilities: effective_capabilities,
          resume_state: resume_state,
          started_at: started_at,
          ended_at: ended_at,
          status: status,
          error: error,
        )
      case run.validate(attempt) {
        Ok(attempt) -> decode.success(attempt)
        Error(_) -> decode.failure(attempt, expected: "valid run attempt")
      }
    }
    _, _, _, _ ->
      decode.failure(
        invalid_run(),
        expected: "supported run attempt schema and enum values",
      )
  }
}

fn stage_decoder() -> decode.Decoder(lifecycle.Stage) {
  decode.string
  |> decode.then(fn(value) {
    case parse_stage(value) {
      Ok(stage) -> decode.success(stage)
      Error(_) ->
        decode.failure(lifecycle.Research, expected: "lifecycle stage")
    }
  })
}

fn repo_binding_decoder() -> decode.Decoder(repo.RepoBinding) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use kind <- decode.field("kind", decode.string)
  use location <- decode.field("location", decode.string)
  use default_branch <- decode.field(
    "default_branch",
    decode.optional(decode.string),
  )
  use base_ref <- decode.field("base_ref", decode.optional(decode.string))
  use target_branch <- decode.field(
    "target_branch",
    decode.optional(decode.string),
  )
  use work_branch <- decode.field("work_branch", decode.optional(decode.string))
  use checkout_policy <- decode.field("checkout_policy", decode.string)

  case parse_repo_kind(kind), checkout_policy {
    Ok(kind), "clone" ->
      decode.success(repo.RepoBinding(
        id: id,
        name: name,
        kind: kind,
        location: location,
        default_branch: default_branch,
        base_ref: base_ref,
        target_branch: target_branch,
        work_branch: work_branch,
        checkout_policy: repo.Clone,
      ))
    _, _ ->
      decode.failure(
        repo.RepoBinding(
          id: "",
          name: "",
          kind: repo.ExternalRepo("invalid"),
          location: "",
          default_branch: None,
          base_ref: None,
          target_branch: None,
          work_branch: None,
          checkout_policy: repo.Clone,
        ),
        expected: "supported repository binding",
      )
  }
}

fn parse_lifecycle_state(
  value: String,
) -> Result(lifecycle.LifecycleState, Nil) {
  case value {
    "onboarded" -> Ok(lifecycle.Onboarded)
    "queued" -> Ok(lifecycle.Queued)
    "researching" -> Ok(lifecycle.Researching)
    "planning" -> Ok(lifecycle.Planning)
    "implementing" -> Ok(lifecycle.Implementing)
    "awaiting_human_review" -> Ok(lifecycle.AwaitingHumanReview)
    "changes_requested" -> Ok(lifecycle.ChangesRequested)
    "merging" -> Ok(lifecycle.Merging)
    "done" -> Ok(lifecycle.Done)
    "blocked" -> Ok(lifecycle.Blocked)
    "failed" -> Ok(lifecycle.Failed)
    "canceled" -> Ok(lifecycle.Canceled)
    _ -> Error(Nil)
  }
}

fn repo_kind_to_string(kind: repo.RepositoryKind) -> String {
  case kind {
    repo.LocalPath -> "local_path"
    repo.GitRemote -> "git_remote"
    repo.ExternalRepo(value) -> value
  }
}

fn parse_repo_kind(value: String) -> Result(repo.RepositoryKind, Nil) {
  case value {
    "local_path" -> Ok(repo.LocalPath)
    "git_remote" -> Ok(repo.GitRemote)
    "" -> Error(Nil)
    value -> Ok(repo.ExternalRepo(value))
  }
}

fn session_role_to_string(role: session.SessionRole) -> String {
  case role {
    session.Main -> "main"
    session.Aux -> "aux"
  }
}

fn parse_session_role(value: String) -> Result(session.SessionRole, Nil) {
  case value {
    "main" -> Ok(session.Main)
    "aux" -> Ok(session.Aux)
    _ -> Error(Nil)
  }
}

fn session_kind_to_string(kind: session.SessionKind) -> String {
  case kind {
    session.Implementation -> "implementation"
    session.PrFeedback -> "pr_feedback"
    session.RegistrySync -> "registry_sync"
    session.Merge -> "merge"
  }
}

fn parse_session_kind(value: String) -> Result(session.SessionKind, Nil) {
  case value {
    "implementation" -> Ok(session.Implementation)
    "pr_feedback" -> Ok(session.PrFeedback)
    "registry_sync" -> Ok(session.RegistrySync)
    "merge" -> Ok(session.Merge)
    _ -> Error(Nil)
  }
}

fn encode_stage(stage: lifecycle.Stage) -> json.Json {
  json.string(stage_to_string(stage))
}

fn stage_to_string(stage: lifecycle.Stage) -> String {
  case stage {
    lifecycle.Research -> "research"
    lifecycle.Plan -> "plan"
    lifecycle.Implement -> "implement"
    lifecycle.HumanReview -> "human_review"
    lifecycle.Merge -> "merge"
  }
}

fn parse_stage(value: String) -> Result(lifecycle.Stage, Nil) {
  case value {
    "research" -> Ok(lifecycle.Research)
    "plan" -> Ok(lifecycle.Plan)
    "implement" -> Ok(lifecycle.Implement)
    "human_review" -> Ok(lifecycle.HumanReview)
    "merge" -> Ok(lifecycle.Merge)
    _ -> Error(Nil)
  }
}

fn run_kind_to_string(kind: run.RunKind) -> String {
  case kind {
    run.Execution -> "execution"
    run.ReviewWatch -> "review_watch"
    run.RegistrySync -> "registry_sync"
    run.MergeRun -> "merge"
  }
}

fn parse_run_kind(value: String) -> Result(run.RunKind, Nil) {
  case value {
    "execution" -> Ok(run.Execution)
    "review_watch" -> Ok(run.ReviewWatch)
    "registry_sync" -> Ok(run.RegistrySync)
    "merge" -> Ok(run.MergeRun)
    _ -> Error(Nil)
  }
}

fn run_status_to_string(status: run.RunStatus) -> String {
  case status {
    run.PreparingWorkspace -> "preparing_workspace"
    run.BuildingPrompt -> "building_prompt"
    run.LaunchingAgent -> "launching_agent"
    run.Streaming -> "streaming"
    run.CollectingArtifacts -> "collecting_artifacts"
    run.Succeeded -> "succeeded"
    run.Failed -> "failed"
    run.TimedOut -> "timed_out"
    run.Stalled -> "stalled"
    run.Canceled -> "canceled"
  }
}

fn merge_entry_status_to_string(status: merge.MergeEntryStatus) -> String {
  case status {
    merge.Completed -> "completed"
    merge.Pending -> "pending"
    merge.FailedEntry -> "failed"
  }
}

fn parse_run_status(value: String) -> Result(run.RunStatus, Nil) {
  case value {
    "preparing_workspace" -> Ok(run.PreparingWorkspace)
    "building_prompt" -> Ok(run.BuildingPrompt)
    "launching_agent" -> Ok(run.LaunchingAgent)
    "streaming" -> Ok(run.Streaming)
    "collecting_artifacts" -> Ok(run.CollectingArtifacts)
    "succeeded" -> Ok(run.Succeeded)
    "failed" -> Ok(run.Failed)
    "timed_out" -> Ok(run.TimedOut)
    "stalled" -> Ok(run.Stalled)
    "canceled" -> Ok(run.Canceled)
    _ -> Error(Nil)
  }
}

fn parse_review_outcome(value: String) -> Result(review.ReviewOutcome, Nil) {
  case value {
    "approve" -> Ok(review.Approve)
    "request_changes" -> Ok(review.RequestChanges)
    "reject" -> Ok(review.Reject)
    "cancel" -> Ok(review.Cancel)
    "defer" -> Ok(review.Defer)
    _ -> Error(Nil)
  }
}

fn parse_artifact_kind(value: String) -> Result(artifact.ArtifactKind, Nil) {
  case value {
    "normalized_ticket" -> Ok(artifact.NormalizedTicket)
    "research_notes" -> Ok(artifact.ResearchNotes)
    "plan" -> Ok(artifact.Plan)
    "diff_summary" -> Ok(artifact.DiffSummary)
    "implementation_notes" -> Ok(artifact.ImplementationNotes)
    "validation_report" -> Ok(artifact.ValidationReport)
    "pull_request_set" -> Ok(artifact.PullRequestSet)
    "review_comments_report" -> Ok(artifact.ReviewCommentsReport)
    "merge_report" -> Ok(artifact.MergeReport)
    "external_updates" -> Ok(artifact.ExternalUpdates)
    _ -> Error(Nil)
  }
}

fn parse_merge_entry_status(
  value: String,
) -> Result(merge.MergeEntryStatus, Nil) {
  case value {
    "completed" -> Ok(merge.Completed)
    "pending" -> Ok(merge.Pending)
    "failed" -> Ok(merge.FailedEntry)
    _ -> Error(Nil)
  }
}

fn invalid_run() -> run.RunAttempt {
  run.RunAttempt(
    id: "",
    ticket_id: "",
    session_id: "",
    kind: run.Execution,
    current_stage: None,
    stages: [],
    attempt: 0,
    workspace_path: "",
    agent_runtime: "",
    capability_profile_digest: None,
    effective_capabilities: [],
    resume_state: lifecycle.Queued,
    started_at: "",
    ended_at: None,
    status: run.Failed,
    error: None,
  )
}
