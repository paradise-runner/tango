import gleam/io
import tango/runtime

pub fn info(message: String) -> Nil {
  write("info", message)
}

pub fn warn(message: String) -> Nil {
  write("warn", message)
}

pub fn error(message: String) -> Nil {
  write("error", message)
}

fn write(level: String, message: String) -> Nil {
  io.println_error(runtime.now_rfc3339() <> " [" <> level <> "] " <> message)
}
