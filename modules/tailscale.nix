# The only network anyone reaches this machine on. No public IP after install, no NSG inbound rules,
# Tailscale SSH for the shell, Orca paired over the tailnet address.
#
# Joining: put a pre-auth key at /var/lib/tailscale/authkey (azure/install-nixos.sh does this from
# $TS_AUTHKEY via nixos-anywhere --extra-files) and the node joins on first boot with SSH enabled.
# Without the file, `tailscaled-autoconnect` fails harmlessly and the operator runs
# `sudo tailscale up --ssh` once over the public-IP SSH window instead. Either way, one time.
{ config, lib, pkgs, ... }:
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    openFirewall = true; # UDP 41641 — direct WireGuard paths instead of DERP relays where the NSG allows
    # Not `authKeyFile`: the module's autoconnect unit blocks for its whole timeout when the file is
    # absent (measured: 90 s of "activating", then failed) and everything ordered after it waits.
  };

  # Everything on the tailnet is trusted by the guest firewall; the tailnet's ACLs are the policy.
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Unattended join, only when a key was staged; consumed and deleted in the same breath so it never
  # outlives its one use. Without the file the unit is skipped (Condition), not failed.
  systemd.services.tailscale-join = {
    description = "Join the tailnet with the staged pre-auth key (skipped when there is none)";
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "tailscaled.service" "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "/var/lib/tailscale/authkey";
    serviceConfig.Type = "oneshot";
    path = [ config.services.tailscale.package ];
    script = ''
      set -euo pipefail
      for _ in $(seq 1 30); do tailscale status >/dev/null 2>&1 && break; sleep 1; done
      tailscale up --ssh --hostname=${config.networking.hostName} --auth-key "file:/var/lib/tailscale/authkey"
      rm -f /var/lib/tailscale/authkey
    '';
  };
}
