# Host composition; inputs are pinned centrally in ../../flake.lock.
{
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      rime-ice,
      xremap,
      ...
    }:
    let
      system = "x86_64-linux";
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations.rivers-laptop = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit rime-ice unstable; };
        modules = [
          ./configuration.nix
          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "hm-backup";
            home-manager.extraSpecialArgs = { inherit rime-ice xremap; };
            home-manager.users.rivers = import ./home.nix;
          }
        ];
      };
    }
