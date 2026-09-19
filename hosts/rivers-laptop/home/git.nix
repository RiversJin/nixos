{ ... }:

{
  programs.git = {
    enable = true;
    settings = {
      user.name = "RiversJin";
      user.email = "riversjin1999@gmail.com";
      core.editor = "vim";
      init.defaultBranch = "main";
      http.proxy = "http://localhost:7890";
      https.proxy = "http://localhost:7890";
    };
  };

  programs.gh = {
    enable = true;
    gitCredentialHelper = {
      enable = true;
    };
  };
}
