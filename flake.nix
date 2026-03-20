{
  description = "gent - An extensible coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    parinfer-rust = {
      url = "github:eraserhd/parinfer-rust";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    tui-wright = {
      url = "github:pepegar/tui-wright";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agg = {
      url = "github:asciinema/agg";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    rust-overlay,
    parinfer-rust,
    tui-wright,
    agg,
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      overlays = [(import rust-overlay)];
      pkgs = import nixpkgs {
        inherit system overlays;
      };

      rustToolchain = pkgs.rust-bin.stable.latest.default.override {
        extensions = ["rust-src" "rustfmt"];
      };

      # Build-time dependencies
      nativeBuildInputs = with pkgs; [
        rustToolchain
        pkg-config
      ] ++ lib.optionals stdenv.isLinux [
        # Linux build dependencies for bindgen
        libclang
        llvmPackages.clang
      ];

      # Runtime dependencies
      buildInputs = with pkgs;
        lib.optionals stdenv.isDarwin [
          # Modern Darwin framework paths
          apple-sdk
          libiconv
        ]
        ++ lib.optionals stdenv.isLinux [
          # Linux dependencies for bindgen/libclang
          libclang.lib
        ];

      # Common package attributes
      commonAttrs = {
        pname = "gent";
        version = "0.1.0";
        src = ./.;
        cargoLock = {
          lockFile = ./Cargo.lock;
        };
        inherit nativeBuildInputs buildInputs;
        # Pass git revision to build.rs
        GIT_HASH = self.shortRev or "dirty";
        # Set up environment for bindgen on Linux
        LIBCLANG_PATH = "${pkgs.libclang.lib}/lib";
        BINDGEN_EXTRA_CLANG_ARGS = pkgs.lib.optionalString pkgs.stdenv.isLinux
          "-I${pkgs.glibc.dev}/include";
        meta = with pkgs.lib; {
          description = "An extensible coding agent built as a lisp machine";
          homepage = "https://github.com/pepegar/gent";
          license = licenses.mit; # Adjust as needed
          maintainers = [];
          platforms = platforms.all;
        };
      };
    in {
      packages = rec {
        # Standalone binary with embedded Janet code (recommended)
        gent-embedded = pkgs.rustPlatform.buildRustPackage (commonAttrs
          // {
            buildFeatures = ["embedded"];
            pname = "gent-embedded";
          });

        # Traditional approach: binary + Janet directory
        gent-bundled = pkgs.rustPlatform.buildRustPackage (commonAttrs
          // {
            postInstall = ''
                            mkdir -p $out/share/gent
                            cp -r janet $out/share/gent/

                            # Create a wrapper script that sets up the Janet path
                            mkdir -p $out/bin
                            mv $out/bin/gent $out/bin/.gent-unwrapped

                            cat > $out/bin/gent << 'EOF'
              #!/bin/sh
              # Find the Janet directory relative to this script
              SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
              JANET_DIR="$SCRIPT_DIR/../share/gent/janet"

              # If janet/ exists in current directory, use that (development mode)
              if [ -d "janet" ]; then
                  exec "$SCRIPT_DIR/.gent-unwrapped" "$@"
              else
                  # Otherwise, temporarily symlink to the installed location
                  if [ ! -L "janet" ]; then
                      ln -sf "$JANET_DIR" janet
                      exec "$SCRIPT_DIR/.gent-unwrapped" "$@"
                      rm janet
                  else
                      exec "$SCRIPT_DIR/.gent-unwrapped" "$@"
                  fi
              fi
              EOF
                            chmod +x $out/bin/gent
            '';
          });

        # Default to the embedded version (single binary)
        gent = gent-embedded;
        default = gent;

        # Skill packages
        skill = pkgs.stdenv.mkDerivation {
          pname = "gent-configuration-skill";
          version = "0.1.0";
          src = ./.gent/skills/configuration;
          dontBuild = true;
          installPhase = ''
            mkdir -p $out
            cp -r . $out/
          '';
          meta = with pkgs.lib; {
            description = "Gent configuration skill";
            homepage = "https://github.com/pepegar/gent";
            license = licenses.mit;
          };
        };
      };

      devShells.default = pkgs.mkShell {
        buildInputs =
          nativeBuildInputs
          ++ buildInputs
          ++ [
            parinfer-rust.packages.${system}.default
            tui-wright.packages.${system}.default
            agg.defaultPackage.${system}
          ]
          ++ (with pkgs; [
            # Additional development tools
            janet # For running tests
            cargo-watch
            cargo-edit
          ]);

        shellHook = ''
          echo "gent development environment"
          echo "Run 'cargo build' to build"
          echo "Run 'cargo build --features embedded' for standalone binary"
          echo "Run 'janet janet/test/run.janet' to test"
          echo "Run 'parinfer-rust -m paren -l janet < file.janet' to format"
        '';
      };

      checks.parinfer = let
        parinfer = parinfer-rust.packages.${system}.default;
        checkScript = pkgs.writeShellScript "parinfer-check.sh" ''
          set -uo pipefail
          failed=0
          skipped=0
          src="$1"
          out="$2"
          for f in $(find "$src/janet" -name '*.janet'); do
            name="''${f#$src/}"
            tmpfile=$(mktemp)
            if ! ${parinfer}/bin/parinfer-rust --mode paren --language janet --no-janet-long-strings < "$f" > "$tmpfile" 2>/dev/null; then
              echo "SKIP: $name (parinfer-rust cannot process this file)"
              skipped=$((skipped + 1))
              rm -f "$tmpfile"
              continue
            fi
            if ! diff -u "$f" "$tmpfile" > /dev/null 2>&1; then
              echo "FAIL: $name needs parinfer formatting"
              diff -u "$f" "$tmpfile" || true
              failed=1
            fi
            rm -f "$tmpfile"
          done
          if [ "$failed" = "1" ]; then
            echo ""
            echo "Run 'parinfer-rust -m paren -l janet < file.janet' to fix"
            exit 1
          fi
          echo "All processable .janet files pass parinfer check (skipped $skipped)"
          touch "$out"
        '';
      in
        pkgs.runCommand "parinfer-check" {nativeBuildInputs = [parinfer pkgs.diffutils];} ''
          ${checkScript} ${self} $out
        '';

      # For `nix run`
      apps = {
        default = flake-utils.lib.mkApp {
          drv = self.packages.${system}.gent;
        };
        gent = flake-utils.lib.mkApp {
          drv = self.packages.${system}.gent;
        };
        gent-bundled = flake-utils.lib.mkApp {
          drv = self.packages.${system}.gent-bundled;
        };
      };
    });
}

