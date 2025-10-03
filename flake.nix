{
  description = "DeadBot Flake Env";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cargo2nix = {
      url = "github:cargo2nix/cargo2nix/release-0.11.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forEachSupportedSystem =
        f:
        inputs.nixpkgs.lib.genAttrs supportedSystems (
          system:
          f {
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                inputs.self.overlays.default
              ];
            };
          }
        );
    in
    {
      overlays.default = final: prev: {
        rustToolchain =
          with inputs.fenix.packages.${prev.stdenv.hostPlatform.system};
          combine (
            with stable;
            [
              clippy
              rustc
              cargo
              rustfmt
              rust-src
            ]
          );
      };

      packages = forEachSupportedSystem (
        { pkgs }:
        {
          dead-bot = pkgs.rustPlatform.buildRustPackage {
            pname = "dead-bot";
            version = "0.1.0";
            src = ./dead-bot;
            cargoHash = "sha256-lnjQb42ynfT+Pn9VLmtQ/yFLjq5yttzlsBaRjrbNxgQ=";
            
            nativeBuildInputs = with pkgs; [
              pkg-config
            ];
            
            buildInputs = with pkgs; [
              openssl
            ];
          };
          default = inputs.self.packages.${pkgs.system}.dead-bot;
        }
      );

      devShells = forEachSupportedSystem (
        { pkgs }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              #Rust Stuff
              rustToolchain
              openssl
              pkg-config
              cargo-deny
              cargo-edit
              cargo-watch
              rust-analyzer

              # cargo2nix tool
              inputs.cargo2nix.packages.${pkgs.system}.cargo2nix

              lazydocker
              lazygit
              pre-commit
            ];

            env = {
              # Required by rust-analyzer
              RUST_SRC_PATH = "${pkgs.rustToolchain}/lib/rustlib/src/rust/library";
            };
          };
        }
      );
    };
}