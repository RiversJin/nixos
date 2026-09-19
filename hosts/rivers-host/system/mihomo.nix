{ config, pkgs, lib, ... }:

let
  pythonWithYaml = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  configDir = "/var/lib/mihomo";

  # Use the same generated Mihomo publication as rivers-gateway.

  # Keep the desktop's existing explicit-proxy behavior. The gateway feeds dae via
  # a SOCKS port; this host exposes the same policy as a mixed port for Codex/Git.
  localOverrides = builtins.toJSON {
    mixed-port = 7890;
    external-controller = "127.0.0.1:9090";
    external-ui = "ui";

    profile = {
      store-selected = true;
    };
  };

  # Script to download subscription, merge local overrides, validate, and apply
  mihomoUpdate = pkgs.writeShellScript "mihomo-update" ''
        set -euo pipefail
    umask 077
    SUB_BASE="$(<${config.age.secrets.mihomo-subscription.path})"
        export PATH="${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.curl
            pythonWithYaml
            pkgs.mihomo
          ]
        }"

        CONFIG_DIR="${configDir}"
        CONFIG="$CONFIG_DIR/config.yaml"
    BACKUP="$CONFIG_DIR/config.yaml.bak"
    TMPFILE="$CONFIG_DIR/.config.yaml.new"
    VALIDATE_DIR="$(mktemp -d "$CONFIG_DIR/.validate.XXXXXX")"
    trap 'rm -rf "$VALIDATE_DIR" "$TMPFILE" "$TMPFILE.sub"' EXIT

        # Download subscription
        echo "Downloading subscription..."
        if ! curl -sf --connect-timeout 10 --max-time 30 -o "$TMPFILE.sub" "$SUB_BASE/mihomo.yaml"; then
          echo "Download failed"
          # If we have no config at all (first boot), we cannot proceed.
          if [ ! -f "$CONFIG" ]; then
            echo "FATAL: No existing config and download failed"
            exit 1
          fi
          # Reuse the current config as the merge base so local overrides still apply.
          cp "$CONFIG" "$TMPFILE.sub"
        fi

        # Merge local overrides on top of subscription config
        echo "Merging local overrides..."
        python3 -c '
    import sys, json

    # PyYAML may not be available, use a simple approach
    # Read subscription yaml
    with open(sys.argv[1]) as f:
        sub_content = f.read()

    overrides = json.loads(sys.argv[2])
    with open(sys.argv[4]) as f:
        overrides["secret"] = f.read().strip()

    # Import yaml
    import importlib
    yaml = importlib.import_module("yaml")

    config = yaml.safe_load(sub_content) or {}

    # The router publication exposes SOCKS on 7892 for dae. On the desktop the
    # existing consumers expect a mixed HTTP/SOCKS endpoint on 7890.
    config.pop("socks-port", None)

    # Deep merge: overrides win
    def deep_merge(base, override):
        result = dict(base)
        for key, value in override.items():
            if key in result and isinstance(result[key], dict) and isinstance(value, dict):
                result[key] = deep_merge(result[key], value)
            elif key in result and isinstance(result[key], list) and isinstance(value, list):
                # For lists, extend and deduplicate
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

    # Use the exact geodata publication consumed by rivers-gateway. The
    # nixpkgs geosite database does not contain every tag used by this policy.
    echo "Downloading geodata..."
    curl -sf --connect-timeout 10 --max-time 120 -o "$VALIDATE_DIR/GeoIP.dat" "$SUB_BASE/dae-assets/geoip.dat"
    curl -sf --connect-timeout 10 --max-time 120 -o "$VALIDATE_DIR/GeoSite.dat" "$SUB_BASE/dae-assets/geosite.dat"
    ln -s ${pkgs.metacubexd} "$VALIDATE_DIR/ui"

    # Validate the complete config and matching geodata before applying either.
    echo "Validating config..."
    if ! mihomo -t -d "$VALIDATE_DIR" -f "$TMPFILE" 2>&1; then
      echo "Validation failed, keeping existing config"
      exit 1
    fi

    # Apply the validated publication.
    if [ -f "$CONFIG" ]; then
      cp "$CONFIG" "$BACKUP"
    fi
    mv "$VALIDATE_DIR/GeoIP.dat" "$CONFIG_DIR/GeoIP.dat"
    mv "$VALIDATE_DIR/GeoSite.dat" "$CONFIG_DIR/GeoSite.dat"
    mv "$TMPFILE" "$CONFIG"
    echo "Config updated successfully"
  '';

  # Fallback config for first boot when subscription is unreachable
  fallbackConfig = pkgs.writeText "mihomo-fallback.yaml" ''
    mixed-port: 7890
    allow-lan: true
    mode: direct
    log-level: info
    ipv6: true
    external-controller: 127.0.0.1:9090
    external-ui: ui

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
    description = "Mihomo desktop proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    conflicts = [ "sing-box.service" ];
    serviceConfig = {
      ExecStartPre = [
        "-${pkgs.iproute2}/bin/ip link delete Meta"
        (pkgs.writeShellScript "mihomo-prepare" ''
            ln -sfn ${pkgs.metacubexd} ${configDir}/ui
          [ -f ${configDir}/GeoIP.dat ] || cp ${pkgs.v2ray-geoip}/share/v2ray/geoip.dat ${configDir}/GeoIP.dat
          [ -f ${configDir}/GeoSite.dat ] || cp ${pkgs.v2ray-domain-list-community}/share/v2ray/geosite.dat ${configDir}/GeoSite.dat
            chmod 644 ${configDir}/GeoIP.dat ${configDir}/GeoSite.dat

            # First boot: ensure a config exists
            if [ ! -f ${configDir}/config.yaml ]; then
              echo "No config found, trying subscription..."
              if ! ${mihomoUpdate}; then
                echo "Subscription failed, using fallback (direct mode)"
                cp ${fallbackConfig} ${configDir}/config.yaml
              fi
            fi
          ${pythonWithYaml}/bin/python3 - ${configDir}/config.yaml ${config.age.secrets.mihomo-controller.path} <<'PYSECRET'
import pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
c = yaml.safe_load(p.read_text())
c["secret"] = pathlib.Path(sys.argv[2]).read_text().strip()
p.write_text(yaml.safe_dump(c, allow_unicode=True, sort_keys=False))
p.chmod(0o600)
PYSECRET
        '')
      ];
      ExecStart = "${pkgs.mihomo}/bin/mihomo -d ${configDir} -f ${configDir}/config.yaml";
      ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
      Restart = "on-failure";
      RestartSec = 5;
      StateDirectory = "mihomo";
      WorkingDirectory = configDir;
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
      OnCalendar = "*-*-* 10:05:00";
      Persistent = true;
    };
  };
}
