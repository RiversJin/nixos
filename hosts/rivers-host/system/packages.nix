{
  config,
  pkgs,
  lib,
  claudeCodeNix,
  ...
}:

let
  claudeCode = claudeCodeNix.packages.${pkgs.stdenv.hostPlatform.system}.claude-code;
in
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

    (writeShellScriptBin "claude" ''
      export TZDIR="${pkgs.tzdata}/share/zoneinfo"
      export TZ="America/Denver"
      export LANG="en_US.UTF-8"
      export LANGUAGE="en_US:en"
      export LC_ALL="en_US.UTF-8"
      export LC_ADDRESS="en_US.UTF-8"
      export LC_COLLATE="en_US.UTF-8"
      export LC_CTYPE="en_US.UTF-8"
      export LC_IDENTIFICATION="en_US.UTF-8"
      export LC_MEASUREMENT="en_US.UTF-8"
      export LC_MESSAGES="en_US.UTF-8"
      export LC_MONETARY="en_US.UTF-8"
      export LC_NAME="en_US.UTF-8"
      export LC_NUMERIC="en_US.UTF-8"
      export LC_PAPER="en_US.UTF-8"
      export LC_TELEPHONE="en_US.UTF-8"
      export LC_TIME="en_US.UTF-8"

      exec ${claudeCode}/bin/claude "$@"
    '')
    (writeShellScriptBin "mi-cc" ''
      set -euo pipefail
      unset ANTHROPIC_API_KEY
      unset ANTHROPIC_SMALL_FAST_MODEL
      export ANTHROPIC_BASE_URL="https://token-plan-cn.xiaomimimo.com/anthropic"
      ANTHROPIC_AUTH_TOKEN="$(<${config.age.secrets.mimo-token.path})"
      export ANTHROPIC_AUTH_TOKEN
      export ANTHROPIC_MODEL="mimo-v2.5-pro[1m]"
      export ANTHROPIC_DEFAULT_SONNET_MODEL="mimo-v2.5[1m]"
      export ANTHROPIC_DEFAULT_OPUS_MODEL="mimo-v2.5-pro[1m]"
      export ANTHROPIC_DEFAULT_HAIKU_MODEL="mimo-v2.5[1m]"
      export CLAUDE_CODE_SUBAGENT_MODEL="haiku"

      exec ${claudeCode}/bin/claude "$@"
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
