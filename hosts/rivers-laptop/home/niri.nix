{
  config,
  lib,
  pkgs,
  ...
}:
let
  screenshotDir = "${config.home.homeDirectory}/Pictures/Screenshots/Niri-screenshots";
  noctalia = pkgs.noctalia-shell.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace Modules/Panels/Launcher/LauncherListDelegate.qml \
        --replace-fail 'font.weight: Style.fontWeightBold' 'font.weight: Style.fontWeightMedium'
      substituteInPlace Modules/Panels/Launcher/LauncherGridDelegate.qml \
        --replace-fail 'font.weight: Style.fontWeightBold' 'font.weight: Style.fontWeightMedium'
      # Reuse Noctalia's overview renderer with our per-monitor daily wallpapers.
      substituteInPlace Modules/Background/Overview.qml \
        --replace-fail 'CompositorService.isNiri && Settings.data.wallpaper.enabled &&' 'CompositorService.isNiri &&' \
        --replace-fail 'property string wallpaper: ""' 'property string wallpaper: "file://${config.home.homeDirectory}/.local/state/niri-daily/current/wallpaper"'
      # Qt cannot resolve Fcitx's English-state symbolic icon through the GTK theme.
      substituteInPlace Modules/Bar/Widgets/Tray.qml \
        --replace-fail 'let icon = modelData?.icon || "";' 'let icon = modelData?.icon || ""; if (/\/(input-keyboard-symbolic|fcitx_rime_latin)(\?|$)/.test(icon)) return "file://${./niri/rime-latin.svg}";'
    '';
  });
  wallpaper = pkgs.runCommand "niri-moonlit-ridges.png" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    rsvg-convert ${./niri/wallpaper.svg} -o "$out"
  '';
  dailyState = "${config.home.homeDirectory}/.local/state/niri-daily";
  themeFiles = {
    "niri/config.kdl" = "niri.kdl";
    "mako/config" = "mako.conf";
    "swaylock/config" = "swaylock.conf";
  };
  themeBase = pkgs.linkFarm "niri-theme-base" (
    lib.mapAttrsToList (_: name: {
      inherit name;
      path = config.xdg.configFile."niri/theme-base/${name}".source;
    }) themeFiles
  );
  dailyTheme = pkgs.writeShellApplication {
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
      export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
      exec python3 ${./niri/daily-theme.py} "$@"
    '';
  };
  screenshotAnnotate = pkgs.writeShellApplication {
    name = "niri-screenshot-annotate";
    runtimeInputs = [ pkgs.grim pkgs.slurp pkgs.satty pkgs.wl-clipboard pkgs.coreutils ];
    text = ''
      geometry=$(slurp) || exit 0
      screenshot=$(mktemp --suffix=.png)
      trap 'rm -f "$screenshot"' EXIT
      grim -g "$geometry" "$screenshot"
      mkdir -p "$HOME/Pictures/Screenshots"
      satty --filename "$screenshot" \
        --initial-tool arrow \
        --copy-command wl-copy \
        --output-filename "$HOME/Pictures/Screenshots/$(date +%Y-%m-%d_%H-%M-%S-%N)-annotated.png"
    '';
  };
  forceClose = pkgs.writeShellApplication {
    name = "niri-force-close";
    runtimeInputs = [ pkgs.python3 pkgs.niri ];
    text = ''
      exec python3 ${./niri/force-close.py}
    '';
  };
  sessionService = description: command: {
    Unit = {
      Description = description;
      PartOf = [ "niri-desktop.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = command;
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install.WantedBy = [ "niri-desktop.target" ];
  };
in
{
  home.packages = with pkgs; [
    dailyTheme
    forceClose
    screenshotAnnotate
    noctalia
    kitty
    cliphist
    grim
    slurp
    satty
    brightnessctl
    pavucontrol
    libnotify
    thunar
    adwaita-icon-theme
    kdePackages.breeze
    kdePackages.breeze-icons
    mako
    swaylock
    swayidle
    swaybg
    wl-clipboard
    playerctl
  ];
  # Seed writable Noctalia preferences when the declarative preset changes.
  # Ordinary rebuilds preserve changes made in Noctalia's settings UI.
  home.activation.niriNoctalia = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    run mkdir -p "${config.home.homeDirectory}/.config/noctalia"
    for name in settings colors; do
      source_file="${./niri/noctalia}/$name.json"
      target_file="${config.home.homeDirectory}/.config/noctalia/$name.json"
      preset_file="${config.home.homeDirectory}/.config/noctalia/.$name-preset.json"
      if ! cmp -s "$source_file" "$preset_file" || [ ! -f "$target_file" ]; then
        run install -m 600 "$source_file" "$target_file"
        run install -m 600 "$source_file" "$preset_file"
      fi
    done
  '';
  # A path-only tray glyph avoids font-dependent rendering of Rime's SVG.
  xdg.dataFile."icons/klassy-dark/22/input-keyboard-symbolic.svg".source = ./niri/rime-latin.svg;
  xdg.dataFile."icons/klassy-dark/22/fcitx_rime_latin.svg".source = ./niri/rime-latin.svg;
  xdg.dataFile."icons/hicolor/scalable/apps/fcitx_rime_latin.svg".source = ./niri/rime-latin.svg;
  xdg.dataFile."icons/hicolor/scalable/apps/org.fcitx.Fcitx5.fcitx_rime_latin.svg".source = ./niri/rime-latin.svg;
  xdg.configFile."niri/theme-base/niri.kdl".source = ./niri/config.kdl;
  xdg.configFile."niri/wallpaper.png".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/wallpaper";
  xdg.configFile."niri/config.kdl".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/niri.kdl";
  xdg.configFile."swaylock/config".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/swaylock.conf";
  xdg.configFile."mako/config".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/mako.conf";
  xdg.configFile."niri/theme-base/mako.conf".source = ./niri/mako.conf;
  home.activation.niriFcitxHotkey = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    run ${pkgs.python3}/bin/python3 ${./niri/fcitx-hotkeys.py}
  '';
  home.activation.niriDailyTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${dailyTheme}/bin/niri-daily init
  '';
  systemd.user.timers.niri-daily-theme = {
    Unit = {
      Description = "Daily anime wallpaper and palette";
      PartOf = [ "niri-desktop.target" ];
    };
    Timer = {
      OnCalendar = "*-*-* 09:00:00";
      Persistent = true;
      Unit = "niri-daily-theme.service";
    };
    Install.WantedBy = [ "niri-desktop.target" ];
  };
  xdg.desktopEntries.niri-wallpaper-next = {
    name = "换一张壁纸";
    genericName = "Wallpaper";
    settings.Keywords = "bz;bizhi;huanbizhi;wallpaper;anime;random;theme;";
    comment = "随机二次元壁纸并自动搭配桌面颜色";
    exec = "${dailyTheme}/bin/niri-daily next";
    icon = "preferences-desktop-wallpaper";
    terminal = false;
    categories = [ "Utility" ];
    settings.NotShowIn = "KDE;";
  };

  # A target started only by Niri, so these daemons do not enter KDE sessions.
  systemd.user.targets.niri-desktop = {
    Unit = {
      Description = "Niri desktop components";
      BindsTo = [ "niri.service" ];
      After = [ "niri.service" ];
    };
  };
  systemd.user.services = {
    niri-daily-theme = {
      Unit = {
        Description = "Select today's anime wallpaper and generate desktop colors";
        After = [ "graphical-session.target" ];
        PartOf = [ "niri-desktop.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${dailyTheme}/bin/niri-daily update";
        TimeoutStartSec = 240;
      };
      Install.WantedBy = [ "niri-desktop.target" ];
    };
    niri-polkit = sessionService "Niri authentication agent" "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    niri-bar = lib.recursiveUpdate
      (sessionService "Niri Noctalia desktop shell" "${noctalia}/bin/noctalia-shell")
      {
        Unit.After = [ "graphical-session.target" "niri-notifications.service" ];
        Service.Environment = [ "QS_ICON_THEME=breeze" ];
      };
    niri-wallpaper = sessionService "Moonlit ridges wallpaper" "${dailyTheme}/bin/niri-daily wallpaper";
    niri-notifications = sessionService "Niri notifications" "${pkgs.mako}/bin/mako";
  };

  xdg.configFile."niri/theme-base/swaylock.conf".text = ''
    image=${wallpaper}
    scaling=fill
    font=Maple Mono Normal NF CN
    indicator-radius=72
    indicator-thickness=5
    color=101923
    inside-color=14202fcc
    ring-color=91b8ed
    key-hl-color=91b8ed
    bs-hl-color=edb69b
    text-color=dce5ef
    line-uses-inside
    inside-wrong-color=402536
    ring-wrong-color=ed8796
    show-failed-attempts
  '';
  services.swayidle = {
    enable = true;
    events = {
      lock = "${pkgs.swaylock}/bin/swaylock -f; ${pkgs.niri}/bin/niri msg action power-off-monitors";
      before-sleep = "${pkgs.swaylock}/bin/swaylock -f";
    };
  };
  xdg.configFile."kitty/kitty.conf".text = ''
    font_family Maple Mono Normal NF CN
    font_size 12.0
    background #12141d
    foreground #f4f1ff
    selection_background #3a3448
    selection_foreground #ffffff
    cursor #f6c177
    active_tab_background #c4b5fd
    active_tab_foreground #12141d
    inactive_tab_background #1d202b
    inactive_tab_foreground #c7c3d8
    window_padding_width 10
    background_opacity 0.82
    dynamic_background_opacity yes
    hide_window_decorations titlebar-only
    confirm_os_window_close 0
  '';

  home.file.".local/bin/niri-clipboard" = {
    executable = true;
    text = ''
      #!${pkgs.runtimeShell}
      exec ${noctalia}/bin/noctalia-shell ipc call launcher clipboard
    '';
  };
  home.file.".local/bin/niri-screenshot" = {
    executable = true;
    text = ''
      #!${pkgs.bash}/bin/bash
      set -euo pipefail

      mkdir -p "${screenshotDir}"
      file="${screenshotDir}/Screenshot from $(${pkgs.coreutils}/bin/date '+%Y-%m-%d %H-%M-%S').png"
      geometry="$(${pkgs.slurp}/bin/slurp || true)"
      [ -n "$geometry" ] || exit 0
      ${pkgs.grim}/bin/grim -g "$geometry" "$file"
      ${pkgs.wl-clipboard}/bin/wl-copy < "$file"

      if [ "''${1:-}" = "--edit" ]; then
        ${pkgs.satty}/bin/satty --filename "$file" --output-filename "$file" || true
      fi
    '';
  };

}
