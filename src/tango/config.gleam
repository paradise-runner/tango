import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tango/store/file

pub type OrchestratorConfig {
  OrchestratorConfig(poll_interval_ms: Int, max_concurrent_workers: Int)
}

pub type AgentConfig {
  AgentConfig(command: String, transport: String, default_model: String)
}

pub type AgentRuntime {
  CodexRuntime
  OpencodeRuntime
}

pub type OpencodeAgentConfig {
  OpencodeAgentConfig(command: String, provider: String, default_model: String)
}

pub type WorkspaceConfig {
  WorkspaceConfig(command: String, root: String)
}

pub type CapabilityProfile {
  CapabilityProfile(
    skills: List(String),
    execution_tools: List(String),
    merge_tools: List(String),
  )
}

pub type RegistryConfig {
  RegistryConfig(
    cli: String,
    skill: String,
    statuses: Dict(String, String),
    status_map_validated: Bool,
  )
}

pub type ForgeConfig {
  ForgeConfig(cli: String, skill: String)
}

pub type ReviewConfig {
  ReviewConfig(
    require_human_review: Bool,
    watch_interval_ms: Int,
    watch_activity: String,
  )
}

pub type Config {
  Config(
    state_dir: String,
    operator_id: Option(String),
    orchestrator: OrchestratorConfig,
    agent_runtime: AgentRuntime,
    agent_codex: AgentConfig,
    agent_opencode: OpencodeAgentConfig,
    workspace_aicasa: WorkspaceConfig,
    capability_profiles: Dict(String, CapabilityProfile),
    registries: Dict(String, RegistryConfig),
    forges: Dict(String, ForgeConfig),
    review: ReviewConfig,
    merge_authority: String,
    retention_completed: String,
    dashboard_kind: String,
  )
}

pub type ConfigError {
  Io(String)
  InvalidConfig(String)
}

pub fn defaults(state_dir: String, operator_id: Option(String)) -> Config {
  Config(
    state_dir: state_dir,
    operator_id: operator_id,
    orchestrator: OrchestratorConfig(
      poll_interval_ms: 30_000,
      max_concurrent_workers: 2,
    ),
    agent_runtime: CodexRuntime,
    agent_codex: AgentConfig(
      command: "codex",
      transport: "exec",
      default_model: "",
    ),
    agent_opencode: OpencodeAgentConfig(
      command: "opencode",
      provider: "openrouter",
      default_model: "",
    ),
    workspace_aicasa: WorkspaceConfig(
      command: "casa",
      root: state_dir <> "/workspaces",
    ),
    capability_profiles: dict.new(),
    registries: dict.new(),
    forges: dict.new(),
    review: ReviewConfig(
      require_human_review: True,
      watch_interval_ms: 30_000,
      watch_activity: "comments_only",
    ),
    merge_authority: "agent_after_human_approval",
    retention_completed: "indefinite",
    dashboard_kind: "terminal",
  )
}

pub fn load(path: String) -> Result(Option(Config), ConfigError) {
  case file.read(path) {
    Ok(contents) -> parse(contents) |> result.map(Some)
    Error("enoent") -> Ok(None)
    Error(reason) -> Error(Io(reason))
  }
}

pub fn save(path: String, config: Config) -> Result(Nil, ConfigError) {
  file.atomic_replace(path, encode(config))
  |> result.map_error(Io)
}

pub fn with_runtime_root(config: Config, runtime_root: String) -> Config {
  let workspace_root = case
    config.workspace_aicasa.root == config.state_dir <> "/workspaces"
  {
    True -> runtime_root <> "/workspaces"
    False -> config.workspace_aicasa.root
  }
  Config(
    ..config,
    state_dir: runtime_root,
    workspace_aicasa: WorkspaceConfig(
      ..config.workspace_aicasa,
      root: workspace_root,
    ),
  )
}

