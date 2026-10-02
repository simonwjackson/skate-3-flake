{
  description = "Skate 3 recomp for NixOS: the upstream prebuilt release, or a source build";

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
            "skate3-source-unwrapped"
            # requireFile marks the disc files unfree.
            "default.xex"
            "EAWebkit.xex"
          ];
      };
      skate3-unwrapped = pkgs.callPackage ./package.nix { };
      skate3 = pkgs.callPackage ./launcher.nix { inherit skate3-unwrapped; };

      # ReXGlue needs Clang; upstream's Linux CI uses Clang 20.
      skate3-source-unwrapped = pkgs.callPackage ./package-source.nix {
        stdenv = pkgs.llvmPackages_20.stdenv;
      };
      skate3-source = pkgs.callPackage ./launcher.nix {
        skate3-unwrapped = skate3-source-unwrapped;
      };
    in
    {
      packages.${system} = {
        inherit
          skate3
          skate3-unwrapped
          skate3-source
          skate3-source-unwrapped
          ;
        default = skate3;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${skate3}/bin/skate3";
        };
        source = {
          type = "app";
          program = "${skate3-source}/bin/skate3";
        };
      };
    };
}
