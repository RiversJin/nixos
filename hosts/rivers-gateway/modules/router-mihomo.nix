{
  lib,
  pkgs,
  unstable,
  ...
}:

let
  mihomoPkg = unstable.mihomo;
  metacubexdPkg = unstable.metacubexd;
  sourceRoot = "/home/rivers/.local/share/router-proxy-source/current";
  stateRoot = "/var/lib/mihomo-router";
  releasesDir = "${stateRoot}/releases";
  currentConfig = "${stateRoot}/current";

  installPublication = pkgs.writeShellApplication {
    name = "router-mihomo-install-publication";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      jq
      mihomoPkg
      systemd
    ];
    text = ''
      set -euo pipefail

      mode="''${1:---install-only}"
      source_root=${sourceRoot}
      state_root=${stateRoot}
      releases_dir=${releasesDir}
      current_config=${currentConfig}

      prune_releases() {
        local active kept entry dir
        active="$(readlink -f "$current_config")"
        kept=0
        while IFS= read -r entry; do
          dir="''${entry#* }"
          if [[ "$(readlink -f "$dir")" == "$active" ]]; then
            continue
          fi
          if (( kept < 2 )); then
            kept=$((kept + 1))
            continue
          fi
          rm -rf -- "$dir"
        done < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr)
      }

      source_release="$(readlink -f "$source_root")"
      test -d "$source_release"
      test -f "$source_release/publication.sha256"
      (
        cd "$source_release"
        sha256sum -c publication.sha256 >/dev/null
      )
      jq -e '.mihomo_router == true and (.files | index("mihomo.yaml") != null)' \
        "$source_release/manifest.json" >/dev/null

      generation="$({
        cat "$source_release/publication.sha256"
        printf '%s\n' ${mihomoPkg} ${metacubexdPkg}
      } | sha256sum | awk '{ print $1 }')"
      release="$releases_dir/$generation"

      install -d -m 0700 -o mihomo -g mihomo "$state_root" "$releases_dir"
      if [[ ! -f "$release/.ready" ]]; then
        rm -rf "$release"
        install -d -m 0700 "$release"
        install -m 0600 "$source_release/mihomo.yaml" "$release/config.yaml"
        install -m 0600 "$source_release/dae-assets/geoip.dat" "$release/GeoIP.dat"
        install -m 0600 "$source_release/dae-assets/geosite.dat" "$release/GeoSite.dat"
        ln -s ${metacubexdPkg} "$release/ui"
        chown -R mihomo:mihomo "$release"

        if ! ${lib.getExe mihomoPkg} -t -d "$release" -f "$release/config.yaml"; then
          rm -rf "$release"
          exit 1
        fi
        chown -R mihomo:mihomo "$release"
        touch "$release/.ready"
        chown mihomo:mihomo "$release/.ready"
        chmod 0600 "$release/.ready"
      fi

      new_target="releases/$generation"
      old_target="$(readlink "$current_config" 2>/dev/null || true)"
      if [[ "$old_target" == "$new_target" ]]; then
        prune_releases
        echo "mihomo generation $generation is already active"
        exit 0
      fi

      rm -f "$state_root/current.new"
      ln -s "$new_target" "$state_root/current.new"
      mv -Tf "$state_root/current.new" "$current_config"
      chown -h mihomo:mihomo "$current_config"

      if [[ "$mode" == "--restart" ]]; then
        if ! systemctl restart mihomo.service; then
          rm -f "$current_config"
          if [[ -n "$old_target" ]]; then
            ln -s "$old_target" "$current_config"
            chown -h mihomo:mihomo "$current_config"
            systemctl restart mihomo.service || true
          fi
          exit 1
        fi
      fi

      prune_releases
      echo "activated mihomo generation $generation"
    '';
  };
in
{
  users.groups.mihomo = { };
  users.users.mihomo = {
    isSystemUser = true;
    group = "mihomo";
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."mihomo-admin" = {
      listen = [
        {
          addr = "192.168.50.1";
          port = 9090;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:9090";
        proxyWebsockets = true;
        extraConfig = ''
          allow 192.168.50.2;
          allow 192.168.50.10;
          allow 192.168.50.11;
          deny all;
        '';
      };
    };
  };

  systemd.services.mihomo = {
    description = "Mihomo Router proxy and DNS engine";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    conflicts = [ "sing-box.service" ];
    serviceConfig = {
      Type = "simple";
      User = "mihomo";
      Group = "mihomo";
      PermissionsStartOnly = true;
      StateDirectory = "mihomo-router";
      ExecStart = "${lib.getExe mihomoPkg} -d ${currentConfig} -f ${currentConfig}/config.yaml";
      Restart = "on-failure";
      RestartSec = 5;
      LimitNOFILE = 1048576;
    };
    preStart = ''
      ${installPublication}/bin/router-mihomo-install-publication --install-only
    '';
  };

  systemd.services.router-mihomo-update = {
    description = "Validate and activate a complete Mihomo publication";
    after = [ "mihomo.service" ];
    requires = [ "mihomo.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${installPublication}/bin/router-mihomo-install-publication --restart";
    };
  };

  systemd.timers.router-mihomo-update = {
    description = "Check for a new complete Mihomo publication";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "4min";
      OnUnitActiveSec = "2min";
      Persistent = true;
      Unit = "router-mihomo-update.service";
    };
  };

  environment.systemPackages = [ mihomoPkg ];
}
