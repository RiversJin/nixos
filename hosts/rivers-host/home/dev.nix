{
  config,
  lib,
  pkgs,
  ...
}:

{
  home.packages = with pkgs; [
    clang
    rustup
    pkg-config
    openssl
    lld
    nodejs_22
    pixi
  ];

  # Rustup initialization
  home.activation.rustupInit = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if [ ! -d "${config.home.homeDirectory}/.rustup" ]; then
      echo "Initializing rustup for the first time..."
      ${pkgs.rustup}/bin/rustup default stable
    fi
  '';

  # Environment
  home.sessionVariables = {
    CARGO_HOME = "${config.home.homeDirectory}/.cargo";
    RUSTUP_HOME = "${config.home.homeDirectory}/.rustup";
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    CC = "clang";
  };

  home.sessionPath = [
    "${config.home.homeDirectory}/.local/bin"
    "${config.home.homeDirectory}/.npm-global/bin"
    "${config.home.homeDirectory}/.cargo/bin"
    "${pkgs.clang}/bin"
    "${pkgs.llvmPackages.bintools}/bin"
  ];
}
