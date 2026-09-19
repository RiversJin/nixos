{
  pkgs,
  unstable,
  ...
}:

{
  environment.systemPackages = with pkgs; [
    vim
    git
    wget
    firefox

    file
    htop
    iotop
    iftop
    usbutils
    pciutils
    lm_sensors
    lsof
    fastfetch
    jq
    tmux
    neovim
    wl-clipboard

    zsh

    metacubexd
  ];

  environment.variables = {
    EDITOR = "vim";
  };

  environment.sessionVariables = {
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
    NIXOS_OZONE_WL = "1";
  };

  # nix-ld for running unpatched dynamic binaries (VSCode, etc.)
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    alsa-lib
    at-spi2-atk
    atk
    cairo
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
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
  ];

  programs.zsh.enable = true;
}
