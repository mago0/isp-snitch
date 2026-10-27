# Evaluates the Home Manager module without home-manager as a flake input: the
# few Home Manager options it sets are stubbed. Building the result also
# builds (and so checks) the generated config file. The module's runtime
# behavior is not covered here.
self: pkgs:

let
  lib = pkgs.lib.extend (
    _: _: {
      hm.assertions.assertPlatform = module: pkgs: platforms: {
        assertion = lib.elem pkgs.stdenv.hostPlatform.system platforms;
        message = "${module}: not available on ${pkgs.stdenv.hostPlatform.system}";
      };
    }
  );
  inherit (lib) mkOption types;

  stubs = {
    options = {
      assertions = mkOption { type = types.listOf types.unspecified; };
      home.packages = mkOption { type = types.listOf types.package; };
      xdg.configHome = mkOption { default = "/home/alice/.config"; };
      xdg.stateHome = mkOption { default = "/home/alice/.local/state"; };
      xdg.configFile = mkOption {
        type = types.attrsOf (types.submodule { options.source = mkOption { type = types.path; }; });
      };
      systemd.user.services = mkOption { type = types.attrsOf (types.attrsOf types.unspecified); };
    };
    config._module.args.pkgs = pkgs;
  };

  eval = lib.evalModules {
    modules = [
      stubs
      self.homeManagerModules.default
      {
        services.isp-snitch = {
          enable = true;
          settings.interface = "wlp2s0";
        };
      }
    ];
  };
  inherit (eval) config;
  failed = map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
in
assert lib.assertMsg (failed == [ ]) (lib.concatLines failed);
assert
  config.services.isp-snitch.settings.db_path == "/home/alice/.local/state/isp-snitch/isp-snitch.db";
pkgs.writeText "isp-snitch-home-manager-eval.json" (
  builtins.toJSON {
    unit = config.systemd.user.services.isp-snitch;
    config = config.xdg.configFile."isp-snitch/config.toml".source;
  }
)
