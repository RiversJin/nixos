{ config, pkgs, lib, unstable, ... }:

let
  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);


  localOverrides = builtins.toJSON {
    ipv6 = false;
    external-controller = "127.0.0.1:9090";
    external-ui = "/etc/mihomo/ui";

    profile = { store-selected = true; };
    tun = {
      enable = false;
    };
    dns = {
      enable = true;
      listen = "127.0.0.1:1053";
      "enhanced-mode" = "redir-host";
      "default-nameserver" = [
        "223.5.5.5"
        "119.29.29.29"
      ];
      "proxy-server-nameserver" = [
        "https://dns.alidns.com/dns-query"
      ];
      nameserver = [
        "https://dns.alidns.com/dns-query"
        "https://doh.pub/dns-query"
      ];
      fallback = [
        "https://dns.google/dns-query"
        "https://cloudflare-dns.com/dns-query"
      ];
      "fallback-filter" = {
        geoip = true;
        "geoip-code" = "CN";
      };
    };
  };

  mihomoUpdate = pkgs.writeShellScript "mihomo-update" ''
    set -euo pipefail
    umask 077
    SUB_URL="$(<${config.age.secrets.mihomo-subscription.path})"
    export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.curl pythonWithYaml unstable.mihomo ]}"

    CONFIG_DIR="/etc/mihomo"
    CONFIG="$CONFIG_DIR/config.yaml"
    BACKUP="$CONFIG_DIR/config.yaml.bak"
    TMPFILE="$CONFIG_DIR/.config.yaml.new"

    echo "Downloading subscription..."
    if ! curl -sf --connect-timeout 10 --max-time 30 -o "$TMPFILE.sub" "$SUB_URL"; then
      echo "Download failed"
      if [ ! -f "$CONFIG" ]; then
        echo "FATAL: No existing config and download failed"
        exit 1
      fi
      echo "Keeping existing config"
      rm -f "$TMPFILE.sub"
      exit 0
    fi

    echo "Merging local overrides..."
    python3 -c '
import sys, json, importlib
yaml = importlib.import_module("yaml")

with open(sys.argv[1]) as f:
    sub_content = f.read()

overrides = json.loads(sys.argv[2])
with open(sys.argv[4]) as f:
    overrides["secret"] = f.read().strip()
config = yaml.safe_load(sub_content) or {}

REPLACE_KEYS = {"dns", "tun"}

def deep_merge(base, override):
    result = dict(base)
    for key, value in override.items():
        if key in REPLACE_KEYS:
            result[key] = value
        elif key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        elif key in result and isinstance(result[key], list) and isinstance(value, list):
            seen = set()
            merged = []
            for item in result[key] + value:
                s = str(item)
                if s not in seen:
                    seen.add(s)
                    merged.append(item)
            result[key] = merged
        else:
            result[key] = value
    return result

config = deep_merge(config, overrides)

with open(sys.argv[3], "w") as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, width=1000)
' "$TMPFILE.sub" '${localOverrides}' "$TMPFILE" ${config.age.secrets.mihomo-controller.path}
    rm -f "$TMPFILE.sub"

    echo "Validating config..."
    if ! mihomo -t -d "$CONFIG_DIR" -f "$TMPFILE" 2>&1; then
      echo "Validation failed, keeping existing config"
      rm -f "$TMPFILE"
      exit 0
    fi

    if [ -f "$CONFIG" ]; then
      cp "$CONFIG" "$BACKUP"
    fi
    mv "$TMPFILE" "$CONFIG"
    echo "Config updated successfully"
  '';

  fallbackConfig = pkgs.writeText "mihomo-fallback.yaml" ''
    mixed-port: 7890
    allow-lan: true
    mode: direct
    log-level: info
    ipv6: false
    external-controller: 127.0.0.1:9090
    external-ui: /etc/mihomo/ui

    profile:
      store-selected: true
    tun:
      enable: false
    dns:
      enable: false
    proxies: []
    proxy-groups: []
    rules:
      - MATCH,DIRECT
  '';
in
{
  systemd.services.mihomo = {
    description = "Mihomo Proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStartPre = [
        (pkgs.writeShellScript "mihomo-prepare" ''
        mkdir -p /etc/mihomo
        ln -sfn ${unstable.metacubexd} /etc/mihomo/ui
        rm -f /etc/mihomo/geoip.dat /etc/mihomo/geosite.dat
        cp ${pkgs.v2ray-geoip}/share/v2ray/geoip.dat /etc/mihomo/geoip.dat
        cp ${pkgs.v2ray-domain-list-community}/share/v2ray/geosite.dat /etc/mihomo/geosite.dat
        chmod 644 /etc/mihomo/geoip.dat /etc/mihomo/geosite.dat
        [ -f /etc/mihomo/geoip.metadb ] || ${pkgs.curl}/bin/curl -sL -o /etc/mihomo/geoip.metadb "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" || true
        [ -f /etc/mihomo/country.mmdb ] || ${pkgs.curl}/bin/curl -sL -o /etc/mihomo/country.mmdb "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb" || true

        if [ ! -f /etc/mihomo/config.yaml ]; then
          echo "No config found, trying subscription..."
          if ! ${mihomoUpdate}; then
            echo "Subscription failed, using fallback (direct mode)"
            cp ${fallbackConfig} /etc/mihomo/config.yaml
          fi
        fi
          ${pythonWithYaml}/bin/python3 - /etc/mihomo/config.yaml ${config.age.secrets.mihomo-controller.path} <<'PYSECRET'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
c = yaml.safe_load(p.read_text())
c["secret"] = pathlib.Path(sys.argv[2]).read_text().strip()
p.write_text(yaml.safe_dump(c, allow_unicode=True, sort_keys=False))
p.chmod(0o600)
PYSECRET
      '')
      ];
      ExecStart = "${unstable.mihomo}/bin/mihomo -d /etc/mihomo";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "on-failure";
      RestartSec = 5;
      AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW";
      WorkingDirectory = "/etc/mihomo";
      WorkingDirectoryMissing = "create";
    };
  };

  systemd.services.mihomo-update = {
    description = "Update Mihomo subscription";
    after = [ "mihomo.service" ];
    requires = [ "mihomo.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = mihomoUpdate;
      ExecStartPost = "-${pkgs.systemd}/bin/systemctl reload mihomo.service";
    };
  };

  systemd.timers.mihomo-update = {
    description = "Mihomo subscription update timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "30min";
      RandomizedDelaySec = "1min";
    };
  };
}
