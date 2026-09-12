# Disk layout for nixos-anywhere. ONLY the OS disk is declared here — disko formats every disk it
# knows about on install, and the data disk holding /home (checkouts, worktrees, caches,
# Orca's state) must survive a reinstall. modules/workspace.nix mounts that one by LUN and
# formats it once, on first sight, only when it carries no filesystem.
#
# /dev/sda is the Azure OS disk on the SCSI controller for every Gen2 v5 size, ARM included. Verify
# with `lsblk` on the stock VM before the install if the size changes (v6 sizes move the OS disk to NVMe).
{
  disko.devices.disk.os = {
    type = "disk";
    device = "/dev/sda";
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
