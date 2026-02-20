mod native;

use janetrs::client::JanetClient;
use std::path::PathBuf;

/// Find the `janet/` directory containing our scripts.
/// Looks relative to CWD first, then relative to the executable.
fn find_janet_dir() -> PathBuf {
    // Relative to CWD
    let cwd = std::env::current_dir().expect("failed to get cwd");
    let candidate = cwd.join("janet");
    if candidate.exists() {
        return candidate;
    }
    // Relative to the executable
    let exe = std::env::current_exe().expect("failed to get exe path");
    let exe_dir = exe.parent().expect("exe has no parent dir");
    let candidate = exe_dir.join("janet");
    if candidate.exists() {
        return candidate;
    }
    panic!("could not find janet/ directory (looked in {:?} and {:?})", cwd, exe_dir);
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut client = JanetClient::init_with_default_env()?;

    // Register native functions (the "syscalls" of the machine)
    native::register(&mut client);

    // Point Janet's module system at our scripts directory
    let janet_dir = find_janet_dir();
    let janet_dir_str = janet_dir.to_str().expect("janet dir path is not valid UTF-8");
    client.run(format!(
        r#"(setdyn :syspath "{janet_dir_str}")"#
    ))?;

    // Load and run boot.janet — from here, Janet takes over
    let boot_path = janet_dir.join("boot.janet");
    let boot_code = std::fs::read_to_string(&boot_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", boot_path.display(), e));
    client.run(&boot_code)?;

    Ok(())
}
