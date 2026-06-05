#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
check-garnix-installed.sh — quick yes/no probe for Garnix at a SHA.

Usage:
  check-garnix-installed.sh REPO [SHA]

REPO: owner/repo
SHA:  commit to probe (default: HEAD)

Exit codes:
  0 + "installed"                  — a `garnix-ci` check-suite exists on the commit.
  1 + "not-installed-or-not-scoped" — no `garnix-ci` suite (and the webhook may
                                     simply not have fired yet — wait ~30s and retry).
  2 + "gh-error: <message>"        — the `gh api` call itself failed (auth, network,
                                     rate-limit, 404 on the commit). Distinct from
                                     "not installed" so the agent doesn't loop on
                                     install-the-app advice when the real fix is
                                     `gh auth login` (or similar).

Requires: gh, git.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

repo="${1:?usage: check-garnix-installed.sh REPO [SHA]}"
sha="${2-$(git rev-parse HEAD)}"

if ! out=$(gh api "repos/$repo/commits/$sha/check-suites" \
  --jq '[.check_suites[] | select(.app.slug=="garnix-ci")] | length' 2>&1); then
  echo "gh-error: $out" >&2
  exit 2
fi

if [[ ${out:-0} -gt 0 ]]; then
  echo "installed"
  exit 0
fi

echo "not-installed-or-not-scoped"
exit 1
