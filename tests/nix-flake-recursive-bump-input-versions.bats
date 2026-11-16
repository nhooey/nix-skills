#!/usr/bin/env bats
# The bump skill's scripts, run against the lock in
# fixtures/flake-metadata.json through the stub nix and gh.

load test_helper

setup() {
  common_setup
  scratch_dir work
}

# --- classify-direct-vs-transitive.sh ---------------------------------------

@test "classify lists each locked node's parents across string and follows edges" {
  run "$BUMP_SCRIPTS/classify-direct-vs-transitive.sh"
  assert_success
  assert_output - <<'OUT'
nixpkgs: root, flake-parts, foo
flake-parts: root
foo: root
bar: foo
dead: 
OUT
}

@test "classify applies the predicate and still skips the unlocked root" {
  run "$BUMP_SCRIPTS/classify-direct-vs-transitive.sh" '.locked.owner == "nhooey"'
  assert_success
  assert_output - <<'OUT'
foo: root
bar: foo
dead: 
OUT
}

# --- list-filtered-inputs.sh -------------------------------------------------

@test "list-filtered-inputs defaults to inputs owned by the gh login" {
  export GH_LOGIN=nhooey
  run "$BUMP_SCRIPTS/list-filtered-inputs.sh"
  assert_success
  assert_output "$(printf '%s\t%s\t%s\t%s\t%s\n' \
    foo nhooey foo 3333333333333333333333333333333333333333 HEAD \
    bar nhooey bar 4444444444444444444444444444444444444444 main \
    dead nhooey dead 5555555555555555555555555555555555555555 HEAD)"
  grep -qx '  user' "$STUB_LOG"
}

@test "list-filtered-inputs uses an explicit predicate without asking gh" {
  run "$BUMP_SCRIPTS/list-filtered-inputs.sh" '.locked.owner == "NixOS"'
  assert_success
  assert_output "$(printf 'nixpkgs\tNixOS\tnixpkgs\t1111111111111111111111111111111111111111\tnixos-unstable')"
  run grep -c '^gh$' "$STUB_LOG"
  assert_output 0
}

@test "list-filtered-inputs fails clearly without gh and without a predicate" {
  # A PATH holding only the tools the script needs before it reaches gh.
  mkdir -p "$BATS_TEST_TMPDIR/nogh"
  ln -s "$(command -v bash)" "$BATS_TEST_TMPDIR/nogh/bash"
  PATH="$BATS_TEST_TMPDIR/nogh" run "$BUMP_SCRIPTS/list-filtered-inputs.sh"
  assert_failure 1
  assert_output --partial "needs gh on PATH"
}

# --- find-behind-inputs.sh ---------------------------------------------------

@test "find-behind-inputs prints behind and unresolved inputs, not current ones" {
  cat >"$BATS_TEST_TMPDIR/heads" <<'HEADS'
nhooey/foo@HEAD 3333333333333333333333333333333333333333
nhooey/bar@main 9999999999999999999999999999999999999999
HEADS
  export GH_HEADS="$BATS_TEST_TMPDIR/heads"
  run --separate-stderr "$BUMP_SCRIPTS/find-behind-inputs.sh"
  assert_success
  assert_output "$(printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    bar nhooey bar 4444444444444444444444444444444444444444 9999999999999999999999999999999999999999 main \
    dead nhooey dead 5555555555555555555555555555555555555555 UNRESOLVED HEAD)"
  [[ $stderr == *"could not resolve nhooey/dead@HEAD"* ]]
}

@test "find-behind-inputs queries \$OWNER in place of each input's owner" {
  cat >"$BATS_TEST_TMPDIR/heads" <<'HEADS'
fork/nixpkgs@nixos-unstable 1111111111111111111111111111111111111111
HEADS
  export GH_HEADS="$BATS_TEST_TMPDIR/heads" OWNER=fork
  run "$BUMP_SCRIPTS/find-behind-inputs.sh" '.locked.owner == "NixOS"'
  assert_success
  assert_output ""
  grep -qx '  repos/fork/nixpkgs/commits/nixos-unstable' "$STUB_LOG"
}

# --- verify-cascade-complete.sh ----------------------------------------------

@test "verify-cascade-complete reports all green when nothing is behind" {
  cat >"$BATS_TEST_TMPDIR/heads" <<'HEADS'
nhooey/foo@HEAD 3333333333333333333333333333333333333333
nhooey/bar@main 4444444444444444444444444444444444444444
nhooey/dead@HEAD 5555555555555555555555555555555555555555
HEADS
  export GH_HEADS="$BATS_TEST_TMPDIR/heads"
  run "$BUMP_SCRIPTS/verify-cascade-complete.sh"
  assert_success
  assert_output "all green"
}

