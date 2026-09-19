{ pkgs, ... }:

let
  statusFile = "/run/router-health-status";
  machine = "rivers-router";

  healthCheck = pkgs.writeShellApplication {
    name = "router-health-check";
    runtimeInputs = with pkgs; [
      bind.dnsutils
      coreutils
      curl
      gawk
      gnugrep
      iproute2
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      state_dir="''${STATE_DIRECTORY:?}"
      output="$(mktemp ${statusFile}.XXXXXX)"
      trap 'rm -f "$output"' EXIT

      write_status() {
        printf '%s\n' "$*" > "$output"
        chown rivers:users "$output"
        chmod 0644 "$output"
        mv "$output" ${statusFile}
        trap - EXIT
      }

      reset_failure() {
        printf '0\n' > "$state_dir/$1.failures"
      }

      maybe_heal() {
        local component="$1" unit="$2" failures last now
        failures="$(cat "$state_dir/$component.failures" 2>/dev/null || printf 0)"
        failures=$((failures + 1))
        printf '%s\n' "$failures" > "$state_dir/$component.failures"
        if (( failures < 3 )); then
          return 0
        fi

        now="$(date +%s)"
        last="$(cat "$state_dir/$component.last-restart" 2>/dev/null || printf 0)"
        if (( now - last < 300 )); then
          return 0
        fi

        if systemctl -M ${machine} restart "$unit"; then
          printf '%s\n' "$now" > "$state_dir/$component.last-restart"
          printf '0\n' > "$state_dir/$component.failures"
          actions+=("restart:$unit")
        fi
      }

      actions=()
      if ! systemctl is-active --quiet container@${machine}.service; then
        write_status "DOWN container=failed"
        exit 0
      fi

      leader="$(machinectl show ${machine} -p Leader --value)"
      if [[ -z "$leader" || "$leader" == 0 ]]; then
        write_status "DOWN container=no-leader"
        exit 0
      fi

      in_router() {
        nsenter -t "$leader" -n -- "$@"
      }

      ppp=down
      if systemctl -M ${machine} is-active --quiet pppd-wan.service &&
         in_router ip -o link show ppp0 >/dev/null 2>&1; then
        ppp=up
        reset_failure ppp
      else
        maybe_heal ppp pppd-wan.service
      fi

      mihomo=down
      if systemctl -M ${machine} is-active --quiet mihomo.service &&
         in_router ss -lnt | grep -q '127.0.0.1:7892 ' &&
         in_router ss -lnt | grep -q '127.0.0.1:1053 ' &&
         in_router curl --silent --fail --max-time 3 \
           -H @/run/router-secrets/controller-header \
           http://127.0.0.1:9090/version >/dev/null; then
        mihomo=ok
        reset_failure mihomo
      else
        maybe_heal mihomo mihomo.service
      fi

      dnsmasq=down
      if systemctl -M ${machine} is-active --quiet dnsmasq.service &&
         dig @192.168.50.1 router.home.arpa A +tries=1 +time=2 +short | grep -qx '192.168.50.1'; then
        dnsmasq=ok
        reset_failure dnsmasq
      else
        maybe_heal dnsmasq dnsmasq.service
      fi

      dae=down
      if systemctl -M ${machine} is-active --quiet dae.service &&
         in_router tc qdisc show dev lan0 | grep -q 'clsact' &&
         in_router tc filter show dev lan0 ingress | grep -q 'dae_'; then
        dae=ok
        reset_failure dae
      else
        maybe_heal dae dae.service
      fi

      upstream=down
      dns_ms=-
      query="$(dig @192.168.50.1 www.baidu.com A +tries=1 +time=3 +stats 2>/dev/null || true)"
      if grep -q 'status: NOERROR' <<<"$query"; then
        upstream=ok
        dns_ms="$(awk '/Query time:/ { print $4; exit }' <<<"$query")"
        [[ -n "$dns_ms" ]] || dns_ms=-
      fi

      overall=OK
      if [[ "$ppp" != up || "$mihomo" != ok || "$dnsmasq" != ok || "$dae" != ok ]]; then
        overall=DOWN
      elif [[ "$upstream" != ok ]]; then
        overall=DEGRADED
      fi

      action_text=none
      if (( ''${#actions[@]} > 0 )); then
        action_text="$(IFS=,; printf '%s' "''${actions[*]}")"
      fi
      write_status "$overall ppp=$ppp dnsmasq=$dnsmasq dns-upstream=$upstream/''${dns_ms}ms dae=$dae mihomo=$mihomo action=$action_text"
    '';
  };

  smokeTest = pkgs.writeShellApplication {
    name = "router-smoke-test";
    runtimeInputs = with pkgs; [
      bind.dnsutils
      coreutils
      curl
      gnugrep
      systemd
    ];
    text = ''
      set -u
      unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
      failed=0

      check() {
        local name="$1"
        shift
        if "$@"; then
          printf 'ok   %s\n' "$name"
        else
          printf 'FAIL %s\n' "$name"
          failed=1
        fi
      }

      check container systemctl is-active --quiet container@${machine}.service
      check dns-local sh -c "dig @192.168.50.1 router.home.arpa A +tries=1 +time=2 +short | grep -qx 192.168.50.1"
      check domestic curl -4 --silent --fail --output /dev/null --connect-timeout 5 --max-time 12 https://www.zhihu.com
      check openai sh -c "code=\$(curl -4 --silent --output /dev/null --connect-timeout 5 --max-time 12 --write-out '%{http_code}' https://api.openai.com/v1/models); test \"\$code\" = 401"
      check webui curl --silent --fail --output /dev/null --max-time 5 http://192.168.50.1:9090/ui/

      if [[ -r ${statusFile} ]]; then
        printf '\n%s\n' "$(cat ${statusFile})"
      fi
      exit "$failed"
    '';
  };
in
{
  systemd.services."container@${machine}" = {
    startLimitIntervalSec = 60;
    startLimitBurst = 5;
    serviceConfig.RestartSec = "3s";
  };

  systemd.services.router-health-check = {
    description = "Check and conservatively heal Router container services";
    after = [ "container@${machine}.service" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "router-health";
      ExecStart = "${healthCheck}/bin/router-health-check";
    };
  };

  systemd.timers.router-health-check = {
    description = "Periodically check Router container health";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "30s";
      Unit = "router-health-check.service";
    };
  };

  environment.systemPackages = [ smokeTest ];
}
