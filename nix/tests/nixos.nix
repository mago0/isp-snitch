# VM test of the NixOS module.
#
# The client reaches the target's network through the router on two links:
# eth1 (vlan 1) and eth2 (vlan 3). The routing table prefers eth2 (lower
# metric), so only SO_BINDTODEVICE makes probes leave through eth1, the
# configured interface. The hop 1 address tells the two paths apart.
self:
{ lib, ... }:

let
  addrOf = node: iface: (lib.head node.networking.interfaces.${iface}.ipv4.addresses).address;
  route = address: via: metric: {
    inherit address via;
    prefixLength = 24;
    options.metric = toString metric;
  };
in
{
  name = "isp-snitch";

  nodes = {
    # eth1: vlan 1, eth2: vlan 2 (target), eth3: vlan 3
    router =
      { pkgs, ... }:
      {
        virtualisation.vlans = [
          1
          2
          3
        ];
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        environment.systemPackages = [ pkgs.curl ];
      };

    target =
      { nodes, ... }:
      {
        virtualisation.vlans = [ 2 ];
        networking.interfaces.eth1.ipv4.routes = [
          (route "192.168.1.0" (addrOf nodes.router "eth2") 0)
          (route "192.168.3.0" (addrOf nodes.router "eth2") 0)
        ];
      };

    # eth1: vlan 1 (the probe interface), eth2: vlan 3 (the preferred route)
    client =
      { nodes, pkgs, ... }:
      {
        imports = [ self.nixosModules.default ];
        virtualisation.vlans = [
          1
          3
        ];
        networking.interfaces.eth1.ipv4.routes = [ (route "192.168.2.0" (addrOf nodes.router "eth1") 200) ];
        networking.interfaces.eth2.ipv4.routes = [ (route "192.168.2.0" (addrOf nodes.router "eth3") 10) ];
        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
          pkgs.sqlite
        ];

        services.isp-snitch = {
          enable = true;
          openFirewall = true;
          settings = {
            interface = "eth1";
            listen = "0.0.0.0:9181";
            probe.max_ttl = 8;
            retention.minute_days = 7;
            targets = [
              {
                name = "target";
                addr = addrOf nodes.target "eth1";
              }
            ];
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      isp-snitch = lib.getExe nodes.client.services.isp-snitch.package;
      routerEth1 = addrOf nodes.router "eth1";
      routerEth3 = addrOf nodes.router "eth3";
      targetAddr = addrOf nodes.target "eth1";
      clientAddr = addrOf nodes.client "eth1";
      # mtr table row for hop 1 answered by this address
      hop1 = addr: "grep -E '^ +1 +${lib.escapeRegex addr} '";
    in
    ''
      import json

      start_all()
      router.wait_for_unit("network.target")
      target.wait_for_unit("network.target")
      client.wait_for_unit("isp-snitch.service")
      client.wait_for_open_port(9181)

      with subtest("routing alone takes eth2; binding to eth1 takes eth1"):
          client.wait_until_succeeds("${isp-snitch} trace --rounds 3 --max-ttl 4 ${targetAddr} | ${hop1 routerEth3}", timeout=60)
          client.succeed("${isp-snitch} trace --interface eth1 --rounds 3 --max-ttl 4 ${targetAddr} | ${hop1 routerEth1}")

      with subtest("runs as a dynamic user with no capabilities"):
          show = client.succeed("systemctl show isp-snitch -p DynamicUser -p CapabilityBoundingSet -p AmbientCapabilities")
          assert "DynamicUser=yes\n" in show, show
          assert "CapabilityBoundingSet=\n" in show, show
          assert "AmbientCapabilities=\n" in show, show
          pid = client.succeed("systemctl show isp-snitch -p MainPID --value").strip()
          caps = client.succeed(f"grep -E '^Cap(Inh|Prm|Eff|Bnd|Amb)' /proc/{pid}/status")
          assert all(line.split()[1] == "0000000000000000" for line in caps.splitlines()), caps

      with subtest("config comes from the module settings"):
          status = json.loads(client.succeed("curl -sf localhost:9181/api/status"))
          assert status["interface"] == "eth1", status

      with subtest("rows are flushed to SQLite"):
          client.wait_until_succeeds("journalctl -u isp-snitch -o cat | grep -q probe_flush", timeout=150)
          client.succeed("sqlite3 /var/lib/isp-snitch/isp-snitch.db 'select count(*) from hop_minute' | grep -qv '^0$'")

      with subtest("the service's probes leave through eth1"):
          # Retried: the first flush can predate the router forwarding.
          client.wait_until_succeeds(
              "curl -sf localhost:9181/api/targets/1/hops"
              " | jq -e '(.hops | map({key: (.ttl | tostring), value: .addr}) | from_entries)"
              " | .[\"1\"] == \"${routerEth1}\" and .[\"2\"] == \"${targetAddr}\"'",
              timeout=150,
          )

      with subtest("openFirewall opens the listen port"):
          router.succeed("curl -sf http://${clientAddr}:9181/healthz")
    '';
}
