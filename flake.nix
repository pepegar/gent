{
  description = "gent - An extensible coding agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    rust-overlay,
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
      ];

      # Runtime dependencies
      buildInputs = with pkgs;
        lib.optionals stdenv.isDarwin [
          # Modern Darwin framework paths
          apple-sdk
          libiconv
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
      };

      devShells.default = pkgs.mkShell {
        buildInputs =
          nativeBuildInputs
          ++ buildInputs
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
        '';
      };

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

