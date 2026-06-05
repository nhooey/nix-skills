#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
inventory-flakes.sh — list `flake.nix` files in the current repo.

Usage:
  inventory-flakes.sh

Emits TSV: <path>\t<tracked|untracked>
Exits 0 if any flake.nix files are found; exit 1 otherwise.

Requires: git.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

found=0

while IFS= read -r f; do
  [[ -z $f ]] && continue
  printf '%s\ttracked\n' "$f"
  found=1
done < <(git ls-files '*flake.nix' '**/flake.nix' 2>/dev/null || true)

while IFS= read -r f; do
  [[ -z $f ]] && continue
  printf '%s\tuntracked\n' "$f"
  found=1
done < <(git ls-files -o --exclude-standard '*flake.nix' '**/flake.nix' 2>/dev/null || true)

[[ $found -eq 1 ]]
