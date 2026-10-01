{
  description = "Skate 3 recomp (upstream prebuilt Linux release) for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        # Allow only this flake's unfree packages, so `nix run` works as is.
        config.allowUnfreePredicate =
          pkg:
          builtins.elem (nixpkgs.lib.getName pkg) [
            "skate3"
            "skate3-unwrapped"
          ];
      };
      skate3-unwrapped = pkgs.callPackage ./package.nix { };
      skate3 = pkgs.callPackage ./launcher.nix { inherit skate3-unwrapped; };
    in
    {
      packages.${system} = {
        inherit skate3 skate3-unwrapped;
        default = skate3;
      };

      apps.${system}.default = {
        type = "app";
        program = "${skate3}/bin/skate3";
      };
    };
}
