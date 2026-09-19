{
  config,
  lib,
  pkgs,
  ...
}:
let
  home = config.home.homeDirectory;
in
{
  # Keep the native PizzaPi build and credentials outside the Nix store.
  systemd.user.services.pizzapi-runner = {
    Unit.Description = "PizzaPi local runner";
    Service = {
      ExecStart = "${home}/.local/share/pizzapi-trial/bin/pizza-linux-x64 runner";
      WorkingDirectory = "${home}/pizzapi-trial-workspace";
      Environment = [
        "PIZZAPI_RUNNER_NAME=rivers-host"
        "PATH=${
          lib.makeBinPath [
            pkgs.bubblewrap
            pkgs.socat
          ]
        }:${home}/.local/bin:/etc/profiles/per-user/rivers/bin:/run/current-system/sw/bin"
      ];
      Restart = "always";
      RestartSec = 5;
      TimeoutStopSec = 45;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
