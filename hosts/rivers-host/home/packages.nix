{ pkgs, ... }:

{
  imports = [ ./qq.nix ];

  home.packages = with pkgs; [
    nemo-with-extensions
    wechat
    nixfmt
    nixd
    tree
    time
    bat
    pwvucontrol
    resources
    gh
    uv
    # Keep the credential backend stable across Plasma and niri sessions.
    (symlinkJoin {
      name = "obsidian-with-keyring";
      paths = [ obsidian ];
      nativeBuildInputs = [ makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/obsidian --add-flags "--password-store=gnome-libsecret"
      '';
    })
  ];

  # Desktop entries
  xdg.desktopEntries = {
    screen-off = {
      name = "关闭屏幕";
      genericName = "Turn off display";
      comment = "Turn off displays";
      exec = "niri msg action power-off-monitors";
      icon = "preferences-desktop-display";
      categories = [ "System" ];
      terminal = false;
      settings = {
        Keywords = "screen;display;monitor;dpms;turn off display;turn off displays;关闭屏幕;熄屏;";
      };
    };
    display-power-save = {
      name = "显示器省电";
      genericName = "Display power save";
      comment = "Switch displays to 4K60 and lower AMD GPU memory clock";
      exec = "display-power-save";
      icon = "battery-profile-powersave";
      categories = [ "System" ];
      terminal = false;
      settings = {
        Keywords = "display;monitor;power;save;gpu;refresh;省电;显示器;刷新率;";
      };
    };
    display-performance = {
      name = "显示器高刷";
      genericName = "Display performance";
      comment = "Restore high refresh displays and automatic AMD GPU clocks";
      exec = "display-performance";
      icon = "battery-profile-performance";
      categories = [ "System" ];
      terminal = false;
      settings = {
        Keywords = "display;monitor;performance;gpu;refresh;高刷;显示器;刷新率;";
      };
    };
    wechat = {
      name = "微信";
      exec = "env QT_IM_MODULE=fcitx wechat %U";
      icon = "wechat";
      comment = "Wechat Desktop";
      categories = [ "Utility" ];
      startupNotify = true;
      terminal = false;
    };
    code = {
      name = "Visual Studio Code";
      comment = "Code Editing. Redefined.";
      exec = "/home/rivers/.local/bin/code %F";
      icon = "/home/rivers/.local/apps/VSCode-linux-x64/resources/app/resources/linux/code.png";
      categories = [
        "TextEditor"
        "Development"
        "IDE"
      ];
      mimeType = [
        "inode/directory"
        "text/plain"
      ];
      startupNotify = true;
      settings = {
        StartupWMClass = "Code";
      };
      actions = {
        new-empty-window = {
          name = "New Empty Window";
          exec = "/home/rivers/.local/bin/code --new-window %F";
          icon = "/home/rivers/.local/apps/VSCode-linux-x64/resources/app/resources/linux/code.png";
        };
      };
    };
  };
}
