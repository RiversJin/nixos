{ config, pkgs, lib, ... }:

{
  environment.systemPackages = with pkgs; [
    rsync
  ];

  systemd.services.nixos-config-sync = {
    description = "Sync NixOS configuration to backup location";
    unitConfig.RequiresMountsFor = [
      "/mnt/hdd0"
      "/mnt/hdd1"
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      StateDirectory = "nixos-config-sync";
    };
    script = ''
      set -euo pipefail

      state="''${STATE_DIRECTORY:?}/source.sha256"
      fingerprint="$({
        cd /home/rivers/nixos
        ${pkgs.findutils}/bin/find . -xdev \
          -printf '%P\t%y\t%m\t%U\t%G\t%s\t%T@\t%l\0' \
          | ${pkgs.coreutils}/bin/sort -z
      } | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.gawk}/bin/awk '{ print $1 }')"

      if [[ -f "$state" && "$(<"$state")" == "$fingerprint" ]]; then
        echo "NixOS configuration unchanged; skipping disk backup"
        exit 0
      fi

      ${pkgs.rsync}/bin/rsync -av --delete /home/rivers/nixos/ /mnt/hdd0/nixos/
      ${pkgs.rsync}/bin/rsync -av --delete /home/rivers/nixos/ /mnt/hdd1/nixos/
      ${pkgs.coreutils}/bin/printf '%s\n' "$fingerprint" > "$state.new"
      ${pkgs.coreutils}/bin/mv "$state.new" "$state"
    '';
  };

  systemd.timers.nixos-config-sync = {
    description = "Timer for NixOS configuration sync";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1h";
      Persistent = true;
    };
  };
}
