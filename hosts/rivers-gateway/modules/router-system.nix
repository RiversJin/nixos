{ pkgs, ... }:

let
  lanAddress = "192.168.50.1";
  lanCidr = "${lanAddress}/24";
  aria2Address = "192.168.50.4";
  aria2BtPort = 6881;
  localDomain = "home.arpa";
in
{
  imports = [
    ./router-dae.nix
    ./router-mihomo.nix
  ];

  networking = {
    hostName = "rivers-router";
    domain = localDomain;
    useDHCP = false;
    useNetworkd = true;
    nftables.enable = true;

    nat = {
      enable = true;
      internalInterfaces = [ "lan0" ];
      externalInterface = "ppp0";
      forwardPorts = [
        {
          sourcePort = aria2BtPort;
          destination = "${aria2Address}:${toString aria2BtPort}";
          proto = "tcp";
        }
        {
          sourcePort = aria2BtPort;
          destination = "${aria2Address}:${toString aria2BtPort}";
          proto = "udp";
        }
      ];
    };

    firewall = {
      enable = true;
      trustedInterfaces = [ "lan0" ];
      checkReversePath = "loose";
      filterForward = true;
      extraForwardRules = ''
        iifname "ppp0" oifname "lan0" ip6 daddr & ::ffff:ffff:ffff:ffff == ::a2 meta l4proto { tcp, udp } th dport ${toString aria2BtPort} accept comment "allow public IPv6 BitTorrent to aria2"
        iifname "lan0" oifname "ppp0" tcp flags syn tcp option maxseg size set rt mtu comment "clamp TCP MSS to PPPoE path MTU"
        iifname "lan0" oifname "ppp0" accept comment "allow LAN to PPPoE WAN"
        iifname "lan0" oifname "wan0" accept comment "allow LAN to raw WAN"
      '';
    };
  };

  systemd.network = {
    enable = true;
    wait-online.enable = false;

    networks = {
      "10-wan0" = {
        matchConfig.Name = "wan0";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig.RequiredForOnline = "no";
      };

      "10-lan0" = {
        matchConfig.Name = "lan0";
        address = [ lanCidr ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = false;
          IPv6SendRA = true;
          DHCPPrefixDelegation = true;
        };
        dhcpPrefixDelegationConfig = {
          UplinkInterface = "ppp0";
          SubnetId = 0;
          Announce = true;
        };
        ipv6SendRAConfig = {
          EmitDNS = true;
          DNS = "_link_local";
          Managed = false;
          OtherInformation = true;
        };
        linkConfig.RequiredForOnline = "no";
      };

      "20-ppp0" = {
        matchConfig.Name = "ppp0";
        networkConfig = {
          DHCP = "ipv6";
          IPv6AcceptRA = true;
          KeepConfiguration = "dynamic";
          DNS = [
            "223.5.5.5"
            "1.1.1.1"
          ];
        };
        dhcpV6Config = {
          WithoutRA = "solicit";
          UseDelegatedPrefix = true;
        };
        ipv6AcceptRAConfig.DHCPv6Client = "always";
        linkConfig.RequiredForOnline = "no";
      };
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv6.conf.default.forwarding" = 1;
  };

  services.pppd = {
    enable = true;
    peers.wan = {
      autostart = true;
      config = ''
        plugin pppoe.so
        nic-wan0
        ifname ppp0
        file /run/router-secrets/pppoe-options

        noipdefault
        +ipv6
        ipv6cp-accept-local
        ipv6cp-accept-remote
        defaultroute
        replacedefaultroute
        usepeerdns

        persist
        maxfail 0
        holdoff 5
        lcp-echo-interval 20
        lcp-echo-failure 3

        mtu 1492
        mru 1492
        hide-password
      '';
    };
  };

  environment.etc."ppp/chap-secrets".source = "/run/router-secrets/pppoe-secrets";

  environment.etc."ppp/pap-secrets".source = "/run/router-secrets/pppoe-secrets";

  services.dnsmasq = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      interface = "lan0";
      bind-interfaces = true;
      domain-needed = true;
      bogus-priv = true;
      no-resolv = true;
      strict-order = true;
      domain = localDomain;
      expand-hosts = true;
      local = "/${localDomain}/";
      address = [
        "/router.${localDomain}/${lanAddress}"
        "/rivers-router.${localDomain}/${lanAddress}"
        "/aria2.${localDomain}/192.168.50.4"
      ];
      server = [
        "127.0.0.1#1053"
        "223.5.5.5"
      ];
      dhcp-authoritative = true;
      dhcp-range = [ "192.168.50.100,192.168.50.199,12h" ];
      dhcp-host = [
        "04:7c:16:7c:32:e8,rivers-host,192.168.50.10,12h"
        "4c:49:6c:32:63:ab,rivers-laptop,192.168.50.11,12h"
      ];
      dhcp-option = [
        "option:router,${lanAddress}"
        "option:dns-server,${lanAddress}"
        "option:domain-name,${localDomain}"
      ];
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "no";
    };
  };

  users.users.rivers = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [ "wheel" ];
    hashedPasswordFile = "/run/router-secrets/password-hash";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB88UzWy7D87cgUAvO+I/KcwrYM7XIFgBkLiOn4a6qq6 rivers@DESKTOP-5GDVV2F"
    ];
  };

  security.sudo.wheelNeedsPassword = true;

  environment.systemPackages = with pkgs; [
    bind.dnsutils
    conntrack-tools
    ethtool
    iproute2
    nftables
    ppp
    tcpdump
    vim
    zsh
  ];

  programs.zsh.enable = true;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.trusted-users = [
    "root"
    "rivers"
  ];
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = "192.168.50.10";
      protocol = "ssh-ng";
      systems = [ "x86_64-linux" ];
      sshUser = "rivers";
      sshKey = "/etc/nix/rivers-host-builder_ed25519";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUp0MnVQY2FQYlA0YkFMeVlMNXJoRlJKU0duUjZkaStmT21JN0VvL1J0bnUgcm9vdEByaXZlcnMtaG9zdAo=";
      maxJobs = 4;
      speedFactor = 4;
      supportedFeatures = [
        "nixos-test"
        "benchmark"
        "big-parallel"
        "kvm"
      ];
    }
  ];
  nix.settings.builders-use-substitutes = true;

  system.stateVersion = "25.05";
}
