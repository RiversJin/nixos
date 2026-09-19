{ pkgs, ... }:
{
  # Keep the compositor and Home Manager's niri helpers on the same trial build.
  nixpkgs.overlays = [
    (_final: prev: {
      niri = prev.niri.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../patches/niri-blur-crop-v2.patch
          ../patches/niri-shake-2797.diff
          ../patches/niri-shake-fixes.patch
          ../patches/niri-idle-cache-cleanup.patch
        ];
        postInstall = old.postInstall + ''
          mkdir -p $out/libexec
          for f in target/x86_64-unknown-linux-gnu/release/deps/niri-*; do
            if [ -x "$f" ] && "$f" --list 2>/dev/null | grep -q crop_tests; then
              cp "$f" $out/libexec/niri-blur-tests
            fi
          done
        '';
        env = old.env // {
          NIRI_BUILD_COMMIT = "Nixpkgs-blur-crop-shake-idle-cache-fix";
        };
      });
    })
  ];

  programs.niri = {
    enable = true;
    useNautilus = false;
  };
  services.displayManager.defaultSession = "niri";
  security.pam.services.swaylock = { };
  environment.systemPackages = [
    pkgs.xwayland-satellite
  ];
}
