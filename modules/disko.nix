# Disk layout for nixos-anywhere. ONLY the OS disk is declared here — disko formats every disk it
# knows about on install, and the data disk holding /home (checkouts, worktrees, caches,
# Orca's state) must survive a reinstall. modules/workspace.nix mounts that one by LUN and
# formats it once, on first sight, only when it carries no filesystem.
#
# The device is NOT a kernel name. `/dev/sda` was, and it is whichever disk the kernel probed first: on
# oval-builder's install that happened to be the OS disk, on oval-runner's it was the 32 GiB data disk,
# and NixOS was installed onto that while the 64 GiB OS disk kept its stock Ubuntu. The Hyper-V storage
# controllers are probed in no fixed order, so `by-path` names (which carry the SCSI host number) are no
# better. What IS fixed is Azure's layout: the OS disk is LUN 0 on the OS storage controller, VMBus
# f8b3781a-1e82-4818-a1c3-63d806ec15bb; data disks sit on a different controller. `orca-vm install`
# boots the installer, finds exactly that disk, and links it here before disko runs (azure/install-nixos.sh).
# Only the install reads this path: the installed system mounts by partition label.
#
# NVMe sizes (v6) put the OS disk on NVMe; the lookup refuses rather than guess, and would need extending.
{
  disko.devices.disk.os = {
    type = "disk";
    device = "/dev/orca-vm-os-disk";
    content = {
      type = "gpt";
      partitions = {
        esp = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
