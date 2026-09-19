{ config, pkgs, unstable, ... }:

let
  generatorDir = "/home/rivers/projects/sing-box-static-sub";
  sourceDir = "/home/rivers/projects/sing-box-static-sub/dist/public";
  localRoot = "/home/rivers/.local/share/router-container-source";

  syncScript = pkgs.writeShellApplication {
    name = "router-proxy-sync";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gawk
      gnugrep
      jq
    ];
    text = ''
      set -euo pipefail

      source_dir=${sourceDir}
      local_root=${localRoot}
      snapshot="$RUNTIME_DIRECTORY/publication"

      prune_releases() {
        local active kept entry dir
        active="$(readlink -f "$local_root/current")"
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
        done < <(find "$local_root/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr)
      }

      tree_manifest() {
        (
          cd "$1"
          find . -type f ! -name publication.sha256 -print0 | sort -z | xargs -0 sha256sum
        )
      }

      validate_publication() {
        local root="$1"

        jq -e '
          (.files | index("sing-box.json") != null) and
          (.files | index("policy.json") != null) and
          (.files | index("outbounds.json") != null) and
          (.files | index("config.dae") != null) and
          (.files | index("mihomo.yaml") != null) and
          (.dae_vps_adapter == true) and
          (.mihomo_router == true) and
          (.bundled_rule_sets | type == "array" and length > 0) and
          (.dae_assets | type == "array" and length == 2)
        ' "$root/manifest.json" >/dev/null

        test -s "$root/config.dae"

        jq -e --slurpfile manifest "$root/manifest.json" '
          ([.route.rule_set[].tag] - [$manifest[0].bundled_rule_sets[].tag]) | length == 0
        ' "$root/policy.json" >/dev/null

        jq -e '
          any(.outbounds[]; .tag == "Proxy" and .type == "selector") and
          any(.outbounds[]; .tag == "auto" and .type == "urltest" and (.outbounds | length > 0))
        ' "$root/outbounds.json" >/dev/null

        while IFS=$'\t' read -r file expected_bytes; do
          test -f "$root/$file"
          actual_bytes="$(stat -c %s "$root/$file")"
          test "$actual_bytes" = "$expected_bytes"
        done < <(jq -r '.bundled_rule_sets[] | [.file, (.bytes | tostring)] | @tsv' "$root/manifest.json")

        while IFS=$'\t' read -r file expected_bytes expected_sha256; do
          test -f "$root/$file"
          actual_bytes="$(stat -c %s "$root/$file")"
          test "$actual_bytes" = "$expected_bytes"
          printf '%s  %s\n' "$expected_sha256" "$root/$file" | sha256sum -c - >/dev/null
        done < <(jq -r '.dae_assets[] | [.file, (.bytes | tostring), .sha256] | @tsv' "$root/manifest.json")
      }

      rm -rf "$snapshot"
      mkdir -p "$snapshot"

      before="$(tree_manifest "$source_dir")"
      cp -a --reflink=auto "$source_dir/." "$snapshot/"
      after="$(tree_manifest "$source_dir")"
      copied="$(tree_manifest "$snapshot")"

      if [[ "$before" != "$after" || "$after" != "$copied" ]]; then
        echo "publication changed while taking snapshot; retry on next timer run" >&2
        exit 1
      fi

      validate_publication "$snapshot"
      tree_manifest "$snapshot" > "$snapshot/publication.sha256"
      generation="$(sha256sum "$snapshot/publication.sha256" | awk '{ print $1 }')"

      local_release="$local_root/releases/$generation"
      local_tmp="$local_root/releases/.$generation.tmp"
      mkdir -p "$local_root/releases"
      if [[ ! -d "$local_release" ]]; then
        rm -rf "$local_tmp"
        mkdir -p "$local_tmp"
        cp -a "$snapshot/." "$local_tmp/"
        chmod -R go-rwx "$local_tmp"
        mv "$local_tmp" "$local_release"
      fi
      chmod -R go-rwx "$local_release"
      rm -f "$local_root/current.new"
      ln -s "releases/$generation" "$local_root/current.new"
      mv -Tf "$local_root/current.new" "$local_root/current"
      prune_releases

      echo "published proxy generation $generation locally"
    '';
  };
in
{
  systemd.services.sing-box-static-sub = {
    description = "Generate the daily proxy subscription and geodata publication";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [
      pkgs.bash
      pkgs.coreutils
      pkgs.nodejs
      pkgs.openssh
      pkgs.rsync
      unstable.sing-box
    ];
    environment.SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    serviceConfig = {
      Type = "oneshot";
      User = "rivers";
      Group = "users";
      WorkingDirectory = generatorDir;
      EnvironmentFile = config.age.secrets.proxy-generator-env.path;
      ExecStart = "${pkgs.bash}/bin/bash ${generatorDir}/scripts/generate-and-sync.sh";
    };
  };

  systemd.timers.sing-box-static-sub = {
    description = "Generate the proxy subscription and geodata once per day";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 04:00:00";
      RandomizedDelaySec = "15min";
      Persistent = true;
      Unit = "sing-box-static-sub.service";
    };
  };

  systemd.services.router-proxy-sync = {
    description = "Publish the current proxy policy and nodes to the Router";
    after = [
      "network-online.target"
      "container@rivers-router.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "rivers";
      Group = "users";
      RuntimeDirectory = "router-proxy-sync";
      ExecStart = "${syncScript}/bin/router-proxy-sync";
    };
  };

  systemd.timers.router-proxy-sync = {
    description = "Periodically publish proxy policy and nodes to the Router container";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3min";
      OnUnitActiveSec = "2min";
      Persistent = true;
      Unit = "router-proxy-sync.service";
    };
  };
}
