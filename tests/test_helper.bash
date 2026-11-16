# Shared setup for the bats suite: a scratch HOME, a fixed git identity, and
# the stub `nix` and `gh` from tests/stubs first on PATH, so the scripts run
# offline and every call they make is logged to $STUB_LOG.

bats_require_minimum_version 1.5.0

bats_load_library bats-support
bats_load_library bats-assert

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
NIX_FLAKES_SCRIPTS="$REPO_ROOT/skills/nix-flakes/scripts"
BUMP_SCRIPTS="$REPO_ROOT/skills/nix-flake-recursive-bump-input-versions/scripts"

common_setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
  git config --global user.name "Test User"
  git config --global user.email "test@example.invalid"
  git config --global init.defaultBranch master
  # Keep git from finding a repository above the scratch directories.
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"

  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"
  export NIX_METADATA_JSON="$TESTS_DIR/fixtures/flake-metadata.json"
  export PATH="$TESTS_DIR/stubs:$PATH"
}

# Make a fresh directory under the test's tmpdir and cd into it.
scratch_dir() {
  local dir="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$dir"
  cd "$dir"
}

# Make a fresh git repository and cd into it.
scratch_repo() {
  scratch_dir "$1"
  git init --quiet
}

# Create each named file, empty, with its parent directories.
touch_files() {
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    : >"$f"
  done
}
