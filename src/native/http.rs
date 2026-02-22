use janetrs::{client::JanetClient, env::CFunOptions, Janet, JanetString, JanetKeyword, JanetTable};
use std::collections::HashMap;
use std::sync::{mpsc, Mutex};
use std::sync::atomic::{AtomicU64, Ordering};

// ── Stream registry ──────────────────────────────────────────────

enum StreamEvent {
    Line(String),
    Done,
    Error(String),
}

static NEXT_STREAM_ID: AtomicU64 = AtomicU64::new(1);
static STREAMS: Mutex<Option<HashMap<u64, mpsc::Receiver<StreamEvent>>>> = Mutex::new(None);

fn init_streams() {
    let mut guard = STREAMS.lock().unwrap();
    if guard.is_none() {
        *guard = Some(HashMap::new());
    }
}

/// Extract a string from a Janet value (string or keyword).
fn janet_val_to_str(val: Janet, ctx: &str) -> String {
    if let Ok(s) = val.try_unwrap::<JanetString>() {
        String::from_utf8_lossy(s.as_bytes()).into_owned()
    } else if let Ok(kw) = val.try_unwrap::<JanetKeyword>() {
        String::from_utf8_lossy(kw.as_bytes()).into_owned()
    } else {
        panic!("http/request: {} must be a string or keyword", ctx);
    }
}

/// Collect headers from a Janet table or struct into owned (key, value) pairs.
fn collect_headers(headers_val: Janet) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    if headers_val.is_nil() {
        return pairs;
    }
    if let Ok(headers) = headers_val.try_unwrap::<janetrs::JanetTable>() {
        for (k, v) in headers.iter() {
            pairs.push((janet_val_to_str(*k, "header key"), janet_val_to_str(*v, "header value")));
        }
    } else if let Ok(headers) = headers_val.try_unwrap::<janetrs::JanetStruct>() {
        for (k, v) in headers.iter() {
            pairs.push((janet_val_to_str(*k, "header key"), janet_val_to_str(*v, "header value")));
        }
    } else {
        panic!("headers must be a table or struct");
    }
    pairs
}

/// Build a ureq request with method, URL, and headers.
fn build_request(agent: &ureq::Agent, method: &str, url: &str, headers: &[(String, String)]) -> ureq::Request {
    let mut req = match method {
        "GET" => agent.get(url),
        "POST" => agent.post(url),
        "PUT" => agent.put(url),
        "DELETE" => agent.delete(url),
        _ => panic!("unsupported HTTP method: {}", method),
    };
    for (key, val) in headers {
        req = req.set(key, val);
    }
    req
}

/// (http/request method url headers body)
/// Blocking HTTP request. Returns response body as a string.
#[janetrs::janet_fn(arity(fix(4)))]
fn request(args: &mut [Janet]) -> Janet {
    let method: JanetString = args[0].try_unwrap().expect("http/request: method must be a string");
    let url: JanetString = args[1].try_unwrap().expect("http/request: url must be a string");

    let method_str = std::str::from_utf8(method.as_bytes()).expect("method is not UTF-8");
    let url_str = std::str::from_utf8(url.as_bytes()).expect("url is not UTF-8");

    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(30))
        .timeout_read(std::time::Duration::from_secs(60))
        .build();

    let headers = collect_headers(args[2]);
    let req = build_request(&agent, method_str, url_str, &headers);

    let response = if args[3].is_nil() {
        req.call()
    } else {
        let body: JanetString = args[3].try_unwrap().expect("http/request: body must be a string");
        let body_str = std::str::from_utf8(body.as_bytes()).expect("body not UTF-8");
        req.send_string(body_str)
    };

    match response {
        Ok(resp) => {
            let body = resp.into_string().unwrap_or_default();
            Janet::from(JanetString::new(body.as_bytes()))
        }
        Err(ureq::Error::Status(code, resp)) => {
            let body = resp.into_string().unwrap_or_default();
            eprintln!("http/request error: status {} — {}", code, body);
            Janet::nil()
        }
        Err(e) => {
            eprintln!("http/request error: {}", e);
            Janet::nil()
        }
    }
}

