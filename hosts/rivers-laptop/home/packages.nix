{ pkgs, ... }:

{
  home.packages = with pkgs; [
    nixfmt
    nixd
    tree
    bat
    gh
    uv
    google-chrome
    wechat
  ];

  xdg.desktopEntries = {
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
      categories = [ "TextEditor" "Development" "IDE" ];
      mimeType = [ "inode/directory" "text/plain" ];
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
