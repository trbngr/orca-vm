# The workspace: the user, the data disk under /home, the tools every repo shell assumes are on the
# host, and ~/<dir> seeded from ./workspace.
#
# What the host provides vs what the repos provide, and why the line is there:
#   * host: git, gh, direnv + nix-direnv, jq, ripgrep, python, node, tmux, and whatever host.nix's
#     `packages` adds (the agent CLIs) — the things .envrc files, scripts and Orca's agents reach for
#     BEFORE a repo shell is entered.
#   * repo: language toolchains, pinned by each repo's own flake.nix + flake.lock and entered by
#     direnv. Nothing toolchain-shaped on the host, so two repos pinning different versions never
#     collide. (A repo without a flake gets only what the host has.)
#
# Layout:
#   ~/<dir>/repos/<repo>          primary checkouts (workspace/init.sh clones them from repos.conf)
#   ~/<dir>/.envrc                workspace-level environment, loaded by every repo shell that
#                                 `source_up`s
#   ~/orca/workspaces/<repo>/*    Orca's worktrees
#   /Users/<name> → /home/<name>  optional shim for files that carry a Mac's absolute home path
{ config, lib, pkgs, ... }:
let
  cfg = config.orcaVm.workspace;
  home = "/home/${cfg.name}";
  workspace = "${home}/${cfg.dir}";
  # orca-vm create attaches the data disk at LUN 1. waagent's udev rules (66-azure-storage.rules,
  # installed by services.waagent) name it precisely: scsi1 is the data controller. NOT nixpkgs'
  # /dev/disk/by-lun/1 — that rule matches `?:0:0:1` on ANY host, which is also the temp disk on the
  # OS controller (0:0:0:1), and on a first boot it pointed at the data disk at second 6 and at the
  # temp disk at second 19. Once formatted, the filesystem is found by its label, whatever the path.
  dataDisk = "/dev/disk/azure/scsi1/lun1";
  dataLabel = cfg.dataDiskLabel;
  # The size's temp disk — ephemeral by contract (wiped on deallocate), so formatting it whenever it
  # arrives blank is the design, not a risk. waagent could do this (ResourceDisk.Format) but does not
  # on NixOS (its daemon half is not what the module runs); the unit below is explicit and visible.
  resourceDisk = "/dev/disk/azure/resource";
  resourceLabel = cfg.scratchDiskLabel;

  # host.nix names packages as strings ("claude-code", "nodePackages.foo"); resolve them here.
  resolve = name: lib.attrByPath (lib.splitString "." name)
    (throw "orca-vm: no package `${name}` in nixpkgs (host.nix `packages`)") pkgs;
  extraPackages = map resolve cfg.packages;
