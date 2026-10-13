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
    host_state_dir=/run/host-fan-feedback
    host_minimum_pwm=20
    host_channel=3
    state_dir=/run/fan-feedback
  '';
in
{
  environment.systemPackages = [ fanFeedback ];
  environment.etc."fan-feedback.conf".source = configuration;

  # Grant only the confirmed host case header; CPU and pump stay root-owned.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="hwmon", DEVPATH=="/devices/platform/nct6683.2592/hwmon/hwmon*", ATTR{name}=="nct6687", ATTR{pwm3_enable}=="[12]", RUN+="${pkgs.coreutils}/bin/chown rivers:users /sys%p/pwm3 /sys%p/pwm3_enable"
  '';

  systemd.services.host-fan-feedback = {
    description = "Independent CPU and motherboard feedback for host case fan";
    wantedBy = [ "multi-user.target" ];
    after = [
      "systemd-modules-load.service"
      "systemd-udev-trigger.service"
    ];
    serviceConfig = {
      Type = "simple";
      User = "rivers";
      Group = "users";
      ExecStart = "${fanFeedback}/bin/fan-feedback --config ${configuration} host-daemon";
      ExecStopPost = "${fanFeedback}/bin/fan-feedback --config ${configuration} host-auto";
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStopSec = 30;
      RuntimeDirectory = "host-fan-feedback";
      RuntimeDirectoryMode = "0750";
      RuntimeDirectoryPreserve = "restart";
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ReadWritePaths = [ "/sys/devices/platform/nct6683.2592/hwmon" ];
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      LockPersonality = true;
    };
  };

  systemd.services.fan-feedback = {
    description = "PEX88096 temperature feedback and quiet BLE fan control";
    wantedBy = [ "multi-user.target" ];
    wants = [ "bluetooth.service" ];
    after = [
      "bluetooth.service"
      "systemd-modules-load.service"
    ];
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
