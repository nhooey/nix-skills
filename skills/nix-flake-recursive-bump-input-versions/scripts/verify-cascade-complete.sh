#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
verify-cascade-complete.sh — re-check filtered inputs at upstream HEAD.

Usage:
  verify-cascade-complete.sh [PREDICATE]
  OWNER=<owner> verify-cascade-complete.sh [PREDICATE]   # override

Re-runs the behind-input scan after a bump cascade lands. Exits 0 + "all
green" if every filtered input is at upstream HEAD; exits 1 + one line per
remaining mismatch (or unresolved ref) otherwise.

Requires: gh, jq, nix.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"

mismatches=$("$here/find-behind-inputs.sh" "${1-}")
if [[ -z $mismatches ]]; then
  echo "all green"
  exit 0
fi

echo "still behind (UNRESOLVED rows mean the ref couldn't be checked — see stderr above for details):"
printf '%s\n' "$mismatches"
exit 1
