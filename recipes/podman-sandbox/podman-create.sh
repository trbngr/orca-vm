#!/usr/bin/env bash
# Orca environment recipe — CREATE. One rootless podman container for one Orca workspace, on the
# orca-vm host. Runs where the Orca runtime runs (the server), as the workspace user, from the repo
# root. Prints ONE JSON object to stdout: an SSH connection Orca dials to import the repo and add the
# worktree inside the sandbox. Everything else goes to stderr.
#
# The sandbox (see orca-vm/modules/sandbox.nix for the design):
#   rootfs        a per-sandbox COPY of $ORCA_SANDBOX_ROOTFS (a nix store path of symlinks into the store —
#                 the copy is a few KB). A copy, not an :O overlay: store paths are mode 0555 all the way
#                 down and the overlay inherits that, so podman cannot even create /etc/mtab in it (measured)
#   /nix          the host store + daemon socket, read-only: `nix develop` resolves from the host store
#   <repo root>   this primary checkout, read-write, at the same absolute path
#   overlays      ORCA_SANDBOX_OVERLAYS (sandbox.conf): host dirs as overlays — warm, writes stay inside
#   home          ~/.local/state/orca-sandbox/<name>/home — the worktree lands under ~/orca there
#   limits        ORCA_SANDBOX_CPUS (4) / ORCA_SANDBOX_MEMORY (12g) / pids 8192
#   sshd          published on 127.0.0.1:<random>; Orca dials with ~/.ssh/orca-sandbox
#   tokens        GH_TOKEN from `gh auth token`; CLAUDE_CODE_OAUTH_TOKEN from
#                 ~/.config/orca-sandbox/claude-token when present (`claude setup-token` once, host-side)
set -euo pipefail

log() { printf 'podman-create: %s\n' "$*" >&2; }

