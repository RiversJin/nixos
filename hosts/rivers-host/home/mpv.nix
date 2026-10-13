{ lib, pkgs, ... }:

{
  # mpv
  programs.mpv = {
    enable = true;
    # The built-in subtitle menu invokes the ffmpeg CLI to extract subtitles.
    extraMakeWrapperArgs = [
      "--prefix"
      "PATH"
      ":"
      (lib.makeBinPath [ pkgs.ffmpeg ])
    ];
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
