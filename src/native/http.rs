use janetrs::{client::JanetClient, env::CFunOptions, Janet, JanetString, JanetKeyword, JanetTable};
use std::sync::{mpsc, Mutex};

// ── Background stream state ──────────────────────────────────────────────

enum StreamEvent {
    Line(String),
    Done,
    Error(String),
}

static STREAM_RX: Mutex<Option<mpsc::Receiver<StreamEvent>>> = Mutex::new(None);

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

/// (http/request method url headers body)
/// Blocking HTTP request. Returns response body as a string.
///
/// - method: string ("GET", "POST", etc.)
/// - url: string
/// - headers: janet table {:header-name "value" ...}
/// - body: string or nil
///
/// Returns: string (response body)
///
/// This is the blocking variant. The async variant (http/stream-to) will push
/// SSE chunks into a Janet ev/chan from a background thread.
#[janetrs::janet_fn(arity(fix(4)))]
fn request(args: &mut [Janet]) -> Janet {
    let method: JanetString = args[0].try_unwrap().expect("http/request: method must be a string");
    let url: JanetString = args[1].try_unwrap().expect("http/request: url must be a string");
    // args[2] = headers table
    // args[3] = body string or nil

    let method_str = std::str::from_utf8(method.as_bytes()).expect("method is not UTF-8");
    let url_str = std::str::from_utf8(url.as_bytes()).expect("url is not UTF-8");

    // Build agent with timeouts (30s connect, 60s read)
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(30))
        .timeout_read(std::time::Duration::from_secs(60))
        .build();

    let mut req = match method_str {
        "GET" => agent.get(url_str),
        "POST" => agent.post(url_str),
        "PUT" => agent.put(url_str),
        "DELETE" => agent.delete(url_str),
        _ => panic!("http/request: unsupported method {}", method_str),
    };

    // Extract headers from Janet table or struct
    if !args[2].is_nil() {
        // Collect header pairs — handles both tables and structs
        let mut header_pairs: Vec<(String, String)> = Vec::new();

        if let Ok(headers) = args[2].try_unwrap::<janetrs::JanetTable>() {
            for (k, v) in headers.iter() {
                let key = janet_val_to_str(*k, "header key");
                let val = janet_val_to_str(*v, "header value");
                header_pairs.push((key, val));
            }
        } else if let Ok(headers) = args[2].try_unwrap::<janetrs::JanetStruct>() {
            for (k, v) in headers.iter() {
                let key = janet_val_to_str(*k, "header key");
                let val = janet_val_to_str(*v, "header value");
                header_pairs.push((key, val));
            }
        } else {
            panic!("http/request: headers must be a table or struct");
        }

        for (key, val) in &header_pairs {
            req = req.set(key, val);
        }
    }

    // Send request with optional body
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
/// Streaming HTTP request. Reads the response body line-by-line and calls
/// `callback` with each line as a Janet string.
///
/// - method: string ("GET", "POST", etc.)
/// - url: string
/// - headers: janet table {:header-name "value" ...}
/// - body: string or nil
/// - callback: janet function — called with (callback line) for each line
///
/// Returns: true on success, nil on error.
///
/// This is the key primitive for SSE streaming from LLMs.
#[janetrs::janet_fn(arity(fix(5)))]
fn stream(args: &mut [Janet]) -> Janet {
    use std::io::BufRead;

    let method: JanetString = args[0].try_unwrap().expect("http/stream: method must be a string");
    let url: JanetString = args[1].try_unwrap().expect("http/stream: url must be a string");
    // args[2] = headers table
    // args[3] = body string or nil
    let callback: janetrs::JanetFunction = args[4].try_unwrap().expect("http/stream: callback must be a function");

    let method_str = std::str::from_utf8(method.as_bytes()).expect("method is not UTF-8");
    let url_str = std::str::from_utf8(url.as_bytes()).expect("url is not UTF-8");

    // Build agent with timeouts (30s connect, no read timeout for streaming)
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(30))
        .build();

    let mut req = match method_str {
        "GET" => agent.get(url_str),
        "POST" => agent.post(url_str),
        "PUT" => agent.put(url_str),
        "DELETE" => agent.delete(url_str),
        _ => panic!("http/stream: unsupported method {}", method_str),
    };

    // Extract headers from Janet table or struct
    if !args[2].is_nil() {
        let mut header_pairs: Vec<(String, String)> = Vec::new();

        if let Ok(headers) = args[2].try_unwrap::<janetrs::JanetTable>() {
            for (k, v) in headers.iter() {
                let key = janet_val_to_str(*k, "header key");
                let val = janet_val_to_str(*v, "header value");
                header_pairs.push((key, val));
            }
        } else if let Ok(headers) = args[2].try_unwrap::<janetrs::JanetStruct>() {
            for (k, v) in headers.iter() {
                let key = janet_val_to_str(*k, "header key");
                let val = janet_val_to_str(*v, "header value");
                header_pairs.push((key, val));
            }
        } else {
            panic!("http/stream: headers must be a table or struct");
        }

        for (key, val) in &header_pairs {
            req = req.set(key, val);
        }
    }

    // Send request with optional body
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
                        // Call the Janet callback with this line
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
/// Start an HTTP request in a background thread. Response lines are buffered
/// and can be read non-blockingly with http/stream-read.
///
/// Returns true on success (request started), nil on error.
#[janetrs::janet_fn(arity(fix(4)))]
fn stream_start(args: &mut [Janet]) -> Janet {
    use std::io::BufRead;

    let method: JanetString = args[0].try_unwrap().expect("http/stream-start: method must be a string");
    let url: JanetString = args[1].try_unwrap().expect("http/stream-start: url must be a string");

    let method_str = String::from_utf8_lossy(method.as_bytes()).into_owned();
    let url_str = String::from_utf8_lossy(url.as_bytes()).into_owned();

    // Collect headers into owned strings
    let mut header_pairs: Vec<(String, String)> = Vec::new();
    if !args[2].is_nil() {
        if let Ok(headers) = args[2].try_unwrap::<janetrs::JanetTable>() {
            for (k, v) in headers.iter() {
                let key = janet_val_to_str(*k, "header key");
                let val = janet_val_to_str(*v, "header value");
                header_pairs.push((key, val));
            }
        } else if let Ok(headers) = args[2].try_unwrap::<janetrs::JanetStruct>() {
            for (k, v) in headers.iter() {
                let key = janet_val_to_str(*k, "header key");
                let val = janet_val_to_str(*v, "header value");
                header_pairs.push((key, val));
            }
        } else {
            panic!("http/stream-start: headers must be a table or struct");
        }
    }

    // Collect body into owned string
    let body_str: Option<String> = if args[3].is_nil() {
        None
    } else {
        let body: JanetString = args[3].try_unwrap().expect("http/stream-start: body must be a string");
        Some(String::from_utf8_lossy(body.as_bytes()).into_owned())
    };

    let (tx, rx) = mpsc::channel();

    // Store the receiver globally
    {
        let mut guard = STREAM_RX.lock().unwrap();
        *guard = Some(rx);
    }

    // Spawn background thread
    std::thread::spawn(move || {
        // Build agent with timeouts (30s connect, no read timeout for streaming)
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(30))
            .build();

        let mut req = match method_str.as_str() {
            "GET" => agent.get(&url_str),
            "POST" => agent.post(&url_str),
            "PUT" => agent.put(&url_str),
            "DELETE" => agent.delete(&url_str),
            _ => {
                let _ = tx.send(StreamEvent::Error(format!("unsupported method {}", method_str)));
                return;
            }
        };

        for (key, val) in &header_pairs {
            req = req.set(key, val);
        }

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

    Janet::boolean(true)
}

/// (http/stream-read)
/// Non-blocking read of the next line from the background stream.
///
/// Returns:
///   - string: the next SSE line
///   - :done keyword: stream finished normally
///   - {:type :error :message "..."} table: error occurred
///   - nil: no data available yet
#[janetrs::janet_fn(arity(fix(0)))]
fn stream_read(_args: &mut [Janet]) -> Janet {
    let guard = STREAM_RX.lock().unwrap();
    match guard.as_ref() {
        None => Janet::from(JanetKeyword::new(b"done")), // no active stream
        Some(rx) => {
            match rx.try_recv() {
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
            }
        }
    }
}

/// (http/stream-stop)
/// Cancel the background stream. Drops the receiver, causing the background
/// thread to exit on its next send attempt.
#[janetrs::janet_fn(arity(fix(0)))]
fn stream_stop(_args: &mut [Janet]) -> Janet {
    let mut guard = STREAM_RX.lock().unwrap();
    *guard = None;
    Janet::boolean(true)
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"request", request_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream", stream_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream-start", stream_start_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream-read", stream_read_c).namespace(c"http"));
    client.add_c_fn(CFunOptions::new(c"stream-stop", stream_stop_c).namespace(c"http"));
}