@test "verify-cascade-complete fails and lists what is still behind" {
  cat >"$BATS_TEST_TMPDIR/heads" <<'HEADS'
nhooey/foo@HEAD 3333333333333333333333333333333333333333
nhooey/bar@main 9999999999999999999999999999999999999999
nhooey/dead@HEAD 5555555555555555555555555555555555555555
HEADS
  export GH_HEADS="$BATS_TEST_TMPDIR/heads"
  run "$BUMP_SCRIPTS/verify-cascade-complete.sh"
  assert_failure 1
  assert_line --index 0 --partial "still behind"
  assert_line --index 1 "$(printf 'bar\tnhooey\tbar\t4444444444444444444444444444444444444444\t9999999999999999999999999999999999999999\tmain')"
  assert_equal "${#lines[@]}" 2
}

# --- run-bump-pull-request.sh ------------------------------------------------

# A bare origin with one commit on master holding flake.lock, and a clone of
# it as the consumer checkout.
make_consumer() {
  git init --quiet --bare "$BATS_TEST_TMPDIR/origin.git"
  git clone --quiet "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/consumer" 2>/dev/null
  (
    cd "$BATS_TEST_TMPDIR/consumer"
    echo '{}' >flake.lock
    git add flake.lock
    git commit --quiet -m "Initial lock"
    git push --quiet origin master
  )
  export CONSUMER_REPO="$BATS_TEST_TMPDIR/consumer"
  export BRANCH=bump-foo BASE=master SUBJECT="Bump foo"
  export BODY=$'First paragraph\nwrapped here.\n\nSecond paragraph.'
}

@test "run-bump-pull-request commits, pushes and opens a PR with a reflowed body" {
  make_consumer
  run --separate-stderr "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo bar
  assert_success
  # git's own chatter shares stdout; the PR URL is the last line.
  assert_equal "${lines[-1]}" "https://github.com/example/consumer/pull/1"

  # nix updated only the named inputs, then checked, in that order.
  run grep -E '^nix flake (update|check)' "$STUB_LOG"
  assert_output - <<'OUT'
nix flake update foo bar
nix flake check
OUT

  # The pushed branch holds one commit on top of master with the subject and
  # the body as given.
  run git -C "$BATS_TEST_TMPDIR/origin.git" log --format=%B -n 1 bump-foo
  assert_output "$(printf 'Bump foo\n\nFirst paragraph\nwrapped here.\n\nSecond paragraph.')"
  run git -C "$BATS_TEST_TMPDIR/origin.git" rev-list --count master..bump-foo
  assert_output 1

  # gh got the base, the title, and the body with each paragraph on one line.
  run sed -n '/^gh$/,$p' "$STUB_LOG"
  assert_output - <<'OUT'
gh
  pr
  create
  --base
  master
  --title
  Bump foo
  --body
  First paragraph wrapped here.

Second paragraph.
OUT
}

@test "run-bump-pull-request refuses nix older than 2.19 before touching git" {
  make_consumer
  export NIX_VERSION=2.18.9
  run "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo
  assert_failure 1
  assert_output --partial "need ≥2.19"
  run git -C "$CONSUMER_REPO" branch --list bump-foo
  assert_output ""
}

@test "run-bump-pull-request accepts nix 2.19 and a later major version" {
  make_consumer
  NIX_VERSION=2.19.0 run "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo
  assert_success
  export BRANCH=bump-foo-again
  NIX_VERSION=3.0.0 run "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo
  assert_success
}

@test "run-bump-pull-request refuses a branch that already exists" {
  make_consumer
  git -C "$CONSUMER_REPO" branch bump-foo
  run "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo
  assert_failure 1
  assert_output --partial "branch 'bump-foo' already exists"
  run grep -c '^nix flake update' "$STUB_LOG"
  assert_output 0
}

@test "run-bump-pull-request stops before pushing when nix flake check fails" {
  make_consumer
  export NIX_FLAKE_CHECK_EXIT=1
  run "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo
  assert_failure
  run git -C "$BATS_TEST_TMPDIR/origin.git" branch --list bump-foo
  assert_output ""
  run grep -c '^gh$' "$STUB_LOG"
  assert_output 0
}

@test "run-bump-pull-request needs at least one input" {
  make_consumer
  run "$BUMP_SCRIPTS/run-bump-pull-request.sh"
  assert_failure 2
  assert_output --partial "need at least one input"
}

make_consumer_env_only() {
  export CONSUMER_REPO=/nonexistent BRANCH=b BASE=master SUBJECT=s BODY=b
}

@test "run-bump-pull-request names each missing variable" {
  local var
  for var in CONSUMER_REPO BRANCH BASE SUBJECT BODY; do
    make_consumer_env_only
    unset "$var"
    run "$BUMP_SCRIPTS/run-bump-pull-request.sh" foo
    assert_failure
    assert_output --partial "$var: set $var"
  done
}
