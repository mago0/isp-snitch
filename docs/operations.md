# Operations

## Install on BigOne (systemd)

```
cd ~/Projects/personal/isp-snitch
./scripts/install.sh
```

The script builds a release binary through devbox, then uses sudo to:

- install `/usr/local/bin/isp-snitch`;
- install `/etc/systemd/system/isp-snitch.service`;
- write `/etc/isp-snitch/config.toml` from `deploy/config.example.toml` (first
  install only; an existing config is kept);
- enable and restart the service.

Run it again to update. Set `INTERFACE=eth0` for a first install on another
interface.

The unit uses `DynamicUser=yes` with no capabilities. Data are in
`/var/lib/isp-snitch/isp-snitch.db` (systemd maps it to
`/var/lib/private/isp-snitch/`).

## Redeploy without a password

One-time setup (asks for your sudo password):

```
./scripts/install-deploy-access.sh
```

It installs a root-owned `/usr/local/sbin/isp-snitch-deploy` and a sudoers rule
that lets you (and agents running as you) run only that command, with no
arguments, without a password. From then on:

```
devbox run deploy     # cargo build --release, then the deploy command
```

The deploy command reads `target/release/isp-snitch` as you (so a symlink
cannot make it copy a root-only file), checks the config with the new binary
as you, swaps `/usr/local/bin/isp-snitch` atomically, restarts the service and
fails if it does not come back `active`. It never runs the new binary as root.
Unit file and config changes are not covered: use `./scripts/install.sh`.

Undo: `sudo rm /etc/sudoers.d/isp-snitch /usr/local/sbin/isp-snitch-deploy`.

## Check that it works

```
systemctl status isp-snitch
journalctl -u isp-snitch -f              # JSON wide events
journalctl -u isp-snitch | grep probe_flush | tail -3   # one per minute
curl -s localhost:9180/api/targets | jq .
```

UI: `http://localhost:9180/`.

## Requirements

- Linux 5.7 or later (unprivileged `SO_BINDTODEVICE`).
- `net.ipv4.ping_group_range` covers the service group. systemd sets
  `0 2147483647` by default. Check with `sysctl net.ipv4.ping_group_range`.
  If it is `1 0`, ping sockets are off:
  `sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"` and persist it in
  `/etc/sysctl.d/`.

## Access from the LAN

The UI listens on `127.0.0.1:9180`. For LAN access, set
`listen = "0.0.0.0:9180"` in `/etc/isp-snitch/config.toml`, restart, and
open the port in the firewall (BigOne runs ufw):

```
sudo ufw allow from 192.168.1.0/24 to any port 9180 proto tcp
```

There is no login. Do not expose the port beyond the LAN.

## Access over Tailscale

Listen on all addresses, and open the port only on the tailnet interface:

```
LISTEN=0.0.0.0:9180 ./scripts/install.sh      # first install; or edit listen in the config
sudo ufw allow in on tailscale0 to any port 9180 proto tcp comment isp-snitch
```

Then browse to `http://<host>.<tailnet>.ts.net:9180/`. Do not bind `listen`
to the Tailscale IP itself: if tailscaled is not up yet at boot, the bind
fails and the service (and its probing) restarts in a loop until it is.

## Backup

The database is one SQLite file in WAL mode. Take a consistent copy while
the service runs:

```
sudo sqlite3 /var/lib/private/isp-snitch/isp-snitch.db ".backup '/tmp/isp-snitch.db'"
```

## Docker (NAS or Proxmox)

```
nix --extra-experimental-features 'nix-command flakes' build .#docker
docker load -i result
docker run -d --name isp-snitch --restart unless-stopped --network host \
  -v /srv/isp-snitch/config.toml:/config/config.toml:ro \
  -v /srv/isp-snitch/data:/data \
  isp-snitch:0.1.0
```

In the mounted config, set `db_path = "/data/isp-snitch.db"`, and set
`interface` to the host NIC, or remove it to follow the routing table.

Trap: with `--network host` the container uses the **host's**
`net.ipv4.ping_group_range`, and `--sysctl` cannot change it. Many NAS
distributions keep the kernel default `1 0`, which blocks ping sockets. Set
it on the host first. The symptom is `transport_open_failed` events with
"Permission denied" (`EACCES`).

## NixOS

