# The NixOS module and deploy/systemd/isp-snitch.service each spell out the
# service's hardening. This check fails when their [Service] settings differ
# (ExecStart aside), so a change to one must be made to the other.
self: pkgs:

let
  inherit (pkgs) lib;

  deployUnit =
    let
      text = builtins.readFile ../../deploy/systemd/isp-snitch.service;
      # Everything from [Service] up to the next section.
      service = lib.head (builtins.match ".*\n\\[Service]\n([^[]*).*" text);
      settings = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (lib.splitString "\n" service);
      kv = l: builtins.match "([A-Za-z]+)=(.*)" l;
    in
    lib.listToAttrs (map (l: lib.nameValuePair (lib.elemAt (kv l) 0) (lib.elemAt (kv l) 1)) settings);

  nixos = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      self.nixosModules.default
      {
        services.isp-snitch.enable = true;
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = lib.trivial.release;
      }
    ];
  };
  # Rendered the way systemd reads them.
  render =
    v:
    if lib.isBool v then
      (if v then "yes" else "no")
    else if lib.isList v then
      lib.concatStringsSep " " (map toString v)
    else
      toString v;
  moduleUnit = lib.mapAttrs (_: render) nixos.config.systemd.services.isp-snitch.serviceConfig;

  drop = lib.flip removeAttrs [ "ExecStart" ];
  a = drop deployUnit;
  b = drop moduleUnit;
  diff = lib.filter (k: (a.${k} or null) != (b.${k} or null)) (
    lib.unique (lib.attrNames a ++ lib.attrNames b)
  );
  show =
    k:
    "${k}: deploy unit ${toString (a.${k} or "(unset)")}, NixOS module ${toString (b.${k} or "(unset)")}";
in
assert lib.assertMsg (diff == [ ]) (
  "nix/module.nix and deploy/systemd/isp-snitch.service differ:\n"
  + lib.concatMapStringsSep "\n" show diff
);
pkgs.writeText "isp-snitch-unit-matches-deploy" (builtins.toJSON b)
