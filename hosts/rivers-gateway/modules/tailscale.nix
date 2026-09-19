{ pkgs, ... }:

{
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
  };

  services.tailscale = {
    enable = true;
    extraUpFlags = [
      "--login-server"
      "https://t.riversjins.cc:9443"
      "--hostname"
      "rivers-gateway"
      "--accept-dns=false"
      "--advertise-exit-node"
    ];
  };

  # DeepSeek Harness' authenticated remote gateway is bound only to tailscale0.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 3081 ];

  systemd.services.tailscale-exit-node-snat = {
    description = "Give Tailscale exit-node traffic a dedicated Router identity";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" ];
    requires = [ "tailscaled.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.iptables ];
    script = ''
      iptables -t nat -C POSTROUTING -o br-lan -s 100.64.0.0/10 -j SNAT --to-source 192.168.50.3 2>/dev/null || \
        iptables -t nat -I POSTROUTING 1 -o br-lan -s 100.64.0.0/10 -j SNAT --to-source 192.168.50.3
    '';
    preStop = ''
      iptables -t nat -D POSTROUTING -o br-lan -s 100.64.0.0/10 -j SNAT --to-source 192.168.50.3 2>/dev/null || true
    '';
  };
}
