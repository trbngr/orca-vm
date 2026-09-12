#!/usr/bin/env bash
# Create the Azure resources for the host: resource group, network, a public IP that
# exists only for the install window, a Premium SSD v2 data disk at LUN 1, and a stock Ubuntu VM
# that nixos-anywhere will replace in place (orca-vm install).
#
#   orca-vm create            create everything; prints the public IP at the end
#   orca-vm create --plan     print the resource summary and exit
#
# Deliberate choices:
#   --security-type Standard   Trusted Launch (the Gen2 default) enables Secure Boot, and kexec — how
#                              nixos-anywhere boots the installer — is refused under it. Opting out needs
#                              the subscription feature Microsoft.Compute/UseStandardSecurityType, which
#                              this script registers (once, a few minutes to propagate) before the VM.
#   AZ_ZONE                    set only in zonal regions (northcentralus is not one); then the VM, the public
#                              IP and the data disk share it, which Premium SSD v2 requires.
#   Idempotent: every resource is created only if `show` cannot find it, so a failed run is re-run, not
#   cleaned up first.
#   NSG: SSH from THIS machine's public IP only, for the install window. Nothing else, ever.
#   NAT gateway: outbound internet for a VM with no public IP — Azure's default outbound access is gone
#                              for new VNets, and nix/gh/Tailscale all need egress (vm.env, NAT_GATEWAY).
#   The data disk is separate and attached at LUN 1, so it can outlive the VM (delete the VM, keep the
#   disk, recreate, reattach) and so /dev/disk/by-lun/1 is what the NixOS config mounts.
set -euo pipefail

ROOT="${ORCA_VM_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[[ -f "$ROOT/host.nix" && -f "$ROOT/azure/vm.env" ]] || { echo "❌ no host.nix + azure/vm.env under $ROOT — run from your host checkout (or set ORCA_VM_ROOT)" >&2; exit 2; }
# shellcheck source=../azure/vm.env
source "$ROOT/azure/vm.env"

case "$IMAGE_ARCH" in
  arm64) IMAGE_URN="$IMAGE_URN_ARM64" ;;
  x64)   IMAGE_URN="$IMAGE_URN_X64" ;;
  *) echo "IMAGE_ARCH must be arm64 or x64" >&2; exit 2 ;;
esac

[[ -r "$SSH_PUBKEY" ]] || { echo "❌ SSH public key not found: $SSH_PUBKEY" >&2; exit 1; }
MY_IP="$(curl -fsS https://api.ipify.org)"

zone_args=(); [[ -n "$AZ_ZONE" ]] && zone_args=(--zone "$AZ_ZONE")
disk_perf_args=()
if [[ "$DATA_DISK_SKU" == "PremiumV2_LRS" ]]; then
  [[ -n "$AZ_ZONE" ]] || { echo "❌ PremiumV2_LRS needs a zone (AZ_ZONE) — the region must support availability zones" >&2; exit 2; }
  disk_perf_args=(--disk-iops-read-write "$DATA_DISK_IOPS" --disk-mbps-read-write "$DATA_DISK_MBPS")
fi
exists() { az "$@" -o none >/dev/null 2>&1; }  # `az <type> show …` as an existence test

echo "$VM_NAME on Azure"
echo "  subscription  $AZ_SUBSCRIPTION"
echo "  location/zone $AZ_LOCATION / ${AZ_ZONE:-non-zonal}"
echo "  group         $AZ_RG"
echo "  vm            $VM_NAME  $VM_SIZE  ($IMAGE_URN)"
echo "  os disk       ${OS_DISK_GB} GiB Premium SSD"
if [[ "$DATA_DISK_SKU" == "PremiumV2_LRS" ]]; then
  echo "  data disk     ${DATA_DISK_GB} GiB Premium SSD v2, ${DATA_DISK_IOPS} IOPS / ${DATA_DISK_MBPS} MB/s, LUN 1"
else
  echo "  data disk     ${DATA_DISK_GB} GiB ${DATA_DISK_SKU} (sized tier), LUN 1"
fi
echo "  ssh from      $MY_IP/32 (install window only)"
[[ "${1:-}" == "--plan" ]] && exit 0

az account set --subscription "$AZ_SUBSCRIPTION"

# Fail before spending anything if the size is not available to this subscription here.
restricted="$(az vm list-skus -l "$AZ_LOCATION" --size "$VM_SIZE" --query "[0].restrictions[].reasonCode" -o tsv)"
[[ -z "$restricted" ]] || { echo "❌ $VM_SIZE is restricted in $AZ_LOCATION: $restricted (try another region or size; see azure/vm.env)" >&2; exit 1; }

echo "▶ resource group"
az group create -n "$AZ_RG" -l "$AZ_LOCATION" -o none

