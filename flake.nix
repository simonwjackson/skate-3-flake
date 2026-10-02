{
  description = "Skate 3 recomp for NixOS: the upstream prebuilt release, or a source build";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          # Allow only this flake's unfree packages, so `nix run` works as is.
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "skate3"
              "skate3-unwrapped"
              "skate3-source-unwrapped"
              # requireFile marks the disc files unfree.
              "default.xex"
              "EAWebkit.xex"
            ];
        };

      # The source build works on both. ReXGlue needs Clang; upstream's Linux
      # CI uses Clang 20.
      sourcePackages =
        pkgs:
        let
          skate3-source-unwrapped = pkgs.callPackage ./package-source.nix {
            stdenv = pkgs.llvmPackages_20.stdenv;
          };
        in
        {
          inherit skate3-source-unwrapped;
          skate3-source = pkgs.callPackage ./launcher.nix {
            skate3-unwrapped = skate3-source-unwrapped;
          };
        };

      # Upstream publishes a prebuilt Linux release for x86_64 only.
      x86_64 =
        let
          pkgs = pkgsFor "x86_64-linux";
          skate3-unwrapped = pkgs.callPackage ./package.nix { };
          skate3 = pkgs.callPackage ./launcher.nix { inherit skate3-unwrapped; };
        in
        sourcePackages pkgs
        // {
          inherit skate3 skate3-unwrapped;
          default = skate3;
        };

      # ARM64 has no upstream release, so the source build is the default.
      aarch64 =
        let
          source = sourcePackages (pkgsFor "aarch64-linux");
        in
        source // { default = source.skate3-source; };

      app = package: {
        type = "app";
        program = lib.getExe package;
      };
    in
    {
      packages = {
        x86_64-linux = x86_64;
        aarch64-linux = aarch64;
      };

      apps = {
        x86_64-linux = {
          default = app x86_64.skate3;
          source = app x86_64.skate3-source;
        };
        aarch64-linux = {
          default = app aarch64.skate3-source;
          source = app aarch64.skate3-source;
        };
      };
    };
}
