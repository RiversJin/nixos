{ lib, ... }:

{
  programs.wezterm = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      font = lib.generators.mkLuaInline ''
        wezterm.font_with_fallback({
          "JetBrainsMono Nerd Font",
          "Source Han Sans SC",
        })
      '';
      font_size = 12.0;

      colors = {
        background = "#2b3045";
        foreground = "#c0caf5";
      };
      window_background_opacity = 0.76;
      wayland_window_background_blur = true;
      enable_scroll_bar = true;
      window_padding = {
        left = 6;
        right = 6;
        top = 6;
        bottom = 6;
      };

      mouse_bindings = lib.generators.mkLuaInline ''
        {
          {
            event = { Down = { streak = 1, button = { WheelUp = 1 } } },
            mods = "NONE",
            action = wezterm.action.ScrollByLine(-3),
            alt_screen = false,
          },
          {
            event = { Down = { streak = 1, button = { WheelDown = 1 } } },
            mods = "NONE",
            action = wezterm.action.ScrollByLine(3),
            alt_screen = false,
          },
        }
      '';

      audible_bell = "Disabled";
      hide_tab_bar_if_only_one_tab = true;
      window_close_confirmation = "NeverPrompt";
    };
  };
}
