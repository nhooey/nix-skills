#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
check-symlinked-parent-path-flakeref.sh — check whether Nix still rejects a
`path:` flakeref whose directory sits under a symlink.

Usage:
  check-symlinked-parent-path-flakeref.sh

Builds a one-attribute flake in a temp dir, reaches it through a symlink
(the way macOS reaches /private/tmp through /tmp), and evaluates it both
through the symlink and through its physical path.

This backs the "Resolve symlinked directories before a `path:` flakeref"
section of SKILL.md. Exit status tells whether that section is current:

  0  still broken: the symlinked path fails with "is a symlink" and the
     physical path works, so the section and its workaround still apply.
  1  fixed: the symlinked path evaluates, so the section is stale.
  2  inconclusive: nix is missing, or the physical path fails too.

Prints one line: `still-broken`, `fixed` or `inconclusive`, then the Nix
version and, when broken, Nix's error line.

Requires: nix with the nix-command and flakes features.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

if ! command -v nix >/dev/null 2>&1; then
  echo "inconclusive: nix not found"
  exit 2
fi

nix_version="$(nix --version)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The physical temp dir itself may sit under a symlink (macOS $TMPDIR is
# under /var), so resolve it first: the only symlink on the test path is
# then the one made here.
work="$(cd "$work" && pwd -P)"
mkdir -p "$work/real/flake"
ln -s "$work/real" "$work/link"
printf '{ outputs = _: { probe = "ok"; }; }\n' >"$work/real/flake/flake.nix"

nix_eval() {
  nix --extra-experimental-features 'nix-command flakes' \
    eval --raw "path:$1#probe" 2>&1
}

if ! physical="$(nix_eval "$work/real/flake")" || [[ $physical != ok ]]; then
  echo "inconclusive: the physical path failed too"
  echo "$nix_version"
  echo "$physical" | tail -n 3
  exit 2
fi

if linked="$(nix_eval "$work/link/flake")" && [[ $linked == ok ]]; then
  echo "fixed"
  echo "$nix_version"
  exit 1
fi

if grep -q 'is a symlink' <<<"$linked"; then
  echo "still-broken"
  echo "$nix_version"
  grep -m 1 'is a symlink' <<<"$linked" | sed 's/^[[:space:]]*//'
  exit 0
fi

echo "inconclusive: the symlinked path failed with a different error"
echo "$nix_version"
echo "$linked" | tail -n 3
exit 2
