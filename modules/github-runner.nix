# A self-hosted GitHub Actions runner on this box — for repositories whose gates need what only this
# machine has (a local package feed, a warm cache, a toolchain the hosted runners lack, an egress IP a
# firewall admits).
#
# TWO SHAPES, one module:
#
#   * Beside a workspace (the default). One long-lived runner, repository-scoped, running as the workspace
#     user with the workspace's caches and direnv — the same shape as the Orca service beside it. Right for
#     "this box's feed is the only place my gate can restore from", wrong for anything shared.
#
#   * A dedicated CI host. `dedicatedUser.enable` runs jobs as their own system user instead of yours;
#     `ephemeral` + `githubApp` give each job a freshly registered runner and a wiped state and work
#     directory; `cacheDir` keeps what is worth keeping between jobs (NuGet packages, the Actions tool
#     cache) on the temp disk; `docker.enable` gives jobs a rootless podman over a socket; `hostedToolchains`
#     lets the binaries `actions/setup-*` download run on NixOS. On a host that runs nothing else.
#
# TRUST. A self-hosted runner executes whatever a pull request's workflow says. In the first shape that is
# the workspace user, beside the tailnet key, your credentials and every checkout: acceptable for a private
# repository only you push to, and worth re-examining the day that stops being true. The second shape
# holds no personal credential, but a job still runs on a machine inside your network with whatever egress
# it was given. Keep fork pull-request workflows off for every repository that can reach it.
{ config, lib, pkgs, ... }:
let
  cfg = config.orcaVm.githubRunner;
  ws = config.orcaVm.workspace;
  runnerName = config.networking.hostName;
  serviceName = "github-runner-${runnerName}";

  url = if cfg.url != null then cfg.url else "https://github.com/${cfg.repository}";

  dedicated = cfg.dedicatedUser.enable;
  user = if dedicated then cfg.dedicatedUser.name else ws.name;
  uid = cfg.dedicatedUser.uid;

  # Beside a workspace the work directory is where it always was; a CI host puts it on the temp disk.
  workDir = if cfg.workDir != null then cfg.workDir else "${ws.home}/actions-runner";

  # The rootless podman API socket of the runner user, served by its user manager (linger keeps that up).
  podmanSocket = "/run/user/${toString uid}/podman/podman.sock";

  # Jobs run inside the runner service's sandbox, where user namespaces are refused — so `podman` and
  # `docker` in a job are REMOTE clients of the user's podman service, and the containers themselves run
  # outside the sandbox, rootless, as the runner user.
  remotePodman = pkgs.writeShellScriptBin "podman" ''exec ${pkgs.podman}/bin/podman --remote "$@"'';
  remoteDocker = pkgs.writeShellScriptBin "docker" ''exec ${pkgs.podman}/bin/podman --remote "$@"'';

  cacheEnvironment = lib.optionalAttrs (cfg.cacheDir != null) {
    # Immutable, hash-verified on extract: sharing it between jobs brings back no drift, and a cold restore of
    # a large package graph per job is the cost ephemerality would otherwise add.
    NUGET_PACKAGES = "${cfg.cacheDir}/nuget/packages";
    # Where actions/setup-* keep the SDKs they download — versioned directories, the same argument.
    RUNNER_TOOL_CACHE = "${cfg.cacheDir}/toolcache";
    AGENT_TOOLSDIRECTORY = "${cfg.cacheDir}/toolcache";
    # actions/setup-dotnet installs to /usr/share/dotnet on Linux, not to the tool cache, and the runner's
    # filesystem is read-only outside its own paths ("mkdir: cannot create directory '/usr/share'",
    # oval-runner, 2026-09-23). SDKs install side by side by version, so the same argument as above holds.
    DOTNET_INSTALL_DIR = "${cfg.cacheDir}/dotnet";
  };

  dockerEnvironment = lib.optionalAttrs cfg.docker.enable {
    DOCKER_HOST = "unix://${podmanSocket}";
    CONTAINER_HOST = "unix://${podmanSocket}";
    # Testcontainers mounts the socket into its reaper container; tell it the path the daemon sees.
    TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE = podmanSocket;
  };

  toolchainEnvironment = lib.optionalAttrs cfg.hostedToolchains {
    # programs.nix-ld sets these as SESSION variables, which a systemd service never sees.
    NIX_LD = "/run/current-system/sw/share/nix-ld/lib/ld.so";
    NIX_LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
  };

  # Directories on the temp disk exist only after it is mounted, and are gone after a deallocate.
  preparedDirs =
    lib.optional (cfg.workDir != null) workDir
    ++ lib.optionals (cfg.cacheDir != null) [
      cfg.cacheDir
      "${cfg.cacheDir}/nuget/packages"
      "${cfg.cacheDir}/toolcache"
      "${cfg.cacheDir}/dotnet"
    ];
