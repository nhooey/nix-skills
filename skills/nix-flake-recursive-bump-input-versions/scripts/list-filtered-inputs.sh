#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
list-filtered-inputs.sh — filter the working-dir flake's locked inputs by a
                          jq predicate.

Usage:
  list-filtered-inputs.sh [PREDICATE]

PREDICATE: a jq expression evaluated against each lock node's .value, so it
           can reference .locked.owner, .original.ref, etc. Defaults to:
             .locked.owner == "<gh-authenticated-user>"
           (derived at runtime via `gh api user --jq .login`.)

Emits TSV to stdout: <key>\t<owner>\t<repo>\t<rev>\t<ref>
  key:   lock node key
  owner: .value.locked.owner
  repo:  .value.locked.repo
  rev:   .value.locked.rev (40-char SHA)
  ref:   .value.original.ref // "HEAD"

Requires: nix, jq; gh (only when no predicate is passed).
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

predicate="${1-}"
if [[ -z $predicate ]]; then
  if ! command -v gh >/dev/null; then
    echo "list-filtered-inputs.sh: needs gh on PATH to derive default predicate; pass one explicitly or install gh" >&2
    exit 1
  fi
  login=$(gh api user --jq .login)
  predicate=".locked.owner == \"$login\""
fi

nix flake metadata --json | jq -r "
  .locks.nodes | to_entries[] |
  select(.value.locked != null) |
  select(.value | ($predicate)) |
  [.key, .value.locked.owner, .value.locked.repo, .value.locked.rev,
   (.value.original.ref // \"HEAD\")] | @tsv
"
