{
  description = "Nix flake packaging rbw-auto-backup and rbw-auto-sync with a NixOS module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rbw = {
      url = "github:pschmitt/rbw";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rbw,
    }:
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
              overlays = [
                rbw.overlays.default
                self.overlays.default
              ];
            }
          )
        );
    in
    {
      overlays.default = final: prev: {
        rbw-auto-backup = final.callPackage ./nix/rbw-auto-backup.nix { };
        rbw-auto-sync = final.callPackage ./nix/rbw-auto-sync.nix { };
      };

      packages = forAllSystems (pkgs: {
        inherit (pkgs) rbw-auto-backup rbw-auto-sync;
        default = pkgs.rbw-auto-backup;
      });

      nixosModules.default = import ./nix/module.nix;
    };
}