pub fn encode(config: Config) -> String {
  let Config(
    orchestrator: OrchestratorConfig(poll_interval_ms:, max_concurrent_workers:),
    agent_codex: AgentConfig(command:, transport:, default_model:),
    agent_opencode: OpencodeAgentConfig(
      command: opencode_command,
      provider: opencode_provider,
      default_model: opencode_default_model,
    ),
    workspace_aicasa: WorkspaceConfig(
      command: workspace_command,
      root: workspace_root,
    ),
    review: ReviewConfig(
      require_human_review:,
      watch_interval_ms:,
      watch_activity:,
    ),
    ..,
  ) = config
  let operator = case config.operator_id {
    Some(id) -> ["", "[operator]", "id = " <> quoted(id)]
    None -> []
  }
  let profiles =
    config.capability_profiles
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.flat_map(fn(entry) {
      let #(name, CapabilityProfile(skills:, execution_tools:, merge_tools:)) =
        entry
      [
        "",
        "[capability_profiles." <> name <> "]",
        "skills = " <> quoted_list(skills),
        "execution_tools = " <> quoted_list(execution_tools),
        "merge_tools = " <> quoted_list(merge_tools),
      ]
    })
  let registries =
    config.registries
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.flat_map(fn(entry) {
      let #(
        name,
        RegistryConfig(cli:, skill:, statuses:, status_map_validated:),
      ) = entry
      let status_lines =
        statuses
        |> dict.to_list
        |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
        |> list.map(fn(status) { status.0 <> " = " <> quoted(status.1) })
      [
        "",
        "[registries." <> name <> "]",
        "cli = " <> quoted(cli),
        "skill = " <> quoted(skill),
        "status_map_validated = " <> bool_string(status_map_validated),
        "",
        "[registries." <> name <> ".statuses]",
        ..status_lines
      ]
    })
  let forges =
    config.forges
    |> dict.to_list
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.flat_map(fn(entry) {
      let #(name, ForgeConfig(cli:, skill:)) = entry
      [
        "",
        "[forges." <> name <> "]",
        "cli = " <> quoted(cli),
        "skill = " <> quoted(skill),
      ]
    })

  let base = ["[state]", "dir = " <> quoted(config.state_dir), ..operator]
  let runtime = [
    "",
    "[orchestrator]",
    "poll_interval_ms = " <> int.to_string(poll_interval_ms),
    "max_concurrent_workers = " <> int.to_string(max_concurrent_workers),
    "",
    "[agent]",
    "runtime = " <> quoted(agent_runtime_to_string(config.agent_runtime)),
    "",
    "[agent.codex]",
    "command = " <> quoted(command),
    "transport = " <> quoted(transport),
    "default_model = " <> quoted(default_model),
    "",
    "[agent.opencode]",
    "command = " <> quoted(opencode_command),
    "provider = " <> quoted(opencode_provider),
    "default_model = " <> quoted(opencode_default_model),
    "",
    "[workspace.aicasa]",
    "command = " <> quoted(workspace_command),
    "root = " <> quoted(workspace_root),
  ]
  let tail = [
    "",
    "[review]",
    "require_human_review = " <> bool_string(require_human_review),
    "watch_interval_ms = " <> int.to_string(watch_interval_ms),
    "watch_activity = " <> quoted(watch_activity),
    "",
    "[merge]",
    "authority = " <> quoted(config.merge_authority),
    "",
    "[retention]",
    "completed = " <> quoted(config.retention_completed),
    "",
    "[dashboard]",
    "kind = " <> quoted(config.dashboard_kind),
  ]
  list.append(
    base,
    list.append(
      runtime,
      list.append(profiles, list.append(registries, list.append(forges, tail))),
    ),
  )
  |> string.join(with: "\n")
  |> fn(text) { text <> "\n" }
}

pub fn parse(source: String) -> Result(Config, ConfigError) {
  use config <- result.try(
    source
    |> string.split("\n")
    |> parse_lines("", None, defaults("", None)),
  )
  validate(config)
}

