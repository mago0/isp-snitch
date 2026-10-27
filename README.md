# isp-snitch

Shows **where** and **when** your internet connection loses packets.

isp-snitch runs mtr-style traces all the time through one network interface
to a few highly reachable targets (1.1.1.1, 8.8.8.8, 9.9.9.9). It records
loss and latency for every hop, every minute, in SQLite, and serves a small
web UI:

- **Dashboard** (`/`): one dense, btop-style page. Loss and latency strips
  for every target over 6 hours to 90 days, the hop x time heatmap of a
  selected target, a **where** box that says which segment the loss starts
  in (your gateway, the upstream path all targets share, or past the split),
  an **incidents** list, and a live mtr-style **trace**. Keys: `1`-`5` range,
  arrows change target, `l` loss/latency, drag to zoom, click to pick a time.
- **Per target** (`/target/{id}`): a larger hop x time heatmap. Routers that
  only rate-limit their ICMP (Internet Control Message Protocol) replies are
  hatched, so they are not blamed. Click any column for an mtr-style table.

One binary, one SQLite file, no root, no capabilities, no external services.

## Quick start (development)

Needs [devbox](https://www.jetify.com/devbox) and Linux.

```
devbox run check                                      # fmt, clippy, tests
devbox run trace -- --interface enp5s0 --rounds 5 1.1.1.1   # one-shot trace
devbox run dev                                        # service on :9180, data in ./data
```

Open http://localhost:9180/.

## Install as a service

```
./scripts/install.sh
```

On NixOS, import `nixosModules.default` from the flake and set
`services.isp-snitch.enable = true`; `homeManagerModules.default` runs it as a
user service.

See [docs/operations.md](docs/operations.md) for systemd, NixOS, Home Manager,
Docker (Nix flake), LAN access, backup and troubleshooting.

## Configuration

`/etc/isp-snitch/config.toml`. Every key except `db_path` is optional. See
[deploy/config.example.toml](deploy/config.example.toml).

```toml
interface = "enp5s0"          # probes bind to this device; remove to follow routing
listen = "127.0.0.1:9180"
db_path = "/var/lib/isp-snitch/isp-snitch.db"

[[targets]]
name = "Cloudflare"
addr = "1.1.1.1"
```

## Docs

- [docs/architecture.md](docs/architecture.md): how it works
- [docs/api.md](docs/api.md): HTTP API
- [docs/operations.md](docs/operations.md): run and troubleshoot
- [docs/adr/](docs/adr/): decisions
- [AGENTS.md](AGENTS.md): rules for coding agents (and humans)
- [docs/specs/](docs/specs/) and [docs/plans/](docs/plans/): original design and build plan
