# Host composition; inputs are pinned centrally in ../../flake.lock.
{
      nixpkgs,
      home-manager,
      nix-index-database,
      rime-ice,
      xremap,
      claudeCodeNix,
      neovimConfig,
      codex-desktop-linux,
      ...
    }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.rivers-host = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit rime-ice claudeCodeNix; };
        modules = [
          ./modules/plasma-login-manager.nix
          {
            disabledModules = [
              "services/display-managers/plasma-login-manager.nix"
            ];
          }
          ./configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.sharedModules = [
              nix-index-database.homeModules.default
              codex-desktop-linux.homeManagerModules.default
            ];
            home-manager.extraSpecialArgs = {
              inherit rime-ice xremap neovimConfig;
            };
            home-manager.users.rivers = import ./home.nix;
          }
        ];
      };
    }
