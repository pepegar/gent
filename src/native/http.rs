use janetrs::{client::JanetClient, env::CFunOptions, Janet, JanetString, JanetKeyword};

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

    let mut req = match method_str {
        "GET" => ureq::get(url_str),
        "POST" => ureq::post(url_str),
        "PUT" => ureq::put(url_str),
        "DELETE" => ureq::delete(url_str),
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

// TODO: http/stream-to (method url headers body chan)
// Async variant: spawns a thread, makes the request, reads SSE chunks,
// pushes each chunk into a Janet ev/chan.
// Requires: evil_janet channel API + ureq streaming response reader.
// This is the key primitive for streaming LLM responses.

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"request", request_c).namespace(c"http"));
}
