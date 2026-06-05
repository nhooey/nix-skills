#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
discover-flake-outputs.sh — list the flake's outputs by class.system.name.

Usage:
  discover-flake-outputs.sh

Wraps `nix flake show --all-systems --no-write-lock-file --json` and emits
one line per existing output. Shape depends on the output class:
  packages.<system>.<name>      (systemed; 3 segments)
  checks.<system>.<name>        (systemed; 3 segments)
  devShells.<system>.<name>     (systemed; 3 segments)
  apps.<system>.<name>          (systemed; 3 segments)
  nixosConfigurations.<name>    (non-systemed; 2 segments)
  homeManagerModules.<name>     (non-systemed; 2 segments)
  templates.<name>              (non-systemed; 2 segments)
  overlays.<name>               (non-systemed; 2 segments)
  ...

Useful for authoring `garnix.yaml`'s `builds.include` patterns. Walks every
leaf under recognised output classes regardless of whether the leaf JSON
carries a `type` field — so module/template/overlay outputs are not silently
dropped.

Nix eval errors surface on stderr (no `2>/dev/null`); the script exits
non-zero if `nix flake show` fails, so an invalid flake is immediately
visible instead of producing an empty output list.

Requires: nix, jq.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

nix flake show --all-systems --no-write-lock-file --json | jq -r '
  to_entries[] as $top
  | if ($top.value | type) != "object" then empty
    elif ($top.key | IN("packages","checks","devShells","apps","legacyPackages")) then
      ($top.value | to_entries[]) as $sys |
      if ($sys.value | type) != "object" then empty
      else ($sys.value | keys[]) as $name |
           "\($top.key).\($sys.key).\($name)" end
    else
      ($top.value | keys[]) as $name |
      "\($top.key).\($name)"
    end
' | sort -u
