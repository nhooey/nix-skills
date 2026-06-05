#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
classify-direct-vs-transitive.sh — walk `inputs` edges to find each node's
                                   parents in the lock graph.

Usage:
  classify-direct-vs-transitive.sh [PREDICATE]

PREDICATE: a jq expression evaluated against each lock node's .value. Defaults
           to `true` (every locked input — the `.locked != null` guard is
           always applied separately).

Emits to stdout: `<key>: <parent1>, <parent2>, ...`
  • Direct inputs (those listed under root.inputs) show `root` as a parent.
  • Empty parent list means the node is unreferenced (dead in the graph).

Handles both kinds of input edges in flake.lock:
  • Direct string node-id    — e.g.  "nixpkgs": "nixpkgs"
  • `follows`-style array    — e.g.  "nixpkgs": ["root", "nixpkgs"]
                               In the array form the *last* element is
                               the resolved target node-id; the leading
                               elements are the path from root.

Requires: nix, jq.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

predicate="${1:-true}"

nix flake metadata --json | jq -r "
  . as \$root |
  def edge_target(e):
    if (e | type) == \"string\" then e
    elif (e | type) == \"array\" then (e | last)
    else null end;
  def parents(target):
    \$root.locks.nodes | to_entries[] |
    select((.value.inputs // {}) | to_entries[]? | (.value | edge_target(.)) == target) |
    .key;
  \$root.locks.nodes | to_entries[] |
  select(.value.locked != null) |
  select(.value | ($predicate)) |
  .key as \$k | \"\\(\$k): \" + ([parents(\$k)] | join(\", \"))
"
