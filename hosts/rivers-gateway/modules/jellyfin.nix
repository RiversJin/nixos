{ lib, ... }:

{
  services.jellyfin = {
    enable = true;
    openFirewall = false;
    dataDir = "/mnt/hdd1/.jellyfin/data";
    cacheDir = "/mnt/hdd1/.jellyfin/cache";
    hardwareAcceleration = {
      enable = true;
      type = "vaapi";
      device = "/dev/dri/renderD128";
    };
    transcoding = {
      enableHardwareEncoding = true;
      enableToneMapping = true;
      hardwareDecodingCodecs = {
        h264 = true;
        hevc = true;
        hevc10bit = true;
        mpeg2 = true;
        vc1 = true;
        vp9 = true;
      };
    };
  };

  # Traverse /mnt and use the AMD render device.
  users.users.jellyfin.extraGroups = [ "users" "render" "video" ];
  hardware.graphics.enable = true;

  # Remote access through Tailscale only; no public port or discovery rule.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8096 ];

  systemd.tmpfiles.rules = [
    "d /mnt/hdd1/.jellyfin 0700 jellyfin jellyfin -"
  ];
  # tmpfiles refuses to traverse the rivers-owned disk into a jellyfin-owned
  # directory. Create descendants as the service user before encoding.xml.
  systemd.tmpfiles.settings.jellyfinDirs = lib.mkForce { };

  systemd.services.jellyfin = {
    unitConfig.RequiresMountsFor = [ "/mnt/hdd1" ];
    environment.TMPDIR = "/mnt/hdd1/.jellyfin/tmp";
    preStart = lib.mkBefore ''
      mkdir -p /mnt/hdd1/.jellyfin/data/config /mnt/hdd1/.jellyfin/data/log \
        /mnt/hdd1/.jellyfin/cache /mnt/hdd1/.jellyfin/tmp
    '';
    serviceConfig = {
      WorkingDirectory = lib.mkForce "/mnt/hdd1/.jellyfin";
      ReadOnlyPaths = [ "/mnt" ];
      ReadWritePaths = [ "/mnt/hdd1/.jellyfin" ];
    };
  };
}
