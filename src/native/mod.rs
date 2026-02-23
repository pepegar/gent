mod http;
mod json;
mod process;
mod task;
mod term;

use janetrs::client::JanetClient;

/// Register all native functions with the Janet VM.
/// These are the only Rust-provided primitives — the "syscalls" of the lisp machine.
pub fn register(client: &mut JanetClient) {
    term::register(client);
    http::register(client);
    process::register(client);
    json::register(client);
    task::register(client);
}