pub fn get_registry(
  config: Config,
  name: String,
) -> Result(RegistryConfig, ConfigError) {
  config.registries
  |> dict.get(name)
  |> result.map_error(fn(_) { InvalidConfig("unknown registry: " <> name) })
}

pub fn get_capability_profile(
  config: Config,
  name: String,
) -> Result(CapabilityProfile, ConfigError) {
  config.capability_profiles
  |> dict.get(name)
  |> result.map_error(fn(_) {
    InvalidConfig("unknown capability profile: " <> name)
  })
}

pub fn get_forge(
  config: Config,
  name: String,
) -> Result(ForgeConfig, ConfigError) {
  config.forges
  |> dict.get(name)
  |> result.map_error(fn(_) { InvalidConfig("unknown forge: " <> name) })
}

fn parse_lines(
  remaining: List(String),
  section: String,
  state_dir: Option(String),
  config: Config,
) -> Result(Config, ConfigError) {
  case remaining {
    [] ->
      case state_dir {
        Some(state_dir) -> Ok(Config(..config, state_dir: state_dir))
        None -> Error(InvalidConfig("missing [state].dir"))
      }
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "" | "#" <> _ -> parse_lines(rest, section, state_dir, config)
        "[" <> _ ->
          case section_name(trimmed) {
            Ok(next) -> parse_lines(rest, next, state_dir, config)
            Error(error) -> Error(error)
          }
        _ -> {
          use assignment <- result.try(parse_assignment(trimmed))
          let #(key, value) = assignment
          use updated <- result.try(apply(section, key, value, config))
          let next_state_dir = case section, key {
            "state", "dir" -> Some(unquoted(value))
            _, _ -> state_dir
          }
          parse_lines(rest, section, next_state_dir, updated)
        }
      }
    }
  }
}

fn apply(
  section: String,
  key: String,
  value: String,
  config: Config,
) -> Result(Config, ConfigError) {
  case section, key {
    "state", "dir" -> Ok(config)
    "operator", "id" -> Ok(Config(..config, operator_id: Some(unquoted(value))))
    "orchestrator", "poll_interval_ms" -> {
      use parsed <- result.try(positive_int(key, value))
      Ok(
        Config(
          ..config,
          orchestrator: OrchestratorConfig(
            ..config.orchestrator,
            poll_interval_ms: parsed,
          ),
        ),
      )
    }
    "orchestrator", "max_concurrent_workers" -> {
      use parsed <- result.try(positive_int(key, value))
      Ok(
        Config(
          ..config,
          orchestrator: OrchestratorConfig(
            ..config.orchestrator,
            max_concurrent_workers: parsed,
          ),
        ),
      )
    }
    "agent", "runtime" -> {
      use parsed <- result.try(parse_agent_runtime(value))
      Ok(Config(..config, agent_runtime: parsed))
    }
    "agent.codex", "command" ->
      Ok(
        Config(
          ..config,
          agent_codex: AgentConfig(
            ..config.agent_codex,
            command: unquoted(value),
          ),
        ),
      )
    "agent.codex", "transport" ->
      Ok(
        Config(
          ..config,
          agent_codex: AgentConfig(
            ..config.agent_codex,
            transport: unquoted(value),
          ),
        ),
      )
    "agent.codex", "default_model" ->
      Ok(
        Config(
          ..config,
          agent_codex: AgentConfig(
            ..config.agent_codex,
            default_model: unquoted(value),
          ),
        ),
      )
    "agent.opencode", "command" ->
      Ok(
        Config(
          ..config,
          agent_opencode: OpencodeAgentConfig(
            ..config.agent_opencode,
            command: unquoted(value),
          ),
        ),
      )
    "agent.opencode", "provider" ->
      Ok(
        Config(
          ..config,
          agent_opencode: OpencodeAgentConfig(
            ..config.agent_opencode,
            provider: unquoted(value),
          ),
        ),
      )
    "agent.opencode", "default_model" ->
      Ok(
        Config(
          ..config,
          agent_opencode: OpencodeAgentConfig(
            ..config.agent_opencode,
            default_model: unquoted(value),
          ),
        ),
      )
    "workspace.aicasa", "command" ->
      Ok(
        Config(
          ..config,
          workspace_aicasa: WorkspaceConfig(
            ..config.workspace_aicasa,
            command: unquoted(value),
          ),
        ),
      )
    "workspace.aicasa", "root" ->
      Ok(
        Config(
          ..config,
          workspace_aicasa: WorkspaceConfig(
            ..config.workspace_aicasa,
            root: unquoted(value),
          ),
        ),
      )
    "review", "require_human_review" -> {
      use parsed <- result.try(parse_bool(key, value))
      Ok(
        Config(
          ..config,
          review: ReviewConfig(..config.review, require_human_review: parsed),
        ),
      )
    }
    "review", "watch_interval_ms" -> {
      use parsed <- result.try(positive_int(key, value))
      Ok(
        Config(
          ..config,
          review: ReviewConfig(..config.review, watch_interval_ms: parsed),
        ),
      )
    }
    "review", "watch_activity" ->
      Ok(
        Config(
          ..config,
          review: ReviewConfig(..config.review, watch_activity: unquoted(value)),
        ),
      )
    "merge", "authority" ->
      Ok(Config(..config, merge_authority: unquoted(value)))
    "retention", "completed" ->
      Ok(Config(..config, retention_completed: unquoted(value)))
    "dashboard", "kind" -> Ok(Config(..config, dashboard_kind: unquoted(value)))
    "capability_profiles." <> name, _ -> apply_profile(config, name, key, value)
    "registries." <> suffix, _ -> apply_registry(config, suffix, key, value)
    "forges." <> name, _ -> apply_forge(config, name, key, value)
    _, _ -> Ok(config)
  }
}

