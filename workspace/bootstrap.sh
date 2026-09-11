#!/usr/bin/env bash
# First-run setup of the workspace on the box. Safe to re-run.
#
#   ~/<dir>/bootstrap.sh
#
#   1. gh login (interactive, once) and the git credential helper
#   2. clone the repos in repos.conf (init.sh) and `direnv allow` them
#   3. what to do next: log the agent in, pair Orca
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Workspace bootstrap — $ROOT"
echo "═══════════════════════════════════════════"

if ! gh auth status >/dev/null 2>&1; then
  echo "🔑 GitHub: no login yet. Opening the device flow — finish it in a browser on any machine."
  gh auth login --hostname github.com --git-protocol https --web
fi
gh auth setup-git

echo ""
echo "📂 Repositories"
"$ROOT/init.sh"

command -v direnv >/dev/null && direnv allow "$ROOT"

echo ""
echo "═══════════════════════════════════════════"
echo "  ✅ Bootstrap complete"
echo "═══════════════════════════════════════════"
echo ""
echo "Next:"
echo "  1. Log the coding agent in once (state lands on the data disk). Its OAuth URL is long and a"
echo "     terminal wraps it — run it in a wide tmux pane and copy the URL from there:"
echo "       tmux new -s login -x 500 'claude auth login'"
echo "  2. Pair Orca from your laptop (Orca → Settings → Remote Orca Servers → Add Server):"
echo "       orca-pairing"
