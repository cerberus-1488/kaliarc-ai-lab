#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[+] Running core KaliArc AI Lab installer"
"$REPO_DIR/install.sh" "$@"

echo
echo "[+] Applying GitHub-repo extras: agents, scoped tool wrappers, AI Lab menu"
"$REPO_DIR/scripts/post-install-extras.sh" "$@"

echo
echo "[+] Complete. Try:"
echo "    ~/kaliarc-ai-lab/bin/agent-menu.sh"
echo "    ~/kaliarc-ai-lab/bin/tool-menu.sh"
echo "    ~/kaliarc-ai-lab/bin/status.sh"
