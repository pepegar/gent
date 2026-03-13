use janetrs::{client::JanetClient, env::CFunOptions, Janet, JanetKeyword, JanetString};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

// ── Registries ──────────────────────────────────────────────────

static NEXT_LISTENER_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_CONN_ID: AtomicU64 = AtomicU64::new(1);

static LISTENERS: Mutex<Option<HashMap<u64, TcpListener>>> = Mutex::new(None);
static CONNECTIONS: Mutex<Option<HashMap<u64, Connection>>> = Mutex::new(None);

struct Connection {
    stream: TcpStream,
    buf: Vec<u8>,
}

fn init_listeners() {
    let mut guard = LISTENERS.lock().unwrap();
    if guard.is_none() {
        *guard = Some(HashMap::new());
    }
}

fn init_connections() {
    let mut guard = CONNECTIONS.lock().unwrap();
    if guard.is_none() {
        *guard = Some(HashMap::new());
    }
}

// ── Functions ───────────────────────────────────────────────────

/// (net/listen port) → listener-id (number)
/// Start a TCP listener on the given port. Returns a numeric ID.
#[janetrs::janet_fn(arity(fix(1)))]
fn listen(args: &mut [Janet]) -> Janet {
    init_listeners();

    let port: f64 = args[0].try_unwrap().expect("net/listen: port must be a number");
    let port = port as u16;

    let addr = format!("127.0.0.1:{}", port);
    match TcpListener::bind(&addr) {
        Ok(listener) => {
            listener
                .set_nonblocking(true)
                .expect("net/listen: failed to set non-blocking");
            let id = NEXT_LISTENER_ID.fetch_add(1, Ordering::SeqCst);
            let mut guard = LISTENERS.lock().unwrap();
            if let Some(ref mut map) = *guard {
                map.insert(id, listener);
            }
            Janet::number(id as f64)
        }
        Err(e) => {
            eprintln!("net/listen: failed to bind on {}: {}", addr, e);
            Janet::nil()
        }
    }
}

