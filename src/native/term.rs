use crossterm::{
    event::{self, Event, KeyCode, KeyEvent, KeyModifiers, MouseEventKind},
    terminal,
};
use janetrs::{
    client::JanetClient, env::CFunOptions, Janet, JanetKeyword, JanetString, JanetTable,
};

/// (term/write text)
/// Writes text to stdout. Flushes immediately.
#[janetrs::janet_fn(arity(fix(1)))]
fn write(args: &mut [Janet]) -> Janet {
    use std::io::Write;

    let text: JanetString = args[0].try_unwrap().expect("term/write expects a string");
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(text.as_bytes()).expect("failed to write");
    handle.flush().expect("failed to flush");

    Janet::nil()
}

/// (term/readline prompt)
/// Blocking: prints prompt, reads a line from stdin, returns it (or nil on EOF).
/// Works in cooked mode only. For raw mode, use term/read-event.
#[janetrs::janet_fn(arity(fix(1)))]
fn readline(args: &mut [Janet]) -> Janet {
    use std::io::{self, BufRead, Write};

    let prompt: JanetString = args[0].try_unwrap().expect("term/readline expects a string");

    {
        let stdout = io::stdout();
        let mut handle = stdout.lock();
        handle.write_all(prompt.as_bytes()).ok();
        handle.flush().ok();
    }

    let stdin = io::stdin();
    let mut line = String::new();
    match stdin.lock().read_line(&mut line) {
        Ok(0) => Janet::nil(),
        Ok(_) => {
            if line.ends_with('\n') {
                line.pop();
                if line.ends_with('\r') {
                    line.pop();
                }
            }
            Janet::from(JanetString::new(line.as_bytes()))
        }
        Err(_) => Janet::nil(),
    }
}

/// (term/enable-raw-mode)
/// Enter raw mode — keypresses are delivered individually via term/read-event.
/// Returns true on success, false if not a TTY.
#[janetrs::janet_fn(arity(fix(0)))]
fn enable_raw_mode(_args: &mut [Janet]) -> Janet {
    match terminal::enable_raw_mode() {
        Ok(()) => Janet::boolean(true),
        Err(_) => Janet::boolean(false),
    }
}

/// (term/disable-raw-mode)
/// Exit raw mode — restores normal line-buffered terminal input.
#[janetrs::janet_fn(arity(fix(0)))]
fn disable_raw_mode(_args: &mut [Janet]) -> Janet {
    terminal::disable_raw_mode().expect("failed to disable raw mode");
    Janet::nil()
}

/// (term/size)
/// Returns {:cols N :rows N} with the current terminal dimensions.
#[janetrs::janet_fn(arity(fix(0)))]
fn size(_args: &mut [Janet]) -> Janet {
    let (cols, rows) = terminal::size().unwrap_or((80, 24));
    let mut table = JanetTable::with_capacity(2);
    table.insert(JanetKeyword::new(b"cols"), Janet::number(cols as f64));
    table.insert(JanetKeyword::new(b"rows"), Janet::number(rows as f64));
    Janet::from(table)
}

/// (term/read-event &opt timeout-ms)
/// Read a terminal event. Blocks until an event is available, or until timeout-ms
/// milliseconds have passed (returns nil on timeout). Without timeout, blocks forever.
///
/// Returns a table:
///   Key press:  {:type :key :key "a" :ctrl false :alt false :shift false}
///   Special:    {:type :key :key :enter}  {:type :key :key :backspace}  {:type :key :key :tab}
///               {:type :key :key :up} :down :left :right :home :end :delete
///               {:type :key :key :page-up} :page-down :escape
///   Resize:     {:type :resize :cols N :rows N}
///   nil on timeout or error
#[janetrs::janet_fn(arity(range(0, 1)))]
fn read_event(args: &mut [Janet]) -> Janet {
    // Optional timeout
    let has_timeout = !args.is_empty() && !args[0].is_nil();

    // Loop until we get a Key, Resize, or Mouse scroll event.
    // Skips FocusGained/Lost, paste, and non-scroll mouse events.
    loop {
        if has_timeout {
            let timeout_ms: f64 = args[0].try_unwrap().expect("timeout must be a number");
            let duration = std::time::Duration::from_millis(timeout_ms as u64);
            match event::poll(duration) {
                Ok(true) => {}
                Ok(false) => return Janet::nil(), // timeout
                Err(_) => return Janet::nil(),
            }
        }

        match event::read() {
            Ok(Event::Key(key_event)) => return key_event_to_janet(key_event),
            Ok(Event::Mouse(mouse_event)) => {
                match mouse_event.kind {
                    MouseEventKind::ScrollUp => {
                        let mut table = JanetTable::with_capacity(2);
                        table.insert(
                            JanetKeyword::new(b"type"),
                            Janet::from(JanetKeyword::new(b"scroll")),
                        );
                        table.insert(
                            JanetKeyword::new(b"direction"),
                            Janet::from(JanetKeyword::new(b"up")),
                        );
                        return Janet::from(table);
                    }
                    MouseEventKind::ScrollDown => {
                        let mut table = JanetTable::with_capacity(2);
                        table.insert(
                            JanetKeyword::new(b"type"),
                            Janet::from(JanetKeyword::new(b"scroll")),
                        );
                        table.insert(
                            JanetKeyword::new(b"direction"),
                            Janet::from(JanetKeyword::new(b"down")),
                        );
                        return Janet::from(table);
                    }
                    _ => continue, // Skip non-scroll mouse events
                }
            }
            Ok(Event::Resize(cols, rows)) => {
                let mut table = JanetTable::with_capacity(3);
                table.insert(
                    JanetKeyword::new(b"type"),
                    Janet::from(JanetKeyword::new(b"resize")),
                );
                table.insert(JanetKeyword::new(b"cols"), Janet::number(cols as f64));
                table.insert(JanetKeyword::new(b"rows"), Janet::number(rows as f64));
                return Janet::from(table);
            }
            Ok(_) => continue, // Skip focus, paste events
            Err(_) => return Janet::nil(),
        }
    }
}

