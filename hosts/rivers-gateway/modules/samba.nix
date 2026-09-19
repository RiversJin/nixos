{ ... }:

{
  services.samba = {
    enable = true;
    openFirewall = true;

    nmbd.enable = true;

    settings = {
      global = {
        "dead time" = 15;
        "getwd cache" = "yes";
        "guest account" = "nobody";
        "invalid users" = [ "root" ];
        "map to guest" = "bad user";
        "max xmit" = 65536;
        "netbios name" = "RIVERS-GATEWAY";
        "ntlm auth" = "yes";
        "passwd program" = "/run/wrappers/bin/passwd %u";
        "read raw" = "yes";
        "security" = "user";
        "server string" = "NixOS Samba Server";
        "socket options" = "TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072";
        "workgroup" = "WORKGROUP";
        "write raw" = "yes";
      };

      hdd0 = {
        "browseable" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force group" = "users";
        "force user" = "rivers";
        "guest ok" = "yes";
        "guest only" = "no";
        "path" = "/mnt/hdd0";
        "read only" = "no";
        "write list" = "rivers";
      };

      hdd1 = {
        "browseable" = "yes";
        "create mask" = "0644";
        "directory mask" = "0755";
        "force group" = "users";
        "force user" = "rivers";
        "guest ok" = "yes";
        "guest only" = "no";
        "path" = "/mnt/hdd1";
        "read only" = "no";
        "write list" = "rivers";
      };
    };
  };

  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };
}
