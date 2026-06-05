#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
watch-checks.sh — poll Garnix check-runs on a commit until completion.

Usage:
  watch-checks.sh REPO [SHA]

REPO: owner/repo
SHA:  commit to watch (default: HEAD)

Polls `/check-runs` filtered to app.slug=="garnix-ci" every 30s. Emits one
summary line per state change.

Exit codes:
  0 + "all green"              — every check ended in success/neutral/skipped.
  1 + "failures: <json>"       — at least one check ended in another conclusion.
  2 + diagnostic on stderr     — 5 consecutive `gh api` failures (auth, network,
                                rate-limit) — the watcher gives up instead of
                                spinning silently forever.

Requires: gh, jq, git.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

repo="${1:?usage: watch-checks.sh REPO [SHA]}"
sha="${2-$(git rev-parse HEAD)}"

prev=""
fail_count=0
max_failures=5

while true; do
  if ! runs=$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100" \
    --jq '[.check_runs[] | select(.app.slug=="garnix-ci") | {name, status, conclusion}]' 2>&1); then
    fail_count=$((fail_count + 1))
    if ((fail_count >= max_failures)); then
      echo "watch-checks.sh: $max_failures consecutive gh failures; last error: $runs" >&2
      exit 2
    fi
    sleep 30
    continue
  fi
  fail_count=0
  count=$(jq 'length' <<<"$runs")
  if [[ $count == "0" ]]; then
    sleep 30
    continue
  fi
  summary=$(jq -c -S . <<<"$runs")
  if [[ $summary != "$prev" ]]; then
    jq -r '[.[] | "\(.name)=\(.status)\(if .conclusion then "/\(.conclusion)" else "" end)"] | join(", ")' <<<"$runs"
    prev=$summary
  fi
  pending=$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")
  if [[ $pending == "0" ]]; then
    fails=$(jq -c '[.[] | select(.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")]' <<<"$runs")
    if [[ "$(jq length <<<"$fails")" == "0" ]]; then
      echo "all green"
      exit 0
    fi
    echo "failures: $fails"
    exit 1
  fi
  sleep 30
done
