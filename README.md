# orca-vm

A personal build host in the cloud that runs [Orca](https://www.onorca.dev) in server mode, with your
repositories checked out, your tools on PATH and your coding agents logged in — declared end to end in
one Nix flake and installed onto an Azure VM with nixos-anywhere. Laptop, web and phone clients pair
to it over Tailscale; nothing is reachable from the public internet.

```
laptop / web / phone ──Tailscale──▶  <hostName> (NixOS on Azure)
                                      ├─ orca-serve.service     orca serve, as you, advertising the tailnet name
                                      ├─ /home  (data disk)     ~/<workspace>/repos, ~/orca/workspaces, ~/.config/orca
                                      ├─ /mnt/resource          the size's temp disk — scratch, wiped on stop
                                      └─ /nix/store             one store; each repo's flake.nix pins its own toolchain
```

This is a **template**: use it on GitHub ("Use this template"), clone your copy, fill in three files,
deploy. Everything personal is in those files; the modules never need editing for a new person.

## Fill in

| File | What |
|------|------|
| `host.nix` | **The** file: architecture, hostname, your name/email/GitHub login/SSH key, workspace directory, the agent CLIs and other tools, Orca's port and memory ceiling, whether the sandbox and the GitHub runner are on |
| `azure/vm.env` | Subscription, region, VM size, disk sizes. The VM name and image architecture are derived from `host.nix` |
| `workspace/repos.conf` | `owner/name` per line — cloned into `~/<workspace>/repos/` by the bootstrap script |

Then `nix flake check` — it evaluates the whole host without building anything and catches a typo in
`host.nix` before any money is spent. It runs on a Mac.

## Runbook — first deploy

Prerequisites on your laptop: Nix (the [Determinate installer](https://determinate.systems/nix-installer/)
is the easy way), `az login` into the subscription, a Tailscale account and an SSH key. Generate a
**reusable, pre-authorized** auth key in the Tailscale admin console (Settings → Keys) if you want the
box to join unattended.

```bash
direnv allow                      # az, nixos-anywhere, jq from the flake (or: nix develop)
nix flake check

azure/create-vm.sh --plan         # what will be created, and from which IP SSH is allowed
azure/create-vm.sh                # ~3 min. Prints the public IP.

TS_AUTHKEY=tskey-auth-… azure/install-nixos.sh   # ~10–15 min: kexec → disko (OS disk only) → build on the VM → install → reboot
```

After the reboot:

```bash
ssh root@<public ip> tailscale status          # joined? (or: sudo tailscale up --ssh, once, if no key was given)
azure/vm.sh detach-public-ip                   # the box is now tailnet-only
ssh <user>@<hostName>                          # Tailscale SSH from here on
```

On the box, once:

```bash
~/<workspace>/bootstrap.sh                     # gh device login, clone repos.conf, direnv allow
tmux new -s login -x 500 'claude auth login'   # device-auth the agent once; state lands in ~/.claude on the data disk
orca-pairing                                   # the pairing link
```

Paste the pairing link into Orca on the laptop: Settings → Remote Orca Servers → Add Server. Web and
mobile clients pair the same way; generating a new link replaces an unused one (`orca-pairing --fresh`),
and paired clients keep their grant until it is revoked under Shared Server Access.

## Day 2

| Task | Command |
|------|---------|
| Change the host | edit, `nix flake check`, `azure/vm.sh rebuild` (builds on the VM, over the tailnet) |
| Update Orca | bump `version` in `packages/orca.nix`, `nix store prefetch-file <url>` for both AppImages, paste the hashes, rebuild |
| Update nixpkgs | `nix flake update`, review `flake.lock`, rebuild |
| Add a repo | a line in `workspace/repos.conf` **and** in `~/<workspace>/repos.conf` on the box (seeding never overwrites), then `~/<workspace>/init.sh` |
| Stop billing compute | `azure/vm.sh stop` — deallocated VMs bill disks only; `/home` is on the data disk and survives; `/mnt/resource` does not |
| More cores | `azure/vm.sh resize Standard_D32ads_v5` |
| Rescue | `azure/vm.sh serial` — the Azure serial console; the kernel logs to ttyS0 |
| No tailnet on this machine | `azure/vm.sh run '<shell>'` — runs as root through the Azure agent, no network path needed (slow, output capped) |

Costs, order of magnitude (verify in the pricing calculator): `D16ads_v5` ≈ $0.8/h running; a 1 TiB
Premium SSD data disk ≈ $135/mo; the OS disk ≈ $20/mo; the NAT gateway ≈ $32/mo plus egress. Stopped
overnight and weekends, compute is roughly a third of always-on.

## Layout

| Path | What |
|------|------|
| `host.nix` | The machine's identity and your choices — the one file to edit |
| `flake.nix` | `nixosConfigurations.<hostName>`, `packages.<linux>.orca`, a devShell (az, nixos-anywhere, jq), `checks` that evaluate the host |
| `nixos/default.nix`, `disko.nix` | Module composition (add your own NixOS options here); the OS-disk layout (the data disk is deliberately not disko's) |
| `modules/azure.nix` | Platform contract via nixpkgs' `azure-common` (waagent, cloud-init, Hyper-V, serial console, `/dev/disk/azure/*`), UEFI, firewall |
| `modules/tailscale.nix` | Tailscale with SSH, pre-auth key from `/var/lib/tailscale/authkey` (consumed and deleted), tailnet trusted |
| `modules/workspace.nix` | User, data disk under `/home` (formatted on first sight only), host tools, direnv (workspace and `~/orca` whitelisted — Orca worktrees never run `direnv allow`), git identity, workspace seeding, the optional `/Users` shim |
| `modules/orca-server.nix` | `orca-serve.service`: `orca-ide-app --no-sandbox serve`, advertised address resolved from tailscaled at start; `orca-pairing` |
| `modules/sandbox.nix`, `packages/sandbox-rootfs.nix` | Optional: the host side of one rootless podman container per Orca workspace |
| `modules/github-runner.nix` | Optional: a self-hosted GitHub Actions runner as the workspace user |
| `packages/orca.nix` | The release AppImage wrapped for NixOS: `orca-ide` (CLI, Node mode) and `orca-ide-app` (Electron runtime), pinned by tag + hash, x86_64 and aarch64 |
| `workspace/` | What `~/<workspace>` is seeded with: `.envrc`, `repos.conf`, `init.sh`, `bootstrap.sh` |
| `recipes/podman-sandbox/` | The Orca environment recipe to copy into a repository that wants sandboxed workspaces |
| `azure/` | `vm.env`, `create-vm.sh` (idempotent), `install-nixos.sh`, `vm.sh` (status/stop/start/resize/rebuild/detach-public-ip/ssh/serial/run) |

## Design decisions

- **A VM, not a container service.** A long-lived, stateful, IOPS-heavy box with terminals, a
  persistent runtime and child containers per workspace. ACA/ACI cannot nest containers or give fast
  local disk; AKS is a control plane for a fleet of one. The containers belong *inside* the VM.
- **NixOS from this flake, not a golden image.** `nixos-anywhere` kexecs a stock Ubuntu VM into the
  NixOS installer and installs the host — reproducible from `flake.lock`, rebuilt in place with
  `nixos-rebuild`, no VHD pipeline. A Mac cannot build Linux closures, so install and rebuild both build
  **on the VM**; evaluation (`nix flake check`) runs anywhere.
- **Tailnet-only.** No public IP after install, no inbound NSG rules, Tailscale SSH for the shell, Orca
  paired over the MagicDNS name. The public IP exists for the install window and is then deleted.
  Outbound goes through a **NAT gateway**: a VM without a public IP has no default outbound access on a
  VNet created after September 2025 — measured the moment the install IP was detached, when nix, gh and
  Tailscale's control plane all went dark at once.
- **The toolchain is the repos' business.** The host carries git, gh, direnv + nix-direnv, node,
  python and the agent CLIs. Language toolchains come from each repo's own `flake.nix`, entered by
  direnv, so two repos can pin different SDKs. A repo without a flake gets only what the host has —
  add what it needs to `packages` in `host.nix`.
- **The data disk is not disko's.** disko formats every disk it knows about on install; `/home`
  (checkouts, worktrees, caches, Orca's state) is mounted by label and formatted only when blank, so a
  reinstall of the OS disk never touches it. Nothing is addressed by device letter — Azure shuffles them
  between boots.
- **Trusted Launch is off.** kexec, which is how nixos-anywhere boots the installer, is refused under
  Secure Boot. `create-vm.sh` registers the subscription feature that allows a Gen2 VM to opt out.

## Optional: one sandbox per workspace

With `sandbox.enable = true` in `host.nix`, every Orca workspace can run in its own rootless podman
container: its own home, process table and memory ceiling, with the host's nix store shared read-only
so a repo's flake resolves instantly and builds land on the host for every other sandbox. The host side
is `modules/sandbox.nix` + `packages/sandbox-rootfs.nix`; the lifecycle is an Orca environment recipe
that lives **in each repository** that wants it, because that is what Orca reads:

```bash
cd ~/<workspace>/repos/<repo>
cp <orca-vm>/recipes/podman-sandbox/orca.yaml .
mkdir -p scripts/orca-vm && cp <orca-vm>/recipes/podman-sandbox/{podman-*.sh,sandbox.conf} scripts/orca-vm/
git add orca.yaml scripts/orca-vm && git commit -m "Add the podman sandbox recipe"
```

`sandbox.conf` holds the per-repository knobs: host directories to mount as overlays (package caches, a
local feed — warm, and writes stay inside the sandbox), CPU and memory ceilings. Validate with
`orca vm recipe doctor podman-sandbox --provision` on the box, then pick **Run on → Podman sandbox**
when creating a workspace.

Inside a sandbox: you are your user (uid 1000), `gh` is logged in through the host's token, git has your
identity, and the agent CLIs from `host.nix` are present. For a logged-in Claude inside sandboxes, run
`claude setup-token` once on the host (in a wide tmux pane — the URL is long) and save the token it prints
to `~/.config/orca-sandbox/claude-token` (mode 0600).

## Optional: a GitHub Actions runner

For repositories whose CI needs what only this box has. Set `githubRunner.repository` in `host.nix`,
stage a registration token (it is short-lived and consumed once), *then* flip `enable` and rebuild:

```bash
gh api -X POST repos/<owner>/<repo>/actions/runners/registration-token -q .token \
  | ssh <hostName> 'sudo install -m 0600 -o root /dev/stdin /var/lib/github-runner/token'
```

Read the trust note at the top of `modules/github-runner.nix` before pointing a public repository at it.

## Customizing further

- **Workspace-wide environment** — `workspace/.envrc` is loaded by every repo shell that ends its
  `.envrc` with `source_up_if_exists`. Feed paths, cache locations, telemetry opt-outs go there.
- **Files carrying a Mac's absolute home path** — `workspace.macHomeSymlink = true` puts
  `/Users/<name> → /home/<name>` on the box (and in every sandbox).
- **More NixOS** — `nixos/default.nix` is a normal NixOS module: add services, kernel settings, anything.
- **ARM** — `system = "aarch64-linux"` in `host.nix` and an ARM size (`Standard_D16pds_v5`) in
  `azure/vm.env`; both Orca AppImages are packaged. ~20 % cheaper; check the region has the quota.
- **Regions and quota** — `create-vm.sh` refuses a size the subscription cannot have in the region
  before creating anything. Regions without availability zones cannot use Premium SSD v2; `vm.env`
  explains the disk choice.

## Known limits

- **Single operator.** One Linux account, one Orca runtime, one set of credentials. A second person gets
  their own VM from their own copy of this template — isolation between people is a security boundary in
  a way isolation between one person's agents is not.
- **Secrets at rest.** Orca reports `[secrets] The OS keyring is unavailable, so secrets are stored
  unencrypted` — a headless box has no unlocked keyring. The disk is encrypted at rest by Azure and the
  box is tailnet-only; if that is not enough, `gnome-keyring` with a PAM-unlocked login keyring is the fix
  Orca names.
- **Auto-deallocate** is not wired: an Azure Automation schedule or a cron on the laptop calling
  `azure/vm.sh stop` overnight is the shape.

## License

MIT — see [LICENSE](LICENSE). Orca itself is packaged from its release AppImage and carries its own license.