in
{
  # Off unless a host asks for it, and here the default is not politeness.
  # `services.github-runners.<name>.enable` starts a unit that registers on activation, so importing this
  # file with it already on would put a FAILING unit on the next `nixos-rebuild` of any machine whose
  # credential had not been staged first. The order is: stage the token or the App key, flip this, rebuild.
  options.orcaVm.githubRunner = {
    enable = lib.mkEnableOption "a self-hosted GitHub Actions runner";

    repository = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "owner/repo";
      description = ''
        The `owner/repo` this runner registers against. Shorthand for `url`; set exactly one of them.
      '';
    };

    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "https://github.com/my-org";
      description = ''
        What the runner registers against: `https://github.com/<owner>/<repo>` for one repository, or
        `https://github.com/<org>` for the organisation (then restrict it to repositories with a runner
        group in the organisation's settings). Set exactly one of this and `repository`.
      '';
    };

    tokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/github-runner/token";
      description = ''
        A short-lived REGISTRATION token, staged the way the tailnet key is: written to the file, read
        once at activation, exchanged for the runner's own credential. Ignored when `githubApp` is set.
        Not usable with `ephemeral`: a registration token expires within the hour, and an ephemeral runner
        re-registers after every job.
      '';
    };

    githubApp = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          id = lib.mkOption { type = lib.types.int; description = "The App's numeric ID (not the client ID)."; };
          login = lib.mkOption { type = lib.types.str; description = "The account the App is installed on."; };
          privateKeyFile = lib.mkOption {
            type = lib.types.path;
            default = "/var/lib/github-runner/app.pem";
            description = "The App's private key, staged like the token: root-owned, mode 0600.";
          };
        };
      });
      default = null;
      description = ''
        Authenticate as a GitHub App instead of a staged registration token. On every start the service
        mints a short-lived installation token from the key and exchanges it for a fresh registration
        token, so no PAT and no long-lived token is stored. The App needs one permission: "Self-hosted
        runners: Read and write" on the organisation (or "Administration" on the repository).
      '';
    };

    runnerGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "consumer-ci";
      description = ''
        The organisation runner group to register into; null is the org's Default group. Set it for an
        org-scoped runner: the group's repository access is what limits which repositories can use the
        runner. An ephemeral runner re-registers after every job, so the group has to be named here — a
        one-off move in the UI would be undone by the next job. The group must exist before registration.
      '';
    };

    ephemeral = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        One job per registration: the runner deregisters after its job, the unit restarts, and the state
        and work directories are wiped before it registers again. Needs `githubApp`.
      '';
    };

    dedicatedUser = {
      enable = lib.mkEnableOption "a system user of the runner's own, instead of the workspace user";
      name = lib.mkOption { type = lib.types.str; default = "github-runner"; description = "Its name."; };
      uid = lib.mkOption {
        type = lib.types.int;
        default = 2000;
        description = ''
          A fixed uid, not a dynamic one: an ephemeral restart would otherwise hand the same service a new
          uid, which would lose ownership of the caches, and the podman socket path carries it.
        '';
      };
    };

    workDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/mnt/resource/github-runner/work";
      description = ''
        Where jobs check out and build — `$GITHUB_WORKSPACE`'s parent. Wiped on every start. Null keeps
        the workspace-host default, `~/actions-runner` on the data disk.
      '';
    };

    cacheDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/mnt/resource/github-runner/cache";
      description = ''
        What survives between jobs on purpose: the NuGet package cache and the Actions tool cache. Both are
        immutable versioned content, so keeping them costs no reproducibility. Null keeps nothing.
      '';
    };

    docker = {
      enable = lib.mkEnableOption "a rootless podman service for jobs, reachable as `docker` and `podman`";
      pruneSchedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "When to prune the runner's containers and images (a systemd calendar expression).";
      };
    };

    hostedToolchains = lib.mkEnableOption ''
      programs.nix-ld with the libraries prebuilt toolchains need (the .NET SDK among them), so the binaries
      `actions/setup-dotnet` and friends download run as they would on a hosted runner
    '';

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

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = (cfg.repository == null) != (cfg.url == null);
          message = "orcaVm.githubRunner: set exactly one of `repository` and `url`.";
        }
        {
          assertion = cfg.ephemeral -> cfg.githubApp != null;
          message = "orcaVm.githubRunner.ephemeral needs `githubApp`: a staged registration token expires within the hour.";
        }
        {
          assertion = cfg.docker.enable -> dedicated;
          message = "orcaVm.githubRunner.docker needs `dedicatedUser`: the podman service belongs to the runner's own user.";
        }
      ];

      services.github-runners.${runnerName} = {
        enable = true;

        # One runner, named for the machine, so a queued job in the Actions UI names the box it is waiting
        # for rather than a number.
        name = runnerName;

        inherit url;
        inherit (cfg) extraLabels ephemeral runnerGroup;

        # Take over a registration that still carries this name. A restart (every `nixos-rebuild switch`
        # that touches the unit) re-registers while GitHub still shows the previous registration online;
        # the cleanup only removes OFFLINE runners, so registration then failed with "A runner exists with the
        # same name" (oval-runner, 2026-09-23). The name is the hostname, unique per machine, so replacing
        # it only ever replaces this box's own earlier self.
        replace = true;

        tokenFile = if cfg.githubApp == null then cfg.tokenFile else null;
        githubApp = cfg.githubApp;

        # Beside a workspace: the user everything else on this box runs as, so a job sees the same layout,
        # the same caches and the same direnv whitelist an interactive shell does. A runner under its own
        # service user would restore into a different cache and read a different config — the "green on
        # one machine" problem that shape exists to remove. On a CI host: the dedicated user, for the
        # opposite reason.
        inherit user;
        inherit (cfg) workDir;

        extraEnvironment = cacheEnvironment // dockerEnvironment // toolchainEnvironment;

        # `direnv` is how a job enters a repository's pinned toolchain; it is on the system profile and the
        # workspace is whitelisted for the workspace user already (workspace.nix). No language toolchains:
        # each repository pins its own in its flake.nix, or downloads one with actions/setup-*.
        extraPackages = with pkgs;
          [ git gh gnutar gzip bash coreutils ]
          ++ lib.optionals cfg.docker.enable [ remotePodman remoteDocker ]
          ++ cfg.extraPackages;

        serviceOverrides =
          if cfg.workDir == null then {
            # Checkouts and caches live under /home on the data disk. The runner's work directory belongs
            # there too rather than on the OS disk.
            WorkingDirectory = lib.mkForce workDir;
            ReadWritePaths = [ ws.home ];
          } else {
            ReadWritePaths = preparedDirs;
          };
      };

      # 0755, not 0700: nixpkgs keeps the runner's state in /var/lib/github-runner/<name>, owned by the runner's
      # user, and a 0700 root parent locked a dedicated user out of its own state directory ("mkdir: cannot
      # create directory '/var/lib/github-runner': Permission denied", oval-runner, 2026-09-23). The secrets
      # beside it are protected by their own mode — the token and the App key are root-owned 0600 files.
      systemd.tmpfiles.rules = [ "d /var/lib/github-runner 0755 root root -" ]
        ++ lib.optional (cfg.workDir == null) "d ${workDir} 0755 ${ws.name} users -";
    }

    (lib.mkIf dedicated {
      users.groups.${user} = { };
      users.users.${user} = {
        isSystemUser = true;
        group = user;
        inherit uid;
        home = "/var/lib/${user}-home";
        createHome = true;
        # Rootless podman: a sub-uid/gid range for the containers' other uids, and a user manager that
        # stays up without a login so the podman socket is there when a job asks for it.
        autoSubUidGidRange = cfg.docker.enable;
        linger = cfg.docker.enable;
      };
    })

    (lib.mkIf (preparedDirs != [ ]) {
      # The temp disk is mounted (and formatted, when blank) after boot and wiped on every deallocate, so
      # its directories are made here, after the mount, rather than by tmpfiles.
      systemd.services."${serviceName}-dirs" = {
        description = "Directories for the GitHub Actions runner on the temp disk";
        wantedBy = [ "${serviceName}.service" ];
        before = [ "${serviceName}.service" ];
        unitConfig.RequiresMountsFor = preparedDirs;
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = lib.concatMapStringsSep "\n" (d: "install -d -m 0750 -o ${user} -g ${user} ${d}") preparedDirs;
      };
      systemd.services.${serviceName} = {
        requires = [ "${serviceName}-dirs.service" ];
        after = [ "${serviceName}-dirs.service" ];
      };
    })

    (lib.mkIf cfg.docker.enable {
      # podman itself is on for the host already (workspace.nix); a CI host also wants the `docker` name for
      # interactive debugging. Jobs get their own remote wrappers (above).
      virtualisation.podman.dockerCompat = lib.mkForce true;

      # nixpkgs hardens the runner with ProtectHome=true, which hides /run/user along with /home, so a job
      # could not reach the podman socket ("connect: permission denied", oval-runner, 2026-09-23). tmpfs keeps
      # /home and /root empty inside the sandbox; only this user's runtime directory is bound back in.
      # Measured with systemd-run under the same sandbox: `yes` and `read-only` fail, this runs a container.
      systemd.services.${serviceName}.serviceConfig = {
        ProtectHome = "tmpfs";
        BindPaths = [ "/run/user/${toString uid}" ];
      };

      # Images and stopped containers accumulate across jobs by design (the scratch database's image stays
      # warm); pruning on a schedule rather than per job keeps that warmth and bounds the disk.
      systemd.services."${serviceName}-podman-prune" = {
        description = "Prune the GitHub Actions runner's podman images and containers";
        serviceConfig = {
          Type = "oneshot";
          User = user;
          Environment = [ "CONTAINER_HOST=unix://${podmanSocket}" ];
        };
        script = "${pkgs.podman}/bin/podman --remote system prune --all --force --filter until=24h";
      };
      systemd.timers."${serviceName}-podman-prune" = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnCalendar = cfg.docker.pruneSchedule; Persistent = true; };
      };
    })

    (lib.mkIf cfg.hostedToolchains {
      programs.nix-ld.enable = true;
      # What the .NET SDK and runtime load (ICU for globalisation, OpenSSL for TLS, krb5 for Negotiate auth),
      # plus the usual base a prebuilt Linux binary expects.
      programs.nix-ld.libraries = with pkgs; [
        stdenv.cc.cc.lib
        zlib
        icu
        openssl
        krb5
        lttng-ust
        libunwind
        curl
      ];
    })
  ]);
}
