#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
run-bump-pull-request.sh — execute one consumer-flake bump as a PR.

Usage:
  CONSUMER_REPO=<path> BRANCH=<name> BASE=<base-branch> \
  SUBJECT=<subject>    BODY=<body> \
  run-bump-pull-request.sh <input1> [<input2> ...]

Env:
  CONSUMER_REPO  absolute path to the consumer-flake checkout
  BRANCH         topic branch name to create from origin/$BASE
  BASE           consumer's default branch (e.g. master, main); also the
                 PR base — passed to `gh pr create --base "$BASE"` so the
                 PR targets the same branch we cut from.
  SUBJECT        commit subject + PR title
  BODY           commit body + PR body; blank-line separated paragraphs.
                 Reflowed for the PR body by an awk paragraph-join so each
                 paragraph collapses to one GFM line. awk, not `fmt` — a
                 dev shell's `fmt`/`nix fmt` shadows coreutils `fmt` on
                 PATH, rejects `-w`, and would silently yield an empty body.

Preflight:
  • Requires nix ≥2.19 — earlier versions silently ignore positional
    `nix flake update <input>` args and update every input.
  • Fails fast if $BRANCH already exists locally (e.g. from a prior
    half-finished run). Recovery: `git -C "$CONSUMER_REPO" branch -D "$BRANCH"`.

Steps (fail-fast on any non-zero exit):
  1. cd "$CONSUMER_REPO"
  2. git fetch --quiet origin
  3. git checkout -b "$BRANCH" "origin/$BASE"
  4. nix flake update <inputs ...>
  5. nix flake check
  6. git add flake.lock && git commit -m "$SUBJECT" -m "$BODY"
  7. git push -u origin "$BRANCH"
  8. gh pr create --base "$BASE" --title "$SUBJECT" --body "$(reflowed body)"

Prints the created PR URL to stdout on success.

Requires: git, nix (≥2.19), gh, awk.
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

: "${CONSUMER_REPO:?set CONSUMER_REPO}"
: "${BRANCH:?set BRANCH}"
: "${BASE:?set BASE (the consumer default branch)}"
: "${SUBJECT:?set SUBJECT (commit + PR title)}"
: "${BODY:?set BODY (commit + PR body, blank-line separated paragraphs)}"

# Join the lines within each blank-line-separated paragraph into one GFM line.
# awk paragraph mode (RS="") instead of `fmt -w` so a dev shell's `fmt`/`nix
# fmt` command can't shadow coreutils `fmt` and silently blank the PR body.
reflow() { awk 'BEGIN { RS = ""; ORS = "\n\n" } { gsub(/\n/, " "); print }'; }

if [[ $# -eq 0 ]]; then
  echo "run-bump-pull-request.sh: need at least one input name to bump" >&2
  exit 2
fi

nix_ver=$(nix --version | awk '{print $NF}')
awk_version_check='BEGIN { split(v, a, "."); if ((a[1]+0) < 2 || ((a[1]+0) == 2 && (a[2]+0) < 19)) exit 1; exit 0 }'
if ! awk -v v="$nix_ver" "$awk_version_check"; then
  echo "run-bump-pull-request.sh: nix $nix_ver detected; need ≥2.19 for positional 'nix flake update <input>' args (older nix silently bumps every input). Upgrade nix or run the bump steps inline." >&2
  exit 1
fi

cd "$CONSUMER_REPO"

if git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  echo "run-bump-pull-request.sh: branch '$BRANCH' already exists in $CONSUMER_REPO. Delete it first (e.g. \`git -C \"$CONSUMER_REPO\" branch -D $BRANCH\`) or pick a different BRANCH." >&2
  exit 1
fi

git fetch --quiet origin
git checkout -b "$BRANCH" "origin/$BASE"

nix flake update "$@"
nix flake check

git add flake.lock
git commit -m "$SUBJECT" -m "$BODY"
git push -u origin "$BRANCH"

gh pr create --base "$BASE" --title "$SUBJECT" --body "$(printf '%s\n' "$BODY" | reflow)"
