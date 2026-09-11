# The root filesystem of a workspace sandbox — a store path, not an image.
#
# One rootless podman container per Orca workspace runs FROM this directory (`podman run --rootfs
# <copy of this> …`), and everything it points at lives in the host's /nix/store, which is
# bind-mounted in read-only. So there is no image to build, load or version — the rootfs is rebuilt
# with the flake like any other output, the host installs it at /etc/orca-sandbox/rootfs, and a
# container started after a rebuild gets the new one. Inside, `nix develop` talks to the host's nix
# daemon over its socket, so a repo's flake resolves from the host store instantly and builds land
# there for every other sandbox too.
#
# What is in here is only what a shell over SSH needs before a repo's own flake takes over: sshd,
# bash, the host tools every .envrc and script reaches for, direnv with the workspace whitelisted,
# git with the identity and the gh credential helper, and the agent CLIs from host.nix. No language
# toolchains — the repo's flake provides them, exactly as on the host.
#
# Nothing secret: host keys and the authorized key are mounted or injected at run time by
# recipes/podman-sandbox/podman-create.sh through /entrypoint, which runs as the container's root,
# prepares /etc/ssh and the user's ~/.ssh, then execs sshd.
{ lib, pkgs, user ? "me", uid ? 1000, gid ? 100, fullName ? "Your Name", email ? "you@example.com"
, workspaceDir ? "workspace", macHomeSymlink ? false, extraPackages ? [ ] }:
let
  resolve = name: lib.attrByPath (lib.splitString "." name)
    (throw "orca-vm: no package `${name}` in nixpkgs (host.nix `packages`)") pkgs;
  profile = pkgs.buildEnv {
    name = "orca-sandbox-profile";
    paths = (with pkgs; [
      bashInteractive coreutils findutils gnugrep gnused gawk diffutils which file less procps util-linux
      gzip gnutar xz unzip curl wget cacert openssh git gh jq ripgrep python3 nodejs_22 tmux direnv nix
      nettools
    ]) ++ map resolve extraPackages;
  };
  home = "/home/${user}";

  # A plain string, not writeText: the rootfs is evaluated on a Mac for a Linux host, and reading a
  # derivation's output at eval time would need to build it there.
  sshdConfig = ''
    Port 22
    ListenAddress 0.0.0.0
    HostKey /etc/ssh/ssh_host_ed25519_key
    PidFile /run/sshd.pid
    PermitRootLogin no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes
    AuthorizedKeysFile ${home}/.ssh/authorized_keys
    # Tokens for the session (GH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN, …) are written to ~/.ssh/environment
    # by /entrypoint from the container's environment; this is what applies them to every session,
    # interactive or `ssh host cmd` alike — sshd does not pass its own environment on.
    PermitUserEnvironment yes
    SetEnv PATH=${profile}/bin:${home}/.local/bin DIRENV_CONFIG=/etc/direnv
    AcceptEnv LANG LC_* TERM COLORTERM
    UsePAM no
    UseDNS no
    X11Forwarding no
    AllowTcpForwarding yes
    ClientAliveInterval 60
    Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
  '';

  entrypoint = pkgs.writeShellScript "orca-sandbox-entrypoint" ''
    set -euo pipefail
    export PATH=${profile}/bin
    # The rootfs is a per-sandbox copy made by the host user, so everything in it is uid 1000 here.
    # sshd insists that its privilege-separation directory, its config directory and its host keys
    # are root's and not writable by anyone else — this process is the container's root, so make them so.
    install -d -m 0755 /etc/ssh /run /var/empty
    chown 0:0 /var/empty /etc/ssh /run
    chmod 0755 /var/empty /etc/ssh /run
    # Host keys: mounted read-only at /hostkeys, owned by the host user; copy and own them here.
    for k in /hostkeys/ssh_host_*_key; do
      [ -f "$k" ] || continue
      install -m 0600 -o 0 -g 0 "$k" "/etc/ssh/$(basename "$k")"
      [ -f "$k.pub" ] && install -m 0644 -o 0 -g 0 "$k.pub" "/etc/ssh/$(basename "$k").pub" || true
    done
    [ -f /etc/ssh/ssh_host_ed25519_key ] || { echo "entrypoint: no host key at /hostkeys" >&2; exit 1; }
    # The user's ~/.ssh: the key Orca dials with, and the session environment carrying the tokens.
    install -d -m 0700 -o ${toString uid} -g ${toString gid} ${home}/.ssh
    [ -n "''${ORCA_SSH_PUBLIC_KEY:-}" ] || { echo "entrypoint: ORCA_SSH_PUBLIC_KEY is not set" >&2; exit 1; }
    printf '%s\n' "$ORCA_SSH_PUBLIC_KEY" > ${home}/.ssh/authorized_keys
    : > ${home}/.ssh/environment
    for v in GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY ORCA_SANDBOX_NAME; do
      eval "val=\''${$v:-}"
      [ -n "$val" ] && printf '%s=%s\n' "$v" "$val" >> ${home}/.ssh/environment
    done
    chown ${toString uid}:${toString gid} ${home}/.ssh/authorized_keys ${home}/.ssh/environment
    chmod 0600 ${home}/.ssh/authorized_keys ${home}/.ssh/environment
    install -d -m 0755 -o ${toString uid} -g ${toString gid} ${home}/.local ${home}/.local/bin ${home}/orca
    exec ${pkgs.openssh}/bin/sshd -D -e -f /etc/ssh/sshd_config
  '';

  exports = ''
    export PATH=${profile}/bin:${home}/.local/bin
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export NIX_REMOTE=daemon
    export NIX_CONFIG="experimental-features = nix-command flakes"
    export ORCA_SANDBOX=1
    export DIRENV_CONFIG=/etc/direnv
  '';

  etcFiles = {
    "passwd" = ''
      root:x:0:0:root:/root:${profile}/bin/bash
      sshd:x:74:74:SSH privilege separation:/var/empty:/bin/false
      ${user}:x:${toString uid}:${toString gid}:${fullName}:${home}:${profile}/bin/bash
      nobody:x:65534:65534:nobody:/:/bin/false
    '';
    "group" = ''
      root:x:0:
      users:x:${toString gid}:
      sshd:x:74:
      nogroup:x:65534:
    '';
    "nsswitch.conf" = "passwd: files\ngroup: files\nhosts: files dns\n";
    "profile" = ''
      ${exports}
      [ -f /etc/bashrc ] && . /etc/bashrc
    '';
    "bashrc" = ''
      # Every bash reads this (BASH_ENV points here for non-interactive ones too): direnv's hook is what
      # makes a worktree's flake load the moment a shell lands in it, interactive or not.
      ${exports}
      case $- in *i*) eval "$(direnv hook bash)";; esac
    '';
    "direnv/direnv.toml" = ''
      [whitelist]
      prefix = ["${home}/${workspaceDir}", "${home}/orca"]
    '';
    "direnv/lib/nix-direnv.sh" = "source ${pkgs.nix-direnv}/share/nix-direnv/direnvrc\n";
    "gitconfig" = ''
      [user]
        name = ${fullName}
        email = ${email}
      [init]
        defaultBranch = main
      [commit]
        gpgsign = false
      [pull]
        rebase = false
      [safe]
        directory = *
      [credential "https://github.com"]
        helper =
        helper = !gh auth git-credential
    '';
    "ssh/sshd_config" = sshdConfig;
    "nix/nix.conf" = "experimental-features = nix-command flakes\ntrusted-users = root ${user}\n";
    "hostname" = "orca-sandbox\n";
    "os-release" = "NAME=\"Orca sandbox\"\nID=orca-sandbox\nPRETTY_NAME=\"Orca sandbox (NixOS store)\"\n";
  };
in
pkgs.runCommand "orca-sandbox-rootfs" { passthru = { inherit profile entrypoint; }; } ''
  mkdir -p $out/{bin,usr/bin,etc,dev,proc,sys,run,tmp,var/empty,root,nix,hostkeys}
  mkdir -p $out${home}
  chmod 1777 $out/tmp
  ln -s ${profile}/bin/bash $out/bin/sh
  ln -s ${profile}/bin/bash $out/bin/bash
  ln -s ${profile}/bin/env  $out/usr/bin/env
  ln -s ${profile}/bin/false $out/bin/false
  ${lib.optionalString macHomeSymlink ''
    mkdir -p $out/Users
    ln -s ${home} $out/Users/${user}
  ''}
  ln -s ${entrypoint} $out/entrypoint
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: text: ''
    mkdir -p "$out/etc/$(dirname ${name})"
    cat > "$out/etc/${name}" <<'EOF'
${text}EOF
  '') etcFiles)}
  ln -s ${pkgs.cacert}/etc/ssl $out/etc/ssl
  # BASH_ENV for non-interactive shells that Orca and `ssh host cmd` spawn: the same exports as a login.
  echo 'BASH_ENV=/etc/bashrc' >> $out/etc/environment
''