fn apply_forge(
  config: Config,
  name: String,
  key: String,
  value: String,
) -> Result(Config, ConfigError) {
  let current =
    dict.get(config.forges, name)
    |> result.unwrap(ForgeConfig("", ""))
  let updated = case key {
    "cli" -> ForgeConfig(..current, cli: unquoted(value))
    "skill" -> ForgeConfig(..current, skill: unquoted(value))
    _ -> current
  }
  Ok(Config(..config, forges: dict.insert(config.forges, name, updated)))
}

fn apply_profile(
  config: Config,
  name: String,
  key: String,
  value: String,
) -> Result(Config, ConfigError) {
  let current =
    dict.get(config.capability_profiles, name)
    |> result.unwrap(CapabilityProfile([], [], []))
  use values <- result.try(parse_list(key, value))
  let updated = case key {
    "skills" -> CapabilityProfile(..current, skills: values)
    "execution_tools" -> CapabilityProfile(..current, execution_tools: values)
    "merge_tools" -> CapabilityProfile(..current, merge_tools: values)
    _ -> current
  }
  Ok(
    Config(
      ..config,
      capability_profiles: dict.insert(
        config.capability_profiles,
        name,
        updated,
      ),
    ),
  )
}

fn apply_registry(
  config: Config,
  suffix: String,
  key: String,
  value: String,
) -> Result(Config, ConfigError) {
  let parts = string.split(suffix, ".")
  case parts {
    [name] -> {
      let current =
        dict.get(config.registries, name)
        |> result.unwrap(RegistryConfig("", "", dict.new(), False))
      let updated = case key {
        "cli" -> Ok(RegistryConfig(..current, cli: unquoted(value)))
        "skill" -> Ok(RegistryConfig(..current, skill: unquoted(value)))
        "status_map_validated" -> {
          use parsed <- result.try(parse_bool(key, value))
          Ok(RegistryConfig(..current, status_map_validated: parsed))
        }
        _ -> Ok(current)
      }
      use updated <- result.try(updated)
      Ok(
        Config(
          ..config,
          registries: dict.insert(config.registries, name, updated),
        ),
      )
    }
    [name, "statuses"] -> {
      let current =
        dict.get(config.registries, name)
        |> result.unwrap(RegistryConfig("", "", dict.new(), False))
      let updated =
        RegistryConfig(
          ..current,
          statuses: dict.insert(current.statuses, key, unquoted(value)),
        )
      Ok(
        Config(
          ..config,
          registries: dict.insert(config.registries, name, updated),
        ),
      )
    }
    _ -> Ok(config)
  }
}

