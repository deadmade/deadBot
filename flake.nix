{
  description = "DeadBot Flake Env";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    arion = {
      url = "github:hercules-ci/arion";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane/v0.21.1";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    crane,
    flake-utils,
    arion,
    git-hooks,
    treefmt-nix,
    advisory-db,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      inherit (pkgs) lib;

      craneLib = crane.mkLib pkgs;
      src = craneLib.cleanCargoSource ./.;

      commonArgs = {
        inherit src;
        strictDeps = true;

        buildInputs = [
          # Add additional build inputs here
          #openssl
        ];

        # Additional environment variables can be set directly
        # MY_CUSTOM_VAR = "some value";
      };

      # Build *just* the cargo dependencies (of the entire workspace),
      # so we can reuse all of that work (e.g. via cachix) when running in CI
      # It is *highly* recommended to use something like cargo-hakari to avoid
      # cache misses when building individual top-level-crates
      cargoArtifacts = craneLib.buildDepsOnly commonArgs;

      individualCrateArgs =
        commonArgs
        // {
          inherit cargoArtifacts;
          inherit (craneLib.crateNameFromCargoToml {inherit src;}) version;
          # NB: we disable tests since we'll run them all via cargo-nextest
          doCheck = false;
        };

      fileSetForCrate = crate:
        lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions [
            ./Cargo.toml
            ./Cargo.lock
            (craneLib.fileset.commonCargoSources ./crates/dead-bot-workspace-hack)
            (craneLib.fileset.commonCargoSources crate)
          ];
        };

      dead-bot = craneLib.buildPackage (
        individualCrateArgs
        // {
          pname = "dead-bot";
          cargoExtraArgs = "-p dead-bot";
          src = fileSetForCrate ./crates/dead-bot;
        }
      );
    in {
      checks = {
        inherit dead-bot;

        deadBot-clippy = craneLib.cargoClippy (
          commonArgs
          // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          }
        );

        deadBot-doc = craneLib.cargoDoc (
          commonArgs
          // {
            inherit cargoArtifacts;
            # This can be commented out or tweaked as necessary, e.g. set to
            # `--deny rustdoc::broken-intra-doc-links` to only enforce that lint
            env.RUSTDOCFLAGS = "--deny warnings";
          }
        );

        # Check formatting
        deadBot-fmt = craneLib.cargoFmt {
          inherit src;
        };

        deadBot-toml-fmt = craneLib.taploFmt {
          src = pkgs.lib.sources.sourceFilesBySuffices src [".toml"];
          # taplo arguments can be further customized below as needed
          # taploExtraArgs = "--config ./taplo.toml";
        };

        # Audit dependencies
        deadBot-audit = craneLib.cargoAudit {
          inherit src advisory-db;
        };

        # Run tests with cargo-nextest
        # Consider setting `doCheck = false` on other crate derivations
        # if you do not want the tests to run twice
        deadBot-nextest = craneLib.cargoNextest (
          commonArgs
          // {
            inherit cargoArtifacts;
            partitions = 1;
            partitionType = "count";
            cargoNextestPartitionsExtraArgs = "--no-tests=pass";
          }
        );

        # Ensure that cargo-hakari is up to date
        deadBot-hakari = craneLib.mkCargoDerivation {
          inherit src;
          pname = "deadBot-hakari";
          cargoArtifacts = null;
          doInstallCargoArtifacts = false;

          buildPhaseCargoCommand = ''
            cargo hakari generate --diff  # workspace-hack Cargo.toml is up-to-date
            cargo hakari manage-deps --dry-run  # all workspace crates depend on workspace-hack
            cargo hakari verify
          '';

          nativeBuildInputs = [
            pkgs.cargo-hakari
          ];
        };
      };

      packages = {
        inherit dead-bot;
        dead-bot-docker = pkgs.dockerTools.buildImage {
          name = "dead-bot";
          tag = "latest";
          config = {
            Cmd = ["${self.packages.${system}.dead-bot}/bin/dead-bot"];
            User = "1000:1000";
          };
        };
      };

      devShells = {
        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            # Validate flake
            flake-checker.enable = true;

            nix-fmt = {
              enable = true;
              name = "nix fmt";
              entry = "nix fmt .";
              language = "system";
              files = "\\.nix$";
            };

            flake-check = {
              enable = true;
              name = "nix flake check";
              entry = "nix flake check";
              language = "system";
              pass_filenames = false;
              always_run = true;
            };

            # Git hooks
            check-merge-conflicts.enable = true;
            convco.enable = true;
            check-added-large-files.enable = true;
            end-of-file-fixer.enable = true;
            trufflehog.enable = true;
          };
        };

        default = craneLib.devShell {
          shellHook = ''
            ${self.devShells.${system}.pre-commit-check.shellHook}
          '';
          checks = self.checks.${system};

          packages = with pkgs; [
            #Rust Stuff
            openssl
            pkg-config
            cargo-deny
            cargo-edit
            cargo-watch
            cargo-hakari
            rust-analyzer

            # Docker and container tools
            lazydocker

            # Arion for managing Docker Compose
            arion.packages.${pkgs.system}.arion

            # Development tools
            lazygit
            redis
          ];

          env = {
            # Required by rust-analyzer
            RUST_SRC_PATH = "${pkgs.rustc}/lib/rustlib/src/rust/library";
          };
        };
      };

      formatter =
        (treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          programs.alejandra.enable = true;
          programs.rustfmt.enable = true;
          programs.deadnix.enable = true;
          programs.taplo.enable = true;
        }).config.build.wrapper;

      # Arion project configuration
      arion = arion.lib.eval {
        modules = [
          (import ./arion-compose.nix)
          ({...}: let
            botInstances = 3;
            mkBotServiceOverride = i: {
              name = "dead-bot-${toString i}";
              value.service.image = self.packages.${system}.dead-bot-docker;
            };
          in {
            services = builtins.listToAttrs (
              map mkBotServiceOverride (builtins.genList (x: x + 1) botInstances)
            );
          })
        ];
        pkgs = nixpkgs.legacyPackages.${system};
      };
    });
}
