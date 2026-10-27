{
  description = "isp-snitch: per-hop ISP packet-loss monitor";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        isp-snitch = pkgs.rustPlatform.buildRustPackage {
          pname = "isp-snitch";
          version = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).package.version;
          src = pkgs.lib.cleanSource ./.;
          cargoLock.lockFile = ./Cargo.lock;
          # Live tests open ICMP sockets, which the Nix build sandbox does not allow.
          doCheck = false;
          meta.mainProgram = "isp-snitch";
        };
        default = isp-snitch;

        # Run with --network host (to see the probe interface) and mount a config
        # at /config/config.toml whose db_path points into /data.
        docker = pkgs.dockerTools.buildLayeredImage {
          name = "isp-snitch";
          tag = isp-snitch.version;
          contents = [ isp-snitch pkgs.cacert ];
          extraCommands = "mkdir -p data config";
          config = {
            Entrypoint = [ "${isp-snitch}/bin/isp-snitch" ];
            Cmd = [ "run" "--config" "/config/config.toml" ];
            Volumes = { "/data" = { }; };
            ExposedPorts = { "9180/tcp" = { }; };
          };
        };
      });

      # `services.isp-snitch`. See docs/operations.md, "NixOS" and "Home Manager".
      nixosModules.default = import ./nix/module.nix self;
      homeManagerModules.default = import ./nix/home-manager-module.nix self;

      checks = forAll (pkgs:
        let
          isp-snitch = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          settings = import ./nix/settings.nix { inherit pkgs; inherit (pkgs) lib; };
        in
        {
          package = isp-snitch;
          nixos-module = pkgs.testers.runNixOSTest (import ./nix/tests/nixos.nix self);
          # A setting the binary rejects fails the build of the config file.
          home-manager-module = import ./nix/tests/home-manager-eval.nix self pkgs;
          unit-matches-deploy = import ./nix/tests/unit-matches-deploy.nix self pkgs;
          # A setting the binary rejects fails the build of the config file.
          config-rejects-ipv6 = pkgs.testers.testBuildFailure' {
            drv = settings.configFile isp-snitch {
              db_path = "/tmp/x.db";
              targets = [ { name = "v6"; addr = "2606:4700:4700::1111"; } ];
            };
            expectedBuilderExitCode = 1;
            expectedBuilderLogEntries = [ "is IPv6; only IPv4 targets are supported" ];
          };
        });
    };
}
