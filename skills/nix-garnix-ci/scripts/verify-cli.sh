#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
verify-cli.sh — Garnix check-suite + check-run summary for a commit.

Usage:
  verify-cli.sh REPO [SHA]

REPO: owner/repo
SHA:  commit to inspect (default: HEAD)

Emits, in order:
  1. one JSON object per CI app: {"app", "status", "conclusion"}
  2. per-check (Garnix only): <conclusion-or-status>\t<name>\t<url>

Requires: gh, jq, git.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

repo="${1:?usage: verify-cli.sh REPO [SHA]}"
sha="${2-$(git rev-parse HEAD)}"

gh api "repos/$repo/commits/$sha/check-suites" \
  --jq '.check_suites[] | {app: .app.slug, status, conclusion}'

gh api "repos/$repo/commits/$sha/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.app.slug=="garnix-ci")
        | "\(.conclusion // .status)\t\(.name)\t\(.html_url)"'
