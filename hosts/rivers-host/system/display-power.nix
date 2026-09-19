{ pkgs, ... }:

let
  amdgpuDevice = ''
    gpu_device=""
    for dev in /sys/class/drm/card*/device; do
      if [ -e "$dev/pp_dpm_mclk" ] && [ -e "$dev/power_dpm_force_performance_level" ]; then
        gpu_device="$dev"
        break
      fi
    done

    if [ -z "$gpu_device" ]; then
      echo "No amdgpu DPM device found" >&2
      exit 1
    fi
  '';

  displayPowerSaveRoot = pkgs.writeShellScriptBin "display-power-save-root" ''
    set -eu

    ${amdgpuDevice}

    echo manual > "$gpu_device/power_dpm_force_performance_level"
    echo 1 > "$gpu_device/pp_dpm_mclk"
  '';

  displayPerformanceRoot = pkgs.writeShellScriptBin "display-performance-root" ''
    set -eu

    ${amdgpuDevice}

    echo auto > "$gpu_device/power_dpm_force_performance_level"
  '';

  sessionEnv = ''
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="''${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
    export WAYLAND_DISPLAY="''${WAYLAND_DISPLAY:-wayland-0}"
  '';

  displayPowerSave = pkgs.writeShellScriptBin "display-power-save" ''
    set -eu

    ${sessionEnv}

    ${pkgs.niri}/bin/niri msg output DP-1 mode 3840x2160@60
    ${pkgs.niri}/bin/niri msg output DP-3 mode 3840x2160@60
    sleep 2
    exec /run/wrappers/bin/sudo -n ${displayPowerSaveRoot}/bin/display-power-save-root
  '';

  displayPerformance = pkgs.writeShellScriptBin "display-performance" ''
    set -eu

    ${sessionEnv}

    /run/wrappers/bin/sudo -n ${displayPerformanceRoot}/bin/display-performance-root
    sleep 1
    ${pkgs.niri}/bin/niri msg output DP-1 mode 3840x2160@120
    exec ${pkgs.niri}/bin/niri msg output DP-3 mode 3840x2160@120
  '';
in
{
  environment.systemPackages = [
    displayPowerSave
    displayPerformance
    displayPowerSaveRoot
    displayPerformanceRoot
  ];

  security.sudo.extraRules = [
    {
      users = [ "rivers" ];
      commands = [
        {
          command = "${displayPowerSaveRoot}/bin/display-power-save-root";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${displayPerformanceRoot}/bin/display-performance-root";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
