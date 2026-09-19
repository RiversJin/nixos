{ config, pkgs, ... }:
let
  workPath = "/mnt/hdd0/aria2";
  downloadPath = "${workPath}/downloads";
  completePath = "${workPath}/complete";
  rpcPort = 6800;
  rpcUrl = "http://192.168.50.4:${toString rpcPort}/jsonrpc";
  webPort = 6880;
  btPort = 6881;
  trackersUrl = "https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt";
  # Boot fallback; the weekly updater replaces this at runtime through RPC.
  btTrackersFallback = [
    "udp://zer0day.ch:1337/announce"
    "udp://tracker.publictracker.xyz:6969/announce"
    "http://tracker.opentrackr.org:1337/announce"
    "udp://open.demonii.com:1337/announce"
    "udp://open.tracker.cl:1337/announce"
    "udp://open.stealth.si:80/announce"
    "udp://tracker2.dler.org:80/announce"
    "udp://tracker.wildkat.net:6969/announce"
    "udp://tracker.tryhackx.org:6969/announce"
    "udp://tracker.qu.ax:6969/announce"
    "udp://tracker.filemail.com:6969/announce"
    "udp://tracker.ducks.party:1984/announce"
    "udp://tracker.auctor.tv:6969/announce"
    "udp://tracker-udp.gbitt.info:80/announce"
    "udp://tr4ck3r.duckdns.org:6969/announce"
    "udp://torrentclub.online:54123/announce"
    "udp://torrentclub.online:1984/announce"
    "udp://t.overflow.biz:6969/announce"
    "udp://seedpeer.net:6969/announce"
    "udp://retracker01-msk-virt.corbina.net:80/announce"
  ];
  updateBtTrackers = pkgs.writeShellApplication {
    name = "aria2-update-trackers";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gawk
      gnused
      jq
    ];
    text = ''
      set -euo pipefail

      cached="$STATE_DIRECTORY/trackers_best.txt"
      downloaded="$(mktemp)"
      normalized="$(mktemp)"
      trap 'rm -f "$downloaded" "$normalized"' EXIT

      if curl --fail --silent --show-error --location \
        --connect-timeout 15 --max-time 45 \
        ${trackersUrl} >"$downloaded"; then
        sed -e 's/\r$//' -e '/^[[:space:]]*$/d' "$downloaded" >"$normalized"
        awk '
          !/^(udp|https?):\/\/[^[:space:],]+$/ { exit 1 }
          END { if (NR < 5 || NR > 200) exit 1 }
        ' "$normalized"
        install -m 0600 "$normalized" "$cached"
      elif [[ -s "$cached" ]]; then
        echo "tracker download failed; applying cached list" >&2
        cp "$cached" "$normalized"
      else
        echo "tracker download failed and no cached list is available" >&2
        exit 1
      fi

      trackers="$(paste -sd, "$normalized")"
      token="token:$(<"$CREDENTIALS_DIRECTORY/rpcSecretFile")"
      rpc_url=${rpcUrl}

      rpc() {
        curl --fail --silent --show-error \
          --header 'Content-Type: application/json' \
          --data-binary @- "$rpc_url"
      }

      request="$(jq -cn \
        --arg token "$token" \
        --arg trackers "$trackers" \
        '{jsonrpc:"2.0",id:"trackers",method:"aria2.changeGlobalOption",params:[$token,{"bt-tracker":$trackers}]}')"
      response="$(printf '%s' "$request" | rpc)"
      jq -e '.result == "OK"' <<<"$response" >/dev/null

      list_gids() {
        local method="$1"
        local params
        if [[ "$method" == "aria2.tellActive" ]]; then
          params="$(jq -cn --arg token "$token" '[$token,["gid","bittorrent"]]')"
        else
          params="$(jq -cn --arg token "$token" '[$token,0,1000,["gid","bittorrent"]]')"
        fi
        jq -cn \
          --arg method "$method" \
          --argjson params "$params" \
          '{jsonrpc:"2.0",id:"list",method:$method,params:$params}' \
          | rpc \
          | jq -r '.result[] | select(.bittorrent != null) | .gid'
      }

      while IFS= read -r gid; do
        [[ -n "$gid" ]] || continue
        request="$(jq -cn \
          --arg token "$token" \
          --arg gid "$gid" \
          --arg trackers "$trackers" \
          '{jsonrpc:"2.0",id:"trackers",method:"aria2.changeOption",params:[$token,$gid,{"bt-tracker":$trackers}]}')"
        response="$(printf '%s' "$request" | rpc)"
        jq -e '.result == "OK"' <<<"$response" >/dev/null
      done < <(
        {
          list_gids aria2.tellActive
          list_gids aria2.tellWaiting
        } | sort -u
      )

      echo "applied $(wc -l <"$normalized") trackers"
    '';
  };
  syncBtListenAddress = pkgs.writeShellApplication {
    name = "aria2-sync-bt-listen-address";
    runtimeInputs = with pkgs; [
      curl
      iproute2
      jq
      systemd
    ];
    text = ''
      set -euo pipefail

      preferred_ipv6="$(${pkgs.iproute2}/bin/ip -6 -j address show dev aria2-lan scope global \
        | ${pkgs.jq}/bin/jq -r '
            [.[].addr_info[]
              | select(.scope == "global" and .preferred_life_time != 0)
              | .local]
            | first // empty
          ')"

      [[ -n "$preferred_ipv6" ]] || exit 0
      if ${pkgs.iproute2}/bin/ss -H -lnt6 "sport = :${toString btPort}" \
        | ${pkgs.gnugrep}/bin/grep -Fq "[$preferred_ipv6]:${toString btPort}"; then
        exit 0
      fi

      token="token:$(<"$CREDENTIALS_DIRECTORY/rpcSecretFile")"
      request="$(${pkgs.jq}/bin/jq -cn \
        --arg token "$token" \
        '{jsonrpc:"2.0",id:"save",method:"aria2.saveSession",params:[$token]}')"
      ${pkgs.curl}/bin/curl --fail --silent --show-error \
        --header 'Content-Type: application/json' \
        --data-binary "$request" \
        ${rpcUrl} \
        | ${pkgs.jq}/bin/jq -e '.result == "OK"' >/dev/null

      ${pkgs.systemd}/bin/systemctl --no-block restart aria2.service
    '';
  };
  gracefulStop = pkgs.writeShellApplication {
    name = "aria2-graceful-stop";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      set -euo pipefail

      main_pid="''${1:-}"
      credential_file="''${2:-}"
      [[ "$main_pid" =~ ^[1-9][0-9]*$ ]] || exit 0
      [[ -r "$credential_file" ]] || {
        echo "aria2 RPC credential is not readable" >&2
        exit 1
      }

      token="token:$(<"$credential_file")"

      rpc_call() {
        local id="$1"
        local method="$2"
        local request response
        request="$(jq -cn \
          --arg token "$token" \
          --arg id "$id" \
          --arg method "$method" \
          '{jsonrpc:"2.0",id:$id,method:$method,params:[$token]}')"
        response="$(curl --fail --silent --show-error \
          --connect-timeout 5 --max-time 30 \
          --header 'Content-Type: application/json' \
          --data-binary "$request" \
          ${rpcUrl})"
        jq -e '.result == "OK"' <<<"$response" >/dev/null
      }

      # Persist all resumable and force-saved seeding jobs before asking aria2
      # to unregister from BitTorrent trackers and finish its own cleanup.
      rpc_call save aria2.saveSession
      rpc_call shutdown aria2.shutdown

      for _ in $(seq 1 240); do
        kill -0 "$main_pid" 2>/dev/null || exit 0
        sleep 1
      done

      echo "aria2 did not exit within 240 seconds" >&2
      exit 1
    '';
  };
  linkCompletedDownloads = pkgs.writeShellApplication {
    name = "aria2-link-completed-downloads";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      jq
    ];
    text = ''
      set -euo pipefail

      if (( $# < 3 )); then
        echo "usage: $0 GID FILE_COUNT FIRST_FILE" >&2
        exit 2
      fi

      gid="$1"
      file_count="$2"
      first_file="$3"

      if [[ ! "$gid" =~ ^[0-9a-fA-F]{16}$ ]]; then
        echo "invalid aria2 GID: $gid" >&2
        exit 2
      fi

      download_root="''${ARIA2_DOWNLOAD_ROOT:-${downloadPath}}"
      complete_root="''${ARIA2_COMPLETE_ROOT:-${completePath}}"
      rpc_url="''${ARIA2_RPC_URL:-${rpcUrl}}"

      if [[ -n "''${ARIA2_RPC_SECRET_FILE:-}" ]]; then
        credential_file="$ARIA2_RPC_SECRET_FILE"
      elif [[ -n "''${CREDENTIALS_DIRECTORY:-}" ]]; then
        credential_file="$CREDENTIALS_DIRECTORY/rpcSecretFile"
      else
        echo "aria2 RPC credential is unavailable" >&2
        exit 1
      fi

      if [[ ! -r "$credential_file" ]]; then
        echo "cannot read aria2 RPC credential: $credential_file" >&2
        exit 1
      fi

      token="token:$(<"$credential_file")"
      request="$(jq -cn \
        --arg token "$token" \
        --arg gid "$gid" \
        '{jsonrpc:"2.0",id:"completed-files",method:"aria2.tellStatus",params:[$token,$gid,["files"]]}')"
      response="$(
        printf '%s' "$request" \
          | curl --fail --silent --show-error \
              --header 'Content-Type: application/json' \
              --data-binary @- \
              "$rpc_url"
      )"

      if ! jq -e '.result.files | type == "array"' <<<"$response" >/dev/null; then
        message="$(jq -r '.error.message // "invalid RPC response"' <<<"$response" 2>/dev/null || true)"
        echo "cannot query completed files for $gid: $message" >&2
        exit 1
      fi

      download_root="$(realpath -e -- "$download_root")"
      mkdir -p -- "$complete_root"
      complete_root="$(realpath -e -- "$complete_root")"

      linked=0
      skipped=0
      failed=0

      while IFS= read -r -d "" source; do
        if [[ ! -f "$source" || -L "$source" ]]; then
          echo "skip non-regular download file: $source" >&2
          (( skipped += 1 ))
          continue
        fi

        source="$(realpath -e -- "$source")"
        case "$source" in
          "$download_root"/*)
            ;;
          *)
            echo "skip file outside download root: $source" >&2
            (( skipped += 1 ))
            continue
            ;;
        esac

        relative="$(realpath --relative-to="$download_root" -- "$source")"
        destination="$complete_root/$relative"
        mkdir -p -- "$(dirname -- "$destination")"

        if [[ -e "$destination" || -L "$destination" ]]; then
          if [[ "$source" -ef "$destination" ]]; then
            (( skipped += 1 ))
          else
            echo "refusing to replace existing destination: $destination" >&2
            failed=1
          fi
          continue
        fi

        if ln -- "$source" "$destination"; then
          (( linked += 1 ))
        else
          echo "failed to hard-link $source to $destination" >&2
          failed=1
        fi
      done < <(
        jq -j '
          .result.files[]
          | select(.selected == "true" and .length == .completedLength)
          | .path, "\u0000"
        ' <<<"$response"
      )

      echo \
        "aria2 completion $gid: linked=$linked skipped=$skipped files=$file_count first=$first_file"
      exit "$failed"
    '';
  };
in
{
  # aria2 1.37 binds an interface's first IPv6 address. On Linux that is
  # commonly the link-local address, which prevents public IPv6 BT ingress.
  nixpkgs.overlays = [
    (_final: prev: {
      aria2 = prev.aria2.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../patches/aria2-prefer-global-ipv6.patch ];
      });
    })
  ];

  services.aria2 = {
    enable = true;
    rpcSecretFile = config.age.secrets.aria2-rpc.path;
    downloadDirPermission = "0775";
    serviceUMask = "0002";
    settings = {
      "dir" = downloadPath;
      "enable-rpc" = true;
      "rpc-listen-port" = rpcPort;
      "rpc-allow-origin-all" = true;
      "rpc-listen-all" = "true";
      "async-dns" = false;

      # Use a dedicated dual-stack L2 identity that dae leaves direct.
      "interface" = "aria2-lan";
      # Buffer and reorder BitTorrent piece writes before flushing to the HDD.
      "disk-cache" = "512M";
      "enable-mmap" = true;
      "enable-dht" = true;
      "enable-dht6" = true;
      "enable-peer-exchange" = "true";
      # A stable peer/DHT port is required for router forwarding.
      "listen-port" = [
        {
          from = btPort;
          to = btPort;
        }
      ];
      "dht-listen-port" = btPort;
      "bt-tracker" = builtins.concatStringsSep "," btTrackersFallback;

      "input-file" = "${workPath}/config/aria2.session";
      "save-session" = "${workPath}/config/aria2.session";
      "save-session-interval" = 60;
      # Completed BitTorrent jobs are active seeders but otherwise omitted from
      # the saved session, so retain them across planned restarts as well.
      "force-save" = true;

      "dht-file-path" = "${workPath}/config/dht.dat";
      "dht-file-path6" = "${workPath}/config/dht6.dat";

      "continue" = true;
      "max-concurrent-downloads" = 64;
      "max-tries" = 5;
      "conditional-get" = true;

      # Stop seeding when either target is reached: ratio 16 or 15 days.
      "seed-ratio" = 16.0;
      "seed-time" = 15 * 24 * 60;

      "content-disposition-default-utf8" = true;
      "auto-file-renaming" = true;

      "use-head" = true;

      # Link completed files immediately; for BitTorrent this runs before seeding.
      "on-download-complete" = "${linkCompletedDownloads}/bin/aria2-link-completed-downloads";
      "on-bt-download-complete" = "${linkCompletedDownloads}/bin/aria2-link-completed-downloads";
    };
  };

  systemd.services.aria2.serviceConfig = {
    ExecStop = "${gracefulStop}/bin/aria2-graceful-stop $MAINPID %d/rpcSecretFile";
    # aria2 exits with status 7 when unfinished jobs remain in the saved
    # session, which is expected during a planned stop or restart.
    SuccessExitStatus = [ "7" ];
    TimeoutStopSec = "5min";
  };

  systemd.services.aria2-network-ready = {
    description = "Wait for the dedicated aria2 network interface";
    before = [ "aria2.service" ];
    requiredBy = [ "aria2.service" ];
    after = [ "systemd-networkd.service" ];
    path = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.iproute2
    ];
    script = ''
      for attempt in $(seq 1 60); do
        if ip -4 address show dev aria2-lan 2>/dev/null \
          | grep -q '192\.168\.50\.4/32' \
          && ip -6 address show dev aria2-lan scope global 2>/dev/null \
          | grep -q 'inet6 '; then
          exit 0
        fi
        sleep 1
      done
      echo "aria2-lan did not become dual-stack ready" >&2
      exit 1
    '';
    serviceConfig.Type = "oneshot";
  };

  systemd.services.aria2-trackers-update = {
    description = "Update aria2 public trackers";
    after = [
      "aria2.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "aria2.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "aria2";
      Group = "aria2";
      StateDirectory = "aria2-trackers";
      LoadCredential = "rpcSecretFile:${config.age.secrets.aria2-rpc.path}";
      ExecStart = "${updateBtTrackers}/bin/aria2-update-trackers";
    };
  };

  # Residential IPv6 prefixes may change after PPPoE reconnects. Restart aria2
  # only when its BT listener no longer matches the preferred aria2-lan address.
  systemd.services.aria2-network-address-sync = {
    description = "Keep aria2 BitTorrent bound to the current public IPv6 address";
    after = [
      "aria2.service"
      "network-online.target"
    ];
    wants = [
      "aria2.service"
      "network-online.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      LoadCredential = "rpcSecretFile:${config.age.secrets.aria2-rpc.path}";
      ExecStart = "${syncBtListenAddress}/bin/aria2-sync-bt-listen-address";
    };
  };

  systemd.timers.aria2-network-address-sync = {
    description = "Check aria2 public IPv6 listener";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Unit = "aria2-network-address-sync.service";
    };
  };

  systemd.timers.aria2-trackers-update = {
    description = "Update aria2 public trackers weekly";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 04:00:00";
      RandomizedDelaySec = "2h";
      Persistent = true;
      Unit = "aria2-trackers-update.service";
    };
  };

  services.nginx = {
    enable = true;
    virtualHosts.ariang = {
      listen = [
        {
          addr = "0.0.0.0";
          port = webPort;
        }
      ];
      root = "${pkgs.ariang}/share/ariang";
      locations."/".extraConfig = ''
        allow 192.168.50.0/24;
        allow 100.64.0.0/10;
        deny all;
      '';
      locations."/jsonrpc" = {
        proxyPass = "http://192.168.50.4:${toString rpcPort}/jsonrpc";
        proxyWebsockets = true;
        extraConfig = ''
          allow 192.168.50.0/24;
          allow 100.64.0.0/10;
          deny all;
        '';
      };
    };
  };

  networking.firewall = {
    interfaces = {
      br-lan.allowedTCPPorts = [
        rpcPort
        webPort
      ];
      tailscale0.allowedTCPPorts = [ webPort ];
      aria2-lan = {
        allowedTCPPorts = [ btPort ];
        allowedUDPPorts = [ btPort ];
      };
    };
  };

  # rivers 用户加入 aria2 组,以便管理下载的文件
  users.users.rivers.extraGroups = [ "aria2" ];
  # /mnt is intentionally restricted to root:users; aria2 needs to traverse it.
  users.users.aria2.extraGroups = [ "users" ];

  # 确保目录权限正确
  systemd.tmpfiles.rules = [
    "d ${workPath} 0775 rivers users -"
    "d ${workPath}/config 0775 rivers users -"
    "d ${downloadPath} 0775 rivers users -"
    "d ${completePath} 0775 rivers users -"
  ];
}
