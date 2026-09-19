{ lib, ... }:

{
  # Nix settings
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  nix.settings.auto-optimise-store = true;
  nix.settings.trusted-users = [
    "root"
    "rivers"
  ];
  nix.distributedBuilds = true;
  nix.buildMachines = [
    {
      hostName = "192.168.50.10";
      protocol = "ssh-ng";
      systems = [ "x86_64-linux" ];
      sshUser = "rivers";
      sshKey = "/etc/nix/rivers-host-builder_ed25519";
      publicHostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUp0MnVQY2FQYlA0YkFMeVlMNXJoRlJKU0duUjZkaStmT21JN0VvL1J0bnUgcm9vdEByaXZlcnMtaG9zdAo=";
      maxJobs = 4;
      speedFactor = 4;
      supportedFeatures = [
        "nixos-test"
        "benchmark"
        "big-parallel"
        "kvm"
      ];
    }
  ];
  nix.settings.builders-use-substitutes = true;
  nix.settings.substituters = lib.mkForce [
    "https://mirrors.tuna.tsinghua.edu.cn/nix-channels/store"
    "https://mirrors.ustc.edu.cn/nix-channels/store"
    "https://nix-community.cachix.org"
    "https://cache.nixos.org"
  ];
  nix.settings.trusted-public-keys = [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];
  nix.extraOptions = ''
    !include /etc/nix/github-token.conf
  '';

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    # 笔记本经常关机，错过的时间窗口开机后补跑
    persistent = true;
    options = "--delete-older-than 7d";
  };
}
