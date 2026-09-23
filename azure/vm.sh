#!/usr/bin/env bash
# Day-2 operations on the VM.
#
#   orca-vm status             power state, size, IPs
#   orca-vm stop               deallocate — compute stops billing, disks stay (the data disk keeps /home)
#   orca-vm start
#   orca-vm resize <size>      e.g. Standard_D32ads_v5; the VM is deallocated for it
#   orca-vm rebuild            nixos-rebuild switch over the tailnet, built on the VM (after editing)
#   orca-vm detach-public-ip   after Tailscale is up: no public address at all
#   orca-vm ssh                ssh root@<public ip> (install window); day to day use Tailscale SSH
#   orca-vm serial             the Azure serial console (rescue)
#   orca-vm run '<shell>'      run a shell snippet as root THROUGH THE AZURE AGENT — no network path
#                                  needed. The way in from a machine that is not on the tailnet (slow: ~30 s
#                                  round trip, output capped by Azure).
set -euo pipefail

ROOT="${ORCA_VM_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ -f "$ROOT/host.nix" && -f "$ROOT/azure/vm.env" ]] || { echo "❌ no host.nix + azure/vm.env under $ROOT — run from your host checkout (or set ORCA_VM_ROOT)" >&2; exit 2; }
# shellcheck source=../azure/vm.env
source "$ROOT/azure/vm.env"

case "${1:-}" in
  rebuild)
    # No az needed: the tailnet is the path. The user account from host.nix, sudo without a password.
    user="$(hostval user.name)"
    exec nixos-rebuild switch --flake "${ORCA_VM_FLAKE:-$ROOT}#$VM_NAME" \
      --target-host "$user@$VM_NAME" --build-host "$user@$VM_NAME" --use-remote-sudo ;;
esac

az account set --subscription "$AZ_SUBSCRIPTION"

case "${1:-}" in
  status)
    az vm show -d -g "$AZ_RG" -n "$VM_NAME" --query '{name:name,power:powerState,size:hardwareProfile.vmSize,publicIp:publicIps,privateIp:privateIps,zone:zones[0]}' -o table ;;
  stop)   az vm deallocate -g "$AZ_RG" -n "$VM_NAME" -o none && echo "deallocated" ;;
  start)  az vm start -g "$AZ_RG" -n "$VM_NAME" -o none && echo "started" ;;
  resize)
    [[ -n "${2:-}" ]] || { echo "usage: vm.sh resize <size>" >&2; exit 2; }
    az vm deallocate -g "$AZ_RG" -n "$VM_NAME" -o none
    az vm resize -g "$AZ_RG" -n "$VM_NAME" --size "$2" -o none
    az vm start -g "$AZ_RG" -n "$VM_NAME" -o none && echo "resized to $2 and started" ;;
  detach-public-ip)
    az network nic ip-config update -g "$AZ_RG" --nic-name "$VM_NAME-nic" -n ipconfig1 --remove publicIpAddress -o none
    az network public-ip delete -g "$AZ_RG" -n "$VM_NAME-pip" -o none
    az network nsg rule delete -g "$AZ_RG" --nsg-name "$VM_NAME-nsg" -n allow-ssh-operator -o none
    echo "public IP and the operator SSH rule are gone; the box is tailnet-only" ;;
  ssh)
    IP="$(az vm show -d -g "$AZ_RG" -n "$VM_NAME" --query publicIps -o tsv)"
    [[ -n "$IP" ]] || { echo "no public IP — use Tailscale: ssh $(hostval user.name)@$VM_NAME" >&2; exit 1; }
    exec ssh "root@$IP" ;;
  serial) exec az serial-console connect -g "$AZ_RG" -n "$VM_NAME" ;;
  run)
    [[ -n "${2:-}" ]] || { echo "usage: vm.sh run '<shell>'" >&2; exit 2; }
    az vm run-command invoke -g "$AZ_RG" -n "$VM_NAME" --command-id RunShellScript --scripts "$2" \
      --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,$p' ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
