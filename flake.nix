{
  description = "Nix flake packaging bw-backup and bw-sync with a NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      overlays.default = final: prev: {
        bw-backup = final.callPackage ./nix/bw-backup.nix { };
        bw-sync = final.callPackage ./nix/bw-sync.nix { };
      };

      packages = forAllSystems (pkgs: {
        inherit (pkgs) bw-backup bw-sync;
        default = pkgs.bw-backup;
      });

      nixosModules.default = import ./nix/module.nix;
    };
}
