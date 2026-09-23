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
    # On unless a host says otherwise: a dedicated CI box (githubRunner.dedicatedUser) runs no Orca.
    enable = host.orca.enable or true;
    inherit (host.orca) port pairingAddress memoryHigh memoryMax;
  };

  orcaVm.sandbox.enable = host.sandbox.enable;

  # Every key past `enable` is optional, so a host.nix written for the workspace-runner shape (repository +
  # labels) keeps evaluating unchanged; the CI-host keys are documented in modules/github-runner.nix.
  orcaVm.githubRunner = let r = host.githubRunner; in {
    inherit (r) enable;
    repository = r.repository or null;
    url = r.url or null;
    extraLabels = r.labels or [ "nixos" ];
    githubApp = r.githubApp or null;
    ephemeral = r.ephemeral or false;
    dedicatedUser.enable = r.dedicatedUser or false;
    workDir = r.workDir or null;
    cacheDir = r.cacheDir or null;
    docker.enable = r.docker or false;
    hostedToolchains = r.hostedToolchains or false;
  };

  # Root keeps the same keys: nixos-anywhere's post-install SSH, and `nixos-rebuild --target-host` when
  # the user account is mid-change. Tailscale SSH is the day-to-day door; port 22 is for the public-IP
  # window during install and for the serial-console-less rescue case.
  users.users.root.openssh.authorizedKeys.keys = host.user.authorizedKeys;

  # The NixOS release this machine was first installed with. Never bump casually — it gates stateful
  # defaults (database formats, service state layouts), not features.
  system.stateVersion = host.stateVersion or "26.11";
}
