#!/usr/bin/env bats
# The repository's own bin/nix-skills tool: argument parsing, the scaffold it
# writes, and the nix calls it makes, each against a scratch PRJ_ROOT.

load test_helper

TOOL="$REPO_ROOT/bin/nix-skills"

setup() {
  common_setup
  scratch_repo "root-$BATS_TEST_NUMBER"
  export PRJ_ROOT="$PWD"
  cat >README.md <<'MD'
# demo

## Skills in this repo

| Name | Description | Link |
| --- | --- | --- |
| alpha | First. | [skills/alpha](skills/alpha) |

## Adding a new skill
MD
}

# --- top level ---------------------------------------------------------------

@test "--help lists every command token" {
  run "$TOOL" --help
  assert_success
  assert_line --index 0 --partial "nix-skills — "
  assert_line --partial "test [BATS_ARGS...]"
  assert_line --partial "new-skill NAME DESCRIPTION"
  assert_line --partial "update-skill-locks [NAME...]"
}

@test "no command and an unknown command are usage errors" {
  run "$TOOL"
  assert_failure 2
  assert_output --partial "missing command"

  run "$TOOL" frobnicate
  assert_failure 2
  assert_output --partial "unknown command 'frobnicate'"
}

@test "each command answers --help with its own usage" {
  local cmd
  for cmd in test new-skill update-skill-locks; do
    run "$TOOL" "$cmd" --help
    assert_success
    assert_line --index 0 --partial "nix-skills $cmd — "
  done
}

# --- new-skill ---------------------------------------------------------------

@test "new-skill writes SKILL.md, flake.nix and the README row" {
  run "$TOOL" new-skill nix-demo "Demo patterns in Nix flakes."
  assert_success
  # Nix can't lock a flake.nix git doesn't track, so the next step adds it.
  assert_output --partial "run 'git add skills/nix-demo' and"

  run head -4 skills/nix-demo/SKILL.md
  assert_output "$(printf -- '---\nname: nix-demo\ndescription: Demo patterns in Nix flakes.\n---')"

  run grep -c 'skillName = "nix-demo";' skills/nix-demo/flake.nix
  assert_output 1
  run grep -c 'source = import ../../source.nix;' skills/nix-demo/flake.nix
  assert_output 1

  run sed -n '7,9p' README.md
  assert_line --index 0 "| alpha | First. | [skills/alpha](skills/alpha) |"
  assert_line --index 1 "| nix-demo | Demo patterns in Nix flakes. | [skills/nix-demo](skills/nix-demo) |"
  assert_line --index 2 ""
}

@test "new-skill keeps a description with YAML and table syntax intact" {
  local desc='Do X: then Y | Z, with a \t and a "quote".'
  run "$TOOL" new-skill nix-demo "$desc"
  assert_success

  # Plain, `Do X: then Y` would be a YAML mapping error.
  run sed -n 3p skills/nix-demo/SKILL.md
  assert_output 'description: "Do X: then Y | Z, with a \\t and a \"quote\"."'

  run grep -F '| nix-demo |' README.md
  assert_output '| nix-demo | Do X: then Y \| Z, with a \t and a "quote". | [skills/nix-demo](skills/nix-demo) |'
}

@test "new-skill quotes a description YAML would read as another type" {
  local desc
  for desc in yes 42 '- a list' '#hash' 'ends with:'; do
    rm -rf skills/nix-demo
    run "$TOOL" new-skill nix-demo "$desc"
    assert_success
    run sed -n 3p skills/nix-demo/SKILL.md
    assert_output "description: \"$desc\""
  done
}

@test "new-skill appends the row when the table ends the README" {
  printf '## Skills in this repo\n\n| Name | Description | Link |\n| --- | --- | --- |\n' >README.md
  run "$TOOL" new-skill beta "Second."
  assert_success
  run tail -1 README.md
  assert_output "| beta | Second. | [skills/beta](skills/beta) |"
}

@test "new-skill rejects a bad name, a missing description and an existing skill" {
  local bad
  for bad in Nix-Demo nix_demo -nix nix- 'nix--demo' ''; do
    run "$TOOL" new-skill "$bad" "Desc."
    assert_failure 2
  done

  run "$TOOL" new-skill nix-demo
  assert_failure 2
  run "$TOOL" new-skill nix-demo ""
  assert_failure 2

  mkdir -p skills/alpha
  run "$TOOL" new-skill alpha "Desc."
  assert_failure 1
  assert_output --partial "skills/alpha already exists"
}

@test "new-skill writes nothing when the README has no skill table" {
  echo "# no table" >README.md
  run "$TOOL" new-skill nix-demo "Desc."
  assert_failure 1
  assert_output --partial "no table"
  assert [ ! -e skills/nix-demo ]
  assert_equal "$(cat README.md)" "# no table"
}

# --- update-skill-locks ------------------------------------------------------

@test "update-skill-locks updates every tracked skill flake by default" {
  touch_files skills/a/flake.nix skills/b/flake.nix skills/untracked/flake.nix
  git add skills/a/flake.nix skills/b/flake.nix
  run "$TOOL" update-skill-locks
  assert_success
  assert_line "==> skills/a"
  assert_line "==> skills/b"
  refute_line "==> skills/untracked"
  assert_equal "$(grep -c '^nix flake update' "$STUB_LOG")" 2
  assert [ -s skills/a/flake.lock ]
  assert [ -s skills/b/flake.lock ]
}

@test "update-skill-locks updates only the named skills" {
  touch_files skills/a/flake.nix skills/b/flake.nix
  git add skills
  run "$TOOL" update-skill-locks b
  assert_success
  refute_line "==> skills/a"
  assert [ -s skills/b/flake.lock ]
  assert [ ! -e skills/a/flake.lock ]
}

@test "update-skill-locks refuses an unknown or invalid name before updating" {
  touch_files skills/a/flake.nix
  run "$TOOL" update-skill-locks a missing
  assert_failure 1
  assert_output --partial "skills/missing/flake.nix does not exist"
  run "$TOOL" update-skill-locks ../a
  assert_failure 2
  assert_equal "$(cat "$STUB_LOG")" ""
}
