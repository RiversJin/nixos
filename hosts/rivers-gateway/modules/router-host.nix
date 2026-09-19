{ ... }:

{

  networking.useDHCP = false;
  networking.useNetworkd = true;
  # aria2-lan is a second L2 identity in the host namespace, so replies arrive
  # on a different interface than the main-table reverse route.
  networking.firewall.checkReversePath = "loose";

  systemd.network = {
    enable = true;
    wait-online.enable = false;

    links = {
      "10-lan-ap0" = {
        matchConfig.MACAddress = "c8:ff:bf:06:96:47";
        linkConfig.Name = "lan-ap0";
      };
    };

    netdevs = {
      "10-br-lan" = {
        netdevConfig = {
          Name = "br-lan";
          Kind = "bridge";
        };
        bridgeConfig.STP = false;
      };

      "10-br-wan" = {
        netdevConfig = {
          Name = "br-wan";
          Kind = "bridge";
        };
        bridgeConfig.STP = false;
      };

      "20-vlan-lan" = {
        netdevConfig = {
          Name = "vlan-lan";
          Kind = "vlan";
        };
        vlanConfig.Id = 10;
      };

      "20-vlan-wan" = {
        netdevConfig = {
          Name = "vlan-wan";
          Kind = "vlan";
        };
        vlanConfig.Id = 100;
      };

      "20-aria2-veth" = {
        netdevConfig = {
          Name = "aria2-br";
          Kind = "veth";
        };
        peerConfig = {
          Name = "aria2-lan";
          MACAddress = "02:a2:00:00:50:04";
        };
      };
    };

    networks = {
      "05-aria2-br" = {
        matchConfig.Name = "aria2-br";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
          Bridge = "br-lan";
        };
        linkConfig.RequiredForOnline = "no";
      };

      "06-aria2-lan" = {
        matchConfig.Name = "aria2-lan";
        address = [ "192.168.50.4/32" ];
        routes = [
          {
            Gateway = "192.168.50.1";
            GatewayOnLink = true;
            Metric = 500;
          }
        ];
        networkConfig = {
          DHCP = "no";
          IPv6AcceptRA = true;
          IPv6PrivacyExtensions = false;
        };
        ipv6AcceptRAConfig = {
          UseDNS = false;
          # Keep the route available to processes bound to aria2-lan without
          # making it the gateway host's preferred IPv6 default route.
          RouteMetric = 2048;
          Token = "::a2";
        };
        linkConfig.RequiredForOnline = "no";
      };

      "10-eno1" = {
        matchConfig.Name = "eno1";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
          VLAN = [
            "vlan-lan"
            "vlan-wan"
          ];
        };
        linkConfig.RequiredForOnline = "no";
      };

      "10-lan-ap0" = {
        matchConfig.MACAddress = "c8:ff:bf:06:96:47";
        networkConfig = {
          DHCP = "no";
          Bridge = "br-lan";
        };
        linkConfig.RequiredForOnline = "no";
      };

      "20-vlan-lan" = {
        matchConfig.Name = "vlan-lan";
        networkConfig = {
          DHCP = "no";
          Bridge = "br-lan";
        };
        linkConfig.RequiredForOnline = "no";
      };

      "20-vlan-wan" = {
        matchConfig.Name = "vlan-wan";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
          Bridge = "br-wan";
        };
        linkConfig.RequiredForOnline = "no";
      };

      "30-br-lan" = {
        matchConfig.Name = "br-lan";
        address = [
          "192.168.50.2/24"
          "192.168.50.3/32"
        ];
        routes = [
          {
            Gateway = "192.168.50.1";
            GatewayOnLink = true;
            Metric = 200;
          }
        ];
        networkConfig = {
          DHCP = "no";
          DNS = [ "192.168.50.1" ];
          Domains = [ "home" ];
          IPv6AcceptRA = true;
        };
        linkConfig.RequiredForOnline = "no";
      };

      "30-br-wan" = {
        matchConfig.Name = "br-wan";
        networkConfig = {
          DHCP = "no";
          LinkLocalAddressing = "no";
          IPv6AcceptRA = false;
        };
        linkConfig.RequiredForOnline = "no";
      };
    };
  };

  services.irqbalance.enable = true;
}
