use std::env;
use std::fs;
use std::path::Path;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = env::var_os("OUT_DIR").unwrap();
    let dest_path = Path::new(&out_dir).join("embedded_janet.rs");
    
    // Only embed if the embedded feature is enabled
    if env::var("CARGO_FEATURE_EMBEDDED").is_ok() {
        let mut embedded_code = String::new();
        embedded_code.push_str("{\n");
        embedded_code.push_str("    use std::fs;\n");
        embedded_code.push_str("    let temp_dir = std::env::temp_dir().join(\"gent-janet\");\n");
        embedded_code.push_str("    if temp_dir.exists() { return temp_dir; }\n");
        embedded_code.push_str("    fs::create_dir_all(&temp_dir).expect(\"failed to create temp janet dir\");\n\n");
        
        embed_directory("janet", &mut embedded_code)?;
        
        embedded_code.push_str("    temp_dir\n");
        embedded_code.push_str("}\n");
        
        fs::write(&dest_path, embedded_code)?;
    } else {
        // Create empty file if not embedding
        fs::write(&dest_path, "{ panic!(\"embedded feature not enabled\") }\n")?;
    }
    
    // Tell cargo to re-run if janet files change
    println!("cargo:rerun-if-changed=janet/");
    Ok(())
}

fn embed_directory(dir: &str, code: &mut String) -> std::io::Result<()> {
    use std::fs;
    
    let entries = fs::read_dir(dir)?;
    
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        
        if path.is_dir() {
            let dir_name = path.file_name().unwrap().to_str().unwrap();
            let sub_dir = format!("{}/{}", dir, dir_name);
            embed_directory(&sub_dir, code)?;
        } else if path.extension().map_or(false, |ext| ext == "janet") {
            let relative_path = path.strip_prefix("janet/").unwrap();
            
            let content = fs::read_to_string(&path)?;
            // Escape the content for inclusion in Rust code
            let escaped_content = content.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
            
            // Only create parent directory if it's not empty
            if let Some(parent) = relative_path.parent() {
                if !parent.as_os_str().is_empty() {
                    code.push_str(&format!(
                        "    fs::create_dir_all(temp_dir.join(\"{}\")).ok();\n",
                        parent.to_str().unwrap()
                    ));
                }
            }
            
            code.push_str(&format!(
                "    fs::write(temp_dir.join(\"{}\"), \"{}\").expect(\"failed to write {}\");\n",
                relative_path.to_str().unwrap(),
                escaped_content,
                relative_path.to_str().unwrap()
            ));
        }
    }
    
    Ok(())
}