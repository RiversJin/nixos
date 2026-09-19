{ unstable, ... }:

let
  publicationRoot = "/home/rivers/.local/share/router-container-source";
in
{
  systemd.tmpfiles.rules = [
    "d /sys/fs/bpf/rivers-router 0700 root root -"
    "d ${publicationRoot} 0700 rivers users -"
  ];

  # NixOS containers normally attach extra veths to their bridges in an
  # ExecStartPost step, after the container reports READY.  The Router waits
  # for PPPoE during boot, so let host networkd attach both veths immediately
  # when systemd-nspawn creates them instead.
  systemd.network.networks = {
    "05-router-container-wan0" = {
      matchConfig.Name = "wan0";
      networkConfig = {
        DHCP = "no";
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
        Bridge = "br-wan";
      };
      linkConfig.RequiredForOnline = "no";
    };

    "05-router-container-lan0" = {
      matchConfig.Name = "lan0";
      networkConfig = {
        DHCP = "no";
        LinkLocalAddressing = "no";
        IPv6AcceptRA = false;
        Bridge = "br-lan";
      };
      linkConfig.RequiredForOnline = "no";
    };
  };

  containers.rivers-router = {
    autoStart = true;
    privateNetwork = true;
    privateUsers = "no";

    extraVeths = {
      wan0.hostBridge = "br-wan";
      lan0.hostBridge = "br-lan";
    };

    additionalCapabilities = [
      "CAP_BPF"
      "CAP_IPC_LOCK"
      "CAP_NET_ADMIN"
      "CAP_NET_RAW"
      "CAP_PERFMON"
      "CAP_SYS_ADMIN"
      "CAP_SYS_RESOURCE"
    ];

    allowedDevices = [
      {
        node = "/dev/ppp";
        modifier = "rwm";
      }
    ];

    bindMounts = {
      "/run/router-secrets" = {
        hostPath = "/run/router-secrets";
        isReadOnly = true;
      };
      "/dev/ppp" = {
        hostPath = "/dev/ppp";
        isReadOnly = false;
      };

      "/home/rivers/.local/share/router-proxy-source" = {
        hostPath = publicationRoot;
        isReadOnly = true;
      };

      "/sys/fs/bpf" = {
        hostPath = "/sys/fs/bpf/rivers-router";
        isReadOnly = false;
      };
    };

    specialArgs = { inherit unstable; };
    config = {
      imports = [ ./router-container.nix ];
    };
  };
}