echo "▶ network security group (SSH from $MY_IP only)"
exists network nsg show -g "$AZ_RG" -n "$VM_NAME-nsg" || az network nsg create -g "$AZ_RG" -n "$VM_NAME-nsg" -o none
# The rule is (re)written every run: the operator's IP is whatever it is today.
az network nsg rule create -g "$AZ_RG" --nsg-name "$VM_NAME-nsg" -n allow-ssh-operator \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "$MY_IP/32" --destination-port-ranges 22 -o none 2>/dev/null \
|| az network nsg rule update -g "$AZ_RG" --nsg-name "$VM_NAME-nsg" -n allow-ssh-operator \
  --source-address-prefixes "$MY_IP/32" -o none

echo "▶ virtual network"
exists network vnet show -g "$AZ_RG" -n "$VM_NAME-vnet" || az network vnet create -g "$AZ_RG" -n "$VM_NAME-vnet" \
  --address-prefix 10.42.0.0/16 --subnet-name default --subnet-prefix 10.42.1.0/24 -o none

if [[ "$NAT_GATEWAY" == "true" ]]; then
  echo "▶ NAT gateway (the box's outbound path once its public IP is gone)"
  exists network public-ip show -g "$AZ_RG" -n "$VM_NAME-natip" || az network public-ip create -g "$AZ_RG" -n "$VM_NAME-natip" \
    --sku Standard --allocation-method Static "${zone_args[@]}" -o none
  exists network nat gateway show -g "$AZ_RG" -n "$VM_NAME-nat" || az network nat gateway create -g "$AZ_RG" -n "$VM_NAME-nat" \
    --public-ip-addresses "$VM_NAME-natip" --idle-timeout 10 "${zone_args[@]}" -o none
  az network vnet subnet update -g "$AZ_RG" --vnet-name "$VM_NAME-vnet" -n default --nat-gateway "$VM_NAME-nat" -o none
fi

echo "▶ public IP (temporary — removed after Tailscale is up)"
exists network public-ip show -g "$AZ_RG" -n "$VM_NAME-pip" || az network public-ip create -g "$AZ_RG" -n "$VM_NAME-pip" \
  --sku Standard --allocation-method Static "${zone_args[@]}" -o none

echo "▶ NIC with accelerated networking"
exists network nic show -g "$AZ_RG" -n "$VM_NAME-nic" || az network nic create -g "$AZ_RG" -n "$VM_NAME-nic" \
  --vnet-name "$VM_NAME-vnet" --subnet default --network-security-group "$VM_NAME-nsg" \
  --public-ip-address "$VM_NAME-pip" --accelerated-networking true -o none

echo "▶ data disk ($DATA_DISK_SKU)"
exists disk show -g "$AZ_RG" -n "$VM_NAME-home" || az disk create -g "$AZ_RG" -n "$VM_NAME-home" \
  --size-gb "$DATA_DISK_GB" --sku "$DATA_DISK_SKU" "${zone_args[@]}" "${disk_perf_args[@]}" -o none

echo "▶ subscription feature UseStandardSecurityType (lets a Gen2 VM opt out of Trusted Launch)"
state="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query properties.state -o tsv 2>/dev/null || true)"
if [[ "$state" != "Registered" ]]; then
  az feature register --namespace Microsoft.Compute --name UseStandardSecurityType -o none
  for _ in $(seq 1 60); do
    state="$(az feature show --namespace Microsoft.Compute --name UseStandardSecurityType --query properties.state -o tsv)"
    [[ "$state" == "Registered" ]] && break
    echo "  … $state"; sleep 15
  done
  [[ "$state" == "Registered" ]] || { echo "❌ feature still $state — re-run in a few minutes" >&2; exit 1; }
  az provider register -n Microsoft.Compute -o none
fi

echo "▶ virtual machine (stock Ubuntu; nixos-anywhere replaces it)"
exists vm show -g "$AZ_RG" -n "$VM_NAME" || az vm create -g "$AZ_RG" -n "$VM_NAME" --size "$VM_SIZE" "${zone_args[@]}" \
  --image "$IMAGE_URN" --nics "$VM_NAME-nic" --security-type Standard \
  --os-disk-size-gb "$OS_DISK_GB" --storage-sku Premium_LRS --os-disk-name "$VM_NAME-os" \
  --admin-username "$ADMIN_USER" --ssh-key-values "$SSH_PUBKEY" -o none

echo "▶ data disk at LUN 1"
if [[ "$(az vm show -g "$AZ_RG" -n "$VM_NAME" --query "storageProfile.dataDisks[?lun==\`1\`].name | [0]" -o tsv)" != "$VM_NAME-home" ]]; then
  az vm disk attach -g "$AZ_RG" --vm-name "$VM_NAME" --name "$VM_NAME-home" --lun 1 -o none
fi

IP="$(az vm show -d -g "$AZ_RG" -n "$VM_NAME" --query publicIps -o tsv)"
echo ""
echo "✅ $VM_NAME is up at $IP (stock Ubuntu). Next: orca-vm install"