/// (http/stream method url headers body callback)
/// Blocking streaming HTTP request. Reads response line-by-line, calls callback.
#[janetrs::janet_fn(arity(fix(5)))]
fn stream(args: &mut [Janet]) -> Janet {
    use std::io::BufRead;

    let method: JanetString = args[0].try_unwrap().expect("http/stream: method must be a string");
    let url: JanetString = args[1].try_unwrap().expect("http/stream: url must be a string");
    let callback: janetrs::JanetFunction = args[4].try_unwrap().expect("http/stream: callback must be a function");

    let method_str = std::str::from_utf8(method.as_bytes()).expect("method is not UTF-8");
    let url_str = std::str::from_utf8(url.as_bytes()).expect("url is not UTF-8");

    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(30))
        .build();

    let headers = collect_headers(args[2]);
    let req = build_request(&agent, method_str, url_str, &headers);

    let response = if args[3].is_nil() {
        req.call()
    } else {
        let body: JanetString = args[3].try_unwrap().expect("http/stream: body must be a string");
        let body_str = std::str::from_utf8(body.as_bytes()).expect("body not UTF-8");
        req.send_string(body_str)
    };

    match response {
        Ok(resp) => {
            let reader = resp.into_reader();
            let buf_reader = std::io::BufReader::new(reader);

            for line_result in buf_reader.lines() {
                match line_result {
                    Ok(line) => {
                        let janet_line = Janet::from(JanetString::new(line.as_bytes()));
                        let mut cb = callback.clone();
                        let _ = cb.call(&mut [janet_line]);
                    }
                    Err(_) => break,
                }
            }
            Janet::boolean(true)
        }
        Err(ureq::Error::Status(code, resp)) => {
            let body = resp.into_string().unwrap_or_default();
            eprintln!("http/stream error: status {} — {}", code, body);
            Janet::nil()
        }
        Err(e) => {
            eprintln!("http/stream error: {}", e);
            Janet::nil()
        }
    }
}

/// (http/stream-start method url headers body)
/// Start an HTTP request in a background thread. Returns a stream-id (number)
/// that can be used with http/stream-read and http/stream-stop.
///
/// Returns: stream-id (number) on success, nil on error.
#[janetrs::janet_fn(arity(fix(4)))]
fn stream_start(args: &mut [Janet]) -> Janet {
    use std::io::BufRead;

    init_streams();

    let method: JanetString = args[0].try_unwrap().expect("http/stream-start: method must be a string");
    let url: JanetString = args[1].try_unwrap().expect("http/stream-start: url must be a string");

    let method_str = String::from_utf8_lossy(method.as_bytes()).into_owned();
    let url_str = String::from_utf8_lossy(url.as_bytes()).into_owned();
    let header_pairs = collect_headers(args[2]);

    let body_str: Option<String> = if args[3].is_nil() {
        None
    } else {
        let body: JanetString = args[3].try_unwrap().expect("http/stream-start: body must be a string");
        Some(String::from_utf8_lossy(body.as_bytes()).into_owned())
    };

    let stream_id = NEXT_STREAM_ID.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = mpsc::channel();

    // Store the receiver in the registry
    {
        let mut guard = STREAMS.lock().unwrap();
        if let Some(ref mut map) = *guard {
            map.insert(stream_id, rx);
        }
    }

    // Spawn background thread
    std::thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(30))
            .build();

        let req = build_request(&agent, &method_str, &url_str, &header_pairs);

        let response = match &body_str {
            Some(body) => req.send_string(body),
            None => req.call(),
        };

        match response {
            Ok(resp) => {
                let reader = resp.into_reader();
                let buf_reader = std::io::BufReader::new(reader);

                for line_result in buf_reader.lines() {
                    match line_result {
                        Ok(line) => {
                            if tx.send(StreamEvent::Line(line)).is_err() {
                                break; // receiver dropped (stream-stop called)
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(StreamEvent::Error(e.to_string()));
                            break;
                        }
                    }
                }
                let _ = tx.send(StreamEvent::Done);
            }
            Err(ureq::Error::Status(code, resp)) => {
                let body = resp.into_string().unwrap_or_default();
                let _ = tx.send(StreamEvent::Error(format!("status {} — {}", code, body)));
            }
            Err(e) => {
                let _ = tx.send(StreamEvent::Error(format!("{}", e)));
            }
        }
    });

    Janet::number(stream_id as f64)
}

