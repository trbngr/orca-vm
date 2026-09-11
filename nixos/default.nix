# Module composition for the host. Values live in ../host.nix; behaviour lives in ../modules/.
# This is the place to add your own NixOS options (extra services, kernel settings, …).
{ host, lib, ... }:
{
  imports = [
    ./disko.nix
    ../modules/azure.nix
    ../modules/tailscale.nix
    ../modules/workspace.nix
    ../modules/orca-server.nix
    ../modules/sandbox.nix
    ../modules/github-runner.nix
  ];

  networking.hostName = host.hostName;

  orcaVm.workspace = {
    inherit (host.user) name fullName email githubUser authorizedKeys;
    inherit (host.workspace) dir macHomeSymlink;
    inherit (host) packages;
  };

  orcaVm.orca = {
    enable = true;
    inherit (host.orca) port pairingAddress memoryHigh memoryMax;
  };

  orcaVm.sandbox.enable = host.sandbox.enable;

  orcaVm.githubRunner = {
    inherit (host.githubRunner) enable repository;
    extraLabels = host.githubRunner.labels;
  };

  # Root keeps the same keys: nixos-anywhere's post-install SSH, and `nixos-rebuild --target-host` when
  # the user account is mid-change. Tailscale SSH is the day-to-day door; port 22 is for the public-IP
  # window during install and for the serial-console-less rescue case.
  users.users.root.openssh.authorizedKeys.keys = host.user.authorizedKeys;

  # The NixOS release this machine was first installed with. Never bump casually — it gates stateful
  # defaults (database formats, service state layouts), not features.
  system.stateVersion = "26.11";
}
