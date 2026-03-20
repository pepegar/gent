mod buffer;
mod crypto;
mod http;
mod json;
mod net;
mod process;
mod task;
mod term;

use janetrs::client::JanetClient;

/// Register all native functions with the Janet VM.
/// These are the only Rust-provided primitives — the "syscalls" of the lisp machine.
pub fn register(client: &mut JanetClient) {
    term::register(client);
    http::register(client);
    net::register(client);
    process::register(client);
    json::register(client);
    task::register(client);
    buffer::register(client);
    crypto::register(client);
}
