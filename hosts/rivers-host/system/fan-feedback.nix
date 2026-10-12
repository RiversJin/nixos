{ pkgs, ... }:
let
  fanFeedback = pkgs.callPackage ../../../packages/fan-feedback { };
  configuration = pkgs.writeText "fan-feedback.conf" ''
    address=0D:B3:AF:43:2C:DB
    adapter=hci0
    pci=0000:40:00.0
    gpu_pci=0000:31:00.0,0000:3a:00.0
    minimum_pwm=30
    fallback_pwm=100
    presence_file=/run/user/1000/fan-feedback-presence
    state_dir=/run/fan-feedback
  '';
in
{
  environment.systemPackages = [ fanFeedback ];
  environment.etc."fan-feedback.conf".source = configuration;

  systemd.services.fan-feedback = {
    description = "PEX88096 temperature feedback and quiet BLE fan control";
    wantedBy = [ "multi-user.target" ];
    wants = [ "bluetooth.service" ];
    after = [ "bluetooth.service" "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "simple";
      User = "rivers";
      Group = "users";
      ExecStart = "${fanFeedback}/bin/fan-feedback --config ${configuration} daemon";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStopSec = 30;
      RuntimeDirectory = "fan-feedback";
      RuntimeDirectoryMode = "0750";
      RuntimeDirectoryPreserve = "restart";
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      LockPersonality = true;
    };
  };
}
