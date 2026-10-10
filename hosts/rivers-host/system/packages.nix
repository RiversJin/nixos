{
  pkgs,
  lib,
  ...
}:

{
  # System packages
  environment.systemPackages = with pkgs; [
    alsa-utils
    vim
    git
    wget
    google-chrome
    zed-editor
    (writeShellScriptBin "ssh-askpass" ''
      exec ${openssh-askpass}/libexec/gtk-ssh-askpass "$@"
    '')

    file

    mission-center
    htop
    btop-rocm
    iotop
    iftop
    usbutils
    pciutils
    lm_sensors
    lsof
    fastfetch
    jq
    rocmPackages.clr
    rocmPackages.rocminfo
    (writeShellScriptBin "rocm-smi" ''
      export LD_LIBRARY_PATH="${lib.makeLibraryPath [ libdrm ]}''${LD_LIBRARY_PATH:+:}''${LD_LIBRARY_PATH:-}"
      exec ${rocmPackages.rocm-smi}/bin/rocm-smi "$@"
    '')

    zsh

    # Wayland utilities
    ghostty
    kitty
    wezterm
    xdg-terminal-exec
    grim
    slurp
    wl-clipboard
    vulkan-tools
    (python3.withPackages (ps: [ ps.pyyaml ]))
    tmux
    zellij
    wineWow64Packages.stable
    winetricks
    zenity
    metacubexd # mihomo web dashboard
    ddcutil
    nh
  ];

  environment.variables = {
    EDITOR = "vim";
  };

  environment.sessionVariables = {
    NH_FLAKE = "/home/rivers/nixos";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    NIXOS_OZONE_WL = "1";
    XDG_DATA_DIRS = [
      "/var/lib/flatpak/exports/share"
      "/home/rivers/.local/share/flatpak/exports/share"
    ];
  };

  # Flatpak (for Bottles)
  services.flatpak.enable = true;
  system.activationScripts.flatpak-mirror = ''
    if ! ${pkgs.flatpak}/bin/flatpak remotes --columns=name | grep -q '^flathub$'; then
      ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    fi
    ${pkgs.flatpak}/bin/flatpak remote-modify flathub --url=https://mirror.sjtu.edu.cn/flathub || true
  '';

  # nix-ld for running unpatched dynamic binaries
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Common dependencies for Electron apps (VSCode, etc.)
    alsa-lib
    at-spi2-atk
    atk
    cairo
    cups
    dbus
    expat
    glib
    gtk3
    libxkbcommon
    libgbm
    mesa
    nspr
    nss
    pango
    systemd
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcb

    # Electron bundled libffmpeg.so is in its own dir, no need for system ffmpeg
  ];

  # AppImage support for downloaded desktop apps and URL protocol handlers.
  programs.appimage.enable = true;
  programs.appimage.binfmt = true;

  programs.zsh.enable = true;
  programs.chromium.enable = true;
  programs.firefox.enable = true;
}
