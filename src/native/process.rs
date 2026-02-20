use janetrs::{client::JanetClient, env::CFunOptions, Janet, JanetString, JanetTable, JanetKeyword};

/// (process/exec cmd &opt args)
/// Execute a command and return a table with :stdout, :stderr, :status.
///
/// - cmd: string (the command to run)
/// - args: optional tuple/array of string arguments
///
/// Returns: {:stdout "..." :stderr "..." :status 0}
#[janetrs::janet_fn(arity(range(1)))]
fn exec(args: &mut [Janet]) -> Janet {
    let cmd: JanetString = args[0].try_unwrap().expect("process/exec: cmd must be a string");
    let cmd_str = std::str::from_utf8(cmd.as_bytes()).expect("cmd is not UTF-8");

    let mut command = std::process::Command::new(cmd_str);

    // Add arguments if provided
    if args.len() > 1 && !args[1].is_nil() {
        let cmd_args: janetrs::JanetTuple = args[1].try_unwrap().expect("process/exec: args must be a tuple");
        for arg in cmd_args.iter() {
            let s: JanetString = arg.try_unwrap().expect("process/exec: each arg must be a string");
            let s_str = std::str::from_utf8(s.as_bytes()).expect("arg is not UTF-8");
            command.arg(s_str);
        }
    }

    let output = command
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output();

    match output {
        Ok(out) => {
            let mut result = JanetTable::with_capacity(3);
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            let status = out.status.code().unwrap_or(-1);

            result.insert(
                JanetKeyword::new("stdout"),
                JanetString::new(stdout.as_bytes()),
            );
            result.insert(
                JanetKeyword::new("stderr"),
                JanetString::new(stderr.as_bytes()),
            );
            result.insert(JanetKeyword::new("status"), Janet::number(status as f64));

            Janet::from(result)
        }
        Err(e) => {
            let mut result = JanetTable::with_capacity(3);
            result.insert(JanetKeyword::new("stdout"), JanetString::new(b""));
            result.insert(
                JanetKeyword::new("stderr"),
                JanetString::new(format!("failed to execute: {}", e).as_bytes()),
            );
            result.insert(JanetKeyword::new("status"), Janet::number(-1.0));
            Janet::from(result)
        }
    }
}

pub fn register(client: &mut JanetClient) {
    client.add_c_fn(CFunOptions::new(c"exec", exec_c).namespace(c"process"));
}
