# A self-hosted GitHub Actions runner on this box — for repositories whose gates need what only this
# machine has (a local package feed, a warm cache, a toolchain the hosted runners lack).
#
# WHAT IT IS NOT. Not an autoscaling fleet and not ephemeral-per-job: one long-lived runner on a
# long-lived box, the same shape as the Orca service beside it. If two repositories ever need to build
# at once, add a second `services.github-runners.<name>` entry rather than reaching for a controller.
#
# TRUST. A self-hosted runner executes whatever a pull request's workflow says. For a private,
# single-author repository the exposure is the author's own branches — but re-examine this before the
# repository takes an outside contributor or goes public, because a fork PR would then run on a
# machine holding the tailnet key, your credentials and every checkout.
{ config, lib, pkgs, ... }:
let
  cfg = config.orcaVm.githubRunner;
  ws = config.orcaVm.workspace;
in
{
  # Off unless a host asks for it, and here the default is not politeness.
  # `services.github-runners.<name>.enable` starts a unit that exchanges a token on activation, so
  # importing this file with it already on would put a FAILING unit on the next `nixos-rebuild` of any
  # machine whose token had not been staged first. The order is: stage the token, flip this, rebuild.
  options.orcaVm.githubRunner = {
    enable = lib.mkEnableOption "a self-hosted GitHub Actions runner";

    repository = lib.mkOption {
      type = lib.types.str;
      example = "owner/repo";
      description = ''
        The `owner/repo` this runner registers against. Repository-scoped rather than organisation-scoped
        on purpose — see the trust note at the top of this file.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/github-runner/token";
      description = ''
        A short-lived REGISTRATION token, staged the way the tailnet key is: written to the file, read
        once at activation, exchanged for the runner's own credential. Nothing long-lived reaches the
        store or this repository.
      '';
    };

    extraLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixos" ];
      description = "Labels a workflow selects on; `self-hosted` is implicit.";
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Tools a workflow needs BEFORE it enters a project directory, beyond git/gh/tar.";
    };
  };

  # The token is a REGISTRATION token, not a PAT, and it is short-lived by design: GitHub mints it for
  # one hour and the runner exchanges it once for its own credential under ~/actions-runner. Stage it
  # the way the tailnet key is staged — write the file, let the unit consume it:
  #
  #   gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token \
  #     | ssh <hostName> 'sudo install -m 0600 -o root /dev/stdin /var/lib/github-runner/token'
  #
  # The NixOS module reads it at activation and rewrites its own state; the file is not needed again.
  config = lib.mkIf cfg.enable {
    services.github-runners.${config.networking.hostName} = {
      enable = true;

      # One runner, named for the machine, so a queued job in the Actions UI names the box it is waiting
      # for rather than a number.
      name = config.networking.hostName;

      url = "https://github.com/${cfg.repository}";

      inherit (cfg) tokenFile extraLabels;

      # The user everything else on this box runs as, so a job sees the same workspace layout, the same
      # caches and the same direnv whitelist an interactive shell does. A runner under its own service
      # user would restore into a different cache and read a different config — the "green on one
      # machine" problem this exists to remove.
      user = ws.name;

      # `direnv` is how a job enters a repository's pinned toolchain; it is on the system profile and
      # the workspace is whitelisted for this user already (workspace.nix). No container client:
      # podman is on the host with dockerCompat off; flip that in workspace.nix if a workflow needs
      # a `docker` name. No language toolchains: each repository pins its own in its flake.nix.
      extraPackages = with pkgs; [ git gh gnutar gzip bash coreutils ] ++ cfg.extraPackages;

      serviceOverrides = {
        # Checkouts and caches live under /home on the data disk. The runner's work directory belongs
        # there too rather than on the OS disk.
        WorkingDirectory = lib.mkForce "${ws.home}/actions-runner";
        ReadWritePaths = [ ws.home ];
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/github-runner 0700 root root -"
      "d ${ws.home}/actions-runner 0755 ${ws.name} users -"
    ];
  };
}
