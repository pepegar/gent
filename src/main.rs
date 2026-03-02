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

    // Include git hash in cache directory name to invalidate on rebuild
    let git_hash = env!("GIT_HASH");
    let cache_dir_name = format!("gent-janet-{}", git_hash);
    let temp_dir = std::env::temp_dir().join(cache_dir_name);

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

fn print_help() {
    println!("gent - an extensible coding agent built as a lisp machine");
    println!();
    println!("USAGE:");
    println!("    gent [OPTIONS]");
    println!();
    println!("OPTIONS:");
    println!("    -h, --help              Print help information");
    println!("    -V, --version           Print version information");
    println!("    -l, --load <FILE>       Load Janet file at startup");
    println!("    -q, --no-init-file      Skip loading ~/.gent/init.janet and .gent/init.janet");
    println!("        --headless          Run in headless mode (for programmatic use)");
    println!("        --port <PORT>       Port for RPC server (default: 7888 in headless mode)");
    println!("        --sessions-dir <PATH>  Override session history directory (default: ~/.gent/sessions)");
    println!();
    println!("EXAMPLES:");
    println!("    gent                    Start interactive coding session");
    println!("    gent --headless         Start headless RPC server on port 7888");
    println!("    gent --port 8080        Start with RPC server on custom port");
    println!("    gent -l setup.janet     Load custom setup script at startup");
    println!("    gent -q                 Start without loading config files");
    println!("    gent --sessions-dir /tmp/gent-test  Use custom sessions directory");
    println!();
    println!("ENVIRONMENT:");
    println!("    GENT_STAGE             Path to staging script (for development)");
    println!("    GENT_PROFILE           Set to 1 to enable profiling");
    println!("    GENT_SESSIONS_DIR      Override session history directory");
    println!();
    println!("CONFIG FILES:");
    println!("    ~/.gent/init.janet     User configuration (loaded unless -q)");
    println!("    .gent/init.janet       Project configuration (loaded unless -q)");
    println!();
    println!("Once running, you can use slash commands like:");
    println!("    /help                  Show all available commands");
    println!("    /skills                List discovered skills");
    println!("    /tools                 List registered tools");
    println!("    /session               Show current session info");
    println!("    /quit                  Exit gent");
    println!();
    println!("Skills extend gent's capabilities. Place .janet files in .gent/skills/");
    println!("or ~/.gent/skills/ to add domain-specific functionality.");
}

fn print_version() {
    let version = env!("CARGO_PKG_VERSION");
    let git_hash = env!("GIT_HASH");
    println!("gent {} ({})", version, git_hash);
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Parse CLI flags before booting the Janet VM
    let args: Vec<String> = std::env::args().collect();
    let mut load_files: Vec<String> = Vec::new();
    let mut no_init = false;
    let mut headless = false;
    let mut port: Option<u16> = None;
    let mut sessions_dir: Option<String> = None;
    let mut i = 1;

    while i < args.len() {
        match args[i].as_str() {
            "-h" | "--help" => {
                print_help();
                return Ok(());
            }
            "-V" | "--version" => {
                print_version();
                return Ok(());
            }
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
            "--headless" => { headless = true; i += 1; }
            "--port" => {
                if i + 1 < args.len() {
                    port = Some(args[i + 1].parse().unwrap_or_else(|_| {
                        eprintln!("error: --port requires a number");
                        std::process::exit(1);
                    }));
                    i += 2;
                } else {
                    eprintln!("error: --port requires a number argument");
                    std::process::exit(1);
                }
            }
            "--sessions-dir" => {
                if i + 1 < args.len() {
                    sessions_dir = Some(args[i + 1].clone());
                    i += 2;
                } else {
                    eprintln!("error: --sessions-dir requires a path argument");
                    std::process::exit(1);
                }
            }
            arg if arg.starts_with('-') => {
                eprintln!("error: unknown option '{}'", arg);
                eprintln!("Try 'gent --help' for more information.");
                std::process::exit(1);
            }
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
    if headless {
        client.run(r#"(setdyn :gent/headless true)"#)?;
    }
    if let Some(p) = port {
        client.run(format!(r#"(setdyn :gent/port {})"#, p))?;
    }
    // Check for sessions directory override (CLI flag takes precedence over env var)
    let sessions_dir_override = sessions_dir.or_else(|| std::env::var("GENT_SESSIONS_DIR").ok());
    if let Some(dir) = sessions_dir_override {
        let escaped_dir = dir.replace('\\', "\\\\").replace('"', "\\\"");
        client.run(format!(r#"(setdyn :gent/sessions-dir "{}")"#, escaped_dir))?;
    }

    // Load and run boot.janet — from here, Janet takes over
    let boot_path = janet_dir.join("boot.janet");
    let boot_code = std::fs::read_to_string(&boot_path)
        .unwrap_or_else(|e| panic!("failed to read {}: {}", boot_path.display(), e));
    client.run(&boot_code)?;

    Ok(())
}
