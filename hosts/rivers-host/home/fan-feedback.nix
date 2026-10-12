{ pkgs, ... }:
let
  presence = pkgs.writeShellScript "fan-feedback-presence" ''
    set -eu
    state="$XDG_RUNTIME_DIR/fan-feedback-presence"
    printf 'present\n' > "$state"
    exec ${pkgs.swayidle}/bin/swayidle -w \
      timeout 900 "printf 'away\\n' > '$state'" \
      resume "printf 'present\\n' > '$state'"
  '';
  present = pkgs.writeShellScript "fan-feedback-present" ''
    printf 'present\n' > "$XDG_RUNTIME_DIR/fan-feedback-presence"
  '';
in
{
  systemd.user.services.niri-fan-presence = {
    Unit = {
      Description = "Fan quiet policy from desktop idle notifications";
      PartOf = [ "niri-desktop.target" ];
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = presence;
      ExecStopPost = present;
      Restart = "on-failure";
      RestartSec = 5;
    };
    Install.WantedBy = [ "niri-desktop.target" ];
  };
}
