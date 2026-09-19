{ pkgs, ... }:

{
  networking.hostName = "rivers-host";
  networking.networkmanager.enable = true;
  networking.nameservers = [
    "223.5.5.5"
    "223.6.6.6"
  ];
  networking.hosts = {
    "100.64.0.1" = [
      "rivers-host"
      "rivers-host.ts.riversjins.cc"
    ];
    "100.64.0.2" = [
      "rivers-gateway"
      "rivers-gateway.ts.riversjins.cc"
      "nixos"
      "nixos.ts.riversjins.cc"
    ];
    "100.64.0.3" = [
      "tencent"
      "vm-0-8-debian"
      "tencent.ts.riversjins.cc"
      "vm-0-8-debian.ts.riversjins.cc"
    ];
  };
  networking.firewall.enable = false;

  # Prefer BBR for high-latency WAN downloads.
  boot.kernelModules = [ "tcp_bbr" ];
  boot.kernel.sysctl = {
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
  };

  # iPhone USB tethering / pairing support.
  services.usbmuxd.enable = true;
  environment.systemPackages = with pkgs; [
    libimobiledevice
  ];

  # Wake on LAN
  networking.interfaces.enp42s0.wakeOnLan.enable = true;

  # Tailscale (connect to self-hosted Headscale)
  services.tailscale = {
    enable = true;
    extraUpFlags = [
      "--login-server"
      "https://t.riversjins.cc:9443"
      "--accept-dns=false"
    ];
  };

  # Network discovery (SMB browsing)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };

  # WS-Discovery for Windows SMB shares
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };
}
