# Home Manager module: isp-snitch as a systemd user service. config.toml is
# generated from `services.isp-snitch.settings` into $XDG_CONFIG_HOME, and the
# database lives in $XDG_STATE_HOME. The host's net.ipv4.ping_group_range must
# cover the user's group; a user service cannot set it. See
# docs/operations.md, "Home Manager".
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.isp-snitch;
  common = import ./settings.nix { inherit lib pkgs; };
  configFile = common.configFile cfg.package cfg.settings;
in
{
  options.services.isp-snitch = {
    enable = lib.mkEnableOption "isp-snitch, a per-hop ISP packet-loss monitor, as a user service";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "isp-snitch.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The isp-snitch package to use.";
    };

    settings = common.settingsOption {
      dbPathDefault = "${config.xdg.stateHome}/isp-snitch/isp-snitch.db";
      dbPathDefaultText = lib.literalExpression ''"''${config.xdg.stateHome}/isp-snitch/isp-snitch.db"'';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "services.isp-snitch" pkgs lib.platforms.linux)
    ];

    # Also lets `isp-snitch check-config` and `isp-snitch trace` run by hand.
    home.packages = [ cfg.package ];

    xdg.configFile."isp-snitch/config.toml".source = configFile;

    systemd.user.services.isp-snitch = {
      Unit = {
        Description = "isp-snitch per-hop packet-loss monitor";
        Documentation = [ "https://github.com/mago0/isp-snitch" ];
        X-Restart-Triggers = [ "${configFile}" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} run --config ${config.xdg.configHome}/isp-snitch/config.toml";
        Restart = "always";
        RestartSec = 5;

        # Ping sockets need no capabilities. These settings work in a user
        # manager without namespaces.
        NoNewPrivileges = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
