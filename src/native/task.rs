//! Unified background task system.
//!
//! Provides a single abstraction for all async work: HTTP requests,
//! SSE streaming, and process execution. Results flow through a single
//! channel that the main loop polls with `task/poll`.
//!
//! Janet API:
//!   (task/start :stream {:method "POST" :url "..." :headers {} :body "..."})
//!   (task/start :http {:method "GET" :url "..." :headers {} :body nil})
//!   (task/start :process {:cmd "bash" :args ["-c" "ls"]})
//!   (task/poll)   => @[{:id N :type :line :data "..."} ...]
//!   (task/cancel task-id)

use janetrs::{
    client::JanetClient, env::CFunOptions, Janet, JanetArray, JanetKeyword, JanetString,
    JanetTable,
};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};

// ── Task event types ──────────────────────────────────────────

enum TaskEvent {
    Line { id: u64, data: String },
    Done { id: u64, result: String },
    Error { id: u64, message: String },
}

// ── Global state ──────────────────────────────────────────────

static NEXT_TASK_ID: AtomicU64 = AtomicU64::new(1);

struct TaskSystem {
    tx: mpsc::Sender<TaskEvent>,
    cancel_flags: HashMap<u64, Arc<AtomicBool>>,
}

static SYSTEM: Mutex<Option<TaskSystem>> = Mutex::new(None);
static RX: Mutex<Option<mpsc::Receiver<TaskEvent>>> = Mutex::new(None);

fn init_system() {
    let mut sys = SYSTEM.lock().unwrap();
    if sys.is_none() {
        let (tx, rx) = mpsc::channel();
        *sys = Some(TaskSystem {
            tx,
            cancel_flags: HashMap::new(),
        });
        let mut rx_guard = RX.lock().unwrap();
        *rx_guard = Some(rx);
    }
}

// ── Helpers (shared with http.rs) ─────────────────────────────

fn janet_val_to_string(val: Janet, ctx: &str) -> String {
    if let Ok(s) = val.try_unwrap::<JanetString>() {
        String::from_utf8_lossy(s.as_bytes()).into_owned()
    } else if let Ok(kw) = val.try_unwrap::<JanetKeyword>() {
        String::from_utf8_lossy(kw.as_bytes()).into_owned()
    } else {
        panic!("task: {} must be a string or keyword", ctx);
    }
}

fn collect_headers(headers_val: Janet) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    if headers_val.is_nil() {
        return pairs;
    }
    if let Ok(headers) = headers_val.try_unwrap::<JanetTable>() {
        for (k, v) in headers.iter() {
            pairs.push((
                janet_val_to_string(*k, "header key"),
                janet_val_to_string(*v, "header value"),
            ));
        }
    } else if let Ok(headers) = headers_val.try_unwrap::<janetrs::JanetStruct>() {
        for (k, v) in headers.iter() {
            pairs.push((
                janet_val_to_string(*k, "header key"),
                janet_val_to_string(*v, "header value"),
            ));
        }
    }
    pairs
}

/// Get a value from a JanetTable by keyword, returning Janet::nil() if missing.
fn spec_get(spec: &JanetTable, key: &[u8]) -> Janet {
    spec.get(JanetKeyword::new(key))
        .map(|v| *v)
        .unwrap_or(Janet::nil())
}

fn build_request(
    agent: &ureq::Agent,
    method: &str,
    url: &str,
    headers: &[(String, String)],
) -> ureq::Request {
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

// ── Task: Stream ──────────────────────────────────────────────

fn spawn_stream_task(
    id: u64,
    tx: mpsc::Sender<TaskEvent>,
    cancel: Arc<AtomicBool>,
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
) {
    std::thread::spawn(move || {
        use std::io::BufRead;

        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(30))
            .build();

        let req = build_request(&agent, &method, &url, &headers);

        let response = match &body {
            Some(b) => req.send_string(b),
            None => req.call(),
        };

        match response {
            Ok(resp) => {
                let reader = resp.into_reader();
                let buf_reader = std::io::BufReader::new(reader);

                for line_result in buf_reader.lines() {
                    if cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    match line_result {
                        Ok(line) => {
                            if tx.send(TaskEvent::Line { id, data: line }).is_err() {
                                break;
                            }
                        }
                        Err(e) => {
                            let _ = tx.send(TaskEvent::Error {
                                id,
                                message: e.to_string(),
                            });
                            return;
                        }
                    }
                }
                let _ = tx.send(TaskEvent::Done {
                    id,
                    result: String::new(),
                });
            }
            Err(ureq::Error::Status(code, resp)) => {
                let body = resp.into_string().unwrap_or_default();
                let _ = tx.send(TaskEvent::Error {
                    id,
                    message: format!("status {} — {}", code, body),
                });
            }
            Err(e) => {
                let _ = tx.send(TaskEvent::Error {
                    id,
                    message: format!("{}", e),
                });
            }
        }
    });
}

