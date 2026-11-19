#!/usr/bin/env bats
# Repository-wide rules for the skills under skills/.

load test_helper

# Print the `name` of a SKILL.md's leading `---` frontmatter, read as
# YAML by yq-go; nothing when it is missing or null. awk gates on the
# block opening line 1 and being closed, since yq's front-matter mode
# doesn't report a missing block.
frontmatter_name() {
  awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { closed = 1; exit } END { exit !closed }' "$1" ||
    return 0
  yq --front-matter=extract '.name // ""' "$1"
}

@test "frontmatter_name reads a quoted name with a trailing comment as YAML" {
  local skill_md="$BATS_TEST_TMPDIR/SKILL.md"
  printf '%s\n' '---' 'name: "demo" # the skill' 'description: A demo.' '---' '' '# Demo' >"$skill_md"
  run frontmatter_name "$skill_md"
  assert_output demo
}

@test "every skill's SKILL.md frontmatter name matches its directory" {
  local skill_md dir count=0
  for skill_md in "$REPO_ROOT"/skills/*/SKILL.md; do
    dir="$(basename "$(dirname "$skill_md")")"
    assert_equal "$(frontmatter_name "$skill_md")" "$dir"
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