The flake has a NixOS module. config.toml is generated from
`services.isp-snitch.settings`, one attribute per key of
`deploy/config.example.toml`, and checked with `isp-snitch check-config` at
build time, so a bad setting fails the build, not the service. Keys left
unset are left out of the file, so the binary's defaults apply.

```nix
{
  inputs.isp-snitch.url = "github:mago0/isp-snitch";

  outputs = { nixpkgs, isp-snitch, ... }: {
    nixosConfigurations.bigone = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        isp-snitch.nixosModules.default
        {
          services.isp-snitch = {
            enable = true;
            settings = {
              interface = "enp5s0";
              listen = "0.0.0.0:9180";
              retention.minute_days = 30;
              targets = [
                { name = "Cloudflare"; addr = "1.1.1.1"; }
                { name = "Quad9"; addr = "9.9.9.9"; }
              ];
            };
          };
          # The LAN side only; enp5s0 is the uplink.
          networking.firewall.interfaces.enp4s0.allowedTCPPorts = [ 9180 ];
        }
      ];
    };
  };
}
```

The service is the same hardened unit as `deploy/systemd`: `DynamicUser`,
no capabilities, and the directory of `settings.db_path` (default
`/var/lib/isp-snitch/isp-snitch.db`) as its `StateDirectory`, so `db_path`
must stay under `/var/lib`. `openFirewall = true` opens the port of
`settings.listen` on every interface, uplinks included, so use it only when
every interface is trusted. NixOS sets `net.ipv4.ping_group_range` to
`0 2147483647` by default; the module fails evaluation if it is set to a
range that does not cover the dynamic user's group.

There is no login. To reach the UI over HTTPS with a password, keep
`listen` on loopback and put nginx in front. The htpasswd file must be
readable by the `nginx` user (with sops-nix or agenix, set its owner to
`nginx`); nginx reads it on every request.

```nix
services.nginx = {
  enable = true;
  recommendedProxySettings = true;
  recommendedTlsSettings = true;
  virtualHosts."isp-snitch.example.com" = {
    forceSSL = true;
    enableACME = true;
    basicAuthFile = "/run/secrets/isp-snitch-htpasswd";
    locations."/".proxyPass = "http://127.0.0.1:9180";
  };
};
networking.firewall.allowedTCPPorts = [ 80 443 ];   # ACME and HTTPS
```

## Home Manager

`homeManagerModules.default` runs isp-snitch as a systemd user service, for
a laptop or a host you do not manage with NixOS. It has the same `settings`.
The config is written to `~/.config/isp-snitch/config.toml` and the
database defaults to `~/.local/state/isp-snitch/isp-snitch.db`.

```nix
{
  imports = [ isp-snitch.homeManagerModules.default ];
  services.isp-snitch = {
    enable = true;
    settings.interface = "wlp2s0";
  };
}
```

A user service cannot change sysctls: `net.ipv4.ping_group_range` must
already cover your group (see Requirements). The service stops when you
log out unless lingering is on: `users.users.<name>.linger = true` on NixOS,
`loginctl enable-linger` elsewhere.

## Check the Nix modules

```
nix --extra-experimental-features 'nix-command flakes' flake check
```

It runs:

- `nixos-module`: a VM test (needs KVM). The client reaches the target
  through a router on two links. The routing table prefers `eth2`, the
  service binds to `eth1`, and the test checks hop 1 is the router's `eth1`
  side.
- `home-manager-module`: evaluates the Home Manager module against stubs of
  the Home Manager options it sets and builds its config file. It does not
  run the user service.
- `unit-matches-deploy`: the NixOS unit's `[Service]` settings equal
  `deploy/systemd/isp-snitch.service`.
- `config-rejects-ipv6`: an IPv6 target fails the config build with the
  binary's own error.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `transport_open_failed`, "No such device" | `interface` does not exist | fix `interface`; the service retries every 5 s |
| `transport_open_failed`, "Permission denied" | ping sockets blocked by sysctl | see Requirements |
| 100% loss at TTL 1 with `send_errors` | link down or unplugged | expected: the outage is recorded as loss |
| Loss at one hop, hatched in the UI | that router rate-limits ICMP | not real loss; look at effective loss |
| Empty charts for a period | the service was not running | gaps are `null`, not loss |
