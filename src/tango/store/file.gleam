@external(erlang, "tango_store_ffi", "atomic_replace")
pub fn atomic_replace(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "tango_store_ffi", "atomic_create")
pub fn atomic_create(path: String, contents: String) -> Result(Nil, String)

@external(erlang, "tango_store_ffi", "read")
pub fn read(path: String) -> Result(String, String)

@external(erlang, "tango_store_ffi", "is_regular_file_no_symlink")
pub fn is_regular_file_no_symlink(path: String) -> Bool

@external(erlang, "tango_store_ffi", "list_dir")
pub fn list_dir(path: String) -> Result(List(String), String)

@external(erlang, "tango_store_ffi", "temporary_directory")
pub fn temporary_directory(prefix: String) -> Result(String, String)

@external(erlang, "tango_store_ffi", "remove_tree")
pub fn remove_tree(path: String) -> Result(Nil, String)
