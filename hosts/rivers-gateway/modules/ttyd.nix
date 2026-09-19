{ pkgs, ... }:

let
  port = 7681;
in
{
  services.ttyd = {
    enable = true;
    inherit port;
    writeable = true;
  };

  systemd.services.ttyd.serviceConfig.Restart = "on-failure";

  # Restrict ttyd to specific subnets only
  networking.firewall.extraCommands = ''
    iptables -A nixos-fw -p tcp --dport ${toString port} -s 192.168.3.0/24 -j nixos-fw-accept
    iptables -A nixos-fw -p tcp --dport ${toString port} -s 100.64.0.0/10 -j nixos-fw-accept
  '';
}