/// (http/stream-read &opt stream-id)
/// Non-blocking read of the next line from a background stream.
///
/// If stream-id is provided, reads from that specific stream.
/// If omitted, reads from the most recently created stream (backward compat).
///
/// Returns:
///   - string: the next SSE line
///   - :done keyword: stream finished normally
///   - {:type :error :message "..."} table: error occurred
///   - nil: no data available yet
#[janetrs::janet_fn(arity(range(0, 1)))]
fn stream_read(args: &mut [Janet]) -> Janet {
    init_streams();

    // Determine which stream to read from
    let stream_id: Option<u64> = if !args.is_empty() && !args[0].is_nil() {
        let id: f64 = args[0].try_unwrap().expect("http/stream-read: stream-id must be a number");
        Some(id as u64)
    } else {
        // Backward compat: read from the highest-ID stream
        let guard = STREAMS.lock().unwrap();
        guard.as_ref().and_then(|map| map.keys().max().copied())
    };

    let guard = STREAMS.lock().unwrap();
    let map = match guard.as_ref() {
        Some(m) => m,
        None => return Janet::from(JanetKeyword::new(b"done")),
    };

    let sid = match stream_id {
        Some(id) => id,
        None => return Janet::from(JanetKeyword::new(b"done")),
    };

    match map.get(&sid) {
        None => Janet::from(JanetKeyword::new(b"done")),
        Some(rx) => match rx.try_recv() {
            Ok(StreamEvent::Line(line)) => {
                Janet::from(JanetString::new(line.as_bytes()))
            }
            Ok(StreamEvent::Done) => {
                Janet::from(JanetKeyword::new(b"done"))
            }
            Ok(StreamEvent::Error(e)) => {
                let mut table = JanetTable::with_capacity(2);
                table.insert(
                    JanetKeyword::new(b"type"),
                    Janet::from(JanetKeyword::new(b"error")),
                );
                table.insert(
                    JanetKeyword::new(b"message"),
                    Janet::from(JanetString::new(e.as_bytes())),
                );
                Janet::from(table)
            }
            Err(mpsc::TryRecvError::Empty) => Janet::nil(),
            Err(mpsc::TryRecvError::Disconnected) => {
                Janet::from(JanetKeyword::new(b"done"))
            }
        },
    }
}

/// (http/stream-stop &opt stream-id)
/// Cancel a background stream. Drops the receiver, causing the background
/// thread to exit on its next send attempt.
///
/// If stream-id is provided, stops that specific stream.
/// If omitted, stops all streams (backward compat).
#[janetrs::janet_fn(arity(range(0, 1)))]
fn stream_stop(args: &mut [Janet]) -> Janet {
    init_streams();

    if !args.is_empty() && !args[0].is_nil() {
        let id: f64 = args[0].try_unwrap().expect("http/stream-stop: stream-id must be a number");
        let sid = id as u64;
        let mut guard = STREAMS.lock().unwrap();
        if let Some(ref mut map) = *guard {
            map.remove(&sid);
        }
    } else {
        // Backward compat: stop all streams
        let mut guard = STREAMS.lock().unwrap();
        if let Some(ref mut map) = *guard {
            map.clear();
        }
    }

    Janet::boolean(true)
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"request", request_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream", stream_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream-start", stream_start_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream-read", stream_read_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream-stop", stream_stop_c).namespace(c"http"));
}
