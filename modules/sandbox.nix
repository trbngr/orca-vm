# One rootless podman container per Orca workspace — the host side.
#
# Small on purpose: podman (workspace.nix), the sandbox rootfs installed at a stable path, and the
# state directory. The lifecycle — create, suspend, resume, destroy — is an Orca environment recipe
# that lives IN THE REPOSITORY it applies to (recipes/podman-sandbox/ in this repo is the copy to
# take: an orca.yaml and four scripts), because that is what Orca reads, and because the recipe is
# what changes when a repo's needs do.
#
# What a container gets (see recipes/podman-sandbox/podman-create.sh for the exact mounts):
#   /nix                        the host store and daemon socket, read-only — `nix develop` works, builds
#                               happen on the host daemon and are shared by every sandbox
#   <repo root>                 the primary checkout, read-write, same path — Orca adds the worktree from it
#   ORCA_SANDBOX_OVERLAYS       host directories mounted as overlays (a package cache, a local feed): warm,
#                               and writes inside one sandbox are invisible to every other
#   ~                           a per-sandbox home under ~/.local/state/orca-sandbox/<name>/home
#   --cpus / --memory           a ceiling per workspace; the runtime's cgroup (orca-server.nix) is the box's
#   sshd on a loopback port     Orca dials it with ~/.ssh/orca-sandbox; the box's tailnet is not involved
{ config, lib, pkgs, ... }:
let
  cfg = config.orcaVm.sandbox;
  ws = config.orcaVm.workspace;
  rootfs = pkgs.callPackage ../packages/sandbox-rootfs.nix {
    user = ws.name; fullName = ws.fullName; email = ws.email;
    workspaceDir = ws.dir; macHomeSymlink = ws.macHomeSymlink;
    extraPackages = ws.packages;
  };
in
{
  options.orcaVm.sandbox = {
    enable = lib.mkEnableOption "the per-workspace podman sandbox rootfs";
  };

  config = lib.mkIf cfg.enable {
    # The recipe finds the rootfs here; a rebuild moves the symlink, a running container keeps its old one.
    # /etc rather than the system profile's share/: the profile links only a fixed list of share/ subpaths,
    # and a new one silently is not among them (measured — the first deploy had no symlink at all).
    environment.etc."orca-sandbox/rootfs".source = rootfs;
    environment.variables.ORCA_SANDBOX_ROOTFS = "/etc/orca-sandbox/rootfs";

    systemd.tmpfiles.rules = [
      "d ${ws.home}/.local/state/orca-sandbox 0700 ${ws.name} users -"
    ];
  };
}
