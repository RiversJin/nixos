{ lib, pkgs, ... }:

let
  yaml = pkgs.formats.yaml { };
  configFile = yaml.generate "omp-config.yml" {
    symbolPreset = "nerd";
    theme.dark = "titanium";
    setupVersion = 1;
    modelRoles.default = "kimi-code/k3";
    defaultThinkingLevel = "auto";

    collab = {
      relayUrl = "wss://t.riversjins.cc:8970";
      webUrl = "https://my.omp.sh";
    };
  };
in
{
  home.activation.ompConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    config_path="$HOME/.omp/agent/config.yml"
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/mkdir -p "$HOME/.omp/agent"
    if [[ -L "$config_path" ]]; then
      $DRY_RUN_CMD ${pkgs.coreutils}/bin/unlink "$config_path"
    fi
    $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m 0600 ${configFile} "$config_path"
  '';
}
