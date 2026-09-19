# Zellij Web

Public entry: <https://t.riversjins.cc:9444/>. The portal links to
`gateway-term.riversjins.cc:9444` and `host-term.riversjins.cc:9444`.
Both names are DNS-only CNAMEs to `t.riversjins.cc` in Cloudflare.

Each host runs `zellij-web.service` in rivers' lingering user manager.
The service uses `KillMode=process` so restarting the web listener does not
terminate the detached Zellij session servers it spawned.
Zellij listens on `127.0.0.1:18082` (8082 conflicts with QQ on rivers-host).
Nginx listens on the host's Tailscale address, port 8083, accepts only the
Tencent relay `100.64.0.3`, and forwards HTTP/WebSocket traffic to Zellij.
Tencent Caddy terminates HTTPS. Nginx adds `Secure` to Zellij's authentication
cookie; Zellij supplies `HttpOnly` and `SameSite=Strict`.

`modules/zellij-web.nix` is imported by both NixOS configurations. Rebuild each
host from this repository after changes. The activation script preserves the
existing Zellij configuration, backs it up once as
`~/.config/zellij/config.kdl.before-zellij-web`, and sets `web_sharing "on"`
and `web_server_port 18082`. Existing sessions are not restarted; opt those
into sharing individually through Zellij's Share plugin. Browser and terminal
session versions must match.

## Tencent files

The Debian relay is not managed by this flake. Deploy these two files explicitly:

- `zellij-web.caddy` → `/etc/caddy/conf.d/zellij-web.caddy`
- `zellij-portal.html` → `/srv/zellij-portal/index.html`

`/etc/caddy/Caddyfile` imports `/etc/caddy/conf.d/zellij-web.caddy` in place of
the former ttyd site. Validate Caddy with its existing service environment
(the Cloudflare token must remain out of logs), then reload `caddy.service`.
The pre-migration configuration is `/etc/caddy/Caddyfile.before-zellij-web`.

## Login

Generate tokens **as rivers**, on the appropriate machine:

```sh
umask 077
mkdir -p ~/.local/state/zellij-web
zellij web --create-token > ~/.local/state/zellij-web/login.txt
```

Store the generated token in a password manager. Do not commit token files.
Choose **Remember me** when logging in; version 0.45.1 issues a four-week cookie.
Use `zellij web --list-tokens` and `zellij web --revoke-token NAME` to manage
tokens. This version rejects combining `--create-token` with `--token-name`.

## Verification / rollback

Check `systemctl --user status zellij-web`, `zellij web --status`, and
`/info/version` through each public HTTPS origin. Unauthenticated `/session-list`
must return 401. Verify actual command output in each browser terminal, close
the browser, then reconnect to the same named session. The terminal should
remain alive and the saved login should work.

The migration removes gateway's ttyd module and its port 7681 firewall rules.
To roll back, restore that module/import and rebuild gateway, then restore the
Tencent Caddy backup and reload. Do not kill existing Zellij terminal sessions.

References: [Zellij web client](https://zellij.dev/tutorials/web-client/),
[Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy),
[Nginx cookie flags](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_cookie_flags).
