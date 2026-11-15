{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version: 0.17, the one the package builds on.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            # The oracle for `just check-golden` and `just check-corpus`:
            # Prometheus 3.15.1's own exposition parser, from the flake so the
            # gates run offline. ziglint lints against the minimum supported
            # std, which is 0.17.
            packages = with pkgs; [
              config.packages."ziglint-0-17"
              prom2json
            ];
          };
        };
    };
}
