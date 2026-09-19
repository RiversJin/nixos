# Rivers' NixOS configurations

One flake for three machines, with Home Manager and agenix-managed credentials.

| Output | Role | Package base |
| --- | --- | --- |
| `rivers-host` | AMD desktop, Niri | nixpkgs unstable |
| `rivers-laptop` | Laptop, Niri | nixpkgs unstable |
| `rivers-gateway` | Storage, services, router container | NixOS 26.05 + selected unstable packages |

## Layout

- `hosts/<hostname>/`: hardware, host composition, service differences and secret declarations.
- `modules/desktop/`: shared desktop services and audio.
- `home/`: shared Home Manager modules.
- `secrets/`: encrypted credentials and their recipient policy. No private keys.

The root lock preserves the original machines' input revisions. Host-prefixed inputs intentionally allow independent updates; merging the repository does not upgrade all machines to the same package set.

## Build and deploy

Keep the checkout at `/home/rivers/nixos` on each machine. `/etc/nixos` can continue to point there.

```sh
nix build .#nixosConfigurations.rivers-host.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#rivers-host
```

Use `rivers-laptop` or `rivers-gateway` on those hosts. The old gateway output `nixos` is now `rivers-gateway`. Keep each machine's `system.stateVersion` unchanged.

## Secrets

Each `.age` file is encrypted for the administrator's SSH public key and the one target machine's Ed25519 SSH host key. Private keys stay outside this repository. Keep an independent, secure backup of the administrator's private key before reinstalling machines.

```sh
cd secrets
# Uses ~/.ssh/id_ed25519; run from this directory to load secrets.nix.
nix run ..#agenix -- -e rivers-host-mimo-token.age
# After updating recipient public keys:
nix run ..#agenix -- -r
```

Secrets are decrypted on the target host, usually under `/run/agenix`. Services consume files at runtime. Never use `builtins.readFile`, `writeText` or literal interpolation to turn plaintext secrets back into Nix derivations.

The router's PPPoE options, PAP/CHAP credentials, password hash and API health-check header are decrypted on the gateway into `/run/router-secrets`, then mounted read-only into the router container. These use `symlink = false` so the mounted directory sees updated files. Restart the affected service after credential changes; agenix itself does not manage consumer restarts.

WireGuard credentials are encrypted even though the legacy WireGuard module is not currently imported. Laptop Mihomo and sing-box modules are currently not imported; their credentials are retained encrypted without enabling either service.

Existing application login state, SSH private keys, Nix's `/etc/nix/github-token.conf`, external proxy-generator source/state and service data are still machine-local. This repository is not a backup of that state.

## Public repository checks

```sh
nix run .#gitleaks -- dir . --redact
```

Only public SSH builder host keys are allowlisted. The repository starts with a fresh history; old repositories containing plaintext credentials must remain outside it. Encrypting the new tree does not remove plaintext from old Git repositories, backups or previous Nix store generations, and does not replace rotation of credentials that were exposed.
