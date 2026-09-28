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

  # DSH owns login; keep its public proxy entry on the existing Tailscale address.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 3081 ];

  systemd.sockets.dsh-remote = {
    description = "DSH native-login entry over Tailscale";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "100.64.0.2:3081" ];
    socketConfig = {
      FreeBind = true;
      NoDelay = true;
    };
  };

  systemd.services.dsh-remote = {
    description = "Forward the Tailscale DSH entry to its loopback web server";
    requires = [ "dsh-remote.socket" ];
    after = [ "dsh-remote.socket" ];
    serviceConfig = {
      Type = "notify";
      ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd 127.0.0.1:3080";
      DynamicUser = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

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
