#!/usr/bin/env bash
# The one command for the Azure side. Runs from any checkout that carries host.nix and azure/vm.env
# (this repository, or a consumer of it as a flake input); `nix develop` puts it on PATH with az,
# nixos-anywhere, nixos-rebuild and jq beside it.
#
#   orca-vm create [--plan]        the resource group, network, disks and a stock VM (idempotent)
#   orca-vm install                nixos-anywhere onto it (TS_AUTHKEY=… to join the tailnet unattended)
#   orca-vm rebuild                nixos-rebuild switch over the tailnet, built on the VM
#   orca-vm status|stop|start|resize <size>|detach-public-ip|ssh|serial|run '<shell>'
#
# ORCA_VM_ROOT overrides where host.nix and azure/vm.env are looked for (default: the git toplevel
# of the current directory). ORCA_VM_FLAKE overrides the flake install and rebuild use (default:
# ORCA_VM_ROOT) — for a repository whose one flake declares several hosts, each in a subdirectory:
#   ORCA_VM_ROOT=$PWD/runner ORCA_VM_FLAKE=$PWD orca-vm create
set -euo pipefail

libexec="${ORCA_VM_LIBEXEC:-$(cd "$(dirname "$(realpath "$0")")" && pwd)}"
case "${1:-}" in
  create)  shift; exec "$libexec/create-vm.sh" "$@" ;;
  install) shift; exec "$libexec/install-nixos.sh" "$@" ;;
  ""|-h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *)       exec "$libexec/vm.sh" "$@" ;;
esac