fn validate(config: Config) -> Result(Config, ConfigError) {
  case
    string.trim(config.state_dir),
    config.orchestrator.poll_interval_ms > 0,
    config.orchestrator.max_concurrent_workers > 0,
    string.trim(config.agent_codex.command),
    string.trim(config.agent_opencode.command),
    string.trim(config.agent_opencode.provider),
    string.trim(config.workspace_aicasa.command),
    string.trim(config.workspace_aicasa.root),
    config.review.watch_interval_ms > 0,
    valid_review_activity(config.review.watch_activity),
    valid_merge_authority(config.merge_authority),
    string.trim(config.retention_completed),
    valid_dashboard_kind(config.dashboard_kind)
  {
    "", _, _, _, _, _, _, _, _, _, _, _, _ ->
      Error(InvalidConfig("missing [state].dir"))
    _, False, _, _, _, _, _, _, _, _, _, _, _ ->
      Error(InvalidConfig("orchestrator.poll_interval_ms must be positive"))
    _, _, False, _, _, _, _, _, _, _, _, _, _ ->
      Error(InvalidConfig(
        "orchestrator.max_concurrent_workers must be positive",
      ))
    _, _, _, "", _, _, _, _, _, _, _, _, _ ->
      Error(InvalidConfig("agent.codex.command must not be empty"))
    _, _, _, _, "", _, _, _, _, _, _, _, _ ->
      Error(InvalidConfig("agent.opencode.command must not be empty"))
    _, _, _, _, _, "", _, _, _, _, _, _, _ ->
      Error(InvalidConfig("agent.opencode.provider must not be empty"))
    _, _, _, _, _, _, "", _, _, _, _, _, _ ->
      Error(InvalidConfig("workspace.aicasa.command must not be empty"))
    _, _, _, _, _, _, _, "", _, _, _, _, _ ->
      Error(InvalidConfig("workspace.aicasa.root must not be empty"))
    _, _, _, _, _, _, _, _, False, _, _, _, _ ->
      Error(InvalidConfig("review.watch_interval_ms must be positive"))
    _, _, _, _, _, _, _, _, _, False, _, _, _ ->
      Error(InvalidConfig("review.watch_activity must be comments_only"))
    _, _, _, _, _, _, _, _, _, _, False, _, _ ->
      Error(InvalidConfig("merge.authority must be agent_after_human_approval"))
    _, _, _, _, _, _, _, _, _, _, _, "", _ ->
      Error(InvalidConfig("retention.completed must not be empty"))
    _, _, _, _, _, _, _, _, _, _, _, _, False ->
      Error(InvalidConfig("dashboard.kind must be terminal"))
    _, _, _, _, _, _, _, _, _, _, _, _, _ -> {
      use _ <- result.try(validate_capability_profiles(
        config.capability_profiles,
      ))
      use _ <- result.try(validate_registries(config.registries))
      use _ <- result.try(validate_forges(config.forges))
      Ok(config)
    }
  }
}

fn validate_capability_profiles(
  profiles: Dict(String, CapabilityProfile),
) -> Result(Nil, ConfigError) {
  profiles
  |> dict.to_list
  |> list.try_each(fn(entry) {
    let #(name, CapabilityProfile(skills:, execution_tools:, merge_tools:)) =
      entry
    case
      string.trim(name),
      list.all(skills, non_empty_string),
      list.all(execution_tools, non_empty_string),
      list.all(merge_tools, non_empty_string)
    {
      "", _, _, _ ->
        Error(InvalidConfig("capability profile name must not be empty"))
      _, False, _, _ ->
        Error(InvalidConfig(
          "capability profile " <> name <> " has an empty skill entry",
        ))
      _, _, False, _ ->
        Error(InvalidConfig(
          "capability profile " <> name <> " has an empty execution tool",
        ))
      _, _, _, False ->
        Error(InvalidConfig(
          "capability profile " <> name <> " has an empty merge tool",
        ))
      _, _, _, _ -> Ok(Nil)
    }
  })
}

