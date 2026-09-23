# orca-vm — a NixOS host that runs Orca in server mode, with your repositories checked out and your
# tools on PATH, installed onto an Azure VM with nixos-anywhere and reachable only over Tailscale.
#
# One machine, described here end to end. Everything personal is in host.nix; README.md is the runbook.
#
#   nix flake check                       evaluate the host and the package (works on a Mac)
#   nix develop                           the `orca-vm` command (az, nixos-anywhere, nixos-rebuild, jq inside)
#   orca-vm create [--plan]               the VM, its disks and its network
#   orca-vm install                       nixos-anywhere onto it, built on the VM itself
#   orca-vm rebuild                       nixos-rebuild switch over the tailnet, built on the VM
#   orca-vm status|stop|start|resize|detach-public-ip|ssh|serial|run
#
# A Mac cannot build Linux closures, so both the install and every later rebuild build ON the VM
# (`--build-on remote` / `--build-host`). Evaluation, which is what catches typos, runs anywhere.
#
# Two ways to use this flake:
#   * as a template: edit host.nix, azure/vm.env and workspace/ in your copy — this flake is the host.
#   * as an input: your own flake calls `orca-vm.lib.mkOutputs { host; workspace; extraModules; }` and
#     carries only host.nix, azure/vm.env and workspace/ (README, "Consuming as a flake input").
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
      # The systems the laptop-side tooling is built for; the host itself is whatever host.nix says.
      toolSystems = [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs toolSystems (system: f nixpkgs.legacyPackages.${system});
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];
      forLinux = f: lib.genAttrs linuxSystems (system: f nixpkgs.legacyPackages.${system});

      # The azure/ scripts, packaged behind one command: `orca-vm create|install|rebuild|status|…`.
      # They find host.nix and azure/vm.env in the checkout they run from (git toplevel, or ORCA_VM_ROOT),
      # so a consumer flake carries only those two files and gets the commands from its devShell.
      scriptsFor = pkgs:
        let
          na = nixos-anywhere.packages.${pkgs.stdenv.hostPlatform.system}.default;
          # The user's own nix and git stay in front: this only adds what a laptop may not have.
          path = lib.makeBinPath [ pkgs.azure-cli pkgs.jq pkgs.curl pkgs.openssh pkgs.nixos-rebuild na ];
        in
        pkgs.runCommand "orca-vm-scripts" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
          mkdir -p $out/bin $out/libexec/orca-vm
          cp ${./azure}/create-vm.sh ${./azure}/install-nixos.sh ${./azure}/vm.sh $out/libexec/orca-vm/
          cp ${./azure/orca-vm.sh} $out/bin/orca-vm
          chmod +x $out/bin/orca-vm $out/libexec/orca-vm/*.sh
          patchShebangs $out/bin $out/libexec
          wrapProgram $out/bin/orca-vm --suffix PATH : ${path} --set ORCA_VM_LIBEXEC $out/libexec/orca-vm
        '';
    in
    {
      # ── The library: what a consumer flake calls ────────────────────────────────────────────────
      lib = {
        # A NixOS system from a host.nix attribute set. `workspace` is the directory seeded into
        # ~/<dir> on top of this flake's own workspace/ (yours wins on a name clash); `extraModules`
        # are plain NixOS modules for anything host.nix has no knob for.
        mkHost = { host, workspace ? null, extraModules ? [ ] }: lib.nixosSystem {
          system = host.system;
          specialArgs = { inherit host; };
          modules = [
            self.nixosModules.default
            { orcaVm.workspace.source = workspace; }
          ] ++ extraModules;
        };

        # Every output a host flake needs: the configuration, the check that evaluates it, the
        # devShell with the `orca-vm` command, and the packages. A consumer's flake.nix is one call.
        mkOutputs = args@{ host, ... }:
          let system = self.lib.mkHost args; in
          {
            nixosConfigurations.${host.hostName} = system;
            inherit (self) devShells packages;
            # `nix flake check` evaluates the host's toplevel: every option name and module argument gets
            # checked without building anything — the cheap gate a laptop can run before touching the VM.
            checks = forAllSystems (pkgs: {
              host-evaluates = pkgs.runCommand "${host.hostName}-evaluates" {
                drv = system.config.system.build.toplevel.drvPath;
              } ''echo "$drv" > $out'';

              # The same host as a dedicated CI runner, every runner option on. Nothing builds or deploys it;
              # it exists so a change to modules/github-runner.nix that breaks that shape fails here, on the
              # laptop, rather than on the next rebuild of a CI box.
              ci-runner-evaluates = pkgs.runCommand "${host.hostName}-ci-runner-evaluates" {
                drv = (self.lib.mkHost (args // {
                  host = host // {
                    githubRunner = {
                      enable = true;
                      url = "https://github.com/example-org";
                      labels = [ "linux" "x64" ];
                      githubApp = { id = 1; login = "example-org"; };
                      ephemeral = true;
                      dedicatedUser = true;
                      workDir = "/mnt/resource/github-runner/work";
                      cacheDir = "/mnt/resource/github-runner/cache";
                      docker = true;
                      hostedToolchains = true;
                    };
                  };
                })).config.system.build.toplevel.drvPath;
              } ''echo "$drv" > $out'';
            });
          };
      };

      nixosModules.default = {
        imports = [
          disko.nixosModules.disko
          ./modules/disko.nix
          ./modules/azure.nix
          ./modules/tailscale.nix
          ./modules/workspace.nix
          ./modules/orca-server.nix
          ./modules/sandbox.nix
          ./modules/github-runner.nix
          ./modules/host.nix
        ];
      };

      # The Orca AppImage, wrapped for NixOS: `orca-ide` (the CLI) and `orca-ide-app` (the Electron
      # runtime that `serve` needs). Built per Linux system; the host picks its own.
      packages = forLinux (pkgs: rec {
        orca = pkgs.callPackage ./packages/orca.nix { };
        # The workspace sandbox rootfs — `nix build .#sandbox-rootfs` on the host to inspect it.
        sandbox-rootfs = pkgs.callPackage ./packages/sandbox-rootfs.nix { };
        default = orca;
      }) // forAllSystems (pkgs: { scripts = scriptsFor pkgs; });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ (scriptsFor pkgs) pkgs.azure-cli pkgs.jq ];
          shellHook = ''
            echo "orca-vm: \`orca-vm --help\` for the commands (az $(az version --query '"azure-cli"' -o tsv 2>/dev/null)). See README.md."
          '';
        };
      });
    }
    # This flake is also a host of its own (the template use): host.nix + workspace/ right here.
    // (let own = self.lib.mkOutputs { host = import ./host.nix; workspace = ./workspace; };
        in { inherit (own) nixosConfigurations checks; });
}
