#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
watch-install.sh — poll for Garnix appearing on the repo's HEAD commit.

Usage:
  watch-install.sh REPO [--branch=BRANCH] [--heartbeat=SECONDS]

REPO: owner/repo
--branch=BRANCH: branch whose HEAD to probe (default: repo's default branch).
                 Use this when the user pushed an install-trigger commit to
                 a non-default branch (e.g. a PR branch). Without it, only
                 the default branch's HEAD is checked.
--heartbeat=SECONDS (default 300; must be a positive integer): emit a heartbeat
                 every N seconds while the install has not yet been detected,
                 so a long-running monitor isn't silent.

Polls the chosen branch's HEAD commit every 60s and watches for a check-suite
with app.slug=="garnix-ci". On the absent→present transition, prints
`GARNIX_DETECTED head=<sha>` and exits 0.

If the user installs Garnix but does not push, this watcher will stay silent
forever — pair with an "tell me when you've installed" prompt or an
occasional empty-commit retry.

Requires: gh.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

repo="${1:?usage: watch-install.sh REPO [--branch=BRANCH] [--heartbeat=SECONDS]}"
shift

heartbeat=300
branch=""
for arg in "$@"; do
  case "$arg" in
  --heartbeat=*) heartbeat="${arg#--heartbeat=}" ;;
  --branch=*) branch="${arg#--branch=}" ;;
  *)
    echo "watch-install.sh: unknown arg: $arg" >&2
    exit 2
    ;;
  esac
done

if ! [[ $heartbeat =~ ^[1-9][0-9]*$ ]]; then
  echo "watch-install.sh: --heartbeat must be a positive integer (got: $heartbeat)" >&2
  exit 2
fi

if [[ -z $branch ]]; then
  endpoint="repos/$repo/commits"
else
  endpoint="repos/$repo/commits/$branch"
fi

last_hb=$(date +%s)
while true; do
  if [[ -z $branch ]]; then
    head=$(gh api "$endpoint" --jq '.[0].sha' 2>/dev/null || true)
  else
    head=$(gh api "$endpoint" --jq '.sha' 2>/dev/null || true)
  fi
  if [[ -z $head ]]; then
    sleep 60
    continue
  fi
  has=$(gh api "repos/$repo/commits/$head/check-suites" \
    --jq '[.check_suites[] | select(.app.slug=="garnix-ci")] | length' 2>/dev/null || echo 0)
  if [[ ${has:-0} -gt 0 ]]; then
    echo "GARNIX_DETECTED head=$head"
    exit 0
  fi
  now=$(date +%s)
  if ((now - last_hb > heartbeat)); then
    echo "heartbeat: still no garnix-ci on $head at $(date -u +%H:%M:%SZ)"
    last_hb=$now
  fi
  sleep 60
done