/// (term/suspend)
/// Suspend the process (like ctrl-z in a normal terminal).
/// Disables raw mode, sends SIGTSTP to own process, and when resumed
/// re-enables raw mode. Returns true on success.
#[janetrs::janet_fn(arity(fix(0)))]
fn suspend(_args: &mut [Janet]) -> Janet {
    // 1. Disable raw mode so the terminal is sane while suspended
    let _ = terminal::disable_raw_mode();

    // 2. Leave alternate screen, disable mouse/keyboard protocols, show cursor
    use std::io::Write;
    {
        let stdout = std::io::stdout();
        let mut handle = stdout.lock();
        let _ = handle.write_all(concat!(
            "\x1b[<u",       // pop Kitty keyboard enhancement flags
            "\x1b[?1006l",   // disable SGR mouse mode
            "\x1b[?1000l",   // disable mouse tracking
            "\x1b[r",        // reset scroll region
            "\x1b[?25h",     // show cursor
            "\x1b[?1049l",   // leave alternate screen buffer
            "\n",
        ).as_bytes());
        let _ = handle.flush();
    }

    // 3. Send SIGTSTP to our own process
    #[cfg(unix)]
    {
        unsafe {
            // Restore default SIGTSTP handler (raw mode may have blocked it)
            libc::signal(libc::SIGTSTP, libc::SIG_DFL);
            // Send SIGTSTP to ourselves — this suspends us
            libc::raise(libc::SIGTSTP);
            // When we get here, we've been resumed (SIGCONT)
        }
    }

    // 4. Re-enable raw mode
    let _ = terminal::enable_raw_mode();

    Janet::boolean(true)
}

fn key_event_to_janet(key: KeyEvent) -> Janet {
    let mut table = JanetTable::with_capacity(5);
    table.insert(
        JanetKeyword::new(b"type"),
        Janet::from(JanetKeyword::new(b"key")),
    );

    let key_val = match key.code {
        KeyCode::Char(c) => {
            let mut buf = [0u8; 4];
            let s = c.encode_utf8(&mut buf);
            Janet::from(JanetString::new(s.as_bytes()))
        }
        KeyCode::Enter => Janet::from(JanetKeyword::new(b"enter")),
        KeyCode::Backspace => Janet::from(JanetKeyword::new(b"backspace")),
        KeyCode::Tab => Janet::from(JanetKeyword::new(b"tab")),
        KeyCode::Esc => Janet::from(JanetKeyword::new(b"escape")),
        KeyCode::Up => Janet::from(JanetKeyword::new(b"up")),
        KeyCode::Down => Janet::from(JanetKeyword::new(b"down")),
        KeyCode::Left => Janet::from(JanetKeyword::new(b"left")),
        KeyCode::Right => Janet::from(JanetKeyword::new(b"right")),
        KeyCode::Home => Janet::from(JanetKeyword::new(b"home")),
        KeyCode::End => Janet::from(JanetKeyword::new(b"end")),
        KeyCode::Delete => Janet::from(JanetKeyword::new(b"delete")),
        KeyCode::PageUp => Janet::from(JanetKeyword::new(b"page-up")),
        KeyCode::PageDown => Janet::from(JanetKeyword::new(b"page-down")),
        _ => Janet::nil(),
    };

    table.insert(JanetKeyword::new(b"key"), key_val);
    table.insert(
        JanetKeyword::new(b"ctrl"),
        Janet::boolean(key.modifiers.contains(KeyModifiers::CONTROL)),
    );
    table.insert(
        JanetKeyword::new(b"alt"),
        Janet::boolean(key.modifiers.contains(KeyModifiers::ALT)),
    );
    table.insert(
        JanetKeyword::new(b"shift"),
        Janet::boolean(key.modifiers.contains(KeyModifiers::SHIFT)),
    );

    Janet::from(table)
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"write", write_c).namespace(c"term"));
    client.add_c_fn(CFunOptions::new(c"readline", readline_c).namespace(c"term"));
    client.add_c_fn(CFunOptions::new(c"enable-raw-mode", enable_raw_mode_c).namespace(c"term"));
    client.add_c_fn(CFunOptions::new(c"disable-raw-mode", disable_raw_mode_c).namespace(c"term"));
    client.add_c_fn(CFunOptions::new(c"size", size_c).namespace(c"term"));
    client.add_c_fn(CFunOptions::new(c"read-event", read_event_c).namespace(c"term"));
    client.add_c_fn(CFunOptions::new(c"suspend", suspend_c).namespace(c"term"));
}
