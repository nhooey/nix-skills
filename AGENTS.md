# nix-skills

Agent skills about Nix (`nix-flakes`, `nix-flake-recursive-bump-input-versions`, `nix-clojure`, `nix-java`), one directory each under `skills/`, published as a Nix flake and a Claude Code plugin marketplace (`.claude-plugin/marketplace.json`). Each skill directory is also a flake of its own.

## Build and test

- `nix develop`: the dev shell, with the project's skills installed into `.agents/skills/` from the `skills-devshell/` sub-flake.
- `nix flake check`: evaluates every skill package and fails on any file `nix fmt` would change.
- `nix fmt`: formats every file.