fn validate_registries(
  registries: Dict(String, RegistryConfig),
) -> Result(Nil, ConfigError) {
  registries
  |> dict.to_list
  |> list.try_each(fn(entry) {
    let #(name, RegistryConfig(cli:, skill:, statuses:, status_map_validated:)) =
      entry
    case string.trim(name), string.trim(cli), string.trim(skill) {
      "", _, _ -> Error(InvalidConfig("registry name must not be empty"))
      _, "", _ ->
        Error(InvalidConfig("registry " <> name <> " CLI must not be empty"))
      _, _, "" ->
        Error(InvalidConfig("registry " <> name <> " skill must not be empty"))
      _, _, _ ->
        validate_registry_statuses(name, statuses, status_map_validated)
    }
  })
}

fn validate_registry_statuses(
  name: String,
  statuses: Dict(String, String),
  status_map_validated: Bool,
) -> Result(Nil, ConfigError) {
  use _ <- result.try(
    statuses
    |> dict.to_list
    |> list.try_each(fn(entry) {
      let #(role, value) = entry
      case is_lifecycle_role(role), non_empty_string(value) {
        False, _ ->
          Error(InvalidConfig(
            "registry " <> name <> " has unknown status role " <> role,
          ))
        _, False ->
          Error(InvalidConfig(
            "registry " <> name <> " has empty status " <> role,
          ))
        True, True -> Ok(Nil)
      }
    }),
  )
  case status_map_validated {
    False -> Ok(Nil)
    True ->
      required_status_roles()
      |> list.try_each(fn(role) {
        case dict.get(statuses, role) {
          Ok(_) -> Ok(Nil)
          _ ->
            Error(InvalidConfig(
              "registry " <> name <> " is missing status " <> role,
            ))
        }
      })
  }
}

pub fn required_status_roles() -> List(String) {
  [
    "backlog",
    "todo",
    "in_progress",
    "human_review",
    "merging",
    "blocked",
    "done",
    "wont_do",
  ]
}

pub fn is_lifecycle_role(role: String) -> Bool {
  required_status_roles()
  |> list.contains(role)
}

pub fn provider_status_kind(name: String) -> String {
  case name {
    "github" | "forgejo" -> "labels"
    _ -> "workflow_statuses"
  }
}

pub fn update_registry_status(
  operator_config: Config,
  name: String,
  role: String,
  status_id: String,
) -> Result(Config, ConfigError) {
  case is_lifecycle_role(role), string.trim(status_id) {
    False, _ -> Error(InvalidConfig("unknown lifecycle role: " <> role))
    _, "" -> Error(InvalidConfig("status id must not be empty"))
    True, status_id -> {
      use registry <- result.try(get_registry(operator_config, name))
      let updated =
        RegistryConfig(
          ..registry,
          statuses: dict.insert(registry.statuses, role, status_id),
          status_map_validated: False,
        )
      Ok(
        Config(
          ..operator_config,
          registries: dict.insert(operator_config.registries, name, updated),
        ),
      )
    }
  }
}

pub fn mark_registry_status_map_validated(
  operator_config: Config,
  name: String,
  validated: Bool,
) -> Result(Config, ConfigError) {
  use registry <- result.try(get_registry(operator_config, name))
  use _ <- result.try(validate_registry_statuses(
    name,
    registry.statuses,
    validated,
  ))
  Ok(
    Config(
      ..operator_config,
      registries: dict.insert(
        operator_config.registries,
        name,
        RegistryConfig(..registry, status_map_validated: validated),
      ),
    ),
  )
}

