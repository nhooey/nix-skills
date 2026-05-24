# skills

[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fnhooey%2Fskills-nix)](https://garnix.io/repo/nhooey/skills-nix)

A collection of [Agent Skills](https://www.anthropic.com/engineering/agent-skills) compatible with Claude Code, Codex, Gemini CLI, Cursor, and the `npx skills` / `gh skill` CLIs.

## Install

```sh
# via npx
npx skills add <owner>/<repo>

# via gh CLI extension
gh skill install <owner>/<repo>

# manually
git clone https://github.com/<owner>/<repo>.git
cp -r <repo>/skills/* ~/.claude/skills/
```

This repo also works as a [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins). Add it with:

```sh
/plugin marketplace add <owner>/<repo>
```

### Install via Nix flake

The repo is also a Nix flake. The top-level flake aggregates every skill; each skill directory is *also* its own flake, so you can install one without pulling the others.

The default `nix run` is a **read-only preview** — it lists what would be installed and where, without touching your filesystem. To actually install, use the explicit `#install` app.

```sh
# Preview what would be installed (no side effects)
nix run github:nhooey/skills-nix
nix run 'github:nhooey/skills-nix?dir=skills/nix-garnix-ci'

# Actually install
nix run github:nhooey/skills-nix#install                              # all skills
nix run 'github:nhooey/skills-nix?dir=skills/nix-garnix-ci#install'   # just one

# Or build a derivation containing the skill files (no install side-effect)
nix build github:nhooey/skills-nix#all              # all skills, symlinkJoined
nix build github:nhooey/skills-nix#nix-garnix-ci    # one skill
```

The installer copies into `$CLAUDE_SKILLS_DIR` if set, otherwise `~/.claude/skills/`. Existing skill directories with the same name are replaced.

Each skill derivation produces `$out/share/claude-skills/<name>/` containing `SKILL.md` (and `references/` / `scripts/` if the skill ships them), so you can also wire skills into a Home Manager module or NixOS configuration without using the installer.

## Skills in this repo

| Name | Description | Link |
| --- | --- | --- |
| nix-garnix-ci | Wire up Garnix CI for a Nix flake on GitHub. | [skills/nix-garnix-ci](skills/nix-garnix-ci) |
| nix-flakes | Generic, language-agnostic Nix flake conventions and structure. | [skills/nix-flakes](skills/nix-flakes) |
| nix-flake-recursive-bump-input-versions | Recursively bump owned flake inputs across a multi-repo lock tree, cascading PRs leaves-first. | [skills/nix-flake-recursive-bump-input-versions](skills/nix-flake-recursive-bump-input-versions) |
| nix-clojure | Clojure / ClojureScript packaging in Nix flakes via clj-nix. | [skills/nix-clojure](skills/nix-clojure) |
| nix-java | JVM-specific patterns in Nix flakes (IDE-stable JDK symlink, override patterns). | [skills/nix-java](skills/nix-java) |

## Adding a new skill

Each skill lives in its own folder under `skills/`, named with `lowercase-with-hyphens`. The folder must contain a `SKILL.md` whose YAML frontmatter `name` field matches the folder name.

```
skills/
└── my-skill/
    ├── SKILL.md          # required — frontmatter + instructions
    ├── references/       # optional — long-form docs
    └── scripts/          # optional — executable helpers
```

The frontmatter requires two fields:

```yaml
---
name: my-skill
description: What the skill does, and when the model should invoke it.
---
```

Write the `description` so an agent can decide whether to invoke the skill from that one line — describe both *what it does* and *when to use it*.

To make a new skill installable via Nix in isolation, drop a `flake.nix` into the skill folder modeled on `skills/nix-garnix-ci/flake.nix`. The top-level flake auto-discovers any subdirectory of `skills/` that contains a `SKILL.md`, so the aggregate package picks up new skills without further changes.

## License

[Apache-2.0](LICENSE)
