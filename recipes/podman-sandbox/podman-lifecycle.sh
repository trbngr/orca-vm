#!/usr/bin/env bash
# Orca environment recipe — SUSPEND / RESUME / DESTROY for the podman sandbox (see podman-create.sh).
# Orca passes its lifecycle payload on stdin; the container is `recipeResult.userData.resourceId`.
#
#   suspend   podman stop   — the overlay, home and worktree stay; nothing runs
#   resume    podman start  — and re-emit the connection JSON (the published port is fixed at create)
#   destroy   podman rm -f, the sandbox home, and `git worktree prune` in the primary checkout
set -euo pipefail
log() { printf 'podman-%s: %s\n' "$verb" "$*" >&2; }

verb="${1:?suspend|resume|destroy}"
if [ "${2:-}" != "--local" ] && [ "${ORCA_SANDBOX_HOP:-1}" != "0" ]; then
  # Same hop as podman-create.sh (see there): a clean host session, stdin (the payload) forwarded.
  key="$HOME/.ssh/orca-sandbox"
  exec ssh -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$key" \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$HOME/.local/state/orca-sandbox/known_hosts" \
    "$(id -un)@127.0.0.1" "cd $(printf '%q' "$PWD") && $(printf '%q' "$(realpath "$0")") $(printf '%q' "$verb") --local"
fi
payload="$(cat)"
name="$(printf '%s' "$payload" | jq -r '.recipeResult.userData.resourceId // empty')"
[ -n "$name" ] || { log "no resourceId in the lifecycle payload"; exit 1; }
home="$HOME"; user="$(id -un)"
state="$home/.local/state/orca-sandbox"

case "$verb" in
  suspend)
    podman stop -t 15 "$name" >/dev/null && log "stopped $name" ;;
  resume)
    podman start "$name" >/dev/null
    port="$(printf '%s' "$payload" | jq -r '.recipeResult.userData.port // empty')"
    [ -n "$port" ] || port="$(podman port "$name" 22 | sed -n 's/.*:\([0-9]*\)$/\1/p' | head -1)"
    for _ in $(seq 1 40); do
      ssh -q -o BatchMode=yes -o ConnectTimeout=2 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -i "$home/.ssh/orca-sandbox" -o IdentitiesOnly=yes -p "$port" "$user@127.0.0.1" true 2>/dev/null && break
      sleep 0.5
    done
    root="$(printf '%s' "$payload" | jq -r '.recipeResult.connection.projectRoot // empty')"
    log "resumed $name on 127.0.0.1:$port"
    jq -cn --arg root "$root" --arg name "$name" --argjson port "$port" --arg user "$user" --arg key "$home/.ssh/orca-sandbox" \
      '{schemaVersion:1,connection:{type:"ssh",projectRoot:$root,target:{label:$name,host:"127.0.0.1",port:$port,username:$user,identityFile:$key,identitiesOnly:true}},userData:{provider:"podman",resourceId:$name,port:$port}}' ;;
  destroy)
    podman rm -f -t 10 "$name" >/dev/null 2>&1 || true
    # Inside the user namespace: files the container's root created (sshd's keys, the bind-mount
    # targets) belong to a sub-uid on the host, and only there can this user delete them.
    podman unshare rm -rf "$state/$name"
    root="$(printf '%s' "$payload" | jq -r '.recipeResult.connection.projectRoot // empty')"
    [ -d "$root/.git" ] && git -C "$root" worktree prune || true
    log "destroyed $name" ;;
  *) log "unknown verb"; exit 2 ;;
esac
