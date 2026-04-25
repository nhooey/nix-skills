---
name: nix-flakes
description: Generic, language-agnostic Nix flake conventions. Covers input pinning and the `@inputs` head convention, `inherit` vs `with`, `flake-parts` + the `nix-systems/default` flake for system iteration, single-source-of-truth toolchain pinning, devshell command discipline (lowercase categories, `(category, name)` sort, factoring repeated shell prologues), `treefmt` for formatting, `git ls-files` over `find` for repo-aware file enumeration, wiring checks into `nix flake check`, and links to authoritative external references. Use when authoring a new `flake.nix`, reviewing one for idiom drift, or debugging eval/build issues that smell structural.
---

# Nix Flake Best Practices

Generic, language-agnostic guidance for `flake.nix` files. For JVM-specific patterns see the JVM toolchain notes referenced inline; for Clojure / ClojureScript see the companion `nix-clojure` skill.

## Input management

- **Pin everything.** Use namespaced inputs (`nixpkgs`, `flake-parts`, `devshell`, …) rather than the registry. Reproducible across machines, no surprise updates.
- **Deduplicate the dependency graph.** Set `inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"` on every secondary input. Smaller closure, no version drift between a transitive dep's pinned nixpkgs and yours.
- **Choose a channel deliberately.** Pin to the *current* stable release branch (`nixos-XX.YY` or equivalent for non-NixOS) when you want builds to keep working untouched, and to the rolling `unstable` branch when you need recent toolchains. Document the choice in a comment so future-you knows whether bumping to the next release is a project decision or a routine update. Don't lock a specific version number into long-lived guidance — they age out fast; the *pattern* is what matters.

## The `outputs = { ... }@inputs` convention

Always bind the whole inputs attrset:

```nix
outputs = { self, nixpkgs, flake-parts, ... }@inputs: ...
```

Why: you get destructured access to the inputs you mention by name *and* a single `inputs` reference for the whole set. That single name is what you hand to `flake-parts.lib.mkFlake { inherit inputs; } { ... }` — without it, you'd have to either re-list every input as an attr or thread them individually. It also means adding a new input doesn't require touching the function head.

## Use `inherit` over `with`

`with pkgs;` brings every nixpkgs attribute into scope. It's hostile to readers (where did `lib.foo` come from? `pkgs.lib`? `nixpkgs.lib`? a let-binding?) and makes static analysis impossible. Prefer:

```nix
inherit (pkgs) coreutils findutils git;
inherit (pkgs.lib) optional optionals;
```

over

```nix
with pkgs;
with pkgs.lib;
```

Reserve `with` for cases where you really want a tight ad-hoc scope (e.g. inside a `meta = with lib.licenses; { ... }` for one or two attrs) — and even then, consider whether `inherit` is clearer.

## Structure

- **Use `flake-parts.lib.mkFlake` for non-trivial flakes.** `perSystem` keeps the system axis clean, and modules (`easyOverlay`, `devshell.flakeModule`, `treefmt-nix.flakeModule`) compose via `imports` instead of being open-coded.
- **Iterate systems via the `nix-systems/default` flake** rather than re-declaring the system list in every flake. The convention:

  ```nix
  inputs.systems.url = "github:nix-systems/default";
  outputs = { systems, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;
      perSystem = { pkgs, ... }: { ... };
    };
  ```

  For flake-utils-style flakes, the equivalent is `flake-utils.lib.eachDefaultSystem` — same idea, different surface. Either way, downstream consumers can override the `systems` input to add or remove systems without forking your flake.
- **Single source of truth for `pkgs`.** Resolve once inside the `let` (or `_module.args.pkgs` under flake-parts) and reuse — don't repeat the lookup at every call site.

## Toolchain pinning

When a toolchain — a compiler, runtime, or build tool — has multiple available versions *and* is used by more than one consumer in the flake (the production build, the dev shell, the IDE, CI checks), define a single source of truth for the pinned version and thread it through every consumer. One edit retargets the whole project.

Concretely:

```nix
let
  toolchain = pkgs.someToolchain_42;        # the one knob
  build = pkgs.buildSomething.override { inherit toolchain; };
in {
  packages.default = build;
  devShells.default = pkgs.mkShell {
    nativeBuildInputs = [ toolchain build ];
  };
}
```

Apply this any time you'd otherwise write the toolchain version more than once.

If two packages on PATH inside the dev shell would shadow each other (e.g. a wrapper that re-exports the same tool name), use `pkgs.lib.lowPrio` to demote one rather than removing it. Both stay available; only one wins on `PATH`.

If an IDE needs a stable filesystem path to the toolchain (because the Nix store path changes on every update and the IDE caches it), symlink the resolved toolchain into the workspace from a dev-shell startup hook. The JVM ecosystem has a canonical version of this pattern (a `nix-jdk` symlink in the workspace, gitignored, kept in sync from `devshell.startup`). Apply the same shape to other toolchains as needed.

## Dev shell ergonomics

Use `numtide/devshell` rather than raw `mkShell` — you get the `menu` command, structured help text, and per-command categories out of the box.

### Command discipline

