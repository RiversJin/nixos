{ config, pkgs, lib, ... }:

{
  networking.wg-quick.interfaces.wg0 = {
    address = [ "10.8.0.2/32" "fdcc:ad94:bacf:61a4::cafe:2/128" ];
    mtu = 1420;
    dns = [ "1.1.1.1" "2606:4700:4700::1111" ];
    privateKeyFile = config.age.secrets.wg-private-key.path;

    peers = [
      {
        publicKey = "45IEMdGvy5Vd5XgXLHsd9r8rWUqRW1UcN3Su8smRqRU=";
        presharedKeyFile = config.age.secrets.wg-preshared-key.path;
        allowedIPs = [ "10.8.0.0/24" "fdcc:ad94:bacf:61a4::/64" ];
        persistentKeepalive = 25;
        endpoint = "122.152.212.30:51820";
      }
    ];
  };

  systemd.services.wg-quick-wg0.serviceConfig.Restart = "on-failure";

}