# Per-repository settings next to this script; the environment wins over the file.
conf="$(dirname "$(realpath "$0")")/sandbox.conf"
if [ -f "$conf" ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue ;; esac
    v="${v%\"}"; v="${v#\"}"
    [ -n "$(eval "printf '%s' \"\${$k:-}\"")" ] || export "$k=$v"
  done < "$conf"
fi

# ── Run on the host, not inside Orca's sandbox ────────────────────────────────────────────────────
# The Orca runtime is an AppImage inside a bubblewrap FHS environment: a curated /etc, its own mount
# namespace, no setuid helpers — rootless podman cannot start there, and /etc/orca-sandbox is not even
# visible (measured: "no sandbox rootfs" from Orca, fine by hand). So the recipe hops over loopback SSH
# into a clean session of the same user and runs itself there with --local. The key is the one Orca
# dials sandboxes with; its public half is added to ~/.ssh/authorized_keys once. Set ORCA_SANDBOX_HOP=0
# to skip the hop (a shell that is already on the host).
if [ "${1:-}" != "--local" ] && [ "${ORCA_SANDBOX_HOP:-1}" != "0" ]; then
  key="$HOME/.ssh/orca-sandbox"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -C "orca->sandbox" -f "$key"
  grep -qxF "$(cat "$key.pub")" "$HOME/.ssh/authorized_keys" 2>/dev/null || { cat "$key.pub" >> "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"; }
  mkdir -p "$HOME/.local/state/orca-sandbox"
  exec ssh -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.local/state/orca-sandbox/known_hosts" \
    "$(id -un)@127.0.0.1" \
    "cd $(printf '%q' "$PWD") && env $(for v in ORCA_RECIPE_ID ORCA_VM_INSTANCE_ID ORCA_REPO_URL ORCA_REPO_REF ORCA_REPO_REF_HEAD ORCA_REPO_BRANCH ORCA_SANDBOX_CPUS ORCA_SANDBOX_MEMORY ORCA_SANDBOX_ROOTFS ORCA_SANDBOX_OVERLAYS; do eval "val=\${$v:-}"; [ -n "$val" ] && printf '%s=%q ' "$v" "$val"; done) $(printf '%q' "$(realpath "$0")") --local $(printf '%q ' "${@:1}")"
fi

rootfs="${ORCA_SANDBOX_ROOTFS:-/etc/orca-sandbox/rootfs}"
[ -d "$rootfs" ] || { log "no sandbox rootfs at $rootfs (is this the orca-vm host, with sandbox.enable = true?)"; exit 1; }
command -v podman >/dev/null || { log "podman is not on PATH"; exit 1; }

repo_root="$(git rev-parse --path-format=absolute --show-toplevel)"
user="$(id -un)"; uid="$(id -u)"; gid="$(id -g)"
home="$HOME"
state="$home/.local/state/orca-sandbox"
mkdir -p "$state"

# Identity Orca dials with, and the sandboxes' shared SSH host key — generated once on this host,
# never in the store. One host key for every sandbox keeps known_hosts for 127.0.0.1 stable as the
# published port rotates (Orca's own advice for local Docker recipes).
[ -f "$home/.ssh/orca-sandbox" ] || ssh-keygen -q -t ed25519 -N "" -C "orca->sandbox" -f "$home/.ssh/orca-sandbox"
mkdir -p "$state/hostkeys"
[ -f "$state/hostkeys/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$state/hostkeys/ssh_host_ed25519_key"

recipe_id="${ORCA_RECIPE_ID:-podman-sandbox}"
instance_id="${ORCA_VM_INSTANCE_ID:-$(date +%s)}"
name="orca-$(printf '%s-%s' "$recipe_id" "$instance_id" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-60)"
sandbox_home="$state/$name/home"
sandbox_rootfs="$state/$name/rootfs"
mkdir -p "$sandbox_home"
[ -e "$sandbox_rootfs" ] && podman unshare rm -rf "$sandbox_rootfs"   # a previous life's files belong to a sub-uid
cp -a "$rootfs/." "$sandbox_rootfs"
chmod -R u+w "$sandbox_rootfs"
chmod 1777 "$sandbox_rootfs/tmp"

# Overlay mounts: each host directory is created if missing and mounted at the same path with `:O`.
overlay_args=()
IFS=: read -ra overlays <<< "${ORCA_SANDBOX_OVERLAYS:-}"
for o in "${overlays[@]}"; do
  [ -n "$o" ] || continue
  o="${o/#\~/$home}"
  mkdir -p "$o"
  overlay_args+=(-v "$o:$o:O")
done

gh_token="${GH_TOKEN:-${GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}}"
claude_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
[ -n "$claude_token" ] || [ ! -f "$home/.config/orca-sandbox/claude-token" ] || claude_token="$(cat "$home/.config/orca-sandbox/claude-token")"
[ -n "$claude_token" ] || log "no Claude token (~/.config/orca-sandbox/claude-token) — the agent in this sandbox will need to log in"

cleanup_on_error() { [ "$?" -ne 0 ] && { log "failed — removing $name"; podman rm -f "$name" >/dev/null 2>&1 || true; podman unshare rm -rf "$state/$name" 2>/dev/null || true; }; }
trap cleanup_on_error EXIT

log "starting $name from a copy of $rootfs"
podman run -d --name "$name" \
  --userns=keep-id --user 0:0 \
  --cpus "${ORCA_SANDBOX_CPUS:-4}" --memory "${ORCA_SANDBOX_MEMORY:-12g}" --pids-limit 8192 \
  --hostname "$name" \
  -p 127.0.0.1::22 \
  -v /nix:/nix:ro \
  -v "$sandbox_home:$home" \
  -v "$repo_root:$repo_root" \
  "${overlay_args[@]}" \
  -v "$state/hostkeys:/hostkeys:ro" \
  -e "ORCA_SSH_PUBLIC_KEY=$(cat "$home/.ssh/orca-sandbox.pub")" \
  -e "GH_TOKEN=$gh_token" \
  -e "CLAUDE_CODE_OAUTH_TOKEN=$claude_token" \
  -e "ORCA_SANDBOX_NAME=$name" \
  --label orca-vm.sandbox=1 --label "orca-vm.repo=$repo_root" \
  --rootfs "$sandbox_rootfs" /entrypoint >/dev/null

port=""
for _ in $(seq 1 40); do
  port="$(podman port "$name" 22 2>/dev/null | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1)"
  [ -n "$port" ] && ssh -q -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i "$home/.ssh/orca-sandbox" -o IdentitiesOnly=yes -p "$port" "$user@127.0.0.1" true 2>/dev/null && break
  if ! podman container exists "$name" || [ "$(podman inspect -f '{{.State.Running}}' "$name")" != "true" ]; then
    podman logs "$name" >&2 || true; log "container exited during startup"; exit 1
  fi
  sleep 0.5
done
[ -n "$port" ] || { podman logs "$name" >&2 || true; log "sshd never answered"; exit 1; }
log "$name ready on 127.0.0.1:$port"

trap - EXIT
jq -cn --arg root "$repo_root" --arg name "$name" --arg host 127.0.0.1 --argjson port "$port" \
   --arg user "$user" --arg key "$home/.ssh/orca-sandbox" \
  '{schemaVersion:1,
    connection:{type:"ssh",projectRoot:$root,
      target:{label:$name,host:$host,port:$port,username:$user,identityFile:$key,identitiesOnly:true}},
    userData:{provider:"podman",resourceId:$name,port:$port}}'
