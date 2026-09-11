# orca-vm — a NixOS host that runs Orca in server mode, with your repositories checked out and your
# tools on PATH, installed onto an Azure VM with nixos-anywhere and reachable only over Tailscale.
#
# One machine, described here end to end. Everything personal is in host.nix; README.md is the runbook.
#
#   nix flake check                       evaluate the host and the package (works on a Mac)
#   nix develop                           az + nixos-anywhere + jq for the azure/ scripts
#   azure/create-vm.sh                    the VM, its disks and its network
#   azure/install-nixos.sh                nixos-anywhere onto it, built on the VM itself
#   azure/vm.sh rebuild                   nixos-rebuild switch over the tailnet, built on the VM
#
# A Mac cannot build Linux closures, so both the install and every later rebuild build ON the VM
# (`--build-on remote` / `--build-host`). Evaluation, which is what catches typos, runs anywhere.
{
  description = "orca-vm — a NixOS host for Orca server mode and your workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";
    nixos-anywhere.inputs.nixpkgs.follows = "nixpkgs";
    nixos-anywhere.inputs.disko.follows = "disko";
  };

  outputs = { self, nixpkgs, disko, nixos-anywhere }:
    let
      lib = nixpkgs.lib;
      host = import ./host.nix;
      # The systems the laptop-side tooling is built for; the host itself is whatever host.nix says.
      toolSystems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs toolSystems (system: f nixpkgs.legacyPackages.${system});
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      forLinux = f: lib.genAttrs linuxSystems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Named after host.nix's hostName: `nixos-rebuild --flake .#<hostName>`.
      nixosConfigurations.${host.hostName} = lib.nixosSystem {
        system = host.system;
        specialArgs = { inherit self host; };
        modules = [
          disko.nixosModules.disko
          ./nixos
        ];
      };

      # The Orca AppImage, wrapped for NixOS: `orca-ide` (the CLI) and `orca-ide-app` (the Electron
      # runtime that `serve` needs). Built per Linux system; the host picks its own.
      packages = forLinux (pkgs: rec {
        orca = pkgs.callPackage ./packages/orca.nix { };
        # The workspace sandbox rootfs — `nix build .#sandbox-rootfs` on the host to inspect it.
        sandbox-rootfs = pkgs.callPackage ./packages/sandbox-rootfs.nix { };
        default = orca;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.azure-cli
            pkgs.jq
            pkgs.openssh
            nixos-anywhere.packages.${pkgs.stdenv.hostPlatform.system}.default
          ];
          shellHook = ''
            echo "orca-vm (${host.hostName}): az $(az version --query '"azure-cli"' -o tsv 2>/dev/null), nixos-anywhere on PATH. See README.md."
          '';
        };
      });

      # `nix flake check` evaluates the host's toplevel: every option name and module argument gets
      # checked without building anything — the cheap gate a laptop can run before touching the VM.
      checks = forAllSystems (pkgs: {
        host-evaluates = pkgs.runCommand "${host.hostName}-evaluates" {
          drv = self.nixosConfigurations.${host.hostName}.config.system.build.toplevel.drvPath;
        } ''echo "$drv" > $out'';
      });
    };
}