fn validate_forges(
  forges: Dict(String, ForgeConfig),
) -> Result(Nil, ConfigError) {
  forges
  |> dict.to_list
  |> list.try_each(fn(entry) {
    let #(name, ForgeConfig(cli:, skill:)) = entry
    case string.trim(name), string.trim(cli), string.trim(skill) {
      "", _, _ -> Error(InvalidConfig("forge name must not be empty"))
      _, "", _ ->
        Error(InvalidConfig("forge " <> name <> " CLI must not be empty"))
      _, _, "" ->
        Error(InvalidConfig("forge " <> name <> " skill must not be empty"))
      _, _, _ -> Ok(Nil)
    }
  })
}

fn valid_review_activity(value: String) -> Bool {
  value == "comments_only"
}

fn valid_merge_authority(value: String) -> Bool {
  value == "agent_after_human_approval"
}

fn valid_dashboard_kind(value: String) -> Bool {
  value == "terminal"
}

pub fn agent_runtime_to_string(runtime: AgentRuntime) -> String {
  case runtime {
    CodexRuntime -> "codex"
    OpencodeRuntime -> "opencode"
  }
}

fn parse_agent_runtime(value: String) -> Result(AgentRuntime, ConfigError) {
  case unquoted(value) {
    "codex" -> Ok(CodexRuntime)
    "opencode" -> Ok(OpencodeRuntime)
    _ -> Error(InvalidConfig("agent.runtime must be codex or opencode"))
  }
}

fn non_empty_string(value: String) -> Bool {
  string.trim(value) != ""
}

fn section_name(line: String) -> Result(String, ConfigError) {
  case string.ends_with(line, "]") {
    True -> Ok(line |> string.drop_start(1) |> string.drop_end(1))
    False -> Error(InvalidConfig("invalid section: " <> line))
  }
}

fn parse_assignment(line: String) -> Result(#(String, String), ConfigError) {
  case string.split_once(line, "=") {
    Ok(#(key, value)) -> Ok(#(string.trim(key), string.trim(value)))
    Error(_) -> Error(InvalidConfig("invalid config line: " <> line))
  }
}

fn positive_int(key: String, value: String) -> Result(Int, ConfigError) {
  case int.parse(value) {
    Ok(value) if value > 0 -> Ok(value)
    _ -> Error(InvalidConfig(key <> " must be a positive integer"))
  }
}

fn parse_bool(key: String, value: String) -> Result(Bool, ConfigError) {
  case value {
    "true" -> Ok(True)
    "false" -> Ok(False)
    _ -> Error(InvalidConfig(key <> " must be true or false"))
  }
}

fn parse_list(key: String, value: String) -> Result(List(String), ConfigError) {
  case string.starts_with(value, "["), string.ends_with(value, "]") {
    True, True -> {
      let inner =
        value |> string.drop_start(1) |> string.drop_end(1) |> string.trim
      case inner {
        "" -> Ok([])
        _ ->
          inner
          |> string.split(",")
          |> list.try_map(fn(item) {
            parse_quoted(string.trim(item))
            |> result.map_error(fn(_) {
              InvalidConfig(key <> " must be a list of quoted strings")
            })
          })
      }
    }
    _, _ -> Error(InvalidConfig(key <> " must be a list"))
  }
}

fn unquoted(value: String) -> String {
  parse_quoted(value) |> result.unwrap(value)
}

fn parse_quoted(value: String) -> Result(String, Nil) {
  case string.starts_with(value, "\""), string.ends_with(value, "\"") {
    True, True -> Ok(string.drop_end(string.drop_start(value, 1), 1))
    _, _ -> Error(Nil)
  }
}

fn quoted_list(values: List(String)) -> String {
  "[" <> string.join(list.map(values, quoted), with: ", ") <> "]"
}

fn quoted(value: String) -> String {
  "\"" <> string.replace(value, "\"", "\\\"") <> "\""
}

fn bool_string(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
