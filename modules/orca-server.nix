# `orca serve` as a system service, running as the workspace user.
#
# Why a system service with User= rather than a user service: it starts at boot with no login and no
# linger, `systemctl status orca-serve` and `journalctl -u orca-serve` work from any shell, and it is the
# shape Orca's own headless harness exercises ("the same unprivileged account required by production
# systemd guidance"). Orca's user data — pairing identity, device tokens, terminal history — lives in
# the user's ~/.config/orca on the data disk, so it survives rebuilds and reinstalls alike.
#
# Headless on Linux is a virtual X display or nothing: Electron segfaults without one (Orca's
# ensure-virtual-display: --headless and ozone-headless both crash), and Orca starts its own Xvfb on
# :99 when `Xvfb` is on PATH and DISPLAY is unset. The package puts Xvfb inside the AppImage's FHS
# environment, so the unit sets nothing display-related on purpose. `--no-sandbox` because Chromium's
# SUID sandbox cannot exist inside an unpacked AppImage; Orca's harness passes it by default too.
#
# Pairing: the pairing URL is printed once at start — `orca-pairing` reads it back from the journal.
# Paste it into Orca → Settings → Remote Orca Servers → Add Server. Generating another link replaces
# an unused one; paired clients keep their grant until revoked under Shared Server Access.
{ config, lib, pkgs, ... }:
let
  cfg = config.orcaVm.orca;
  ws = config.orcaVm.workspace;
  orca = pkgs.callPackage ../packages/orca.nix { };
  tailscale = lib.getExe config.services.tailscale.package;

  # The pairing link is printed once, when the runtime starts, and nowhere the CLI can fetch it from
  # (`status --json` carries no pairing fields). This reads it back from the unit's journal for the
  # current boot — the thing to run at a login shell when a new device needs to pair. A link that has
  # already been used is spent; `--fresh` restarts the runtime for a new one (open terminals die).
  orcaPairing = pkgs.writeShellScriptBin "orca-pairing" ''
    set -euo pipefail
    case "''${1:-}" in
      -h|--help)
        echo "usage: orca-pairing [--web] [--fresh]"
        echo "  prints the Orca pairing link of the running server (Orca → Settings → Remote Orca Servers → Add Server)"
        echo "  --web    the web-client URL instead (opens the browser client, pairing embedded)"
        echo "  --fresh  restart orca-serve to mint a new link (a used link is spent; this kills open terminals)"
        exit 0 ;;
      --fresh)
        sudo systemctl restart orca-serve
        for _ in $(seq 1 60); do
          ${pkgs.systemd}/bin/journalctl -u orca-serve -b -o cat --since "-1min" 2>/dev/null | grep -q '^Pairing URL:' && break
          sleep 1
        done ;;
    esac
    log="$(${pkgs.systemd}/bin/journalctl -u orca-serve -b -o cat 2>/dev/null)"
    if [ "''${1:-}" = "--web" ]; then
      printf '%s\n' "$log" | sed -n 's/^Web client URL: //p' | tail -1
    else
      printf '%s\n' "$log" | sed -n 's/^Pairing URL: //p' | tail -1
    fi | grep . || { echo "orca-pairing: no pairing link in this boot's journal — is orca-serve running? (systemctl status orca-serve)" >&2; exit 1; }
  '';
