{ pkgs, ... }:

let
  # Immutable code and isolated Python: no privileged execution from the checkout.
  gpuPowerRoot = pkgs.writeShellScriptBin "gpu-power-root" ''
    exec ${pkgs.python3}/bin/python3 -I ${./scripts/gpu-power.py} "$@"
  '';
  gpuPower = pkgs.writeShellScriptBin "gpu-power" ''
    set -eu
    if [ "$#" -ne 1 ]; then
      echo "Usage: gpu-power {status|high|compute|auto|profile_standard}" >&2
      exit 2
    fi
    case "$1" in
      status) exec ${gpuPowerRoot}/bin/gpu-power-root status ;;
      high|compute|auto|profile_standard)
        exec /run/wrappers/bin/sudo -n ${gpuPowerRoot}/bin/gpu-power-root "$1"
        ;;
      *) echo "Unknown GPU power mode: $1" >&2; exit 2 ;;
    esac
  '';
in
{
  environment.systemPackages = [ gpuPower ];
  security.sudo.extraRules = [
    {
      users = [ "rivers" ];
      commands =
        map
          (mode: {
            command = "${gpuPowerRoot}/bin/gpu-power-root ${mode}";
            options = [ "NOPASSWD" ];
          })
          [
            "high"
            "compute"
            "auto"
            "profile_standard"
          ];
    }
  ];
}