in
{
  options.orcaVm.workspace = {
    name = lib.mkOption { type = lib.types.str; description = "Workspace user (owns the workspace and runs Orca)."; };
    fullName = lib.mkOption { type = lib.types.str; description = "git user.name"; };
    email = lib.mkOption { type = lib.types.str; description = "git user.email"; };
    githubUser = lib.mkOption { type = lib.types.str; description = "GitHub login; informational (gh auth is interactive)."; };
    authorizedKeys = lib.mkOption { type = lib.types.listOf lib.types.str; description = "SSH public keys for the user."; };
    dir = lib.mkOption {
      type = lib.types.str;
      default = "workspace";
      description = "Workspace directory under the user's home, seeded from ./workspace.";
    };
    macHomeSymlink = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Symlink /Users/<name> to /home/<name>.";
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra nixpkgs attribute names to install on the host (agent CLIs and the like).";
    };
    source = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        A directory seeded into the workspace on top of this flake's own ./workspace (a consumer's
        .envrc, repos.conf, extra config files). Seeded first, so on a name clash yours wins.
      '';
    };
    dataDiskLabel = lib.mkOption {
      type = lib.types.str;
      default = "orcahome";
      description = "ext4 label of the data disk under /home. The disk is found by this, never by device name; keep it stable across rebuilds.";
    };
    scratchDiskLabel = lib.mkOption {
      type = lib.types.str;
      default = "orcascratch";
      description = "ext4 label of the ephemeral temp disk at /mnt/resource; a disk without it is reformatted on arrival.";
    };
    # Read by other modules that need the resolved paths.
    home = lib.mkOption { type = lib.types.str; readOnly = true; default = home; };
    workspaceDir = lib.mkOption { type = lib.types.str; readOnly = true; default = workspace; };
  };

  config = {
    # ── The user ───────────────────────────────────────────────────────────────────────────────────
    users.users.${cfg.name} = {
      isNormalUser = true;
      uid = 1000;
      inherit home;
      createHome = false; # orca-vm-home-dirs creates it after /home is mounted — see below
      extraGroups = [ "wheel" ];
      autoSubUidGidRange = true; # rootless podman: a sub-uid/gid range for the container's other uids
      shell = pkgs.bash;
      openssh.authorizedKeys.keys = cfg.authorizedKeys;
    };
    security.sudo.wheelNeedsPassword = false; # single-operator dev box; `nixos-rebuild --use-remote-sudo` relies on it

    # ── Containers (one rootless podman container per Orca workspace, when sandbox.enable) ────────
    # Rootless: the containers run as the workspace user, agents inside them are uid 1000 mapped to
    # the same uid outside (--userns=keep-id), so bind-mounted checkouts keep their ownership. The
    # sub-uid range is what lets a rootless container have more than one uid at all.
    virtualisation.podman = {
      enable = true;
      dockerCompat = false; # the recipe scripts speak podman; flip this if something needs a `docker` name
      defaultNetwork.settings.dns_enabled = true;
    };

    # ── The data disk under /home ──────────────────────────────────────────────────────────────────
    # Formatted once, on first sight, only when blkid finds no filesystem — a reinstall of the OS disk
    # leaves it untouched. `nofail` so a detached disk degrades to a usable machine, not a boot hang.
    fileSystems."/home" = {
      device = "/dev/disk/by-label/${dataLabel}";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=30s" "noatime" ];
    };
    systemd.services.orca-vm-data-disk-init = {
      description = "Format the workspace data disk on first sight (never when it already carries a filesystem)";
      unitConfig.DefaultDependencies = false;
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      before = [ "home.mount" ];
      wantedBy = [ "home.mount" ];
      path = [ pkgs.util-linux pkgs.e2fsprogs ];
      serviceConfig.Type = "oneshot";
      script = ''
        [ -e ${dataDisk} ] || { echo "orca-vm-data-disk-init: ${dataDisk} is not attached; /home stays on the OS disk"; exit 0; }
        # Any filesystem or partition table on it means it is someone's data: never touch it.
        if blkid -p ${dataDisk} 2>/dev/null | grep -Eq 'TYPE=|PTTYPE='; then
          exit 0
        fi
        echo "orca-vm-data-disk-init: ${dataDisk} is blank — creating ext4 labelled ${dataLabel}"
        mkfs.ext4 -L ${dataLabel} -m 0 ${dataDisk}
        udevadm settle
      '';
    };

    # The temp disk: format whenever it shows up without our label (first boot, and every start after a
    # deallocate), then it mounts by label like any other filesystem.
    fileSystems."/mnt/resource" = {
      device = "/dev/disk/by-label/${resourceLabel}";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=15s" "noatime" ];
    };
    systemd.services.orca-vm-resource-disk-init = {
      description = "Format the ephemeral Azure temp disk whenever it arrives blank";
      unitConfig.DefaultDependencies = false;
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      before = [ "mnt-resource.mount" ];
      wantedBy = [ "mnt-resource.mount" ];
      path = [ pkgs.util-linux pkgs.e2fsprogs ];
      serviceConfig.Type = "oneshot";
      script = ''
        [ -e ${resourceDisk} ] || { echo "orca-vm-resource-disk-init: no temp disk on this size"; exit 0; }
        if blkid -o value -s LABEL ${resourceDisk} ${resourceDisk}-part1 2>/dev/null | grep -qx ${resourceLabel}; then
          exit 0
        fi
        echo "orca-vm-resource-disk-init: temp disk is not ours yet — wiping and creating ext4 labelled ${resourceLabel}"
        wipefs -a ${resourceDisk}
        mkfs.ext4 -L ${resourceLabel} -m 0 -E lazy_itable_init=1,lazy_journal_init=1 ${resourceDisk}
        udevadm settle
      '';
    };

    # Home directories are created AFTER /home is mounted, on the data disk. NixOS activation runs
    # before any mount unit, and tmpfiles at second 2 of the first boot — both would create the
    # directory on the OS disk, where the mount then hides it (measured). So activation is told not to,
    # and this unit, ordered by RequiresMountsFor, does it where it belongs.
    systemd.services.orca-vm-home-dirs = {
      description = "Create the workspace user's home on the data disk";
      unitConfig = { RequiresMountsFor = "/home"; ConditionPathIsMountPoint = "/home"; };
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      serviceConfig.RemainAfterExit = true;
      script = ''
        install -d -m 0700 -o ${cfg.name} -g users ${home}
        install -d -m 0755 -o ${cfg.name} -g users ${home}/orca
      '';
    };
    systemd.tmpfiles.rules = lib.optionals cfg.macHomeSymlink [
      "d /Users 0755 root root -"
      "L+ /Users/${cfg.name} - - - - ${home}"
    ];

    # ── Nix ────────────────────────────────────────────────────────────────────────────────────────
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" cfg.name ]; # `nix develop` in a repo shell may need to add substituters
      auto-optimise-store = true;
      max-jobs = "auto";
    };
    nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
    # nix-direnv keeps a GC root per repo shell it has evaluated; the weekly GC respects those.

    # ── Tools on the host ──────────────────────────────────────────────────────────────────────────
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      silent = false;
      # Every .envrc under the workspace and under Orca's worktrees is trusted without a `direnv allow`.
      # direnv's allow is per file path and per content hash: a fresh Orca worktree is a new path, and a
      # `git pull` that changes .envrc is a new hash — either way the shell silently enters WITHOUT the
      # repo's toolchain, and an agent's first build fails in a way that reads as a broken tree.
      # One operator, tailnet-only box: the trust boundary is the account, not the directory.
      settings.whitelist.prefix = [ workspace "${home}/orca" ];
    };
    programs.git = {
      enable = true;
      config = {
        user.name = cfg.fullName;
        user.email = cfg.email;
        init.defaultBranch = "main";
        commit.gpgsign = false; # no signing key on the box
        pull.rebase = false;
      };
    };
    programs.tmux.enable = true;
    programs.bash.completion.enable = true;

    # Unfree packages (the agent CLIs are) are allowed by the names host.nix lists, and nothing else
    # by accident.
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) (map (n: lib.last (lib.splitString "." n)) cfg.packages);

    environment.systemPackages = with pkgs; [
      git gh jq ripgrep python3 nodejs_22 curl wget unzip file tree htop dnsutils
    ] ++ extraPackages;

    # ── ~/<dir>, seeded from ./workspace (and the consumer's `source` first) ───────────────────────
    # Copies only what is absent: a later change to ./workspace never overwrites a file the operator has
    # edited in place. Cloning the repos is `bootstrap.sh`, by hand, because it needs `gh auth`.
    systemd.services.orca-vm-workspace-seed = {
      description = "Seed the workspace from the image's skeleton (never overwrites)";
      after = [ "orca-vm-home-dirs.service" ];
      requires = [ "orca-vm-home-dirs.service" ];
      unitConfig = { RequiresMountsFor = "/home"; ConditionPathIsMountPoint = "/home"; };
      wantedBy = [ "multi-user.target" ];
      serviceConfig = { Type = "oneshot"; User = cfg.name; Group = "users"; };
      path = [ pkgs.coreutils pkgs.findutils ];
      script = ''
        dst=${workspace}
        mkdir -p "$dst/repos"
        for src in ${lib.concatStringsSep " " (lib.optional (cfg.source != null) "${cfg.source}" ++ [ "${../workspace}" ])}; do
          (cd "$src" && find . -type f) | while read -r f; do
            if [ ! -e "$dst/$f" ]; then
              mkdir -p "$dst/$(dirname "$f")"
              cp "$src/$f" "$dst/$f"
              chmod u+w "$dst/$f"
              case "$f" in *.sh) chmod +x "$dst/$f";; esac
              echo "seeded $f from $src"
            fi
          done
        done
      '';
    };

    # Locale/time: builds and logs in UTC; the client side renders local time.
    time.timeZone = "UTC";
    i18n.defaultLocale = "en_US.UTF-8";
  };
}
