{ pkgs, ... }:

{
  programs.kitty = {
    enable = true;
    # Kitty itself is installed system-wide alongside the other terminals.
    package = null;

    font = {
      name = "JetBrainsMono Nerd Font";
      size = 12;
    };
    themeFile = "tokyo_night_storm";

    extraConfig = ''
      mouse_map ctrl+left release grabbed,ungrabbed mouse_handle_click link
      mouse_map ctrl+left press grabbed discard_event
    '';

    settings = {
      foreground = "#c0caf5";
      background = "#2b3045";
      background_opacity = 0.76;
      background_blur = 1;

      window_padding_width = 6;
      placement_strategy = "center";
      active_border_color = "#7aa2f7";
      inactive_border_color = "#414868";

      tab_bar_edge = "top";
      tab_bar_style = "powerline";
      tab_powerline_style = "round";
      active_tab_foreground = "#1a1b26";
      active_tab_background = "#7aa2f7";
      inactive_tab_foreground = "#a9b1d6";
      inactive_tab_background = "#24283b";

      cursor = "#c0caf5";
      cursor_text_color = "#1a1b26";
      cursor_trail = 5;
      cursor_trail_decay = "0.08 0.25";
      cursor_trail_start_threshold = 2;
      enable_audio_bell = false;
      linux_display_server = "wayland";
    };
  };

  xdg.dataFile."applications/kitty-quick-access.desktop" = {
    text = ''
      [Desktop Entry]
      Type=Application
      Name=Kitty Quick Access Terminal
      Comment=Toggle the Kitty quick access terminal
      Exec=${pkgs.kitty}/bin/kitten quick-access-terminal
      Icon=kitty
      Terminal=false
      NoDisplay=true
      StartupNotify=false
      X-KDE-GlobalAccel-CommandShortcut=true
      X-KDE-Shortcuts=Meta+Return
    '';
  };
}
