{ ... }:

{
  # mpv
  programs.mpv = {
    enable = true;
    extraInput = "";
  };
  xdg.configFile."mpv/mpv.conf".text = ''
    vo=gpu-next
    gpu-api=vulkan
    hwdec=auto-safe
    vulkan-device='AMD Radeon RX 7900 XTX (RADV NAVI31)'
    target-colorspace-hint=no
    ao=pulse
  '';
}
