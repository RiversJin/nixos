{ config, pkgs, ... }:

let
  addresses = {
    rivers-host = "100.64.0.1";
    rivers-gateway = "100.64.0.2";
  };
in
{
  users.users.rivers.linger = true;

  home-manager.users.rivers = { lib, ... }: {
    systemd.user.services.zellij-web = {
      Unit.Description = "Zellij browser sessions";
      Service = {
        ExecStart = "${pkgs.zellij}/bin/zellij web --ip 127.0.0.1 --port 18082";
        Restart = "on-failure";
        RestartSec = 3;
        # Session servers daemonize in this cgroup; stop only the web listener.
        KillMode = "process";
        WorkingDirectory = "%h";
        UMask = "0077";
        Environment = [
          "TERM=xterm-256color"
          "SHELL=${pkgs.zsh}/bin/zsh"
          "PATH=/etc/profiles/per-user/rivers/bin:/run/current-system/sw/bin"
        ];
      };
      Install.WantedBy = [ "default.target" ];
    };

    # Preserve interactive customizations; manage only the web-sharing default.
    # Existing sessions must opt in themselves and are never restarted here.
    home.activation.zellijWebSharing = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${pkgs.python3}/bin/python3 ${./zellij-web-sharing.py}
    '';
  };

  # Zellij requires TLS on non-loopback listeners. This proxy crosses only the
  # encrypted tailnet; the public Caddy terminates browser HTTPS on Tencent.
  services.nginx = {
    enable = true;
    virtualHosts.zellij-web = {
      listen = [
        {
          addr = addresses.${config.networking.hostName};
          port = 8083;
        }
      ];
      locations."/" = {
        proxyPass = "http://127.0.0.1:18082";
        proxyWebsockets = true;
        extraConfig = ''
          allow 100.64.0.3;
          deny all;
          proxy_buffering off;
          proxy_cookie_flags session_token secure;
          proxy_read_timeout 86400s;
          proxy_send_timeout 86400s;
        '';
      };
    };
  };
  # Allow nginx to bind before tailscale has restored its address at boot.
  boot.kernel.sysctl."net.ipv4.ip_nonlocal_bind" = 1;
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 8083 ];
}
