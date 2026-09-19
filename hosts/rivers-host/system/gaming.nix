{
  pkgs,
  ...
}:

let
  gamemodeWithAutoRpath =
    pkg:
    pkg.overrideAttrs (old: {
      postFixup = (old.postFixup or "") + ''
        # pressure-vessel imports libgamemodeauto.so into its own preload directory.
        # Keep the companion libgamemode.so discoverable after LD_LIBRARY_PATH is reset.
        for libauto in "$lib/lib/libgamemodeauto.so.0"; do
          if [ -e "$libauto" ]; then
            patchelf --set-rpath "$lib/lib:$(patchelf --print-rpath "$libauto")" "$libauto"
          fi
        done
      '';
    });

  lutrisPkgs = pkgs.extend (
    _final: prev: {
      openldap = prev.openldap.overrideAttrs (_old: {
        # OpenLDAP syncrepl tests are timing-sensitive in the Lutris multi-arch dependency build.
        doCheck = false;
      });
    }
  );

  lutrisUnwrapped = lutrisPkgs.lutris-unwrapped.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      # Fix Gdk.Cursor.new_from_name returning NULL on Wayland
      substituteInPlace lutris/gui/widgets/sidebar.py \
        --replace-fail 'window.set_cursor(Gdk.Cursor.new_from_name(widget.get_display(), "pointer"))' \
        'cursor = Gdk.Cursor.new_from_name(widget.get_display(), "pointer"); window.set_cursor(cursor) if cursor else None'
    '';
  });
in
{
  nixpkgs.overlays = [
    (_final: prev: {
      gamemode = gamemodeWithAutoRpath prev.gamemode;
    })
  ];

  # Lutris without Steam FHS nesting (avoids symlink depth issues with umu-launcher)
  environment.systemPackages = [
    (lutrisPkgs.lutris.override {
      lutris-unwrapped = lutrisUnwrapped;
      steamSupport = false;
      extraPkgs =
        pkgs': with pkgs'; [
          gamemode
          gamescope
          mangohud
          vulkan-tools
          adwaita-icon-theme
          # Proton/Wine deps that steamSupport would normally provide
          libkrb5
          keyutils
        ];
      extraLibraries =
        pkgs': with pkgs'; [
          gamemode
        ];
    })
  ];

  # nix-ld (for dynamically linked binaries like Proton/pressure-vessel)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    glib
    gtk3
    dbus
    libGL
    libGLU
    vulkan-loader
    libx11
    libxcursor
    libxrandr
    libxi
    libxext
    libxfixes
    libxrender
    libxcomposite
    libxdamage
    libxtst
    libxcb
    freetype
    fontconfig
    alsa-lib
    pipewire
    libpulseaudio
    openssl
    curl
  ];

  # Steam
  systemd.tmpfiles.rules = [
    "d /mnt/games 0775 rivers users - -"
    "d /mnt/games/SteamLibrary 0775 rivers users - -"
  ];

  environment.sessionVariables.STEAM_FORCE_DESKTOPUI_SCALING = "1.5";
  programs.steam = {
    enable = true;
    gamescopeSession.enable = true;
    extraCompatPackages = with pkgs; [
      proton-ge-bin
    ];
    package = pkgs.steam.override {
      extraBwrapArgs = [
        "--bind /mnt/games /mnt/games"
      ];
      extraPkgs =
        pkgs': with pkgs'; [
          libxcursor
          libxi
          libxinerama
          libxscrnsaver
          libpng
          libpulseaudio
          libvorbis
          stdenv.cc.cc.lib
          libkrb5
          keyutils
        ];
    };
  };
  programs.gamescope = {
    enable = true;
    capSysNice = false;
  };

  programs.gamemode.enable = true;
}
