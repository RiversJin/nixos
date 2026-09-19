{ ... }:

{
  networking.hostName = "rivers-laptop";
  networking.networkmanager.enable = true;
  networking.nameservers = [ "223.5.5.5" "223.6.6.6" ];
  networking.firewall.enable = false;

  # Network discovery (SMB browsing)
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };

  # WS-Discovery for Windows SMB shares
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };
}
