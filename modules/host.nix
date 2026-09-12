# host.nix → options. The one place the attribute set in host.nix is read; every other module sees only
# `orcaVm.*` options, so a consumer that wants a different knob adds a NixOS module, not a fork.
{ host, ... }:
{
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
  system.stateVersion = host.stateVersion or "26.11";
}
