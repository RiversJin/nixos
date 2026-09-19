{
  lib,
  config,
  pkgs,
  nix-search-tv,
  ...
}:

let
  # Keep the packaged command/option completions, adding dynamic session names.
  zellijCompletions = pkgs.runCommand "zellij-zsh-completions" { } ''
    mkdir -p "$out"
    sed -E '/^.*::(session_name|target_session) -- /s/:_default/:_rivers_zellij_sessions/' \
      ${pkgs.zellij}/share/zsh/site-functions/_zellij > "$out/_zellij"
  '';
in
{
  imports = [ ./pizzapi.nix ];

  home.stateVersion = "25.11";

  home.packages = with pkgs; [
    zellij
    nixfmt
    nixd
    tree
    bat
    tmux
    jq
    gh
    ripgrep

    clang
    rustup
    # llvmPackages.bintools
    pkg-config
    openssl
    lld
    nodejs_22
    chromium
    python3

    nix-search-tv.packages.${pkgs.stdenv.hostPlatform.system}.default
    television
  ];

  # Basic configuration
  home.username = "rivers";
  home.homeDirectory = "/home/rivers";

  # Git configuration
  programs.git = {
    enable = true;
    settings = {
      user.name = "RiversJin";
      user.email = "riversjin1999@gmail.com";

      core.editor = "vim";
      init.defaultBranch = "main";
    };
  };

  programs.gh = {
    enable = true;
    gitCredentialHelper.enable = true;
  };

  programs.fzf = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.starship = {
    enable = true;
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

  programs.zoxide = {
    enable = true;
    enableZshIntegration = true;
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    enableVteIntegration = true;

    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "sudo"
        "extract"
      ];
      # theme = "agnoster";
    };

    plugins = with pkgs; [
      {
        name = "formarks";
        src = fetchFromGitHub {
          owner = "wfxr";
          repo = "formarks";
          rev = "2ffd332e0a965d320e040bc8c23b4be34bf64322";
          sha256 = "155h630d4k1fwc3c74z9j5bc6dqwipc88bqzw292jgaj7kj7n0zr";
        };
        file = "formarks.plugin.zsh";
      }
      {
        name = "zsh-syntax-highlighting";
        src = fetchFromGitHub {
          owner = "zsh-users";
          repo = "zsh-syntax-highlighting";
          rev = "0.8.0";
          sha256 = "1yl8zdip1z9inp280sfa5byjbf2vqh2iazsycar987khjsi5d5w8";
        };
        file = "zsh-syntax-highlighting.zsh";
      }
      {
        name = "zsh-abbrev-alias";
        src = fetchFromGitHub {
          owner = "momo-lab";
          repo = "zsh-abbrev-alias";
          rev = "33fe094da0a70e279e1cc5376a3d7cb7a5343df5";
          sha256 = "1cvgvb1q0bwwnnvkd7yjc7sq9fgghbby1iffzid61gi9j895iblf";
        };
        file = "abbrev-alias.plugin.zsh";
      }
      {
        name = "zsh-autopair";
        src = fetchFromGitHub {
          owner = "hlissner";
          repo = "zsh-autopair";
          rev = "449a7c3d095bc8f3d78cf37b9549f8bb4c383f3d";
          sha256 = "1x16y24hbwcaxfhqabw4x26jmpxzz2zzmlvs9nnbzaxyi20cwfyz";
        };
        file = "autopair.zsh";
      }
    ];

    # enable starship
    initContent = ''
      # Include both running and resurrectable sessions; do not fall back to files.
      _rivers_zellij_sessions() {
        local -a sessions
        sessions=("''${(@f)$(command zellij list-sessions --short --no-formatting 2>/dev/null)}")
        sessions=("''${(@)sessions:#}")
        (( ''${#sessions} )) || return 1
        compadd -a sessions
      }
      fpath=(${zellijCompletions} $fpath)
      autoload -Uz _zellij
      compdef _zellij zellij

      if [ -f "${config.home.homeDirectory}/.cargo/env" ]; then
        source "${config.home.homeDirectory}/.cargo/env"
      fi
    '';
  };

  home.sessionVariables = {
    CARGO_HOME = "${config.home.homeDirectory}/.cargo";
    RUSTUP_HOME = "${config.home.homeDirectory}/.rustup";
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    CC = "clang";
    NIXPKGS_ALLOW_UNFREE = "1";
  };

  home.file.".config/nixpkgs/config.nix".text = ''
    { allowUnfree = true; }
  '';

  home.sessionPath = [
    "${config.home.homeDirectory}/.npm-global/bin"
    "${config.home.homeDirectory}/.cargo/bin"
    # Codex CLI is installed with https://chatgpt.com/codex/install.sh.
    "${config.home.homeDirectory}/.local/bin"
    "${pkgs.clang}/bin"
    "${pkgs.llvmPackages.bintools}/bin"
  ];

  home.file.".cargo/config.toml".text = ''
    [target.x86_64-unknown-linux-gnu]
    linker = "clang"
    ar = "llvm-ar"
    rustflags = ["-C", "link-arg=-fuse-ld=lld"]

    [env]
    CC = "clang"
  '';

  home.file.".config/television/cable/nix.toml".text = ''
    [metadata]
    name = "nix"
    requirements = ["nix-search-tv"]

    [source]
    command = "nix-search-tv print"

    [preview]
    command = "nix-search-tv preview {}"
  '';

  home.file.".config/uv/uv.toml".text = ''
    [[index]]
    url = "https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/"
    default = true
  '';

  home.activation = {
    rustupInit = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if [ ! -d "${config.home.homeDirectory}/.rustup" ]; then
        echo "Initializing rustup for the first time..."
        ${pkgs.rustup}/bin/rustup default stable
      fi
    '';
  };
}