// ── Task: HTTP ────────────────────────────────────────────────

fn spawn_http_task(
    id: u64,
    tx: mpsc::Sender<TaskEvent>,
    _cancel: Arc<AtomicBool>,
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Option<String>,
) {
    std::thread::spawn(move || {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(std::time::Duration::from_secs(30))
            .timeout_read(std::time::Duration::from_secs(60))
            .build();

        let req = build_request(&agent, &method, &url, &headers);

        let response = match &body {
            Some(b) => req.send_string(b),
            None => req.call(),
        };

        match response {
            Ok(resp) => {
                let result = resp.into_string().unwrap_or_default();
                let _ = tx.send(TaskEvent::Done { id, result });
            }
            Err(ureq::Error::Status(code, resp)) => {
                let body = resp.into_string().unwrap_or_default();
                let _ = tx.send(TaskEvent::Error {
                    id,
                    message: format!("status {} — {}", code, body),
                });
            }
            Err(e) => {
                let _ = tx.send(TaskEvent::Error {
                    id,
                    message: format!("{}", e),
                });
            }
        }
    });
}

// ── Task: Process ─────────────────────────────────────────────

fn spawn_process_task(
    id: u64,
    tx: mpsc::Sender<TaskEvent>,
    _cancel: Arc<AtomicBool>,
    cmd: String,
    args: Vec<String>,
) {
    std::thread::spawn(move || {
        let output = std::process::Command::new(&cmd)
            .args(&args)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .output();

        match output {
            Ok(out) => {
                let stdout = String::from_utf8_lossy(&out.stdout);
                let stderr = String::from_utf8_lossy(&out.stderr);
                let status = out.status.code().unwrap_or(-1);
                let result =
                    format!("exit code: {}\nstdout:\n{}\nstderr:\n{}", status, stdout, stderr);
                let _ = tx.send(TaskEvent::Done { id, result });
            }
            Err(e) => {
                let _ = tx.send(TaskEvent::Error {
                    id,
                    message: format!("failed to execute: {}", e),
                });
            }
        }
    });
}

// ── Janet API ─────────────────────────────────────────────────

/// (task/start type spec)
/// Start a background task. Returns task-id (number).
///
/// Types:
///   :stream  {:method :url :headers :body}
///   :http    {:method :url :headers :body}
///   :process {:cmd :args}
#[janetrs::janet_fn(arity(fix(2)))]
fn start(args: &mut [Janet]) -> Janet {
    init_system();

    let task_type: JanetKeyword = args[0]
        .try_unwrap()
        .expect("task/start: type must be a keyword");
    let spec: JanetTable = args[1]
        .try_unwrap()
        .expect("task/start: spec must be a table");

    let type_str = std::str::from_utf8(task_type.as_bytes()).expect("type not UTF-8");
    let task_id = NEXT_TASK_ID.fetch_add(1, Ordering::SeqCst);

    let cancel = Arc::new(AtomicBool::new(false));

    let tx = {
        let mut sys = SYSTEM.lock().unwrap();
        let system = sys.as_mut().expect("task system not initialized");
        system.cancel_flags.insert(task_id, cancel.clone());
        system.tx.clone()
    };

    match type_str {
        "stream" => {
            let method = janet_val_to_string(
                spec_get(&spec, b"method"),
                "method",
            );
            let url = janet_val_to_string(
                spec_get(&spec, b"url"),
                "url",
            );
            let headers_val = spec_get(&spec, b"headers");
            let headers = collect_headers(headers_val);
            let body_val = spec_get(&spec, b"body");
            let body = if body_val.is_nil() {
                None
            } else {
                Some(janet_val_to_string(body_val, "body"))
            };
            spawn_stream_task(task_id, tx, cancel, method, url, headers, body);
        }
        "http" => {
            let method = janet_val_to_string(
                spec_get(&spec, b"method"),
                "method",
            );
            let url = janet_val_to_string(
                spec_get(&spec, b"url"),
                "url",
            );
            let headers_val = spec_get(&spec, b"headers");
            let headers = collect_headers(headers_val);
            let body_val = spec_get(&spec, b"body");
            let body = if body_val.is_nil() {
                None
            } else {
                Some(janet_val_to_string(body_val, "body"))
            };
            spawn_http_task(task_id, tx, cancel, method, url, headers, body);
        }
        "process" => {
            let cmd = janet_val_to_string(
                spec_get(&spec, b"cmd"),
                "cmd",
            );
            let args_val = spec_get(&spec, b"args");
            let task_args = if args_val.is_nil() {
                Vec::new()
            } else {
                let arr: janetrs::JanetTuple =
                    args_val.try_unwrap().expect("task/start: args must be a tuple/array");
                arr.iter()
                    .map(|a| janet_val_to_string(*a, "arg"))
                    .collect()
            };
            spawn_process_task(task_id, tx, cancel, cmd, task_args);
        }
        _ => panic!("task/start: unknown type :{}", type_str),
    }

    Janet::number(task_id as f64)
}

