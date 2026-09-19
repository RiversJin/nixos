{
  description = "NixOS configurations for rivers-host, rivers-laptop and rivers-gateway";
  inputs = {
    host-claudeCodeNix.url = "github:sadjow/claude-code-nix?ref=v2.1.153";
    host-claudeCodeNix.inputs.nixpkgs.follows = "host-nixpkgs";
    host-codex-desktop-linux.url = "github:ilysenko/codex-desktop-linux";
    host-home-manager.url = "github:nix-community/home-manager/master";
    host-home-manager.inputs.nixpkgs.follows = "host-nixpkgs";
    host-neovimConfig.url = "github:RiversJin/neovim";
    host-nix-index-database.url = "github:nix-community/nix-index-database";
    host-nix-index-database.inputs.nixpkgs.follows = "host-nixpkgs";
    host-nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    host-rime-ice.url = "github:iDvel/rime-ice";
    host-rime-ice.flake = false;
    host-xremap.url = "github:xremap/nix-flake";
    laptop-home-manager.url = "github:nix-community/home-manager/master";
    laptop-home-manager.inputs.nixpkgs.follows = "laptop-nixpkgs";
    laptop-nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    laptop-nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    laptop-rime-ice.url = "github:iDvel/rime-ice";
    laptop-rime-ice.flake = false;
    laptop-xremap.url = "github:xremap/nix-flake";
    gateway-home-manager.url = "github:nix-community/home-manager/release-26.05";
    gateway-home-manager.inputs.nixpkgs.follows = "gateway-nixpkgs";
    gateway-nix-index-database.url = "github:nix-community/nix-index-database";
    gateway-nix-index-database.inputs.nixpkgs.follows = "gateway-nixpkgs";
    gateway-nix-search-tv.url = "github:3timeslazy/nix-search-tv";
    gateway-nix-search-tv.inputs.nixpkgs.follows = "gateway-nixpkgs";
    gateway-nixpkgs.url = "https://mirrors.ustc.edu.cn/nix-channels/nixos-26.05/nixexprs.tar.xz";
    gateway-nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "host-nixpkgs";
    agenix.inputs.home-manager.follows = "host-home-manager";
    agenix.inputs.darwin.follows = "";
  };
  outputs = inputs: {
    nixosConfigurations = {
      rivers-host = ((import ./hosts/rivers-host) { claudeCodeNix = inputs.host-claudeCodeNix; codex-desktop-linux = inputs.host-codex-desktop-linux; home-manager = inputs.host-home-manager; neovimConfig = inputs.host-neovimConfig; nix-index-database = inputs.host-nix-index-database; nixpkgs = inputs.host-nixpkgs; rime-ice = inputs.host-rime-ice; xremap = inputs.host-xremap; }).nixosConfigurations.rivers-host.extendModules {
        modules = [ inputs.agenix.nixosModules.default ./hosts/rivers-host/secrets.nix ];
      };
      rivers-laptop = ((import ./hosts/rivers-laptop) { home-manager = inputs.laptop-home-manager; nixpkgs = inputs.laptop-nixpkgs; nixpkgs-unstable = inputs.laptop-nixpkgs-unstable; rime-ice = inputs.laptop-rime-ice; xremap = inputs.laptop-xremap; }).nixosConfigurations.rivers-laptop.extendModules {
        modules = [ inputs.agenix.nixosModules.default ./hosts/rivers-laptop/secrets.nix ];
      };
      rivers-gateway = ((import ./hosts/rivers-gateway) { home-manager = inputs.gateway-home-manager; nix-index-database = inputs.gateway-nix-index-database; nix-search-tv = inputs.gateway-nix-search-tv; nixpkgs = inputs.gateway-nixpkgs; nixpkgs-unstable = inputs.gateway-nixpkgs-unstable; }).nixosConfigurations.nixos.extendModules {
        modules = [ inputs.agenix.nixosModules.default ./hosts/rivers-gateway/secrets.nix ];
      };
    };
    packages.x86_64-linux.gitleaks = inputs.host-nixpkgs.legacyPackages.x86_64-linux.gitleaks;
    packages.x86_64-linux.agenix = inputs.agenix.packages.x86_64-linux.default;
  };
}
