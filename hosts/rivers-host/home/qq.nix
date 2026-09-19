{ pkgs, ... }:

let
  clipboard = pkgs.callPackage ./qq/clipboard.nix { };
  launcher = pkgs.writeShellScript "qq-launcher" ''
    if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
      exec ${clipboard}/bin/qq-wayland-clipboard ${pkgs.qq}/bin/qq "$@"
    fi
    exec ${pkgs.qq}/bin/qq "$@"
  '';
in
{
  home.packages = [
    (pkgs.symlinkJoin {
      name = "qq-with-clipboard";
      paths = [ pkgs.qq ];
      postBuild = ''
        rm $out/bin/qq
        ln -s ${launcher} $out/bin/qq
        # The upstream desktop entry uses an absolute store path.
        rm $out/share/applications/qq.desktop
        substitute ${pkgs.qq}/share/applications/qq.desktop \
          $out/share/applications/qq.desktop \
          --replace-fail '${pkgs.qq}/bin/qq' "$out/bin/qq"
      '';
    })
  ];
}
