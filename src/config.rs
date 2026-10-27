//! Service configuration: a TOML file, validated at startup.

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Config {
    /// Device every probe socket binds to (`SO_BINDTODEVICE`). `None` follows the routing table.
    pub interface: Option<String>,
    pub listen: SocketAddr,
    pub db_path: PathBuf,
    pub probe: ProbeConfig,
    pub retention: RetentionConfig,
    pub targets: Vec<TargetConfig>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ProbeConfig {
    pub interval_ms: u64,
    pub timeout_ms: u64,
    pub max_ttl: u8,
    pub probe_spacing_ms: u64,
}

impl Default for ProbeConfig {
    fn default() -> Self {
        Self {
            interval_ms: 1000,
            timeout_ms: 2000,
            max_ttl: 30,
            probe_spacing_ms: 5,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RetentionConfig {
    pub minute_days: u32,
    pub hour_days: u32,
}

impl Default for RetentionConfig {
    fn default() -> Self {
        Self {
            minute_days: 90,
            hour_days: 365,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TargetConfig {
    pub name: String,
    pub addr: Ipv4Addr,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    interface: Option<String>,
    #[serde(default = "default_listen")]
    listen: SocketAddr,
    db_path: PathBuf,
    #[serde(default)]
    probe: ProbeConfig,
    #[serde(default)]
    retention: RetentionConfig,
    #[serde(default = "default_targets")]
    targets: Vec<RawTarget>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawTarget {
    name: String,
    addr: String,
}

/// `nix/settings.nix` repeats this default: the NixOS module reads the port for `openFirewall`.
fn default_listen() -> SocketAddr {
    SocketAddr::from(([127, 0, 0, 1], 9180))
}

fn default_targets() -> Vec<RawTarget> {
    [
        ("Cloudflare", "1.1.1.1"),
        ("Google", "8.8.8.8"),
        ("Quad9", "9.9.9.9"),
    ]
    .into_iter()
    .map(|(name, addr)| RawTarget {
        name: name.into(),
        addr: addr.into(),
    })
    .collect()
}

impl Config {
    pub fn load(path: &Path) -> Result<Config> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading config file {}", path.display()))?;
        Self::from_toml(&text).with_context(|| format!("in config file {}", path.display()))
    }

    pub fn from_toml(s: &str) -> Result<Config> {
        let raw: RawConfig = toml::from_str(s).context("parsing TOML")?;
        let p = &raw.probe;
        if p.interval_ms == 0 {
            bail!("probe.interval_ms must be greater than 0");
        }
        if p.timeout_ms == 0 {
            bail!("probe.timeout_ms must be greater than 0");
        }
        if !(1..=64).contains(&p.max_ttl) {
            bail!("probe.max_ttl must be between 1 and 64, got {}", p.max_ttl);
        }
        if raw.retention.minute_days == 0 || raw.retention.hour_days == 0 {
            bail!("retention.minute_days and retention.hour_days must be greater than 0");
        }
        if raw.targets.is_empty() {
            bail!("at least one [[targets]] entry is required");
        }
        if let Some(i) = &raw.interface
            && i.trim().is_empty()
        {
            bail!("interface must not be empty; remove it to follow the routing table");
        }
        let mut seen = HashSet::new();
        let mut targets = Vec::with_capacity(raw.targets.len());
        for t in raw.targets {
            let ip: IpAddr = t.addr.parse().with_context(|| {
                format!("target {:?}: {:?} is not an IP address", t.name, t.addr)
            })?;
            let addr = match ip {
                IpAddr::V4(a) => a,
                IpAddr::V6(_) => bail!(
                    "target {:?}: {} is IPv6; only IPv4 targets are supported",
                    t.name,
                    t.addr
                ),
            };
            if !seen.insert(addr) {
                bail!("duplicate target address {addr}");
            }
            targets.push(TargetConfig { name: t.name, addr });
        }
        Ok(Config {
            interface: raw.interface,
            listen: raw.listen,
            db_path: raw.db_path,
            probe: raw.probe,
            retention: raw.retention,
            targets,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_fill_in() {
        let c = Config::from_toml("db_path = \"/tmp/x.db\"").unwrap();
        assert_eq!(c.interface, None);
        assert_eq!(c.listen.to_string(), "127.0.0.1:9180");
        assert_eq!(c.probe.interval_ms, 1000);
        assert_eq!(c.probe.timeout_ms, 2000);
        assert_eq!(c.probe.max_ttl, 30);
        assert_eq!(c.probe.probe_spacing_ms, 5);
        assert_eq!(c.retention.minute_days, 90);
        assert_eq!(c.retention.hour_days, 365);
        let addrs: Vec<String> = c.targets.iter().map(|t| t.addr.to_string()).collect();
        assert_eq!(addrs, ["1.1.1.1", "8.8.8.8", "9.9.9.9"]);
        assert_eq!(c.targets[0].name, "Cloudflare");
    }

    #[test]
    fn interface_and_targets_parse() {
        let c = Config::from_toml(
            r#"
            interface = "enp5s0"
            db_path = "/tmp/x.db"
            [[targets]]
            name = "Cloudflare"
            addr = "1.1.1.1"
            "#,
        )
        .unwrap();
        assert_eq!(c.interface.as_deref(), Some("enp5s0"));
        assert_eq!(c.targets.len(), 1);
    }

    #[test]
    fn ipv6_target_rejected_with_clear_message() {
        let err = Config::from_toml(
            r#"
            db_path = "/tmp/x.db"
            [[targets]]
            name = "v6"
            addr = "2606:4700:4700::1111"
            "#,
        )
        .unwrap_err();
        assert!(format!("{err:#}").contains("IPv6"), "{err:#}");
    }

    #[test]
    fn duplicate_targets_rejected() {
        let err = Config::from_toml(
            r#"
            db_path = "/tmp/x.db"
            [[targets]]
            name = "a"
            addr = "1.1.1.1"
            [[targets]]
            name = "b"
            addr = "1.1.1.1"
            "#,
        )
        .unwrap_err();
        assert!(format!("{err:#}").contains("duplicate"), "{err:#}");
    }

    #[test]
    fn zero_interval_rejected() {
        let err =
            Config::from_toml("db_path = \"/tmp/x.db\"\n[probe]\ninterval_ms = 0\n").unwrap_err();
        assert!(format!("{err:#}").contains("interval_ms"), "{err:#}");
    }

    #[test]
    fn max_ttl_range_enforced() {
        assert!(Config::from_toml("db_path = \"x\"\n[probe]\nmax_ttl = 0\n").is_err());
        assert!(Config::from_toml("db_path = \"x\"\n[probe]\nmax_ttl = 65\n").is_err());
        assert!(Config::from_toml("db_path = \"x\"\n[probe]\nmax_ttl = 64\n").is_ok());
    }

    #[test]
    fn timeout_longer_than_interval_allowed() {
        let c =
            Config::from_toml("db_path = \"x\"\n[probe]\ninterval_ms = 500\ntimeout_ms = 3000\n")
                .unwrap();
        assert_eq!(c.probe.timeout_ms, 3000);
    }

    #[test]
    fn empty_targets_rejected() {
        assert!(Config::from_toml("db_path = \"x\"\ntargets = []\n").is_err());
    }

    #[test]
    fn shipped_configs_parse() {
        let ex = Config::from_toml(include_str!("../deploy/config.example.toml")).unwrap();
        assert_eq!(ex.interface.as_deref(), Some("enp5s0"));
        assert_eq!(ex.targets.len(), 3);
        Config::from_toml(include_str!("../deploy/config.dev.toml")).unwrap();
    }
}
