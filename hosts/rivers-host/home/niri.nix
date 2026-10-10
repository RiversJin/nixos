{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Rofi 2.0.0 lacks Wayland IME; pin the tested upstream implementation.
  rofiIme = pkgs.rofi.override {
    rofi-unwrapped = pkgs.rofi-unwrapped.overrideAttrs (_: {
      version = "2.0.0-dev";
      src = builtins.fetchTree {
        type = "git";
        url = "https://github.com/davatorium/rofi.git";
        rev = "a8569d524cf999c14134b00e7870f9ce88f210de";
        narHash = "sha256-y3dfLYksuUixRRTbQxL4kN3GCekmPoIJAeLDTfi2T6c=";
        ref = "next";
        submodules = true;
        shallow = true;
      };
    });
  };
  noctalia = pkgs.noctalia-shell.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace Modules/Panels/Launcher/LauncherListDelegate.qml \
        --replace-fail 'font.weight: Style.fontWeightBold' 'font.weight: Style.fontWeightMedium'
      substituteInPlace Modules/Panels/Launcher/LauncherGridDelegate.qml \
        --replace-fail 'font.weight: Style.fontWeightBold' 'font.weight: Style.fontWeightMedium'
      # Route every internal lock entry (including launcher and IPC) to swaylock.
      cat > Modules/LockScreen/LockScreen.qml <<'QML'
      import QtQuick
      import Quickshell
      import qs.Services.UI

      Item {
        property bool active: false
        Component.onCompleted: PanelService.lockScreen = this
        onActiveChanged: {
          if (active) {
            Quickshell.execDetached(["${pkgs.swaylock}/bin/swaylock", "-f"]);
            active = false;
          }
        }
      }
      QML
      # Reuse Noctalia's overview renderer with our per-monitor daily wallpapers.
      substituteInPlace Modules/Background/Overview.qml \
        --replace-fail 'CompositorService.isNiri && Settings.data.wallpaper.enabled &&' 'CompositorService.isNiri &&' \
        --replace-fail 'property string wallpaper: ""' 'property string wallpaper: "file://${config.home.homeDirectory}/.local/state/niri-daily/current/wallpaper-" + modelData.name'
      # Qt cannot resolve Fcitx's English-state symbolic icon through the GTK theme.
      substituteInPlace Modules/Bar/Widgets/Tray.qml \
        --replace-fail 'let icon = modelData?.icon || "";' 'let icon = modelData?.icon || ""; if (/\/(input-keyboard-symbolic|fcitx_rime_latin)(\?|$)/.test(icon)) return "file://${./niri/rime-latin.svg}";'
    '';
  });
  controlCard = pkgs.stdenvNoCC.mkDerivation {
    pname = "niri-control-card";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [
      pkgs.wrapGAppsHook3
      pkgs.gobject-introspection
    ];
    buildInputs = [
      pkgs.gtk3
      pkgs.gtk-layer-shell
    ];
    installPhase = ''
      mkdir -p "$out/bin"
      cp ${./niri/controls.py} "$out/bin/niri-control-card"
      sed -i '1i#!${
        pkgs.python3.withPackages (p: [
          p.pygobject3
          p.pulsectl
        ])
      }/bin/python3' "$out/bin/niri-control-card"
      chmod +x "$out/bin/niri-control-card"
    '';
  };
  controlToggle = pkgs.writeShellApplication {
    name = "niri-control-toggle";
    runtimeInputs = [ pkgs.systemd ];
    text = ''
      if systemctl --user is-active --quiet niri-controls.service; then
        systemctl --user kill --signal=SIGUSR1 niri-controls.service
      else
        systemctl --user start niri-controls.service
      fi
    '';
  };
  notificationTools = pkgs.writeShellApplication {
    name = "niri-notifications";
    runtimeInputs = [
      pkgs.python3
      pkgs.mako
      rofiIme
    ];
    text = ''
      exec python3 ${./niri/notifications.py} "$@"
    '';
  };
  gracefulLogout = pkgs.writeShellApplication {
    name = "niri-logout";
    runtimeInputs = [ pkgs.niri pkgs.python3 pkgs.libnotify pkgs.systemd ];
    text = ''
      exec systemd-run --user --collect --unit=niri-graceful-logout \
        --setenv=NIRI_SOCKET="$NIRI_SOCKET" \
        --setenv=PATH="$PATH" \
        python3 ${./niri/logout.py}
    '';
  };
  wallpaper = pkgs.runCommand "niri-moonlit-ridges.png" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
    rsvg-convert ${./niri/wallpaper.svg} -o "$out"
  '';
  dailyState = "${config.home.homeDirectory}/.local/state/niri-daily";
  themeFiles = {
    "niri/config.kdl" = "niri.kdl";
    "waybar/style.css" = "waybar.css";
    "swaync/style.css" = "swaync.css";
    "fuzzel/fuzzel.ini" = "fuzzel.ini";
    "rofi/config.rasi" = "rofi.rasi";
    "mako/config" = "mako.conf";
    "swaylock/config" = "swaylock.conf";
  };
  themeBase = pkgs.linkFarm "niri-theme-base" (
    lib.mapAttrsToList (_: name: {
      inherit name;
      path = config.xdg.configFile."niri/theme-base/${name}".source;
    }) themeFiles
  );
  dailyTheme = import ../../../home/niri-daily.nix {
    inherit pkgs lib themeBase wallpaper;
    outputs = [ "DP-1" "DP-3" ];
    recentLimit = 28;
    themeFiles = lib.attrValues themeFiles;
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
    runtimeInputs = [
      pkgs.python3
      pkgs.niri
    ];
    text = ''
      exec python3 ${./niri/force-close.py}
    '';
  };
  trackpadGestures = pkgs.runCommand "niri-trackpad-gestures" { } ''
    mkdir -p "$out"
    cp ${./niri/gestures}/* "$out/"
  '';
  trackpadGestureConfig = builtins.toJSON {
    touchpad = {
      pinch_deadzone_enabled = "False";
      pinch."5" = {
        i = {
          start = [ ];
          update = { };
          end = [ "${noctalia}/bin/noctalia-shell ipc call launcher toggle" ];
        };
        o = {
          start = [ ];
          update = { };
          end = [ "${pkgs.python3}/bin/python3 ${trackpadGestures}/empty-workspace.py" ];
        };
      };
    };
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
    gracefulLogout
    forceClose
    screenshotAnnotate
    satty
    rofiIme
    noctalia
    kdePackages.breeze-icons
    notificationTools
    controlToggle
    mako
    waybar
    fuzzel
    swaylock
    swayidle
    swaybg
    wl-clipboard
    cliphist
    playerctl
  ];
  home.pointerCursor = {
    enable = true;
    name = "Bibata-Modern-Classic";
    package = pkgs.bibata-cursors;
    size = 24;
    gtk.enable = true;
    x11.enable = true;
  };
  dconf.settings."org/gnome/desktop/interface" = {
    cursor-theme = "Bibata-Modern-Classic";
    cursor-size = 24;
    icon-theme = "breeze";
    color-scheme = "prefer-light";
  };
  home.activation.niriDesktopDefaults = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.python3}/bin/python3 - <<'PYTHON'
    from pathlib import Path
    import re
    for version in ("gtk-3.0", "gtk-4.0"):
        path = Path.home() / ".config" / version / "settings.ini"
        if path.exists():
            text = path.read_text()
            text = re.sub(r"(?m)^gtk-application-prefer-dark-theme=.*$", "gtk-application-prefer-dark-theme=false", text)
            text = re.sub(r"(?m)^gtk-icon-theme-name=.*$", "gtk-icon-theme-name=breeze", text)
            text = re.sub(r"(?m)^gtk-modules=colorreload-gtk-module\n?", "", text)
            path.write_text(text)
    PYTHON
    ${pkgs.xdg-utils}/bin/xdg-mime default nemo.desktop inode/directory
  '';
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
  xdg.dataFile."icons/hicolor/scalable/apps/fcitx_rime_latin.svg".source = ./niri/rime-latin.svg;
  xdg.dataFile."icons/hicolor/scalable/apps/org.fcitx.Fcitx5.fcitx_rime_latin.svg".source =
    ./niri/rime-latin.svg;
  xdg.configFile."niri/theme-base/niri.kdl".source = ./niri/config.kdl;
  xdg.configFile."niri/wallpaper.png".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/wallpaper";
  xdg.configFile."niri/config.kdl".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/niri.kdl";
  xdg.configFile."waybar/style.css".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/waybar.css";
  xdg.configFile."swaync/style.css".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/swaync.css";
  xdg.configFile."fuzzel/fuzzel.ini".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/fuzzel.ini";
  xdg.configFile."swaylock/config".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/swaylock.conf";
  xdg.configFile."rofi/config.rasi".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/rofi.rasi";
  xdg.configFile."niri/theme-base/rofi.rasi".source = ./niri/rofi.rasi;
  xdg.configFile."mako/config".source =
    config.lib.file.mkOutOfStoreSymlink "${dailyState}/current/mako.conf";
  xdg.configFile."niri/theme-base/mako.conf".source = ./niri/mako.conf;
  home.activation.niriDailyTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    ${dailyTheme}/bin/niri-daily init
    # Boot-time activation runs before the user's session bus is available.
    if [ -n "''${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ] &&
       ${pkgs.systemd}/bin/systemctl --user is-active --quiet niri.service; then
      ${pkgs.systemd}/bin/systemd-run --user --wait --pipe --collect ${pkgs.niri}/bin/niri msg action load-config-file --path "${config.home.homeDirectory}/.config/niri/config.kdl"
    fi
  '';
  systemd.user.timers.niri-daily-theme = {
    Unit = {
      Description = "Daily scenery wallpaper and palette";
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
    comment = "随机风景壁纸并自动搭配桌面颜色";
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
    niri-trackpad-gestures = lib.recursiveUpdate
      (sessionService "Magic Trackpad five-finger gestures" "${pkgs.python3}/bin/python3 ${trackpadGestures}/run.py")
      {
        Service.Environment = [
          "PYTHONUNBUFFERED=1"
          "NIRI_GESTURE_CONFIG=${pkgs.writeText "niri-gestures.json" trackpadGestureConfig}"
        ];
      };
    niri-controls = {
      Unit = {
        Description = "Niri audio control card";
        PartOf = [ "niri-desktop.target" ];
        After = [ "graphical-session.target" ];
      };
      Service.ExecStart = "${controlCard}/bin/niri-control-card";
    };
    niri-daily-theme = {
      Unit = {
        Description = "Select today's scenery wallpaper and generate desktop colors";
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
    niri-bar =
      lib.recursiveUpdate (sessionService "Niri Noctalia desktop shell" "${noctalia}/bin/noctalia-shell")
        { Service.Environment = [ "QS_ICON_THEME=breeze" ]; };
    niri-wallpaper = sessionService "Moonlit ridges wallpaper" "${dailyTheme}/bin/niri-daily wallpaper";
    niri-notifications = sessionService "Niri notifications" "${pkgs.mako}/bin/mako";
    niri-fcitx5 = sessionService "Niri input method" "${config.i18n.inputMethod.package}/bin/fcitx5 -D";
    niri-idle = sessionService "Niri lock and display idle" (
      "${pkgs.swayidle}/bin/swayidle -w "
      + "timeout 600 '${pkgs.swaylock}/bin/swaylock -f' "
      + "timeout 900 '${pkgs.niri}/bin/niri msg action power-off-monitors' "
      + "resume '${pkgs.niri}/bin/niri msg action power-on-monitors' "
      + "before-sleep '${pkgs.swaylock}/bin/swaylock -f' "
      + "lock '${pkgs.swaylock}/bin/swaylock -f'"
    );
  };

  xdg.configFile."niri/theme-base/fuzzel.ini".text = ''
    [main]
    fields=filename,name,generic,keywords
    font=Maple Mono Normal NF CN:size=12
    prompt="  ›  "
    width=42
    lines=9
    horizontal-pad=24
    vertical-pad=20
    inner-pad=12
    terminal=${pkgs.kitty}/bin/kitty -e
    layer=overlay
    [colors]
    background=101a28a6
    text=dce5efff
    match=91b8edff
    selection=293e50ff
    selection-text=f0f5f9ff
    selection-match=91b8edff
    border=91b8ed55
    [border]
    width=1
    radius=8
  '';
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
  xdg.configFile."swaync/config.json".text = builtins.toJSON {
    positionX = "right";
    positionY = "top";
    layer = "overlay";
    control-center-layer = "overlay";
    # SwayNC maps keyboard-shortcuts=true to EXCLUSIVE layer keyboard focus.
    # Keep typing in the application even while the notification panel is open.
    keyboard-shortcuts = false;
    notification-inline-replies = false;
    control-center-width = 320;
    fit-to-screen = false;
    control-center-height = -1;
    control-center-margin-top = 0;
    control-center-margin-right = 0;
    control-center-margin-bottom = 0;
    control-center-margin-left = 0;
    control-center-exclusive-zone = true;
    layer-shell-cover-screen = false;
    notification-window-width = 320;
    transition-time = 120;
    timeout = 6;
    timeout-critical = 0;
    widgets = [
      "buttons-grid"
      "notifications"
    ];
    widget-config.buttons-grid = {
      buttons-per-row = 2;
      actions = [
        {
          label = "勿扰";
          type = "toggle";
          command = "${pkgs.swaynotificationcenter}/bin/swaync-client -d";
          update-command = "${pkgs.swaynotificationcenter}/bin/swaync-client -D";
        }
        {
          label = "清空通知";
          command = "${pkgs.swaynotificationcenter}/bin/swaync-client -C";
        }
      ];
    };
  };
  xdg.configFile."niri/theme-base/swaync.css".text = ''
    @import "${pkgs.swaynotificationcenter}/etc/xdg/swaync/style.css";
    :root {
      --cc-bg: rgba(18, 27, 39, 0.48);
      --noti-bg: 18, 29, 42;
      --noti-bg-alpha: 0.58;
      --noti-border-color: rgba(180, 203, 228, 0.12);
      --text-color: #dce5ef;
      --text-color-disabled: #91a4b9;
      --bg-selected: #91b8ed;
      --border-radius: 10px;
      --notification-shadow: none;
      --notification-icon-size: 32px;
      --font-size-body: 13px;
      --font-size-summary: 14px;
      --noti-bg-focus: transparent;
      --noti-bg-hover: rgba(160, 190, 220, 0.10);
    }
    * { font-family: "Noto Sans CJK SC", sans-serif; font-size: 13px; }
    .control-center { margin: 0; border-radius: 0 0 0 10px; border: none; }
    .widget-buttons-grid { margin: 0; padding: 8px 10px 4px; background: transparent; }
    .widget-buttons-grid button { min-height: 26px; padding: 4px 12px; background: rgba(160, 190, 220, 0.06); border: none; border-radius: 6px; }
    .widget-buttons-grid button:hover { background: rgba(160, 190, 220, 0.13); }
    /* Outrank the default collapsed-group and focused-row backgrounds. */
    .control-center .notification-group,
    .control-center .notification-group:focus,
    .control-center .notification-row,
    .control-center .notification-row:focus,
    .control-center .notification-background { background: transparent; box-shadow: none; outline: none; }
    .control-center .notification-group .notification-row .notification-background .notification {
      background: rgba(18, 29, 42, 0.30);
      border: 1px solid rgba(180, 203, 228, 0.10);
    }
    .notification-row .notification-background .notification .notification-default-action { padding: 10px 12px; }
    .notification-row .notification-background .notification .notification-default-action .notification-content .text-box .summary { font-weight: 500; }
    .notification-row .notification-background .notification .notification-default-action .notification-content .text-box .time { font-size: 11px; font-weight: normal; color: #91a4b9; }
    .widget-buttons-grid button { font-weight: normal; }
    .widget-buttons-grid button.active { background: #344c68; }
    .control-center-list-placeholder { min-height: 72px; padding: 12px; }
    .control-center-list-placeholder image { -gtk-icon-size: 24px; }
    .widget-title, .widget-dnd { background: transparent; }
    .widget-title button, .widget-dnd switch { background: #26394e; border: 1px solid #506780; }
    .widget-dnd switch:checked { background: #719dcc; }
  '';
  xdg.configFile."waybar/config.jsonc".text = builtins.toJSON {
    layer = "top";
    position = "top";
    height = 38;
    margin-top = 0;
    margin-left = 0;
    margin-right = 0;
    spacing = 6;
    modules-left = [
      "niri/workspaces"
      "niri/window"
    ];
    modules-center = [ "clock" ];
    modules-right = [
      "custom/notifications"
      "tray"
      "cpu"
      "memory"
      "pulseaudio"
      "network"
    ];
    "niri/workspaces" = {
      format = "{index}";
    };
    "niri/window" = {
      max-length = 38;
    };
    clock = {
      format = "{:%m月%d日  %H:%M}";
      tooltip-format = "{:%Y年%m月%d日 %A}";
    };
    tray = {
      spacing = 10;
      icon-size = 18;
    };
    cpu = {
      format = "CPU {usage}%";
      interval = 5;
    };
    memory = {
      format = "RAM {percentage}%";
      interval = 5;
    };
    pulseaudio = {
      format = "VOL {volume}%";
      format-muted = "静音";
      on-click = "${controlToggle}/bin/niri-control-toggle";
      on-click-right = "${pkgs.pwvucontrol}/bin/pwvucontrol";
    };
    network = {
      format-ethernet = "有线";
      format-wifi = "{essid}";
      format-disconnected = "离线";
      tooltip-format = "{ifname}: {ipaddr}";
    };
    "custom/notifications" = {
      format = "";
      on-click = "${notificationTools}/bin/niri-notifications history";
      on-click-right = "${notificationTools}/bin/niri-notifications dnd";
      tooltip-format = "通知历史\n右键：切换勿扰";
    };
  };
  xdg.configFile."niri/theme-base/waybar.css".text = ''
    * { font-family: "Maple Mono Normal NF CN", sans-serif; font-size: 12px; min-height: 0; }
    window#waybar { background: rgba(12, 20, 30, 0.60); color: #dce5ef; border: none; border-bottom: 1px solid #344356; border-radius: 0; }
    #workspaces button { color: #8193a8; background: transparent; padding: 0 10px; margin: 5px 2px; border-radius: 4px; border: none; }
    #workspaces button.active { background: #91b8ed; color: #14202f; }
    #workspaces button:hover { background: #344356; color: #dce5ef; }
    #custom-notifications { color: #b6c8dc; font-size: 16px; padding: 0 10px; border: none; border-radius: 6px; margin: 4px 0; }
    #custom-notifications:hover { background: rgba(160, 190, 220, 0.12); }
    #window { color: #91a4b9; margin-left: 14px; }
    #clock { color: #dce5ef; font-weight: bold; }
    #cpu, #memory, #pulseaudio, #network, #tray { padding: 0 10px; }
    #cpu, #memory { color: #91a4b9; }
    tooltip { background: #14202f; border: none; border-bottom: 1px solid #344356; border-radius: 0; }
  '';

  xdg.desktopEntries.screen-off.exec = lib.mkForce "${pkgs.niri}/bin/niri msg action power-off-monitors";
  services.xremap.package = lib.mkForce pkgs.xremap.niri;
}
