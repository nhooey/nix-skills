# nix-skills

Agent skills about Nix (`nix-flakes`, `nix-flake-recursive-bump-input-versions`, `nix-clojure`, `nix-java`), one directory each under `skills/`, published as a Nix flake and a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`). Each skill directory is also a flake of its own.

## Build and test

- `nix develop`: the dev shell, with the project's skills installed into `.agents/skills/` from the `skills-devshell/` sub-flake: skillspkgs' `skill-collections` combination, with no additions.
- `nix flake check`: evaluates every skill package, runs the bats suite under `tests/` and fails on any file `nix fmt` would change.
- `nix-skills test`: runs the bats suite directly, quicker than `nix flake check` while iterating; extra arguments go to bats.
- `nix-skills new-skill NAME DESCRIPTION`: scaffolds `skills/NAME/` (`SKILL.md`, `flake.nix`) and its README row.
- `nix-skills update-skill-locks [NAME...]`: updates the per-skill flakes' locks; `update-flake` and `update-skills-devshell` cover the top-level and `skills-devshell/` locks.
- `tests/`: one `.bats` file per skill's scripts, `nix-skills-tool.bats` for `bin/nix-skills`, plus `skills.bats` for repository-wide rules. Stub `nix` and `gh` in `tests/stubs/` stand in for the real ones, so the suite runs offline in the build sandbox.
- `nix fmt`: formats every file.
