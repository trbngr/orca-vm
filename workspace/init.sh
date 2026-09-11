#!/usr/bin/env bash
# Clone every repository in repos.conf into repos/. Idempotent: a repo already present is left alone.
#
#   ./init.sh            clone what is missing, `direnv allow` each repo that has a .envrc
#   ./init.sh --pull     also fast-forward the ones already present (main only, clean trees only)
#
# Authentication is `gh` — `gh auth login` once (device flow works headless), and clones go over
# HTTPS with gh's credential helper, so no deploy keys or tokens live on the box.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_DIR="$ROOT/repos"
REPOS_CONF="$ROOT/repos.conf"
PULL=false
[[ "${1:-}" == "--pull" ]] && PULL=true

command -v gh >/dev/null || { echo "❌ gh is not on PATH" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "❌ gh is not logged in — run: gh auth login (choose HTTPS, device flow)" >&2; exit 1; }
gh auth setup-git >/dev/null 2>&1 || true   # git's credential helper → gh; idempotent

mapfile -t REPOS < <(grep -v '^\s*#' "$REPOS_CONF" | grep -v '^\s*$')
mkdir -p "$REPOS_DIR"

for spec in "${REPOS[@]}"; do
  name="${spec##*/}"
  target="$REPOS_DIR/$name"
  if [[ -d "$target/.git" ]]; then
    if $PULL && [[ -z "$(git -C "$target" status --porcelain)" ]] && [[ "$(git -C "$target" branch --show-current)" == "main" ]]; then
      echo "  ↻ $name (pulling main)"; git -C "$target" pull --ff-only --quiet
    else
      echo "  ✓ $name (already cloned)"
    fi
  else
    echo "  ⬇ Cloning $spec..."
    gh repo clone "$spec" "$target" -- --quiet
  fi
  if [[ -f "$target/.envrc" ]] && command -v direnv >/dev/null; then
    direnv allow "$target" 2>/dev/null || true
  fi
done

echo ""
echo "✅ Repositories present in $REPOS_DIR"
