# nix-skills

A collection of [Agent Skills](https://www.anthropic.com/engineering/agent-skills) compatible with Claude Code, Codex, Gemini CLI, Cursor, and the `npx skills` / `gh skill` CLIs.

## Install

```sh
# via npx
npx skills add nhooey/nix-skills

# via gh CLI extension
gh skill install nhooey/nix-skills

# manually
git clone https://github.com/nhooey/nix-skills.git
cp -r nix-skills/skills/* ~/.claude/skills/
```

This repo also works as a [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugins). Add it with:

```sh
/plugin install nix-skills --marketplace nhooey/nix-skills   # Claude Code 2.1.275+
/plugin marketplace add nhooey/nix-skills                     # older versions, then /plugin install
```

### Install via Nix flake

The repo is also a Nix flake. The top-level flake aggregates every skill; each skill directory is *also* its own flake, so you can install one without pulling the others.

The default `nix run` is a **read-only preview**: it lists what would be installed and where, without touching your filesystem. To install, use the `#install` app. Every app except the preview needs `--scope`:

- `--scope=personal` targets `~/.claude/skills/`.
- `--scope=project` targets `.claude/skills/` under the nearest ancestor of the current directory holding `.git/` or `flake.nix`.
- `--scope=custom --root=<path>` targets `<path>`.

```sh
# Preview what would be installed (no side effects)
nix run github:nhooey/nix-skills
nix run 'github:nhooey/nix-skills?dir=skills/nix-flakes'

# Install
nix run github:nhooey/nix-skills#install -- --scope=personal                          # all skills
nix run github:nhooey/nix-skills#install -- --scope=personal nix-flakes               # named skills
nix run 'github:nhooey/nix-skills?dir=skills/nix-flakes#install' -- --scope=personal  # one skill's own flake

# Or build a derivation containing the skill files (no install side-effect)
nix build github:nhooey/nix-skills                                     # all skills (agent-skills-nhooey-nix-all)
nix build github:nhooey/nix-skills#agent-skill-nhooey-nix-flakes       # one skill
```

By default the installer symlinks each skill from the Nix store into the target directory and registers a per-user GC root so the store path survives `nix-store --gc`. `--profile` installs through `nix profile install` instead. `nix run github:nhooey/nix-skills#install -- --help` lists every option.

The flake also exposes these apps, each taking the same `--scope` flags:

| App | What it does |
| --- | --- |
| `uninstall` | Removes the named skills and their GC roots. |
| `reconcile` | Installs or refreshes every skill in the flake and removes managed entries that aren't in it. |
| `reap` | Removes managed entries whose store paths were garbage-collected, and orphan GC roots. |
| `purge` | Removes every skill agent-skill-flake installed in the target directory, whichever flake installed it. Takes `--dry-run` and `--yes`. |

Each skill derivation produces `$out/share/claude-skills/<name>/` containing `SKILL.md` (and `references/` / `scripts/` if the skill ships them), so you can also wire skills into a Home Manager module or NixOS configuration without using the installer.

## Skills in this repo

| Name | Description | Link |
| --- | --- | --- |
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

To make a new skill installable via Nix in isolation, drop a `flake.nix` into the skill folder modeled on `skills/nix-flakes/flake.nix`. The top-level flake auto-discovers any subdirectory of `skills/` that contains a `SKILL.md`, so the aggregate package picks up new skills without further changes.

## License

[Apache-2.0](LICENSE)
