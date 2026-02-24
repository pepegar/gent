mod native;

use janetrs::client::JanetClient;
use std::path::PathBuf;

/// Find the `janet/` directory containing our scripts.
/// Looks relative to CWD first, then relative to the executable.
/// If neither exists, creates a temporary directory with embedded Janet code.
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
    
    // If we're in a packaged environment, extract embedded Janet code
    #[cfg(feature = "embedded")]
    {
        extract_embedded_janet_code()
    }
    #[cfg(not(feature = "embedded"))]
    {
        panic!("could not find janet/ directory (looked in {:?} and {:?})", cwd, exe_dir);
    }
}

#[cfg(feature = "embedded")]
fn extract_embedded_janet_code() -> PathBuf {
    use std::fs;
    
    let temp_dir = std::env::temp_dir().join("gent-janet");
    
    // Check if already extracted (use boot.janet as marker)
    if temp_dir.join("boot.janet").exists() {
        return temp_dir;
    }
    
    // Remove stale/incomplete extraction
    let _ = fs::remove_dir_all(&temp_dir);
    fs::create_dir_all(&temp_dir).expect("failed to create temp janet dir");
    
    // Write all embedded Janet files
    include!(concat!(env!("OUT_DIR"), "/embedded_janet.rs"));
    
    temp_dir
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse CLI flags before booting the Janet VM
    let args: Vec<String> = std::env::args().collect();
    let mut load_files: Vec<String> = Vec::new();
    let mut no_init = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "-l" | "--load" => {
                if i + 1 < args.len() {
                    load_files.push(args[i + 1].clone());
                    i += 2;
                } else {
                    eprintln!("error: -l requires a file argument");
                    std::process::exit(1);
                }
            }
            "-q" | "--no-init-file" => { no_init = true; i += 1; }
            _ => { i += 1; }
        }
    }

    let mut client = JanetClient::init_with_default_env()?;

    // Register native functions (the "syscalls" of the machine)
    native::register(&mut client);

    // Point Janet's module system at our scripts directory
    let janet_dir = find_janet_dir();
    let janet_dir_str = janet_dir.to_str().expect("janet dir path is not valid UTF-8");
    client.run(format!(
        r#"(setdyn :syspath "{janet_dir_str}")"#
    ))?;

    // Pass CLI flags to Janet via dynamic variables
    if no_init {
        client.run(r#"(setdyn :gent/no-init true)"#)?;
    }
    if !load_files.is_empty() {
        let janet_array = load_files.iter()
            .map(|f| format!("\"{}\"", f.replace('\\', "\\\\").replace('"', "\\\"")))
            .collect::<Vec<_>>().join(" ");
        client.run(format!(r#"(setdyn :gent/load-files @[{}])"#, janet_array))?;
    }

    // Load and run boot.janet — from here, Janet takes over
    let boot_path = janet_dir.join("boot.janet");
    let boot_code = std::fs::read_to_string(&boot_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", boot_path.display(), e));
    client.run(&boot_code)?;

    Ok(())
}