in
{
  options.orcaVm.orca = {
    enable = lib.mkEnableOption "Orca in server mode";
    port = lib.mkOption {
      type = lib.types.port;
      default = 7331;
      description = "Port `orca serve` listens on. Only reachable over the tailnet.";
    };
    pairingAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The address advertised in pairing links. null resolves at start to this node's MagicDNS name,
        falling back to its Tailscale IPv4 — never a public or loopback address.
      '';
    };
    memoryHigh = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "systemd MemoryHigh for the runtime's cgroup (every agent and build); null = unlimited.";
    };
    memoryMax = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "systemd MemoryMax for the runtime's cgroup; null = unlimited.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = orca;
      description = "The wrapped Orca AppImage (packages/orca.nix).";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package # orca-ide (CLI) and orca-ide-app on every PATH
      orcaPairing # `orca-pairing` — the current pairing link, from the journal
      pkgs.xvfb-run # for driving the app by hand under a display, e.g. a one-off `orca-ide-app --no-sandbox serve --json`
    ];

    # Said once per interactive login shell, so the command is discoverable. In the shell's own init
    # rather than users.motd: the motd rides on PAM, and Tailscale SSH spawns the shell itself — no PAM,
    # no motd. A tty guard keeps it out of `ssh host cmd` and scripted logins.
    programs.bash.loginShellInit = ''
      if [ -t 1 ] && [ -z "''${ORCA_SANDBOX:-}" ]; then
        echo "${config.networking.hostName} — Orca runs as a service here: \`orca-pairing\` prints the link to add this server to an Orca client (--web: browser client, --fresh: mint a new one); \`systemctl status orca-serve\`."
      fi
    '';

    # The offscreen browser panes render real pages: Chromium wants a fontconfig and at least one font.
    # The AppImage's FHS environment binds the host's /etc/fonts, so the host's config is what it sees.
    fonts.fontconfig.enable = true;
    fonts.packages = [ pkgs.dejavu_fonts pkgs.liberation_ttf ];

    systemd.services.orca-serve = {
      description = "Orca runtime (server mode)";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "tailscaled.service" "orca-vm-home-dirs.service" ];
      wants = [ "network-online.target" "tailscaled.service" ];
      requires = [ "orca-vm-home-dirs.service" ];
      unitConfig.RequiresMountsFor = ws.home;

      # The runtime's PATH is what it spawns worktrees, hooks, recipes and terminals with: git for its own
      # worktree operations (measured: "spawn git ENOENT" without it), ssh for SSH-mode environments, and
      # the whole system profile so a terminal sees what a login shell would. /run/wrappers for setuid
      # helpers (newuidmap for podman, sudo).
      # System profile FIRST: NixOS wraps some of these (direnv carries DIRENV_CONFIG), and an unwrapped
      # package ahead of it wins the PATH race and loses the wrapper (measured: a terminal with
      # DIRENV_CONFIG empty and every .envrc blocked). The explicit packages are the fallback.
      path = [ "/run/wrappers" "/run/current-system/sw" ]
        ++ [ cfg.package config.services.tailscale.package pkgs.jq pkgs.coreutils pkgs.git pkgs.openssh pkgs.bash pkgs.gh pkgs.nix ];

      environment = {
        HOME = ws.home;
        ORCA_SERVE_PORT = toString cfg.port;
        # Terminals inherit the runtime's environment, not a login shell's: what /etc/profile would set
        # and a worktree needs is set here. direnv's config dir is what makes the whitelist apply.
        DIRENV_CONFIG = "/etc/direnv";
        NIX_CONFIG = "experimental-features = nix-command flakes";
      } // lib.optionalAttrs (cfg.pairingAddress != null) { ORCA_PAIRING_ADDRESS = cfg.pairingAddress; };

      # Resolve the advertised address from the running tailscaled: MagicDNS name (trailing dot
      # stripped), else the v4 address. Until the node is joined there is nothing to advertise, so wait
      # (up to 10 min per attempt; Restart= tries again) rather than advertise 127.0.0.1.
      script = ''
        set -euo pipefail
        addr="''${ORCA_PAIRING_ADDRESS:-}"
        if [ -z "$addr" ]; then
          for _ in $(seq 1 300); do
            addr="$(${tailscale} status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
            [ -n "$addr" ] || addr="$(${tailscale} ip -4 2>/dev/null | head -1 || true)"
            [ -n "$addr" ] && break
            sleep 2
          done
        fi
        [ -n "$addr" ] || { echo "orca-serve: no Tailscale address to advertise; is the node joined?" >&2; exit 1; }
        echo "orca-serve: advertising $addr:$ORCA_SERVE_PORT"
        exec orca-ide-app --no-sandbox serve --port "$ORCA_SERVE_PORT" --pairing-address "$addr"
      '';

      serviceConfig = {
        User = ws.name;
        Group = "users";
        WorkingDirectory = ws.home;
        Restart = "on-failure";
        RestartSec = "5s";
        # Agents and builds are children of this runtime, so this cgroup is where the machine's memory
        # goes. The ceiling keeps sshd, tailscaled and the nix daemon alive when many builds land at
        # once: the kernel reclaims above MemoryHigh and OOM-kills INSIDE the cgroup above MemoryMax —
        # and OOMPolicy=continue is what makes that kill one build rather than the runtime and every agent
        # with it (systemd's default, `stop`, takes the whole service down on the first OOM in it).
        # Per-workspace ceilings are the sandboxes' job; this is the box's last line.
        OOMPolicy = "continue";
        TasksMax = 65536;
        NoNewPrivileges = false;
        LimitNOFILE = 1048576;
        TimeoutStopSec = "30s";
        KillMode = "mixed";
      } // lib.optionalAttrs (cfg.memoryHigh != null) { MemoryHigh = cfg.memoryHigh; }
        // lib.optionalAttrs (cfg.memoryMax != null) { MemoryMax = cfg.memoryMax; };
    };
  };
}
