{ ... }:

let
  httpProxy = "http://127.0.0.1:7890";
in
{
  # Git
  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      user.name = "RiversJin";
      user.email = "riversjin1999@gmail.com";
      core.editor = "nvim";
      init.defaultBranch = "main";
      http.proxy = httpProxy;
      https.proxy = httpProxy;
    };
  };

  programs.gh = {
    enable = true;
    gitCredentialHelper = {
      enable = true;
    };
  };
}
