#!/usr/bin/env bats
# Repository-wide rules for the skills under skills/.

load test_helper

@test "every skill's SKILL.md frontmatter name matches its directory" {
  local skill_md dir name count=0
  for skill_md in "$REPO_ROOT"/skills/*/SKILL.md; do
    dir="$(basename "$(dirname "$skill_md")")"
    name="$(awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit } sub(/^name: */, "") { print; exit }' "$skill_md")"
    assert_equal "$name" "$dir"
    count=$((count + 1))
  done
  ((count > 0))
}

@test "every bundled script answers --help with its usage and exit 0" {
  local script
  for script in "$REPO_ROOT"/skills/*/scripts/*.sh; do
    run "$script" --help
    assert_success
    assert_line --index 0 --partial "$(basename "$script") — "
  done
}
