{
  config,
  lib,
  pkgs,
  ...
}:

let
  nut = config.power.ups.package;
  passwordFile = "/var/lib/nut-credentials/monitor-password";
  schedulerCommand = pkgs.writeShellScript "ups-scheduler-command" ''
    set -eu

    case "''${1:-}" in
      on-battery-timeout)
        # Recheck at expiry so a late ONLINE event cannot shut down on mains.
        if ! status="$(${nut}/bin/upsc w150@localhost ups.status)"; then
          ${pkgs.util-linux}/bin/logger -t ups-scheduler "Cannot read UPS at timer expiry; upsmon retains low-battery and communication-loss protection"
          exit 0
        fi
        case " $status " in
          *" OB "*)
            ${pkgs.util-linux}/bin/logger -t ups-scheduler "UPS has been on battery for 300 seconds; requesting orderly shutdown"
            ${nut}/bin/upsmon -c fsd
            ;;
          *)
            ${pkgs.util-linux}/bin/logger -t ups-scheduler "UPS is no longer on battery; skipping timed shutdown"
            ;;
        esac
        ;;
    esac
  '';
in
{
  power.ups = {
    enable = true;
    mode = "standalone";
    ups.w150 = {
      driver = "usbhid-ups";
      port = "auto";
      description = "WalleCube Smart UPS W150";
      directives = [
        "vendorid = 04d8"
        "productid = d005"
      ];
    };
    upsd.listen = [ { address = "127.0.0.1"; } ];
    users.monitor = {
      inherit passwordFile;
      upsmon = "primary";
    };
    upsmon = {
      monitor.w150 = {
        system = "w150@localhost";
        user = "monitor";
        type = "primary";
      };
      settings = {
        POLLFREQ = 5;
        POLLFREQALERT = 5;
        # Allow USB reconnection; if last seen on battery, shut down after 60s
        # without fresh data. An ordinary USB outage on mains is not a shutdown.
        DEADTIME = 60;
        FINALDELAY = 5;
        SHUTDOWNCMD = "${pkgs.systemd}/bin/systemctl poweroff";
        # W150 output-cutoff/restart support has not been verified. Only shut
        # down the host; leave UPS output management to its own configuration.
        POWERDOWNFLAG = null;
        NOTIFYFLAG = [
          [
            "ONLINE"
            "SYSLOG+EXEC"
          ]
          [
            "ONBATT"
            "SYSLOG+EXEC"
          ]
          [
            "LOWBATT"
            "SYSLOG"
          ]
          [
            "COMMBAD"
            "SYSLOG"
          ]
          [
            "COMMOK"
            "SYSLOG"
          ]
          [
            "SHUTDOWN"
            "SYSLOG"
          ]
        ];
      };
    };
    schedulerRules = toString (
      pkgs.writeText "upssched.conf" ''
        CMDSCRIPT ${schedulerCommand}
        PIPEFN /run/nut/upssched/pipe
        LOCKFN /run/nut/upssched/lock
        AT ONBATT * START-TIMER on-battery-timeout 300
        AT ONLINE * CANCEL-TIMER on-battery-timeout
      ''
    );
  };

  systemd.tmpfiles.rules = [
    "d /run/nut 0755 root root -"
    "d /run/nut/upssched 0700 nutmon nutmon -"
  ];

  # Generate once on the host, keeping the credential out of Git and the store.
  systemd.services.nut-credentials = {
    description = "Initialize local NUT monitor credential";
    before = [
      "upsd.service"
      "upsmon.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "nut-credentials";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      if [ ! -s ${passwordFile} ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${passwordFile}
      fi
    '';
  };
  systemd.services.upsd.requires = [ "nut-credentials.service" ];
  systemd.services.upsmon.requires = [ "nut-credentials.service" ];

  # Supervise the single USB driver directly, so an unexpected exit is retried.
  systemd.services.upsdrv.serviceConfig = {
    Type = lib.mkForce "simple";
    RemainAfterExit = lib.mkForce false;
    ExecStart = lib.mkForce "${nut}/bin/usbhid-ups -a w150 -u root -F";
    Restart = "on-failure";
    RestartSec = 5;
  };
}
