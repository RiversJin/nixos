{ pkgs, lib, themeBase, wallpaper, outputs, recentLimit, themeFiles }:
pkgs.writeShellApplication {
  name = "niri-daily";
  runtimeInputs = [
    (pkgs.python3.withPackages (p: [ p.pillow ]))
    pkgs.matugen
    pkgs.curl
    pkgs.niri
    pkgs.swaybg
    pkgs.systemd
    pkgs.mako
  ];
  text = ''
    export NIRI_THEME_BASE=${themeBase}
    export NIRI_FALLBACK_IMAGE=${wallpaper}
    export NIRI_WALLPAPER_OUTPUTS=${lib.escapeShellArg (lib.concatStringsSep " " outputs)}
    export NIRI_WALLPAPER_RECENT_LIMIT=${toString recentLimit}
    export NIRI_THEME_FILES=${lib.escapeShellArg (lib.concatStringsSep " " themeFiles)}
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    exec python3 ${./niri-daily.py} "$@"
  '';
}
