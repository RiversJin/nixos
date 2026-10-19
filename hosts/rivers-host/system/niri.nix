{ lib, pkgs, ... }:
let
  # Session and host-declared variables, excluding shell-local state (PWD,
  # SHLVL, etc.). Keep this independent of config.environment: those options
  # depend on the display-manager package and would cause evaluation recursion.
  sessionEnvironment = lib.unique (
    [
      "PATH" "HOME" "USER" "LOGNAME" "SHELL"
      "LANG" "LANGUAGE" "LC_ALL" "LC_ADDRESS" "LC_COLLATE" "LC_CTYPE"
      "LC_IDENTIFICATION" "LC_MEASUREMENT" "LC_MESSAGES" "LC_MONETARY"
      "LC_NAME" "LC_NUMERIC" "LC_PAPER" "LC_TELEPHONE" "LC_TIME"
      "DISPLAY" "WAYLAND_DISPLAY" "XAUTHORITY" "DBUS_SESSION_BUS_ADDRESS"
      "XDG_RUNTIME_DIR" "XDG_SESSION_TYPE" "XDG_CURRENT_DESKTOP"
      "XDG_SESSION_DESKTOP" "XDG_SESSION_ID" "XDG_SEAT" "XDG_VTNR"
      "XDG_CONFIG_HOME" "XDG_CONFIG_DIRS" "XDG_DATA_HOME" "XDG_DATA_DIRS"
      "XDG_CACHE_HOME" "XDG_STATE_HOME"
      "XCURSOR_THEME" "XCURSOR_SIZE" "XCURSOR_PATH"
      "GTK_IM_MODULE" "QT_IM_MODULE" "XMODIFIERS" "SDL_IM_MODULE" "GLFW_IM_MODULE"
      "GTK_PATH" "GIO_EXTRA_MODULES" "QT_PLUGIN_PATH" "QTWEBKIT_PLUGIN_PATH"
      "SSH_AUTH_SOCK" "SSH_ASKPASS" "NIX_PROFILES" "NIX_USER_PROFILE_DIR"
      "NIX_PATH" "NIX_SSL_CERT_FILE" "SSL_CERT_FILE" "SSL_CERT_DIR"
      "LOCALE_ARCHIVE" "LOCALE_ARCHIVE_2_27" "TZ" "TZDIR" "TERMINFO_DIRS"
      "EDITOR" "VISUAL" "PAGER" "INFOPATH" "LIBEXEC_PATH"
      "GTK_A11Y" "NO_AT_BRIDGE" "SYSTEMD_XKB_DIRECTORY"
      "NIX_LD" "NIX_LD_LIBRARY_PATH" "NIXPKGS_CONFIG"
      "NH_FLAKE" "NIXOS_OZONE_WL" "ELECTRON_OZONE_PLATFORM_HINT"
      "STEAM_FORCE_DESKTOPUI_SCALING" "CC" "CARGO_HOME" "RUSTUP_HOME"
      "RUSTUP_DIST_SERVER" "RUSTUP_UPDATE_ROOT" "GOPROXY"
      "NPM_CONFIG_PREFIX" "NPM_CONFIG_REGISTRY" "PNPM_HOME"
      "PIP_INDEX_URL" "UV_DEFAULT_INDEX" "STARSHIP_CONFIG"
      "XDG_DESKTOP_DIR" "XDG_DOCUMENTS_DIR" "XDG_DOWNLOAD_DIR"
      "XDG_MUSIC_DIR" "XDG_PICTURES_DIR" "XDG_PUBLICSHARE_DIR"
      "XDG_TEMPLATES_DIR" "XDG_VIDEOS_DIR"
    ]
  );
in
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
          substituteInPlace $out/bin/niri-session \
            --replace-fail 'systemctl --user import-environment' ${lib.escapeShellArg ''
              # Import only supported session variables that are actually set.
              set --
              for name in ${lib.escapeShellArgs sessionEnvironment}; do
                if [ "''${!name+x}" = x ]; then
                  set -- "$@" "$name"
                fi
              done
              systemctl --user import-environment "$@"
            ''} \
            --replace-fail ${lib.escapeShellArg "dbus-update-activation-environment --all\n"} \
              ${lib.escapeShellArg "dbus-update-activation-environment \"$@\"\n"}

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