- **Every command belongs to a `category`.** No uncategorized commands.
- **Category names are lowercase** — they render as `[lowercase]` in the menu and look right when bracketed.
- **Keep commands sorted by `(category, name)`** in the source file. Diff noise stays low; readers can find a command without grepping.
- **Every command has a `help` string.** A newcomer running `menu` should learn what's available without reading the flake source.
- **Ship every tool a contributor needs in the shell** (linters, formatters, language tooling, system utilities). No "install this globally" instructions in the README.
- **Promote dependency-refresh tasks to first-class commands.** `update-deps`, `update-flake`, `update-lockfile` etc. — not tribal knowledge buried in a Slack channel.
- **Factor out repeated shell patterns.** When two commands share a preamble (e.g. "find the workspace root, source helpers, check tool availability"), extract it to a shared helper script in the dev shell rather than copy-pasting. `pkgs.writeShellApplication` is the right tool — wrap the helper, put it on `PATH` via the dev shell, call it from each command.
- **`motd` greets on entry** with the shell name. Useful for distinguishing nested shells.
- **Guard mutating commands** that overlap with developer state. If a `run` command relinks `./node_modules` (or any local path) into the Nix store, only `rm` it if it currently points into the store (`readlink -f` starts with `${builtins.storeDir}`). Don't blow away a developer's local `npm install`.

### Portability of command bodies

Devshell commands run under bash, so bashisms (`${@:-default}`, `[[ ... ]]`, arrays, process substitution) are fine *inside* the dev shell. But the moment a command is extracted into a stand-alone script that someone might run with `sh` or `dash`, those bashisms break. If a command is non-trivial enough that you might lift it out, give it an explicit `#!/usr/bin/env bash` shebang from the start (via `pkgs.writeShellApplication`) so the dependency is visible.

## Formatting

Use `treefmt` (via `numtide/treefmt-nix`) instead of wiring up each language's formatter individually. One `nix fmt` runs every formatter the project needs (Nix, shell, JSON, YAML, JS, Clojure, Rust, …) under one config, with consistent file-discovery semantics. Wire it up via the flake-parts module:

```nix
imports = [ inputs.treefmt-nix.flakeModule ];
perSystem = { ... }: {
  treefmt = {
    projectRootFile = "flake.nix";
    programs.nixfmt.enable = true;
    programs.shfmt.enable = true;
    # add per-language formatters as the project grows
  };
};
```

The flake's `formatter.${system}` is set automatically, so `nix fmt` just works. Avoid hand-rolled `find . -name '*.nix' | xargs nixfmt` — see [Touching files in the repo](#touching-files-in-the-repo).

## Checks

Wire formatters, linters, and tests as `checks.${system}` so `nix flake check` is your CI entry point. Same command runs locally and in CI; no "but it passes on my machine" because of an out-of-band lint runner.

## Touching files in the repo

When a script or dev-shell command needs to enumerate files in the repo, **default to `git ls-files`** rather than `find`:

```sh
git ls-files -z '*.nix' | xargs -0 nixfmt
```

Why: a Nix flake is inherently version-control-aware (the flake itself only sees git-tracked files at evaluation time), so commands that operate on "the project" should match. `find` will silently descend into `node_modules/`, `.git/`, `result-*` symlinks, untracked scratch files, and anything else lying around. `git ls-files` only sees what's tracked, which is almost always what you want. It's also faster.

Common patterns:

```sh
git ls-files '*.nix'                                 # tracked .nix files
git ls-files -z | xargs -0 -I{} sh -c '...' _ {}     # null-safe iteration
git ls-files -co --exclude-standard '*.nix'          # tracked + untracked, but not gitignored
```

The exception: tasks that *intentionally* mutate untracked files (e.g. building output artifacts, generating files into `.gitignore`d paths). For those, `find` (or just doing the work explicitly) is fine — but make the intent visible in a comment.

## Half-adopted modules

If `flake-parts` (or any other module) is in `inputs` but never imported in `outputs`, drop it or migrate. Half-adopted modules are worse than either choice — readers can't tell whether the flake is mid-migration, has dead code, or expects them to use the module in some unspecified way.

## References

Nix and the flake ecosystem evolve fast. These are well-regarded contemporary resources for cross-checking advice in this skill:

- [nix.dev](https://nix.dev/) — official tutorials maintained by the Nix team. Authoritative for language and CLI semantics.
- [Zero to Nix](https://zero-to-nix.com/) — Determinate Systems' modern, flakes-first onboarding.
- [Practical Nix Flakes (Serokell)](https://serokell.io/blog/practical-nix-flakes) — opinionated walkthrough of a real project layout.
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/) — Ryan Yin's free book; broad coverage of flake patterns and home-manager integration.
- [flake.parts](https://flake.parts/) — `flake-parts` ecosystem docs and module index.
- [NixOS Wiki — Flakes](https://wiki.nixos.org/wiki/Flakes) — community-maintained reference, widely linked.
- [`nix-systems/default`](https://github.com/nix-systems/default) — the systems flake referenced above.
- [`numtide/treefmt-nix`](https://github.com/numtide/treefmt-nix) — treefmt + flake integration.
- [`numtide/devshell`](https://github.com/numtide/devshell) — the dev shell module.

When advice in this skill conflicts with one of those, the upstream source wins — re-read it and update.
