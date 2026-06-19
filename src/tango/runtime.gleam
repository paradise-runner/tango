import gleam/option.{type Option}

@external(erlang, "tango_store_ffi", "argv")
pub fn argv() -> List(String)

@external(erlang, "tango_store_ffi", "get_env")
pub fn get_env(name: String) -> Option(String)

@external(erlang, "tango_store_ffi", "find_executable")
pub fn find_executable(name: String) -> Option(String)

@external(erlang, "tango_store_ffi", "ensure_dir")
pub fn ensure_dir(path: String) -> Result(Nil, String)

@external(erlang, "tango_store_ffi", "now_rfc3339")
pub fn now_rfc3339() -> String

@external(erlang, "tango_store_ffi", "unique_id")
pub fn unique_id(prefix: String) -> String

@external(erlang, "tango_store_ffi", "stable_hash")
pub fn stable_hash(value: String) -> String

@external(erlang, "tango_store_ffi", "sha256")
pub fn sha256(value: String) -> String

@external(erlang, "tango_store_ffi", "run_guarded")
pub fn run_guarded(work: fn() -> value) -> Result(value, String)

@external(erlang, "tango_store_ffi", "is_pid_alive")
pub fn is_pid_alive(pid: Int) -> Bool

@external(erlang, "tango_store_ffi", "modified_at_seconds")
pub fn modified_at_seconds(path: String) -> Result(Int, String)

@external(erlang, "tango_store_ffi", "confirm")
pub fn confirm(prompt: String) -> Bool

@external(erlang, "tango_store_ffi", "halt")
pub fn halt(status: Int) -> Nil
