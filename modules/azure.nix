# Azure guest: what the platform needs from the OS, and nothing about what the machine is for.
#
# nixpkgs' azure-common.nix carries the platform contract — waagent + cloud-init (the agent needs it to
# manage networking), systemd-networkd, the Hyper-V initrd modules, the serial console on ttyS0, root
# login by key only, and the `/dev/disk/by-lun/N` udev symlinks (N ≥ 1) that workspace.nix mounts the
# data disk through. Importing it rather than copying it means a platform change in nixpkgs reaches
# this host with `nix flake update`.
{ modulesPath, lib, pkgs, ... }:
{
  imports = [ "${modulesPath}/virtualisation/azure-common.nix" ];

  # Gen2 VMs boot UEFI; disko lays out the ESP.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # The v5 sizes ship Mellanox accelerated networking; the module loads the mlx drivers and leaves the
  # SR-IOV function unmanaged so networkd binds the synthetic NIC as Azure expects.
  virtualisation.azure.acceleratedNetworking = true;

  # The size's temp disk (SCSI on the v5 sizes) is wiped on deallocate. workspace.nix formats and mounts
  # it at /mnt/resource; the agent is told to leave it alone (on this NixOS it did not act on Format=y
  # anyway — measured on the first boot — and two managers of one ephemeral disk is one too many).
  services.waagent.settings.ResourceDisk = {
    Format = false;
    EnableSwap = false;
  };

  # azure-common forces the hostname from the platform (mkDefault ""); the host sets its own.
  # cloud-init would otherwise also try — keep it to network + the provisioning handshake.
  services.cloud-init.settings.preserve_hostname = true;

  # Port 22 stays open in the guest firewall: the NSG is the real gate (SSH from the operator's IP only
  # during install; nothing once the public IP is gone), and Tailscale SSH does not use it at all.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  services.openssh.settings.PasswordAuthentication = false;
  services.openssh.settings.KbdInteractiveAuthentication = false;

  # Kernel: the default LTS is fine; a newer one buys nothing on Hyper-V and costs rebuild time.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages;
}
