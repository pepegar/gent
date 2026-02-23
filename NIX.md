# Nix Packaging for gent

This flake provides two different packaging approaches for gent:

## Installation

### Standalone binary (recommended)
This creates a single self-contained binary with all Janet code embedded:

```sh
# Install temporarily 
nix run github:pepegar/gent

# Install to profile
nix profile install github:pepegar/gent

# Or build locally
nix build .#gent
```

### Binary with bundled Janet directory
This uses the traditional approach where the binary and Janet source are separate:

```sh
nix build .#gent-bundled
```

## Development

Enter the development shell:

```sh
nix develop
```

This provides:
- Rust toolchain
- Janet CLI (for testing)
- cargo-watch, cargo-edit
- All necessary build dependencies

## Architecture

- **Embedded version** (`gent`): Uses Cargo feature `embedded` to compile all Janet source code directly into the Rust binary. Creates a truly standalone executable.
- **Bundled version** (`gent-bundled`): Ships the binary alongside the `janet/` directory, using a wrapper script to set up paths correctly.

Both approaches work identically at runtime - the embedded version just extracts the Janet code to a temporary directory on first run.

## Building locally

```sh
# Regular build (needs janet/ directory present)
cargo build

# Standalone binary with embedded Janet code
cargo build --features embedded --release

# Via Nix (embedded by default)
nix build
```

## Testing

```sh
# Run the full test suite
janet janet/test/run.janet

# Or via Nix
nix develop -c janet janet/test/run.janet
```