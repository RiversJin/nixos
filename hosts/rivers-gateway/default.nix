# Host composition; inputs are pinned centrally in ../../flake.lock.
{
      nixpkgs,
      nixpkgs-unstable,
      home-manager,
      nix-search-tv,
      nix-index-database,
      ...
    }:
    let
      userName = "rivers";
      system = "x86_64-linux";
      unstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit unstable; };
        modules = [
          ./configuration.nix
          home-manager.nixosModules.home-manager
          nix-index-database.nixosModules.nix-index

          {
            home-manager.useUserPackages = true;
            home-manager.useGlobalPkgs = true;
            home-manager.extraSpecialArgs = { inherit nix-search-tv; };

            home-manager.users.${userName} = import ./modules/user/${userName}.nix;
          }
        ];
      };

    }
