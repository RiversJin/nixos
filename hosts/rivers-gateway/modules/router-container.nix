{ lib, ... }:

let
  wanMac = "52:54:00:72:10:64";
  lanMac = "52:54:00:72:10:0a";
in
{
  imports = [ ./router-system.nix ];

  networking.useHostResolvConf = false;
  services.resolved.enable = true;

  systemd.network.networks."10-wan0".linkConfig.MACAddress = wanMac;
  systemd.network.networks."10-lan0".linkConfig.MACAddress = lanMac;

  # The container shares the host Nix store and is rebuilt from the host, so it
  # does not run distributed builds itself.
  nix.distributedBuilds = lib.mkForce false;
  nix.buildMachines = lib.mkForce [ ];
}
