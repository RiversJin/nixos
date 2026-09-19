{
  config,
  pkgs,
  lib,
  unstable,
  ...
}:

let
  btopPackage = unstable.btop-rocm;

  usbAutoMount = pkgs.writeShellScript "usb-auto-mount" ''
    set -eu

    kernel_name="$1"
    dev="/dev/$kernel_name"

    for _ in 1 2 3 4 5; do
      [ -b "$dev" ] && break
      ${pkgs.coreutils}/bin/sleep 1
    done
    [ -b "$dev" ] || exit 0

    fstype="$(${pkgs.util-linux}/bin/blkid -s TYPE -o value "$dev" 2>/dev/null || true)"
    [ -n "$fstype" ] || exit 0

    label="$(${pkgs.util-linux}/bin/blkid -s LABEL -o value "$dev" 2>/dev/null || true)"
    uuid="$(${pkgs.util-linux}/bin/blkid -s UUID -o value "$dev" 2>/dev/null || true)"

    raw_name="$label"
    [ -n "$raw_name" ] || raw_name="$uuid"
    [ -n "$raw_name" ] || raw_name="$kernel_name"

    safe_name="$(printf '%s' "$raw_name" | ${pkgs.coreutils}/bin/tr -c 'A-Za-z0-9._-' '_' | ${pkgs.gnused}/bin/sed 's/^_*//; s/_*$//')"
    [ -n "$safe_name" ] || safe_name="$kernel_name"

    target="/mnt/usb/$safe_name"
    if ${pkgs.util-linux}/bin/findmnt -rn --mountpoint "$target" >/dev/null 2>&1; then
      if ${pkgs.util-linux}/bin/findmnt -rn --source "$dev" --mountpoint "$target" >/dev/null 2>&1; then
        exit 0
      fi

      if [ -n "$uuid" ] && [ "$uuid" != "$safe_name" ]; then
        target="/mnt/usb/$uuid"
      else
        target="/mnt/usb/$safe_name-$kernel_name"
      fi
    fi

    if ${pkgs.util-linux}/bin/findmnt -rn --mountpoint "$target" >/dev/null 2>&1; then
      if ${pkgs.util-linux}/bin/findmnt -rn --source "$dev" --mountpoint "$target" >/dev/null 2>&1; then
        exit 0
      fi
      target="/mnt/usb/$safe_name-$kernel_name"
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$target"
    ${pkgs.coreutils}/bin/chown root:users "$target"
    ${pkgs.coreutils}/bin/chmod 0755 "$target"

    case "$fstype" in
      vfat|exfat|ntfs|ntfs3)
        options="rw,nosuid,nodev,noatime,uid=1000,gid=100,fmask=0022,dmask=0022"
        ;;
      *)
        options="rw,nosuid,nodev,noatime"
        ;;
    esac

    if ! ${pkgs.util-linux}/bin/findmnt -rn --source "$dev" >/dev/null 2>&1; then
      ${pkgs.util-linux}/bin/mount -t "$fstype" -o "$options" "$dev" "$target"
    fi
  '';

  usbAutoUnmount = pkgs.writeShellScript "usb-auto-unmount" ''
    set -eu

    kernel_name="$1"
    dev="/dev/$kernel_name"
    targets="$(${pkgs.util-linux}/bin/findmnt -rn --source "$dev" --output TARGET 2>/dev/null || true)"

    usb_mounts="$(${pkgs.util-linux}/bin/findmnt -rn --output SOURCE,TARGET 2>/dev/null || true)"
    while read -r source target; do
      [ -n "$source" ] || continue
      case "$target" in
        /mnt/usb/*)
          case "$source" in
            "$dev"|*/"$kernel_name")
              targets="$(printf '%s\n%s\n' "$targets" "$target" | ${pkgs.coreutils}/bin/sort -u)"
              ;;
          esac
          ;;
      esac
    done <<EOF
    $usb_mounts
    EOF

    [ -n "$targets" ] || exit 0

    printf '%s\n' "$targets" | while IFS= read -r target; do
      [ -n "$target" ] || continue
      case "$target" in
        /mnt/usb/*)
          ${pkgs.util-linux}/bin/umount -l "$target" || true
          ${pkgs.coreutils}/bin/rmdir "$target" 2>/dev/null || true
          ;;
      esac
    done
  '';

  monitorStatus = pkgs.writeShellScript "monitor-status" ''
    set -u

    sensor_data="$(${pkgs.lm_sensors}/bin/sensors 2>/dev/null || true)"
    cpu="$(printf '%s\n' "$sensor_data" | ${pkgs.gawk}/bin/awk '/^Tctl:/ { v = $2; gsub(/[^0-9.]/, "", v); printf "%.0f", v; exit }')"
    nvme="$(printf '%s\n' "$sensor_data" | ${pkgs.gawk}/bin/awk '/^Composite:/ { v = $2; gsub(/[^0-9.]/, "", v); printf "%.0f", v; exit }')"
    probe="$(printf '%s\n' "$sensor_data" | ${pkgs.gawk}/bin/awk '
      /^it8613-isa-/ { chip = 1; next }
      chip && /^temp1:/ {
        v = $2
        gsub(/[^0-9.]/, "", v)
        if (v ~ /^[0-9.]+$/) printf "%.0f", v
        exit
      }
    ')"
    fan2="$(printf '%s\n' "$sensor_data" | ${pkgs.gawk}/bin/awk '/^fan2:/ { print $2; exit }')"
    fan3="$(printf '%s\n' "$sensor_data" | ${pkgs.gawk}/bin/awk '/^fan3:/ { print $2; exit }')"
    hdd0="$(${pkgs.gawk}/bin/awk -F= '$1 == "hdd0" && $2 != "" { print $2; exit }' /run/monitor-disk-temperatures 2>/dev/null || true)"
    hdd1="$(${pkgs.gawk}/bin/awk -F= '$1 == "hdd1" && $2 != "" { print $2; exit }' /run/monitor-disk-temperatures 2>/dev/null || true)"

    [ -n "$cpu" ] || cpu="-"
    [ -n "$nvme" ] || nvme="-"
    [ -n "$probe" ] || probe="-"
    [ -n "$fan2" ] || fan2="-"
    [ -n "$fan3" ] || fan3="-"
    [ -n "$hdd0" ] || hdd0="unknown"
    [ -n "$hdd1" ] || hdd1="unknown"

    health_state="$(${pkgs.coreutils}/bin/cat /run/router-health-status 2>/dev/null || true)"
    router_state="$(printf '%s\n' "$health_state" | ${pkgs.gawk}/bin/awk '{ print tolower($1); exit }')"
    case "$router_state" in
      ok|degraded|down) ;;
      *) router_state="unknown" ;;
    esac
    wan_state="$(printf '%s\n' "$health_state" | ${pkgs.gawk}/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^ppp=/) { sub(/^ppp=/, "", $i); print $i; exit } }')"
    case "$wan_state" in
      up|down) ;;
      *) wan_state="unknown" ;;
    esac
    dns_state="$(printf '%s\n' "$health_state" | ${pkgs.gawk}/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^dns-upstream=/) { sub(/^dns-upstream=/, "", $i); print $i; exit } }')"
    case "$dns_state" in
      ok/*ms) dns_state="''${dns_state#ok/}" ;;
      down/*) dns_state="down" ;;
      *) dns_state="unknown" ;;
    esac
    dae_state="$(printf '%s\n' "$health_state" | ${pkgs.gawk}/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^dae=/) { sub(/^dae=/, "", $i); print $i; exit } }')"
    case "$dae_state" in
      ok|down) ;;
      *) dae_state="unknown" ;;
    esac
    mihomo_state="$(printf '%s\n' "$health_state" | ${pkgs.gawk}/bin/awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^mihomo=/) { sub(/^mihomo=/, "", $i); print $i; exit } }')"
    case "$mihomo_state" in
      ok|down) ;;
      *) mihomo_state="unknown" ;;
    esac

    uptime_seconds="$(${pkgs.gawk}/bin/awk '{ printf "%d", $1 }' /proc/uptime 2>/dev/null || printf 0)"
    uptime_days="$((uptime_seconds / 86400))"
    uptime_hours="$(((uptime_seconds % 86400) / 3600))"
    if [ "$uptime_days" -gt 0 ]; then
      uptime_text="up ''${uptime_days}d''${uptime_hours}h"
    else
      uptime_minutes="$(((uptime_seconds % 3600) / 60))"
      uptime_text="up ''${uptime_hours}h''${uptime_minutes}m"
    fi

    service_state() {
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$1"; then
        printf '%s ok' "$2"
      else
        printf '%s down' "$2"
      fi
    }

    printf '%s %s | WAN %s DNS %s | CPU %sC NVMe %sC HDD0 %s HDD1 %s Probe %sC | FAN %s/%s | %s %s %s %s %s\n' \
      "$(${pkgs.coreutils}/bin/date +%H:%M)" \
      "$uptime_text" \
      "$wan_state" \
      "$dns_state" \
      "$cpu" \
      "$nvme" \
      "$hdd0" \
      "$hdd1" \
      "$probe" \
      "$fan2" \
      "$fan3" \
      "router $router_state" \
      "dae $dae_state" \
      "mihomo $mihomo_state" \
      "$(service_state samba-smbd.service smb)" \
      "$(service_state tailscaled.service ts)"
  '';

  monitorDiskTemperatures = pkgs.writeShellScript "monitor-disk-temperatures" ''
    set -u

    output="$(${pkgs.coreutils}/bin/mktemp /run/monitor-disk-temperatures.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f "$output"' EXIT

    read_disk() {
      label="$1"
      device="$2"
      smart_output="$(${pkgs.smartmontools}/bin/smartctl -n standby -A "$device" 2>&1 || true)"
      if printf '%s\n' "$smart_output" | ${pkgs.gnugrep}/bin/grep -q 'STANDBY'; then
        disk_state="standby"
      else
        temperature="$(printf '%s\n' "$smart_output" | ${pkgs.gawk}/bin/awk '/^(190|194)[[:space:]]/ { print $10; exit }')"
        case "$temperature" in
          *[!0-9]*|"") disk_state="unknown" ;;
          *) disk_state="''${temperature}C" ;;
        esac
      fi
      printf '%s=%s\n' "$label" "$disk_state" >> "$output"
    }

    read_disk hdd0 /dev/disk/by-label/HDD0
    read_disk hdd1 /dev/disk/by-label/HDD1

    ${pkgs.coreutils}/bin/chown rivers:users "$output"
    ${pkgs.coreutils}/bin/chmod 0644 "$output"
    ${pkgs.coreutils}/bin/mv "$output" /run/monitor-disk-temperatures
  '';

  monitorBtopConfig = pkgs.writeText "monitor-btop.conf" ''
    net_iface = "eno1"
  '';

  monitorBtop = pkgs.writeShellScript "monitor-btop" ''
    exec ${btopPackage}/bin/btop --config ${monitorBtopConfig}
  '';

  monitorTmuxConfig = pkgs.writeText "monitor-tmux.conf" ''
    set -g status on
    set -g status-position top
    set -g status-interval 5
    set -g status-left-length 220
    set -g status-right-length 0
    set -g status-justify left
    set -g status-style "bg=#1f2335,fg=#c0caf5"
    set -g status-left "#[bold,fg=#7aa2f7]#(${monitorStatus})"
    set -g status-right ""
    set -g window-status-format ""
    set -g window-status-current-format ""
    set -g pane-border-status off
    set -g default-terminal "tmux-256color"
    set -ga terminal-overrides ",foot*:Tc"
    set -g mouse off
  '';

  monitorKiosk = pkgs.writeShellScript "monitor-kiosk" ''
    ${pkgs.tmux}/bin/tmux -L monitor-kiosk kill-server >/dev/null 2>&1 || true

    exec ${pkgs.foot}/bin/foot \
      --fullscreen \
      --title=btop-monitor \
      --font="Maple Mono Normal NF CN:size=12" \
      --term=foot-direct \
      ${pkgs.tmux}/bin/tmux -L monitor-kiosk -f ${monitorTmuxConfig} new-session -s monitor ${monitorBtop}
  '';
in
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./modules/backup-sync.nix
    ./modules/aria.nix
    ./modules/tailscale.nix
    ./modules/ttyd.nix
    ./modules/samba.nix
    ./modules/webdav.nix
    ./modules/jellyfin.nix
    ./modules/router-host.nix
    ./modules/router-container-host.nix
    ./modules/router-proxy-sync.nix
    ./modules/router-health.nix
  ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  hardware.enableAllFirmware = true;

  networking.hostName = "rivers-gateway"; # Define your hostname.
  networking.wireless.enable = false;

  # Host networking is managed by systemd-networkd in ./modules/router-host.nix.
  networking.networkmanager.enable = false;

  # Set your time zone.
  time.timeZone = "Asia/Singapore";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_SG.UTF-8";
    LC_IDENTIFICATION = "zh_SG.UTF-8";
    LC_MEASUREMENT = "zh_SG.UTF-8";
    LC_MONETARY = "zh_SG.UTF-8";
    LC_NAME = "zh_SG.UTF-8";
    LC_NUMERIC = "zh_SG.UTF-8";
    LC_PAPER = "zh_SG.UTF-8";
    LC_TELEPHONE = "zh_SG.UTF-8";
    LC_TIME = "zh_SG.UTF-8";
  };

  fonts.packages = with pkgs; [
    maple-mono.Normal-NF-CN-unhinted
    source-han-sans
  ];

  fonts.fontconfig.defaultFonts = {
    monospace = [ "Maple Mono Normal NF CN" ];
    sansSerif = [ "Source Han Sans SC" ];
    serif = [ "Source Han Sans SC" ];
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "cn";
    variant = "";
  };

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.rivers = {
    isNormalUser = true;
    linger = true;
    shell = pkgs.zsh;
    description = "rivers";
    extraGroups = [
      "wheel"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB88UzWy7D87cgUAvO+I/KcwrYM7XIFgBkLiOn4a6qq6 rivers@DESKTOP-5GDVV2F"
    ];
  };

  security.sudo.extraRules = lib.mkAfter [
    {
      users = [ "rivers" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild switch";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/nixos-rebuild switch *";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  systemd.tmpfiles.rules = [
    "d /mnt 0750 root users -"
    "d /mnt/usb 0755 root users -"
  ];

  # tty1 is reserved for the Cage monitor kiosk. A getty started during a
  # system switch conflicts with Cage and takes the display back.
  systemd.services."getty@tty1".enable = false;
  systemd.services."autovt@tty1".enable = false;
  services.logind.settings.Login.NAutoVTs = 0;

  services.cage = {
    enable = true;
    user = "rivers";
    program = monitorKiosk;
    environment = {
      WLR_LIBINPUT_NO_DEVICES = "1";
    };
  };

  systemd.services.cage-tty1.serviceConfig = {
    Restart = "always";
    RestartSec = "10s";
  };

  systemd.services.hd-idle = {
    description = "Spin down idle mechanical disks";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${lib.getExe pkgs.hd-idle} -i 0 -c ata -a /dev/disk/by-label/HDD0 -i 300 -a /dev/disk/by-label/HDD1 -i 300";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.monitor-disk-temperatures = {
    description = "Refresh SATA disk temperatures for the monitor kiosk";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = monitorDiskTemperatures;
    };
  };

  systemd.timers.monitor-disk-temperatures = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "10min";
      Unit = "monitor-disk-temperatures.service";
    };
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    wget
    git
    vim
    file

    nix-output-monitor

    htop
    btopPackage
    iotop
    iftop
    cage
    foot
    kitty.terminfo
    tmux
    usbutils
    pciutils
    lm_sensors
    lsof
    fastfetch

    zsh
    uv

    hdparm
    podman-compose
    ntfs3g
  ];

  virtualisation = {
    containers.enable = true;
    podman = {
      enable = true;
      dockerCompat = true;
      defaultNetwork.settings.dns_enabled = true;
    };
  };

  environment.variables.EDITOR = "vim";
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [
      stdenv.cc.cc.lib
      zlib
      openssl
      icu
    ];
  };

  programs.zsh.enable = true;
  programs.nix-index-database.comma.enable = true;
  services.envfs.enable = true;
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
      PubkeyAuthentication = true;
    };
  };
  system.stateVersion = "25.05";

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
  nix.settings.substituters = lib.mkForce [
    "https://cache.nixos.org"
    "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    "https://mirrors.ustc.edu.cn/nix-channels/store"
  ];
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  services.udev.extraRules =
    let
      mkRule = as: lib.concatStringsSep ", " as;
      mkRules = rs: lib.concatStringsSep "\n" rs;
    in
    mkRules [
      (mkRule [
        ''ACTION=="add|change"''
        ''SUBSYSTEM=="powercap"''
        ''KERNEL=="intel-rapl:*"''
        ''RUN+="${pkgs.coreutils}/bin/chmod 0444 /sys$devpath/energy_uj"''
      ])
      (mkRule [
        ''ACTION=="add|change"''
        ''SUBSYSTEM=="block"''
        ''ENV{ID_BUS}=="usb"''
        ''ENV{ID_FS_USAGE}=="filesystem"''
        ''TAG+="systemd"''
        ''ENV{SYSTEMD_WANTS}+="usb-auto-mount@%k.service"''
      ])
      (mkRule [
        ''ACTION=="remove"''
        ''SUBSYSTEM=="block"''
        ''TAG+="systemd"''
        ''ENV{SYSTEMD_WANTS}+="usb-auto-unmount@%k.service"''
      ])
    ];

  systemd.services."usb-auto-mount@" = {
    description = "Automatically mount USB filesystem %i under /mnt/usb";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${usbAutoMount} %i";
    };
  };

  systemd.services."usb-auto-unmount@" = {
    description = "Unmount USB filesystem %i from /mnt/usb";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${usbAutoUnmount} %i";
    };
  };

  networking.firewall.allowedTCPPorts = [
    1200
    8000
    8765
  ];

}