/// (net/accept listener-id &opt timeout-ms) → conn-id (number) or nil
/// Accept a new connection on the listener. Non-blocking with optional timeout.
#[janetrs::janet_fn(arity(range(1, 2)))]
fn accept(args: &mut [Janet]) -> Janet {
    init_listeners();
    init_connections();

    let listener_id: f64 = args[0]
        .try_unwrap()
        .expect("net/accept: listener-id must be a number");
    let listener_id = listener_id as u64;

    let timeout_ms: Option<u64> = if args.len() > 1 && !args[1].is_nil() {
        let t: f64 = args[1]
            .try_unwrap()
            .expect("net/accept: timeout must be a number");
        Some(t as u64)
    } else {
        None
    };

    let deadline = timeout_ms.map(|ms| std::time::Instant::now() + std::time::Duration::from_millis(ms));

    loop {
        {
            let guard = LISTENERS.lock().unwrap();
            let map = match guard.as_ref() {
                Some(m) => m,
                None => return Janet::nil(),
            };
            let listener = match map.get(&listener_id) {
                Some(l) => l,
                None => return Janet::nil(),
            };

            match listener.accept() {
                Ok((stream, _addr)) => {
                    stream
                        .set_nonblocking(true)
                        .expect("net/accept: failed to set non-blocking");
                    let conn_id = NEXT_CONN_ID.fetch_add(1, Ordering::SeqCst);
                    let mut conn_guard = CONNECTIONS.lock().unwrap();
                    if let Some(ref mut cmap) = *conn_guard {
                        cmap.insert(
                            conn_id,
                            Connection {
                                stream,
                                buf: Vec::new(),
                            },
                        );
                    }
                    return Janet::number(conn_id as f64);
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    // No connection yet
                }
                Err(_) => return Janet::nil(),
            }
        }

        if let Some(dl) = deadline {
            if std::time::Instant::now() >= dl {
                return Janet::nil();
            }
        } else {
            return Janet::nil();
        }

        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

/// (net/read-line conn-id) → string or nil or :closed
/// Non-blocking read of a complete line from a connection.
#[janetrs::janet_fn(arity(fix(1)))]
fn read_line(args: &mut [Janet]) -> Janet {
    init_connections();

    let conn_id: f64 = args[0]
        .try_unwrap()
        .expect("net/read-line: conn-id must be a number");
    let conn_id = conn_id as u64;

    let mut guard = CONNECTIONS.lock().unwrap();
    let map = match guard.as_mut() {
        Some(m) => m,
        None => return Janet::from(JanetKeyword::new(b"closed")),
    };
    let conn = match map.get_mut(&conn_id) {
        Some(c) => c,
        None => return Janet::from(JanetKeyword::new(b"closed")),
    };

    let mut tmp = [0u8; 4096];
    match conn.stream.read(&mut tmp) {
        Ok(0) => Janet::from(JanetKeyword::new(b"closed")),
        Ok(n) => {
            conn.buf.extend_from_slice(&tmp[..n]);
            try_extract_line(conn)
        }
        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => try_extract_line(conn),
        Err(_) => Janet::from(JanetKeyword::new(b"closed")),
    }
}

fn try_extract_line(conn: &mut Connection) -> Janet {
    if let Some(pos) = conn.buf.iter().position(|&b| b == b'\n') {
        let line: Vec<u8> = conn.buf.drain(..=pos).collect();
        let line = if line.ends_with(&[b'\n']) {
            let mut l = line;
            l.pop();
            if l.ends_with(&[b'\r']) {
                l.pop();
            }
            l
        } else {
            line
        };
        Janet::from(JanetString::new(&line))
    } else {
        Janet::nil()
    }
}

/// (net/write-raw conn-id data) → true or false
/// Write a string to the connection WITHOUT appending a newline. Flushes after write.
#[janetrs::janet_fn(arity(fix(2)))]
fn write_raw(args: &mut [Janet]) -> Janet {
    init_connections();

    let conn_id: f64 = args[0]
        .try_unwrap()
        .expect("net/write-raw: conn-id must be a number");
    let conn_id = conn_id as u64;

    let data: JanetString = args[1]
        .try_unwrap()
        .expect("net/write-raw: data must be a string");

    let mut guard = CONNECTIONS.lock().unwrap();
    let map = match guard.as_mut() {
        Some(m) => m,
        None => return Janet::boolean(false),
    };
    let conn = match map.get_mut(&conn_id) {
        Some(c) => c,
        None => return Janet::boolean(false),
    };

    if conn.stream.write_all(data.as_bytes()).is_err() {
        return Janet::boolean(false);
    }
    if conn.stream.flush().is_err() {
        return Janet::boolean(false);
    }

    Janet::boolean(true)
}

/// (net/read-raw conn-id &opt max-bytes) → string or nil or :closed
/// Non-blocking read of raw bytes from a connection. Returns up to max-bytes (default 4096).
#[janetrs::janet_fn(arity(range(1, 2)))]
fn read_raw(args: &mut [Janet]) -> Janet {
    init_connections();

    let conn_id: f64 = args[0]
        .try_unwrap()
        .expect("net/read-raw: conn-id must be a number");
    let conn_id = conn_id as u64;

    let max_bytes: usize = if args.len() > 1 && !args[1].is_nil() {
        let n: f64 = args[1]
            .try_unwrap()
            .expect("net/read-raw: max-bytes must be a number");
        n as usize
    } else {
        4096
    };

    let mut guard = CONNECTIONS.lock().unwrap();
    let map = match guard.as_mut() {
        Some(m) => m,
        None => return Janet::from(JanetKeyword::new(b"closed")),
    };
    let conn = match map.get_mut(&conn_id) {
        Some(c) => c,
        None => return Janet::from(JanetKeyword::new(b"closed")),
    };

    // First check if there's buffered data
    if !conn.buf.is_empty() {
        let n = std::cmp::min(conn.buf.len(), max_bytes);
        let data: Vec<u8> = conn.buf.drain(..n).collect();
        return Janet::from(JanetString::new(&data));
    }

    let mut tmp = vec![0u8; max_bytes];
    match conn.stream.read(&mut tmp) {
        Ok(0) => Janet::from(JanetKeyword::new(b"closed")),
        Ok(n) => Janet::from(JanetString::new(&tmp[..n])),
        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => Janet::nil(),
        Err(_) => Janet::from(JanetKeyword::new(b"closed")),
    }
}

/// (net/write conn-id data) → true or false
/// Write a string followed by newline to the connection. Flushes after write.
#[janetrs::janet_fn(arity(fix(2)))]
fn write_conn(args: &mut [Janet]) -> Janet {
    init_connections();

    let conn_id: f64 = args[0]
        .try_unwrap()
        .expect("net/write: conn-id must be a number");
    let conn_id = conn_id as u64;

    let data: JanetString = args[1]
        .try_unwrap()
        .expect("net/write: data must be a string");

    let mut guard = CONNECTIONS.lock().unwrap();
    let map = match guard.as_mut() {
        Some(m) => m,
        None => return Janet::boolean(false),
    };
    let conn = match map.get_mut(&conn_id) {
        Some(c) => c,
        None => return Janet::boolean(false),
    };

    if conn.stream.write_all(data.as_bytes()).is_err() {
        return Janet::boolean(false);
    }
    if conn.stream.write_all(b"\n").is_err() {
        return Janet::boolean(false);
    }
    if conn.stream.flush().is_err() {
        return Janet::boolean(false);
    }

    Janet::boolean(true)
}

/// (net/connect host port) → conn-id (number) or nil
/// Connect to a TCP server. Returns a numeric connection ID, or nil on failure.
#[janetrs::janet_fn(arity(fix(2)))]
fn connect(args: &mut [Janet]) -> Janet {
    init_connections();

    let host: JanetString = args[0]
        .try_unwrap()
        .expect("net/connect: host must be a string");
    let port: f64 = args[1]
        .try_unwrap()
        .expect("net/connect: port must be a number");
    let port = port as u16;

    let addr = format!("{}:{}", std::str::from_utf8(host.as_bytes()).unwrap_or("127.0.0.1"), port);
    match TcpStream::connect(&addr) {
        Ok(stream) => {
            stream
                .set_nonblocking(true)
                .expect("net/connect: failed to set non-blocking");
            let conn_id = NEXT_CONN_ID.fetch_add(1, Ordering::SeqCst);
            let mut guard = CONNECTIONS.lock().unwrap();
            if let Some(ref mut map) = *guard {
                map.insert(
                    conn_id,
                    Connection {
                        stream,
                        buf: Vec::new(),
                    },
                );
            }
            Janet::number(conn_id as f64)
        }
        Err(e) => {
            eprintln!("net/connect: failed to connect to {}: {}", addr, e);
            Janet::nil()
        }
    }
}

/// (net/close conn-id) → nil
/// Close a connection and remove from registry.
#[janetrs::janet_fn(arity(fix(1)))]
fn close(args: &mut [Janet]) -> Janet {
    init_connections();

    let conn_id: f64 = args[0]
        .try_unwrap()
        .expect("net/close: conn-id must be a number");
    let conn_id = conn_id as u64;

    let mut guard = CONNECTIONS.lock().unwrap();
    if let Some(ref mut map) = *guard {
        map.remove(&conn_id);
    }

    Janet::nil()
}

/// (net/close-listener listener-id) → nil
/// Close a listener and remove from registry.
#[janetrs::janet_fn(arity(fix(1)))]
fn close_listener(args: &mut [Janet]) -> Janet {
    init_listeners();

    let listener_id: f64 = args[0]
        .try_unwrap()
        .expect("net/close-listener: listener-id must be a number");
    let listener_id = listener_id as u64;

    let mut guard = LISTENERS.lock().unwrap();
    if let Some(ref mut map) = *guard {
        map.remove(&listener_id);
    }

    Janet::nil()
}

// ── Registration ────────────────────────────────────────────────

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"connect", connect_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"listen", listen_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"accept", accept_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"read-line", read_line_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"read-raw", read_raw_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"write", write_conn_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"write-raw", write_raw_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"close", close_c).namespace(c"net"));
    client.add_c_fn(CFunOptions::new(c"close-listener", close_listener_c).namespace(c"net"));
}
