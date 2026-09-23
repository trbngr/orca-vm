#!/usr/bin/env bash
# Install NixOS onto the stock VM with nixos-anywhere, building the system ON the VM.
#
#   TS_AUTHKEY=tskey-auth-… orca-vm install      join the tailnet unattended on first boot
#   orca-vm install                              join by hand afterwards: `sudo tailscale up --ssh`
#
# What happens: nixos-anywhere ssh's in as the stock user, kexecs into a NixOS installer held in RAM,
# runs disko on the OS disk only (modules/disko.nix — the data disk is not touched), builds the closure
# of the host there (`--build-on remote`: a Mac cannot build Linux), installs, and reboots into it. A
# Tailscale pre-auth key, if given, rides along as /var/lib/tailscale/authkey and is consumed and
# deleted on first boot (modules/tailscale.nix).
#
# The public IP is left in place. Once `tailscale status` on the box shows it joined, remove it:
#   orca-vm detach-public-ip
set -euo pipefail

ROOT="${ORCA_VM_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ -f "$ROOT/host.nix" && -f "$ROOT/azure/vm.env" ]] || { echo "❌ no host.nix + azure/vm.env under $ROOT — run from your host checkout (or set ORCA_VM_ROOT)" >&2; exit 2; }
# shellcheck source=../azure/vm.env
source "$ROOT/azure/vm.env"

az account set --subscription "$AZ_SUBSCRIPTION"
IP="$(az vm show -d -g "$AZ_RG" -n "$VM_NAME" --query publicIps -o tsv)"
[[ -n "$IP" ]] || { echo "❌ $VM_NAME has no public IP — was it created (orca-vm create)?" >&2; exit 1; }
echo "▶ target $ADMIN_USER@$IP"

# The stock VM's host key will be replaced by the install; forget both before and after.
ssh-keygen -R "$IP" >/dev/null 2>&1 || true

extra="$(mktemp -d)"
trap 'rm -rf "$extra"' EXIT
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  mkdir -p "$extra/var/lib/tailscale"
  printf '%s\n' "$TS_AUTHKEY" > "$extra/var/lib/tailscale/authkey"
  chmod 600 "$extra/var/lib/tailscale/authkey"
  echo "▶ Tailscale pre-auth key staged (consumed on first boot)"
fi

# The flake that declares the host: the checkout itself, or (ORCA_VM_FLAKE) a parent whose flake declares
# several hosts, each with its own host.nix + azure/vm.env in a subdirectory.
flake="${ORCA_VM_FLAKE:-$ROOT}#$VM_NAME"
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30)

# 1. Boot the NixOS installer into RAM, and stop there.
nixos-anywhere --flake "$flake" --phases kexec \
  --target-host "$ADMIN_USER@$IP" \
  --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null

# 2. Find the OS disk by what Azure fixes, not by kernel name: LUN 0 on the OS storage controller (VMBus
#    f8b3781a-1e82-4818-a1c3-63d806ec15bb). Exactly one disk must match, or nothing is formatted —
#    disko destroys whatever /dev/orca-vm-os-disk points at (modules/disko.nix).
echo "▶ locating the OS disk (LUN 0 on the OS storage controller)"
for _ in $(seq 1 30); do ssh "${ssh_opts[@]}" "root@$IP" true 2>/dev/null && break; sleep 5; done
os_disk="$(ssh "${ssh_opts[@]}" "root@$IP" 'set -eu
  found=""
  for d in /sys/block/sd*; do
    case "$(readlink -f "$d/device")" in
      */f8b3781a-1e82-4818-a1c3-63d806ec15bb/host*/target*/*:0:0:0) found="$found /dev/${d##*/}" ;;
    esac
  done
  set -- $found
  [ "$#" -eq 1 ] || { echo "expected one OS disk, found: ${found:-none}" >&2; exit 1; }
  ln -sfn "$1" /dev/orca-vm-os-disk
  echo "$1 $(lsblk -dno SIZE "$1")"')" \
  || { echo "❌ could not identify the OS disk; nothing was formatted" >&2; exit 1; }
echo "  $os_disk → /dev/orca-vm-os-disk"

# 3. Partition that disk, install, reboot — building the system on the VM (a Mac cannot build Linux).
nixos-anywhere --flake "$flake" --phases disko,install,reboot \
  --build-on remote \
  --target-host "root@$IP" \
  --extra-files "$extra" \
  --ssh-option StrictHostKeyChecking=no \
  --ssh-option UserKnownHostsFile=/dev/null

ssh-keygen -R "$IP" >/dev/null 2>&1 || true
echo ""
echo "✅ NixOS installed. In a minute: ssh root@$IP  (or, once joined, ssh <user>@$VM_NAME over Tailscale)"
echo "   Then: orca-vm detach-public-ip   and   ~/<workspace>/bootstrap.sh on the box"
