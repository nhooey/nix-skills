#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
garnix-install-url.sh — prefilled Garnix GitHub App install URL.

Usage:
  garnix-install-url.sh REPO

REPO: owner/repo

Emits one URL that prefills the install/configure screen for the given
repo. Works to add the repo to an existing installation as well as for
fresh installs.

Exits non-zero with a clear error if `gh api` fails (auth, repo not found,
network) — does not emit a malformed URL.

Requires: gh.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

repo="${1:?usage: garnix-install-url.sh REPO}"

if ! tsv=$(gh api "repos/$repo" --jq '[.owner.id, .id] | @tsv' 2>&1); then
  echo "garnix-install-url.sh: gh api failed for repos/$repo: $tsv" >&2
  exit 1
fi

IFS=$'\t' read -r owner_id repo_id <<<"$tsv"

if [[ -z ${owner_id:-} || -z ${repo_id:-} ]]; then
  echo "garnix-install-url.sh: gh returned empty owner or repo id for $repo (response: $tsv)" >&2
  exit 1
fi

printf 'https://github.com/apps/garnix-ci/installations/new/permissions?target_id=%s&repository_ids[]=%s\n' \
  "$owner_id" "$repo_id"
