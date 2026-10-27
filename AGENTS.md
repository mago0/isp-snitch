# AGENTS.md

Guidance for any coding agent working in this repo. Tool-neutral: nothing here
assumes a specific agent or harness. `CLAUDE.md` is a symlink to this file.

## What this is

isp-snitch is an always-on Rust service. It runs mtr-style ICMP traces through
one network interface, stores per-hop loss and latency in SQLite, and serves a
small web UI that shows **where** (which hop) and **when** packet loss happens.
Read `docs/architecture.md` first, then the design spec in `docs/specs/`.

## Validate every change

```
devbox run check   # cargo fmt --check && clippy -D warnings && cargo test
```

- All tools come from `devbox.json`. Do not install toolchains globally.
- `check` also runs shellcheck on `scripts/*.sh` and `deploy/sudo/isp-snitch-deploy`.
- `devbox run fmt` fixes formatting.
- CI (`.github/workflows/ci.yml`) runs the same command.
- Tests in `tests/live_lo.rs` and `tests/service_lo.rs` open real ICMP sockets
  on `lo`. They need `net.ipv4.ping_group_range` to cover your group. If it
  does not, they print `skipped` and pass. Read the output: a skip is not a pass.

## Prove a change works

| What changed | Proof |
|---|---|
| Probing, sockets, tracer | `devbox run trace -- --interface enp5s0 --rounds 5 1.1.1.1` prints an mtr table with the target reached |
| Storage, flush, service | `devbox run dev`, wait 2 minutes, then `sqlite3 data/isp-snitch.db 'select count(*) from hop_minute'` > 0 and `probe_flush` events in stdout |
| API | `curl -s localhost:9180/api/targets` while `devbox run dev` runs |
| UI | open `http://localhost:9180/`, or take headless screenshots of the dashboard at desktop and phone width and of a target page: `chromium --headless=new --screenshot=out.png --window-size=1600,1000 --virtual-time-budget=5000 'http://localhost:9180/#r=6h'` (then `--window-size=420,2400`, and `/target/1#r=6h`) |
| Packaging | `nix --extra-experimental-features 'nix-command flakes' build .#default` and `.#docker` |
| Nix modules (`nix/`) | `nix --extra-experimental-features 'nix-command flakes' flake check` passes, including the `nixos-module` VM test (needs KVM) |
| Deployed service (BigOne) | `devbox run deploy` (passwordless; see `docs/operations.md`), then `journalctl -u isp-snitch -n 20 -o cat` shows `startup` and a `probe_flush` within 70 s |

## Repo map

```
src/icmp/        ping-socket transport (Linux), packet parsing
src/tracer/      round logic (pure), run loop, trace table
src/aggregate.rs rounds -> per-minute hop rows
src/store.rs     SQLite schema, upsert, rollup, retention, bucket queries
src/analysis.rs  effective loss, added loss, rate-limit flag, step ladder
src/blame.rs     where loss starts (gateway/upstream/past split), incidents
src/web/         axum API, embedded UI, HTTP wide events
src/service.rs   wiring for `run`
src/wide.rs      wide-event JSON logger
assets/          UI (plain HTML/CSS/JS, uPlot vendored); compiled into the binary
deploy/          configs and the systemd unit
nix/             NixOS and Home Manager modules, VM test
docs/            architecture, API, operations, ADRs, spec, plan
```

## Invariants (do not break)

1. **Observe only.** The service never changes routes, interfaces or any
   network state.
2. **Probes bind to the device** (`SO_BINDTODEVICE`), not only a source IP.
   BigOne has two uplinks with the same gateway IP. See ADR 0001.
3. **No capabilities.** Unprivileged ping sockets only. Do not add `SOCK_RAW`
   or `CAP_NET_RAW` without an ADR.
4. **A gap is not loss.** No rows = the service was down, shown as `null`.
   Lost probes are rows with `recv < sent`.
5. **Effective loss decides blame.** Loss that does not carry through to the
   target is rate limiting. The UI colors by effective loss.
6. **Distance grows only when a router answers at the old distance.** See the
   spec, "Probing".
7. **IPv4 only** in v1. Config rejects IPv6 targets.
8. **Schema changes are new migrations** appended to `MIGRATIONS` in
   `src/store.rs`. Never edit an applied migration.

## Conventions

- TDD: write the failing test first, watch it fail, then implement.
- Logging: one JSON wide event per unit of work through `wide::Event`, with
  `snake_case` fields. No `println!` in library code. `/healthz` is never
  logged.
- Comments say what a thing is for. Keep traps and non-obvious constraints;
  drop history.
- Pure logic stays free of sockets and clocks (see `TracerCore`), so it can be
  tested with synthetic `Instant`s.
- Docs: plain English, no em or en dashes. Update `docs/api.md` with any API
  change and add an ADR for any decision that reverses one.
- Commits: conventional prefixes (`feat:`, `fix:`, `docs:`, `build:`).
