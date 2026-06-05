#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
find-behind-inputs.sh — list flake inputs whose locked rev is behind upstream
                        HEAD on the pinned ref.

Usage:
  find-behind-inputs.sh [PREDICATE]
  OWNER=<owner> find-behind-inputs.sh [PREDICATE]    # override per-input owner

Reads the working-dir flake.lock via list-filtered-inputs.sh, then for each
(key, owner, repo, rev, ref) row compares the locked rev to the head of <ref>
on <owner>/<repo> via `gh api`. Uses the input's own `.locked.owner` by
default; if $OWNER is set in env, it overrides every input's owner (legacy
behaviour, useful only when the predicate selects forks under one account).

Emits TSV to stdout: <key>\t<owner>\t<repo>\t<rev>\t<head>\t<ref>
  • For behind inputs, <head> is the upstream rev.
  • For inputs whose ref couldn't be resolved (deleted branch, 404, auth dead,
    etc.), <head> is the literal string `UNRESOLVED` — the caller should
    treat these as "not green" and surface them.

Requires: gh, jq, nix.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"

"$here/list-filtered-inputs.sh" "${1-}" | while IFS=$'\t' read -r key owner repo rev ref; do
  effective_owner="${OWNER:-$owner}"
  if ! head=$(gh api "repos/$effective_owner/$repo/commits/$ref" --jq .sha 2>&1); then
    echo "find-behind-inputs.sh: could not resolve $effective_owner/$repo@$ref: $head" >&2
    printf '%s\t%s\t%s\t%s\tUNRESOLVED\t%s\n' "$key" "$effective_owner" "$repo" "$rev" "$ref"
    continue
  fi
  if [[ $head != "$rev" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "$effective_owner" "$repo" "$rev" "$head" "$ref"
  fi
done
