{ pkgs, ... }:

{
  services.dae = {
    enable = true;
    disableTxChecksumIpGeneric = false;
    configFile = "/etc/dae/config.dae";
    assets = with pkgs; [
      v2ray-geoip
      v2ray-domain-list-community
    ];
  };

  # Ensure dae starts after mihomo is ready
  systemd.services.dae = {
    after = [ "mihomo.service" ];
    wants = [ "mihomo.service" ];
    bindsTo = [ "mihomo.service" ];
  };

  # dae config file (not managed by nix store for easy editing)
  environment.etc."dae/config.dae" = {
    mode = "0600";
    text = ''
      global {
        tproxy_port: 12345
        log_level: info
        dial_mode: domain+
        wan_interface: auto
        allow_insecure: false
        auto_config_kernel_parameter: true
        disable_waiting_network: true
      }

      node {
        mihomo: 'socks5://127.0.0.1:7890'
      }

      group {
        proxy {
          filter: name(mihomo)
          policy: fixed(0)
        }
      }

      dns {
        ipversion_prefer: 4
        upstream {
          mihomo_dns: 'udp://127.0.0.1:1053'
        }
        routing {
          request {
            fallback: mihomo_dns
          }
          response {
            fallback: accept
          }
        }
      }

      routing {
        # 禁用 IPv6 — 当前网络无 v6
        ipversion(6) -> block

        # mihomo 和 tailscaled 出站直连，避免回环
        pname(mihomo, tailscaled) -> must_direct

        # NTP 直连，无需走代理
        l4proto(udp) && dport(123) -> direct

        # 本地/内网/组播直连
        dip(geoip:private) -> direct
        dip(224.0.0.0/3, 'ff00::/8') -> direct

        # Steam Relay (SDR) UDP direct
        l4proto(udp) && dport(27000-27300) -> direct

        # China direct
        dip(geoip:cn) -> direct
        domain(geosite:cn) -> direct

        fallback: proxy
      }
    '';
  };
}
