{ pkgs, ... }:

{
  imports = [ ../../../modules/desktop/audio.nix ];
  security.rtkit.enable = true;

  # Sound with PipeWire
  services.pipewire = {
    wireplumber.configPackages = [
      (pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/51-alsa-softvol.conf" ''
        monitor.alsa.rules = [
          {
            matches = [
              { device.name = "~alsa_card.*HECATE_AIR_3.*" }
            ]
            actions = {
              update-props = {
                api.alsa.ignore-dB = true
                api.alsa.soft-mixer = true
              }
            }
          }
          {
            matches = [
              { device.name = "~alsa_card.*MCHOSE_X9.*" }
            ]
            actions = {
              update-props = {
                # Keep hardware volume control without trusting the USB dB range.
                api.alsa.ignore-dB = true
                api.alsa.soft-mixer = false
              }
            }
          }
        ]
      '')
    ];
  };
}