/// (task/poll)
/// Non-blocking poll of all completed task events.
/// Returns an array of event tables:
///   {:id N :type :line :data "..."}
///   {:id N :type :done :result "..."}
///   {:id N :type :error :message "..."}
#[janetrs::janet_fn(arity(fix(0)))]
fn poll(_args: &mut [Janet]) -> Janet {
    init_system();

    let rx_guard = RX.lock().unwrap();
    let rx = match rx_guard.as_ref() {
        Some(r) => r,
        None => return Janet::from(JanetArray::new()),
    };

    let mut results = JanetArray::new();

    loop {
        match rx.try_recv() {
            Ok(event) => {
                let mut table = JanetTable::with_capacity(4);
                match event {
                    TaskEvent::Line { id, data } => {
                        table.insert(
                            JanetKeyword::new(b"id"),
                            Janet::number(id as f64),
                        );
                        table.insert(
                            JanetKeyword::new(b"type"),
                            Janet::from(JanetKeyword::new(b"line")),
                        );
                        table.insert(
                            JanetKeyword::new(b"data"),
                            Janet::from(JanetString::new(data.as_bytes())),
                        );
                    }
                    TaskEvent::Done { id, result } => {
                        table.insert(
                            JanetKeyword::new(b"id"),
                            Janet::number(id as f64),
                        );
                        table.insert(
                            JanetKeyword::new(b"type"),
                            Janet::from(JanetKeyword::new(b"done")),
                        );
                        table.insert(
                            JanetKeyword::new(b"result"),
                            Janet::from(JanetString::new(result.as_bytes())),
                        );

                        // Clean up cancel flag
                        if let Ok(mut sys) = SYSTEM.lock() {
                            if let Some(ref mut s) = *sys {
                                s.cancel_flags.remove(&id);
                            }
                        }
                    }
                    TaskEvent::Error { id, message } => {
                        table.insert(
                            JanetKeyword::new(b"id"),
                            Janet::number(id as f64),
                        );
                        table.insert(
                            JanetKeyword::new(b"type"),
                            Janet::from(JanetKeyword::new(b"error")),
                        );
                        table.insert(
                            JanetKeyword::new(b"message"),
                            Janet::from(JanetString::new(message.as_bytes())),
                        );

                        // Clean up cancel flag
                        if let Ok(mut sys) = SYSTEM.lock() {
                            if let Some(ref mut s) = *sys {
                                s.cancel_flags.remove(&id);
                            }
                        }
                    }
                }
                results.push(Janet::from(table));
            }
            Err(mpsc::TryRecvError::Empty) => break,
            Err(mpsc::TryRecvError::Disconnected) => break,
        }
    }

    Janet::from(results)
}

/// (task/cancel task-id)
/// Cancel a background task. Sets the cancel flag so the task thread exits.
#[janetrs::janet_fn(arity(fix(1)))]
fn cancel(args: &mut [Janet]) -> Janet {
    init_system();

    let id: f64 = args[0]
        .try_unwrap()
        .expect("task/cancel: task-id must be a number");
    let task_id = id as u64;

    let mut sys = SYSTEM.lock().unwrap();
    if let Some(ref mut system) = *sys {
        if let Some(flag) = system.cancel_flags.get(&task_id) {
            flag.store(true, Ordering::Relaxed);
        }
        system.cancel_flags.remove(&task_id);
    }

    Janet::boolean(true)
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"start", start_c).namespace(c"task"));
    client.add_c_fn(CFunOptions::new(c"poll", poll_c).namespace(c"task"));
    client.add_c_fn(CFunOptions::new(c"cancel", cancel_c).namespace(c"task"));
}
