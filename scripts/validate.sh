#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[+] bash -n checks"
bash -n "$ROOT/setup.sh"
bash -n "$ROOT/install.sh"
bash -n "$ROOT/scripts/post-install-extras.sh"

if command -v shellcheck >/dev/null 2>&1; then
  echo "[+] shellcheck"
  shellcheck "$ROOT/setup.sh" "$ROOT/install.sh" "$ROOT/scripts/post-install-extras.sh"
else
  echo "[!] shellcheck not installed; skipping"
fi
