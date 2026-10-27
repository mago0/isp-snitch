# NixOS module: isp-snitch as a hardened systemd service, with config.toml
# generated from `services.isp-snitch.settings`. See docs/operations.md,
# "NixOS". The [Service] settings must match deploy/systemd/isp-snitch.service
# (checked by nix/tests/unit-matches-deploy.nix).
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

  # The database directory, relative to /var/lib: the service's StateDirectory.
  stateDir = lib.removePrefix "/var/lib/" (dirOf cfg.settings.db_path);

  # Ping sockets open only for a group inside net.ipv4.ping_group_range.
  # systemd allocates DynamicUser= groups from this range.
  dynamicGids = {
    first = 61184;
    last = 65519;
  };
  pingRange =
    let
      m = builtins.match "[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]*" (
        toString (config.boot.kernel.sysctl."net.ipv4.ping_group_range" or "")
      );
    in
    if m == null then
      null
    else
      {
        first = lib.toInt (builtins.elemAt m 0);
        last = lib.toInt (builtins.elemAt m 1);
      };
in
{
  options.services.isp-snitch = {
    enable = lib.mkEnableOption "isp-snitch, a per-hop ISP packet-loss monitor";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "isp-snitch.packages.\${pkgs.stdenv.hostPlatform.system}.default";
      description = "The isp-snitch package to use.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to open the TCP port of `settings.listen` in the firewall, on
        every interface. The UI has no login: to allow only the LAN, leave this
        off and use `networking.firewall.interfaces.<name>.allowedTCPPorts`.
      '';
    };

    settings = common.settingsOption { dbPathDefault = "/var/lib/isp-snitch/isp-snitch.db"; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # A plain path one or more directories below /var/lib, so stateDir is a
        # valid StateDirectory= ("//" or ".." would only fail at start).
        assertion =
          builtins.match "/var/lib(/[^/]+)+/[^/]+" cfg.settings.db_path != null
          && !lib.elem ".." (lib.splitString "/" cfg.settings.db_path)
          && !lib.elem "." (lib.splitString "/" cfg.settings.db_path);
        message = "services.isp-snitch.settings.db_path must be in a directory under /var/lib, the service's StateDirectory; it cannot write anywhere else.";
      }
      {
        # NixOS sets "0 2147483647" by default, which covers it.
        assertion =
          pingRange != null && pingRange.first <= dynamicGids.first && pingRange.last >= dynamicGids.last;
        message = ''
          services.isp-snitch: boot.kernel.sysctl."net.ipv4.ping_group_range" must cover the
          DynamicUser group range ${toString dynamicGids.first}-${toString dynamicGids.last}, or the
          service cannot open ping sockets.
        '';
      }
    ];

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [
      (common.listenPort cfg.settings.listen)
    ];

    systemd.services.isp-snitch = {
      description = "isp-snitch per-hop packet-loss monitor";
      documentation = [ "https://github.com/mago0/isp-snitch" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${lib.getExe cfg.package} run --config ${common.configFile cfg.package cfg.settings}";
        Restart = "always";
        RestartSec = 5;

        # Probes are unprivileged ping sockets (AF_INET, SOCK_DGRAM) bound with
        # SO_BINDTODEVICE, which needs no capability since Linux 5.7.
        DynamicUser = true;
        StateDirectory = stateDir;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
          "AF_NETLINK"
        ];
      };
    };
  };
}
