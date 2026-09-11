{
  description = "Autolith mobile bridge for macOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          bridge = pkgs.callPackage ./nix/package.nix { };
        in
        {
          autolith-bridge = bridge;
          default = bridge;
        });

      apps = forAllSystems (system:
        let
          bridge = {
            type = "app";
            program = "${self.packages.${system}.autolith-bridge}/bin/autolith-bridge";
            meta.description = "Run the Autolith mobile bridge";
          };
        in
        {
          autolith-bridge = bridge;
          default = bridge;
        });

      checks = forAllSystems (system: {
        autolith-bridge = self.packages.${system}.autolith-bridge;
      });
    };
}
