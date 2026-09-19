{
  config,
  pkgs,
  lib,
  ...
}:

let
  configDir = "/var/lib/sing-box/config.d";
  singBoxPkg = pkgs.sing-box;


  googleDnsDomains = [
    "google.com"
    "googleapis.com"
    "gstatic.com"
    "googleusercontent.com"
    "googlevideo.com"
    "ggpht.com"
    "googleadservices.com"
    "google-analytics.com"
    "ytimg.com"
    "youtube.com"
    "youtu.be"
    "youtube-nocookie.com"
  ];
  googleDnsRule = builtins.toJSON {
    domain_suffix = googleDnsDomains;
    server = "dns-proxy-cf";
  };
  aiDnsDomains = [
    "openai.com"
    "chatgpt.com"
    "oaistatic.com"
    "oaiusercontent.com"
    "anthropic.com"
    "claude.ai"
  ];
  aiDnsRule = builtins.toJSON {
    domain_suffix = aiDnsDomains;
    server = "dns-proxy-cf";
  };
  steamDnsDomains = [
    "steamcommunity.com"
    "steampowered.com"
    "steamstatic.com"
    "steamcontent.com"
    "steamserver.net"
    "steamcdn.net"
    "steam-chat.com"
    "steamgames.com"
    "valvesoftware.com"
  ];
  steamDnsRule = builtins.toJSON {
    domain_suffix = steamDnsDomains;
    server = "dns-proxy-cf";
  };

  policyNormalizeFilter = ''
    (.dns.servers[]? | select(.tag == "dns-local-a" or .tag == "dns-local-b" or .tag == "dns-direct-doh" or .tag == "dns-direct-ali")) |= (del(.detour) | .routing_mark = "0x80000")
    | (.dns.rules[]? | select(.server == "dns-local-a" or .server == "dns-local-b")) |= (.server = "dns-direct-doh")
    | (.dns.rules[]? | select(.rule_set == "proxy")) |= (.server = "dns-direct-doh")
    # Google/AI/Steam domains need clean DNS in TUN mode; direct CN DoH can return polluted answers.
    | .dns.rules = ([${googleDnsRule}, ${aiDnsRule}, ${steamDnsRule}] + ((.dns.rules // []) | map(select(.domain_suffix != ${builtins.toJSON googleDnsDomains} and .domain_suffix != ${builtins.toJSON aiDnsDomains} and .domain_suffix != ${builtins.toJSON steamDnsDomains}))))
  '';

  fallbackDnsServers = [
    {
      type = "udp";
      tag = "dns-local-a";
      server = "223.5.5.5";
      routing_mark = "0x80000";
    }
    {
      type = "udp";
      tag = "dns-local-b";
      server = "119.29.29.29";
      routing_mark = "0x80000";
    }
    {
      type = "https";
      tag = "dns-direct-doh";
      server = "1.12.12.12";
      tls = {
        server_name = "doh.pub";
      };
      routing_mark = "0x80000";
    }
    {
      type = "https";
      tag = "dns-direct-ali";
      server = "223.5.5.5";
      tls = {
        server_name = "dns.alidns.com";
      };
      routing_mark = "0x80000";
    }
    {
      type = "https";
      tag = "dns-proxy-cf";
      server = "1.1.1.1";
      tls = {
        server_name = "dns.cloudflare.com";
      };
      detour = "Proxy";
    }
    {
      type = "https";
      tag = "dns-proxy-google";
      server = "8.8.8.8";
      tls = {
        server_name = "dns.google";
      };
      detour = "Proxy";
    }
  ];

  # Static device-layer config managed by Nix (TUN, direct/block, clash_api)
  baseConfig = {
    log = {
      level = "info";
      timestamp = true;
    };

    inbounds = [
      {
        type = "tun";
        tag = "tun-in";
        interface_name = "tun0";
        address = [ "172.19.0.1/30" ];
        auto_route = true;
        strict_route = true;
        stack = "gvisor";
        mtu = 9000;
      }
      {
        type = "mixed";
        tag = "mixed-in";
        listen = "127.0.0.1";
        listen_port = 7890;
      }
    ];

    outbounds = [
      {
        type = "direct";
        tag = "direct";
      }
    ];

    route = {
      auto_detect_interface = true;
      default_domain_resolver = "dns-direct-doh";
    };

    experimental = {
      clash_api = {
        external_controller = "127.0.0.1:9090";
        external_ui = "/var/lib/sing-box/ui";

      };
      cache_file = {
        enabled = true;
        path = "/var/lib/sing-box/cache.db";
        store_fakeip = false;
      };
    };
  };

  baseConfigFile = pkgs.writeTextFile {
    name = "sing-box-00-base.json";
    text = builtins.toJSON baseConfig;
  };

  # Fallback policy when subscription is not yet available (first boot)
  fallbackPolicy = {
    dns = {
      servers = fallbackDnsServers;
      rules = [
        { server = "dns-direct-doh"; }
      ];
    };
    route = {
      rules = [
        { action = "sniff"; }
        {
          protocol = "dns";
          action = "hijack-dns";
        }
        {
          ip_is_private = true;
          outbound = "direct";
        }
        { outbound = "Proxy"; }
      ];
    };
  };

  fallbackPolicyFile = pkgs.writeTextFile {
    name = "sing-box-40-policy.json";
    text = builtins.toJSON fallbackPolicy;
  };

  # Fallback proxies when subscription is not yet available (first boot)
  fallbackProxies = {
    outbounds = [
      {
        type = "selector";
        tag = "Proxy";
        outbounds = [ "direct" ];
        default = "direct";
      }
      {
        type = "selector";
        tag = "AI";
        outbounds = [ "direct" ];
        default = "direct";
      }
      {
        type = "selector";
        tag = "Google";
        outbounds = [ "direct" ];
        default = "direct";
      }
      {
        type = "selector";
        tag = "Steam";
        outbounds = [ "direct" ];
        default = "direct";
      }
    ];
  };

  fallbackProxiesFile = pkgs.writeTextFile {
    name = "sing-box-50-proxies.json";
    text = builtins.toJSON fallbackProxies;
  };

  # Subscription update script
  subUpdateScript = pkgs.writeShellScript "sing-box-sub-update" ''
    set -euo pipefail
    umask 077
    SUB_BASE="$(<${config.age.secrets.sing-box-subscription.path})"
    export PATH="${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.jq
        singBoxPkg
      ]
    }"
    export http_proxy="http://127.0.0.1:7890"
    export https_proxy="http://127.0.0.1:7890"

    CONFIG_DIR="${configDir}"
    UPDATED=0

    normalize_policy() {
      local policy_file="$1"
      local normalized="$policy_file.normalized"
      jq '${policyNormalizeFilter}' "$policy_file" > "$normalized"
      mv "$normalized" "$policy_file"
      chmod 600 "$policy_file"
    }

    # Download policy
    POLICY_TMP="$CONFIG_DIR/40-policy.json.tmp"
    if curl -sf --connect-timeout 10 --max-time 30 -4 -o "$POLICY_TMP" "$SUB_BASE&mode=policy"; then
      if jq empty "$POLICY_TMP" 2>/dev/null; then
        normalize_policy "$POLICY_TMP"
        mv "$POLICY_TMP" "$CONFIG_DIR/40-policy.json"
        echo "Policy updated"
        UPDATED=1
      else
        rm -f "$POLICY_TMP"
        echo "Invalid policy JSON, keeping existing"
      fi
    else
      echo "Policy download failed, keeping existing"
    fi

    # Download proxies
    PROXIES_TMP="$CONFIG_DIR/50-proxies.json.tmp"
    if curl -sf --connect-timeout 10 --max-time 30 -4 -o "$PROXIES_TMP" "$SUB_BASE&outbounds-only=1"; then
      if jq empty "$PROXIES_TMP" 2>/dev/null && jq -e '.outbounds' "$PROXIES_TMP" >/dev/null 2>&1; then
        mv "$PROXIES_TMP" "$CONFIG_DIR/50-proxies.json"
        chmod 600 "$CONFIG_DIR/50-proxies.json"
        echo "Proxies updated"
        UPDATED=1
      else
        rm -f "$PROXIES_TMP"
        echo "Invalid proxies JSON, keeping existing"
      fi
    else
      echo "Proxies download failed, keeping existing"
    fi

    # Validate merged config before allowing reload
    if sing-box check -C "$CONFIG_DIR" 2>&1; then
      echo "Config check passed"
    else
      echo "Config check failed, not reloading" >&2
      exit 1
    fi
  '';
in
{
  services.sing-box = {
    enable = true;
    package = singBoxPkg;
  };

  # Override sing-box to use multi-config directory mode + custom preStart
  systemd.services.sing-box = {
    # The module already sets wantedBy and preStart from the package.
    # We only override what's different for multi-config mode.
    serviceConfig = {
      ExecStart = lib.mkForce [
        ""
        "${lib.getExe singBoxPkg} -D /var/lib/sing-box -C ${configDir} run"
      ];
      StateDirectory = lib.mkForce "sing-box";
    };

    preStart = ''
      mkdir -p ${configDir}

      # Write Nix-managed base config (TUN, direct/block, clash_api)
      umask 077
      ${pkgs.jq}/bin/jq --rawfile secret ${config.age.secrets.sing-box-controller.path} '.experimental.clash_api.secret = ($secret | rtrimstr("\n"))' ${baseConfigFile} > ${configDir}/00-base.json

      # Ensure policy file exists (fallback if subscription hasn't run yet)
      if [ ! -f "${configDir}/40-policy.json" ] \
        || ! ${pkgs.jq}/bin/jq -e '.dns.servers' "${configDir}/40-policy.json" >/dev/null 2>&1; then
        cp -f ${fallbackPolicyFile} ${configDir}/40-policy.json
      fi
      ${pkgs.jq}/bin/jq '${policyNormalizeFilter}' "${configDir}/40-policy.json" > "${configDir}/40-policy.json.normalized"
      mv "${configDir}/40-policy.json.normalized" "${configDir}/40-policy.json"
      chmod 600 "${configDir}/40-policy.json"

      # Ensure proxies file exists (fallback if subscription hasn't run yet)
      if [ ! -f "${configDir}/50-proxies.json" ]; then
        cp -f ${fallbackProxiesFile} ${configDir}/50-proxies.json
      fi

      # UI: symlink metacubexd if not already present
      if [ ! -d /var/lib/sing-box/ui ]; then
        ln -sfn ${pkgs.metacubexd} /var/lib/sing-box/ui
      fi
    '';
  };

  # Subscription update
  systemd.services.sing-box-update = {
    description = "Update sing-box proxy subscription";
    after = [ "sing-box.service" ];
    requires = [ "sing-box.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = subUpdateScript;
      ExecStartPost = "${pkgs.systemd}/bin/systemctl reload sing-box.service";
    };
  };

  systemd.timers.sing-box-update = {
    description = "sing-box subscription update timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 10:00:00";
      Persistent = true;
    };
  };
}
