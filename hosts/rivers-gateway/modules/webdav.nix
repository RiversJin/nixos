{ config, pkgs, ... }:

let
  bindAddress = "100.64.0.2";
  port = 8088;
  root = "/mnt/hdd0/WebDAV";
  htpasswdFile = config.age.secrets.webdav-htpasswd.path;
  webdavStart = pkgs.writeShellScript "webdav-start" ''
    set -eu

    exec ${pkgs.rclone}/bin/rclone serve webdav ${root} \
      --addr ${bindAddress}:${toString port} \
      --htpasswd ${htpasswdFile} \
      --dir-cache-time 10s \
      --vfs-cache-mode writes
  '';
in
{
  systemd.tmpfiles.rules = [
    "d ${root} 0750 rivers users -"
  ];

  systemd.services.webdav = {
    description = "WebDAV share for ${root}";
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "rivers";
      Group = "users";
      ExecStartPre = "${pkgs.coreutils}/bin/test -r ${htpasswdFile}";
      ExecStart = webdavStart;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp --dport ${toString port} -s 100.64.0.0/10 -j nixos-fw-accept
  '';
}
