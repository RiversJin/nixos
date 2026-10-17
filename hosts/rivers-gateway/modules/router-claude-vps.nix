{ lib, ... }:

let
  fleet = import ../../../modules/claude-vps/fleet.nix;
in
{
  # Replies from dae must find each namespace through its own LAN host.
  systemd.network.networks."10-lan0".routes = map (peer: {
    Destination = peer.subnet;
    Gateway = peer.lanAddress;
    GatewayOnLink = true;
  }) (lib.attrValues fleet.peers);

  boot.kernelModules = [ "nft_socket" ];

  # Independent of dae: if interception disappears, original packets cannot
  # reach the WAN, another LAN client, or Router management services.
  networking.nftables.tables.claude_vps_guard = {
    family = "inet";
    content = ''
      chain input {
        type filter hook input priority -10; policy accept;
        ip saddr ${fleet.cidr} socket transparent 1 counter accept
        ip saddr ${fleet.cidr} counter drop
      }
      chain forward {
        type filter hook forward priority -10; policy accept;
        ip saddr ${fleet.cidr} counter drop
      }
    '';
  };

  systemd.services.dae = {
    requires = [ "nftables.service" ];
    after = [ "nftables.service" ];
  };
}
