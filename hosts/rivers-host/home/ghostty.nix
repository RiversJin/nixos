{ ... }:

{
  programs.ghostty = {
    enable = true;
    settings = {
      background = "#2b3045";
      foreground = "#c0caf5";
      background-opacity = 0.76;
      background-opacity-cells = true;
      background-blur = true;
      font-family = [
        "JetBrainsMono Nerd Font"
        "Source Han Sans SC"
      ];
      font-size = 12;
      window-padding-x = 6;
      window-padding-y = 6;
      window-padding-balance = true;
      window-decoration = "server";
      confirm-close-surface = false;
      keybind = [
        "ctrl+shift+b=toggle_background_opacity"
      ];
    };
  };

  xdg.configFile."xdg-terminals.list".text = ''
    com.mitchellh.ghostty.desktop
  '';

}
