#!/usr/bin/env bats
# The nix-flakes skill's scripts, each run in a scratch directory.

load test_helper

setup() {
  common_setup
}

# --- detect-project-language.sh ----------------------------------------------

# Run the detector in a fresh repository holding the given files.
detect_in_repo() {
  scratch_repo "repo-$BATS_TEST_NUMBER-$RANDOM"
  touch_files "$@"
  run "$NIX_FLAKES_SCRIPTS/detect-project-language.sh"
}

@test "detect finds a manifest in a subdirectory but not a lookalike name" {
  detect_in_repo crates/foo/Cargo.toml
  assert_success
  assert_output rust

  detect_in_repo notCargo.toml
  assert_failure 1
  assert_output ""
}

@test "detect maps each single-manifest language to its slug" {
  local pair file slug
  for pair in \
    go.mod:go \
    Gemfile.lock:ruby \
    composer.lock:php \
    src/App.csproj:dotnet \
    App.fsproj:dotnet \
    App.sln:dotnet \
    deps.edn:clojure \
    project.clj:clojure \
    pom.xml:java-maven \
    build.gradle:java-gradle \
    settings.gradle.kts:java-gradle \
    build.sbt:scala \
    cabal.project:haskell \
    stack.yaml:haskell \
    pkg/thing.cabal:haskell \
    mix.exs:elixir \
    dune-project:ocaml \
    thing.opam:ocaml \
    shard.yml:crystal \
    DESCRIPTION:r \
    rix.nix:r \
    package.json:node-npm \
    package-lock.json:node-npm \
    pnpm-lock.yaml:node-pnpm \
    yarn.lock:node-yarn-v1 \
    poetry.lock:python-poetry \
    uv.lock:python-uv \
    pdm.lock:python-pdm \
    pyproject.toml:python-generic; do
    file="${pair%%:*}" slug="${pair##*:}"
    detect_in_repo "$file"
    assert_success
    assert_output "$slug"
  done
}

@test "detect picks one Node variant, yarn berry first" {
  detect_in_repo .yarnrc.yml yarn.lock package.json
  assert_output node-yarn-berry

  detect_in_repo yarn.lock pnpm-lock.yaml package-lock.json
  assert_output node-yarn-v1

  detect_in_repo pnpm-lock.yaml package-lock.json package.json
  assert_output node-pnpm
}

@test "detect picks one Python tool, poetry.lock first" {
  detect_in_repo poetry.lock uv.lock pdm.lock pyproject.toml
  assert_output python-poetry

  detect_in_repo uv.lock pdm.lock
  assert_output python-uv
}

@test "detect reads [tool.poetry] from a pyproject.toml in a subdirectory" {
  scratch_repo poetry-section
  mkdir -p services/api
  printf '[tool.poetry]\nname = "api"\n' >services/api/pyproject.toml
  run "$NIX_FLAKES_SCRIPTS/detect-project-language.sh"
  assert_success
  assert_output python-poetry
}

@test "detect lists every language in a polyglot repo, in a fixed order" {
  detect_in_repo go.mod web/package-lock.json Cargo.toml api/uv.lock
  assert_success
  assert_output - <<'OUT'
rust
node-npm
python-uv
go
OUT
}

@test "detect skips gitignored files" {
  scratch_repo ignored
  echo '/vendor/' >.gitignore
  touch_files vendor/go.mod Cargo.toml
  run "$NIX_FLAKES_SCRIPTS/detect-project-language.sh"
  assert_success
  assert_output rust
}

@test "detect falls back to the top-level listing outside a git repository" {
  scratch_dir plain
  touch_files go.mod sub/Cargo.toml
  run "$NIX_FLAKES_SCRIPTS/detect-project-language.sh"
  assert_success
  assert_output go
}

@test "detect exits 1 with no output when nothing matches" {
  detect_in_repo README.md
  assert_failure 1
  assert_output ""
}

# --- inventory-flakes.sh -----------------------------------------------------

@test "inventory lists tracked then untracked flakes, skipping ignored ones" {
  scratch_repo inventory
  echo '/ignored/' >.gitignore
  touch_files flake.nix sub/dir/flake.nix
  git add .gitignore flake.nix sub/dir/flake.nix
  touch_files new/flake.nix ignored/flake.nix
  run "$NIX_FLAKES_SCRIPTS/inventory-flakes.sh"
  assert_success
  assert_output "$(printf '%s\t%s\n' \
    flake.nix tracked \
    sub/dir/flake.nix tracked \
    new/flake.nix untracked)"
}

@test "inventory exits 1 with no output in a repository without flakes" {
  scratch_repo no-flakes
  touch_files README.md
  run "$NIX_FLAKES_SCRIPTS/inventory-flakes.sh"
  assert_failure 1
  assert_output ""
}

# --- check-symlinked-parent-path-flakeref.sh ---------------------------------
# The stub nix answers for the physical path and the symlinked path
# separately, so each outcome the script can report is reachable offline.

@test "symlink check reports still-broken when only the symlinked path fails" {
  NIX_EVAL_PHYSICAL=ok NIX_EVAL_LINK=symlink \
    run "$NIX_FLAKES_SCRIPTS/check-symlinked-parent-path-flakeref.sh"
  assert_success
  assert_line --index 0 still-broken
  assert_line --index 1 "nix (Nix) 2.24.0"
  assert_line --index 2 --partial "is a symlink"
  # It evaluated the probe through both paths, the physical one first.
  run grep -o 'path:[^#]*/\(real\|link\)/flake#probe' "$STUB_LOG"
  assert_line --index 0 --regexp '/real/flake#probe$'
  assert_line --index 1 --regexp '/link/flake#probe$'
}

@test "symlink check reports fixed and exits 1 when both paths evaluate" {
  NIX_EVAL_PHYSICAL=ok NIX_EVAL_LINK=ok \
    run "$NIX_FLAKES_SCRIPTS/check-symlinked-parent-path-flakeref.sh"
  assert_failure 1
  assert_line --index 0 fixed
}

@test "symlink check is inconclusive when the physical path fails too" {
  NIX_EVAL_PHYSICAL=other NIX_EVAL_LINK=symlink \
    run "$NIX_FLAKES_SCRIPTS/check-symlinked-parent-path-flakeref.sh"
  assert_failure 2
  assert_line --index 0 "inconclusive: the physical path failed too"
}

@test "symlink check is inconclusive on a different symlinked-path error" {
  NIX_EVAL_PHYSICAL=ok NIX_EVAL_LINK=other \
    run "$NIX_FLAKES_SCRIPTS/check-symlinked-parent-path-flakeref.sh"
  assert_failure 2
  assert_line --index 0 "inconclusive: the symlinked path failed with a different error"
}

@test "symlink check is inconclusive without nix" {
  mkdir -p "$BATS_TEST_TMPDIR/nonix"
  ln -s "$(command -v bash)" "$BATS_TEST_TMPDIR/nonix/bash"
  PATH="$BATS_TEST_TMPDIR/nonix" run "$NIX_FLAKES_SCRIPTS/check-symlinked-parent-path-flakeref.sh"
  assert_failure 2
  assert_output "inconclusive: nix not found"
}
