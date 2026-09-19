{
  config,
  lib,
  pkgs,
  unstable,
  ...
}:

let
  publicationRoot = "/home/rivers/.local/share/router-proxy-source/current";
  dynamicAssets = "${publicationRoot}/dae-assets";
in
{
  services.dae = {
    enable = true;
    package = unstable.dae;
    configFile = "${publicationRoot}/config.dae";
    assetsPath = dynamicAssets;

    # lan0 is already a trusted Router interface. Do not expose the tproxy
    # listener through the module's global TCP/UDP firewall openings on ppp0.
    openFirewall.enable = false;
  };

  systemd.services.dae = {
    after = [ "pppd-wan.service" ];
    wants = [ "pppd-wan.service" ];
  };

  systemd.services.router-dae-update = {
    description = "Validate and activate the published dae configuration";
    after = [ "dae.service" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "dae-publication";
      Environment = "DAE_LOCATION_ASSET=${config.services.dae.assetsPath}";
      ExecStart = pkgs.writeShellScript "router-dae-update" ''
        set -euo pipefail
        config=${publicationRoot}/config.dae
        assets=${dynamicAssets}
        state="$STATE_DIRECTORY/publication.sha256"
        test -s "$config"
        test -s "$assets/geoip.dat"
        test -s "$assets/geosite.dat"
        ${pkgs.gnugrep}/bin/grep -q '^  vps_adapter:' "$config"
        ${lib.getExe unstable.dae} validate -c "$config"

        generation="$({
          ${pkgs.coreutils}/bin/sha256sum "$config"
          ${pkgs.coreutils}/bin/sha256sum "$assets/geoip.dat"
          ${pkgs.coreutils}/bin/sha256sum "$assets/geosite.dat"
        } | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.gawk}/bin/awk '{ print $1 }')"
        if [[ -f "$state" && "$(<"$state")" == "$generation" ]]; then
          exit 0
        fi

        ${pkgs.systemd}/bin/systemctl restart dae.service
        ${pkgs.systemd}/bin/systemctl is-active --quiet dae.service
        printf '%s\n' "$generation" > "$state"
      '';
    };
  };

  systemd.timers.router-dae-update = {
    description = "Periodically activate a new published dae configuration";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "2min";
      Persistent = true;
      Unit = "router-dae-update.service";
    };
  };
}
