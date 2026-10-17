{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.claude-vps;
  fleet = import ./fleet.nix;
  peer = fleet.peers.${config.networking.hostName} or null;
  ns = "claude-vps";
  hostLink = "cvps-host";
  peerLink = "cvps-peer";
  routeTable = 20300;
  rulePriority = 2030;
  userHome = config.users.users.${cfg.user}.home;
  childPath = lib.concatStringsSep ":" [
    "${userHome}/.local/bin"
    "${userHome}/.npm-global/bin"
    "/etc/profiles/per-user/${cfg.user}/bin"
    "${userHome}/.nix-profile/bin"
    "/run/current-system/sw/bin"
    "/run/wrappers/bin"
  ];
  resolver = pkgs.writeText "claude-vps-resolv.conf" ''
    nameserver 127.0.0.1
    options timeout:3 attempts:2
  '';
  dnsConfig = pkgs.writeText "claude-vps-unbound.conf" ''
    server:
      interface: 127.0.0.1
      port: 53
      do-ip6: no
      do-daemonize: no
      username: ""
      chroot: ""
      directory: ""
      use-syslog: no
      logfile: ""
      pidfile: ""
      access-control: 127.0.0.0/8 allow
      module-config: "iterator"
      tls-cert-bundle: "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    forward-zone:
      name: "."
      forward-tls-upstream: yes
      forward-first: no
      # dae domain+ may redial the TLS SNI: use the DoT hostname, not the DoH hostname.
      forward-addr: 1.1.1.1@853#one.one.one.one
      forward-addr: 1.0.0.1@853#one.one.one.one
  '';
  setup = pkgs.writeShellApplication {
    name = "claude-vps-netns-setup";
    runtimeInputs = with pkgs; [
      coreutils
      iproute2
      jq
      nftables
      procps
    ];
    text = ''
      route="$(ip -4 -json route get ${fleet.router} | jq '.[0]')"
      uplink="$(jq -r '.dev' <<<"$route")"
      source="$(jq -r '.prefsrc // .src // empty' <<<"$route")"
      if [[ "$(jq -r '.gateway // empty' <<<"$route")" != "" || "$source" != ${lib.escapeShellArg cfg.lanAddress} ]]; then
        echo "Claude namespace requires a directly connected Router and LAN address ${cfg.lanAddress}" >&2
        exit 1
      fi

      ip netns add ${ns}
      ip netns exec ${ns} sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1
      ip link add ${hostLink} type veth peer name ${peerLink}
      ip link set ${peerLink} netns ${ns}
      ip address add ${cfg.hostAddress}/30 dev ${hostLink}
      ip -n ${ns} address add ${cfg.namespaceAddress}/30 dev ${peerLink}
      ip -n ${ns} link set lo up

      # Pin the next hop, independently of the host's ordinary default route.
      # If the uplink disappears, the unreachable route prevents RPDB fallback.
      ip route add unreachable default table ${toString routeTable} metric 32767
      ip route add ${fleet.router}/32 dev "$uplink" scope link table ${toString routeTable}
      ip route add default via ${fleet.router} dev "$uplink" onlink table ${toString routeTable} metric 10
      ip rule add priority ${toString rulePriority} iif ${hostLink} lookup ${toString routeTable}
      ip rule add priority ${toString (rulePriority + 1)} iif ${hostLink} unreachable

      nft -f - <<EOF
      table inet claude_vps_host {
        chain input {
          type filter hook input priority -15; policy accept;
          iifname "${hostLink}" counter drop
        }
        chain forward {
          type filter hook forward priority -15; policy accept;
          iifname "${hostLink}" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } counter drop
          iifname "${hostLink}" ip saddr ${cfg.namespaceAddress} oifname "$uplink" rt ip nexthop ${fleet.router} meta l4proto tcp counter accept
          iifname "${hostLink}" counter drop
          oifname "${hostLink}" ip daddr ${cfg.namespaceAddress} ct state established,related counter accept
          oifname "${hostLink}" counter drop
        }
      }
      EOF

      # No namespace traffic is possible until routing and the guard are ready.
      ip link set ${hostLink} up
      ip -n ${ns} link set ${peerLink} up
      ip -n ${ns} route add default via ${cfg.hostAddress} dev ${peerLink}
    '';
  };
  cleanup = pkgs.writeShellApplication {
    name = "claude-vps-netns-cleanup";
    runtimeInputs = with pkgs; [
      iproute2
      nftables
    ];
    text = ''
      # Disconnect first; never remove the guard while the veth is still usable.
      ip link delete ${hostLink} 2>/dev/null || true
      ip netns delete ${ns} 2>/dev/null || true
      ip rule delete priority ${toString rulePriority} iif ${hostLink} lookup ${toString routeTable} 2>/dev/null || true
      ip rule delete priority ${toString (rulePriority + 1)} iif ${hostLink} unreachable 2>/dev/null || true
      ip route flush table ${toString routeTable} 2>/dev/null || true
      nft delete table inet claude_vps_host 2>/dev/null || true
    '';
  };
  enter = pkgs.writeShellApplication {
    name = "claude-vps-enter";
    runtimeInputs = with pkgs; [
      coreutils
      systemd
    ];
    text = ''
      if [[ "$EUID" != 0 || "''${SUDO_USER:-}" != ${lib.escapeShellArg cfg.user} || $# -lt 4 ]]; then
        echo "Use claude-net as ${cfg.user}" >&2
        exit 1
      fi
      mode="$1"
      directory="$2"
      terminal="$3"
      shift 3
      [[ "$mode" == pty || "$mode" == pipe ]]
      [[ "$directory" == /* && "$1" == /* ]]
      [[ "$terminal" =~ ^[a-zA-Z0-9._+-]+$ ]]

      exec systemd-run --quiet --collect --wait "--$mode" --service-type=exec \
        --unit="claude-vps-$(cat /proc/sys/kernel/random/uuid)" \
        --property=User=${lib.escapeShellArg cfg.user} \
        --property=Group=${lib.escapeShellArg config.users.users.${cfg.user}.group} \
        --property=Requires=claude-vps-dns.service \
        --property=BindsTo=claude-vps-netns.service \
        --property='After=claude-vps-netns.service claude-vps-dns.service' \
        --property=NetworkNamespacePath=/run/netns/${ns} \
        --property=BindReadOnlyPaths=${resolver}:/etc/resolv.conf \
        --property=NoNewPrivileges=yes \
        --property=CapabilityBoundingSet= \
        --property=RestrictNamespaces=yes \
        --property='RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK' \
        --property=SystemCallArchitectures=native \
        --property='SystemCallFilter=~@debug @mount @raw-io @reboot @swap @module io_uring_setup io_uring_enter io_uring_register' \
        --property=SystemCallErrorNumber=EPERM \
        --property=PrivatePIDs=yes \
        --property=PrivateTmp=yes \
        --property=PrivateDevices=yes \
        --property=ProtectSystem=full \
        --property=ProtectKernelTunables=yes \
        --property=ProtectKernelModules=yes \
        --property=ProtectControlGroups=yes \
        --property=RestrictSUIDSGID=yes \
        --property=KillMode=control-group \
        --property=TimeoutStopSec=10s \
        --working-directory="$directory" \
        --setenv=HOME=${lib.escapeShellArg userHome} \
        --setenv=PATH=${lib.escapeShellArg childPath} \
        --setenv=LANG=C.UTF-8 --setenv="TERM=$terminal" \
        -- ${pkgs.coreutils}/bin/env \
        -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
        -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
        "$@"
    '';
  };
  launcher = pkgs.writeShellApplication {
    name = "claude-net";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      if [[ $# == 0 ]]; then
        echo 'Usage: claude-net COMMAND [ARG ...]' >&2
        exit 2
      fi
      if [[ "$1" == */* ]]; then
        command_path="$(realpath -e -- "$1")"
      else
        command_path="$(type -P -- "$1")" || {
          echo "Command not installed: $1 (network setup does not install Claude Code)" >&2
          exit 127
        }
      fi
      shift
      mode=pipe
      if [[ -t 0 && -t 1 ]]; then mode=pty; fi
      exec /run/wrappers/bin/sudo -- ${enter}/bin/claude-vps-enter \
        "$mode" "$PWD" "''${TERM:-xterm-256color}" "$command_path" "$@"
    '';
  };
  claudeLauncher = pkgs.writeShellApplication {
    name = "claude-vps";
    text = ''
      exec ${launcher}/bin/claude-net claude "$@"
    '';
  };
in
{
  options.services.claude-vps = {
    enable = lib.mkEnableOption "a fail-closed Claude network namespace routed through the home Router";
    user = lib.mkOption {
      type = lib.types.str;
      default = "rivers";
    };
    lanAddress = lib.mkOption {
      type = lib.types.str;
      default = if peer == null then "" else peer.lanAddress;
      description = "Stable LAN address used by the Router's return route.";
    };
    hostAddress = lib.mkOption {
      type = lib.types.str;
      default = if peer == null then "" else peer.hostAddress;
      description = "Host end of this machine's dedicated /30 veth network.";
    };
    namespaceAddress = lib.mkOption {
      type = lib.types.str;
      default = if peer == null then "" else peer.namespaceAddress;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = peer != null;
        message = "Register this host in modules/claude-vps/fleet.nix before enabling services.claude-vps.";
      }
    ];

    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;
    networking.networkmanager.unmanaged = [ "interface-name:${hostLink}" ];
    environment.etc."netns/${ns}/resolv.conf".source = resolver;
    environment.systemPackages = [
      launcher
      claudeLauncher
    ];

    security.sudo.extraRules = [
      {
        users = [ cfg.user ];
        commands = [
          {
            command = "${enter}/bin/claude-vps-enter";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];

    systemd.services.claude-vps-netns = {
      description = "Isolated Claude network with a pinned Router next hop";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "claude-vps-dns.service"
      ];
      after = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${setup}/bin/claude-vps-netns-setup";
        ExecStopPost = "${cleanup}/bin/claude-vps-netns-cleanup";
        Restart = "on-failure";
        RestartSec = "10s";
      };
    };

    systemd.services.claude-vps-dns = {
      description = "Claude namespace DNS over TLS through the VPS";
      bindsTo = [ "claude-vps-netns.service" ];
      after = [ "claude-vps-netns.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.unbound}/bin/unbound -d -c ${dnsConfig}";
        DynamicUser = true;
        NetworkNamespacePath = "/run/netns/${ns}";
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_NETLINK"
        ];
        Restart = "on-failure";
        RestartSec = "3s";
      };
    };
  };
}
