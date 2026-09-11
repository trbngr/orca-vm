# host.nix — THE file to edit. Everything personal about your machine lives here; the modules read it
# and nothing else in the repository needs to change for a new person or a new box.
#
# flake.nix names the NixOS configuration after `hostName`, and azure/vm.env derives the VM name and
# the image architecture from `hostName` and `system`, so the VM Azure builds and the system Nix builds
# cannot disagree.
#
# After editing: `nix flake check` (evaluates everything, builds nothing, runs on a Mac).
{
  # ── The machine ────────────────────────────────────────────────────────────────────────────────
  # "x86_64-linux" with an x64 Azure size (Standard_D16ads_v5, …) or "aarch64-linux" with an ARM
  # size (Standard_D16pds_v5, …). Both Orca AppImages are packaged; change VM_SIZE in azure/vm.env
  # together with this.
  system = "x86_64-linux";
  # Also the Tailscale node name, the Azure VM name and the `nixos-rebuild --flake .#<hostName>` target.
  hostName = "orca-vm";

  # ── You ────────────────────────────────────────────────────────────────────────────────────────
  user = {
    name = "me";                     # the Linux account; owns the workspace and runs Orca
    fullName = "Your Name";          # git user.name
    email = "you@example.com";       # git user.email
    githubUser = "your-github-login"; # informational; `gh auth login` on the box is what logs you in
    # `cat ~/.ssh/id_ed25519.pub` on the machine you will SSH from. Used for root during the install
    # window and for your account afterwards (Tailscale SSH does not need it, but keep one here).
    authorizedKeys = [
      "ssh-ed25519 AAAA… you@laptop"
    ];
  };

  # ── The workspace ──────────────────────────────────────────────────────────────────────────────
  workspace = {
    # Directory under $HOME that holds repos/, the workspace .envrc and the helper scripts, seeded
    # from ./workspace on first boot. Repositories are cloned into ~/<dir>/repos/<name> by
    # ~/<dir>/bootstrap.sh from workspace/repos.conf.
    dir = "workspace";
    # Symlink /Users/<name> → /home/<name>, so files carrying a Mac's absolute home path (a lock file,
    # a hand-written config) resolve unchanged on the box. Off unless you know you need it.
    macHomeSymlink = false;
  };

  # ── Tools on the host, by nixpkgs attribute name ───────────────────────────────────────────────
  # The host provides what every repo shell reaches for BEFORE the repo's own toolchain is entered:
  # git, gh, direnv + nix-direnv, jq, ripgrep, python, node, tmux are always there. Add the agent CLIs
  # and anything else here; unfree packages in this list are allowed by name automatically.
  # Language toolchains (dotnet, go, rust, …) belong in each repository's own flake.nix, entered by
  # direnv, so two repos can pin different versions — not here.
  packages = [
    "claude-code"   # `claude auth login` once on the box; state lands in ~/.claude on the data disk
    # "codex"
    # "gemini-cli"
  ];

  # ── Orca ───────────────────────────────────────────────────────────────────────────────────────
  orca = {
    port = 7331;          # only reachable over the tailnet
    pairingAddress = null; # null → this node's MagicDNS name, resolved when the service starts
    # Memory ceiling for the runtime's cgroup — every agent, terminal and build is a child of it.
    # Leave headroom for sshd, tailscaled and the nix daemon: ~80–90 % of the VM's RAM. null = no limit.
    memoryHigh = "52G";
    memoryMax = "56G";
  };

  # ── Optional: one rootless podman container per Orca workspace ─────────────────────────────────
  # The host side (rootfs, state directory). The lifecycle is an Orca environment recipe that lives in
  # each repository that wants it — copy recipes/podman-sandbox/ there (see README).
  sandbox.enable = true;

  # ── Optional: a self-hosted GitHub Actions runner on this box ──────────────────────────────────
  # Off until a registration token is staged (see modules/github-runner.nix): enabling it first would
  # put a failing unit on the next rebuild.
  githubRunner = {
    enable = false;
    repository = "owner/repo";  # the runner registers against this repository
    labels = [ "nixos" ];       # `self-hosted` is implicit
  };
}
