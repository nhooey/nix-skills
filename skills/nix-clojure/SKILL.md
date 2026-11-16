---
name: nix-clojure
description: Package Clojure and ClojureScript projects in Nix flakes with clj-nix. Covers `mkCljApp` and `mkCljsApp` with their defaults written out, committing `deps-lock.json` beside `flake.lock`, a JDK pinned through `clojure.override`, a deterministic `node_modules` for shadow-cljs, a comment on every overridden `buildCommand`, `cljfmt`, `clj-kondo` and tests wired as flake checks, and the tools the dev shell ships. Use when packaging a Clojure project with Nix, debugging a clj-nix build, or adding ClojureScript or shadow-cljs to a flake.
---

# Nix + Clojure / ClojureScript

For Clojure and ClojureScript projects packaged with [`clj-nix`](https://github.com/jlesquembre/clj-nix). The generic flake conventions this builds on (input pinning, `flake-parts`, dev shell commands, `treefmt`, `git ls-files`) are in `nix-flakes`.

## Packaging

- Use `clj-nix.lib.mkCljApp` (JVM) or `mkCljsApp` (ClojureScript) with `projectSrc = ./.`, rather than a hand-written derivation.
- Write the defaults out (`nativeImage.enable = false`, `customJdk.enable = false`, `buildId`, `buildTarget`), so the file says what the build is without a trip to the clj-nix README.
- Override `clojure` with the project's pinned JDK, so build, tests, REPL and IDE all run the same one:

  ```nix
  clojure.override { jdk = pinnedJdk; }
  ```

  Take `pinnedJdk` from the single toolchain constant in `nix-flakes`; the JDK overrides for other JVM tools are in `nix-java`.

## Lockfiles

- Commit `deps-lock.json`, clj-nix's lockfile for Maven dependencies, alongside `flake.lock`. Dependency resolution is reproducible only with both.
- Make `update-deps` (regenerate `deps-lock.json`) and `update-flake` (`nix flake update`) dev shell commands.

## ClojureScript / shadow-cljs

- Build `node_modules` from `package-lock.json` with `pkgs.importNpmLock.buildNodeModules { npmRoot = ./.; inherit nodejs; }` (`nodejs` is a required argument) and symlink it in `preBuild`. The build needs no network.
- When overriding `mkCljsApp`'s `buildCommand`, comment why the default wasn't enough, for example: "the default `clj-builder cljs-compile` runs shadow-cljs directly and wouldn't see the `:shadow-cljs` alias's deps".
- In a dev command that relinks `node_modules`, `rm` it only if it points into the Nix store (`readlink -f` starts with `${builtins.storeDir}`), so a developer's own `npm install` survives.

## Lint, format, test as flake checks

Wire the Clojure tooling as `checks.${system}`, so `nix flake check` runs the same way locally and in CI:

- `cljfmt check`: formatting.
- `clj-kondo`: linting.
- The project's test runner (`clojure -M:test`, `bb test`, and so on).

For a repo that mixes Clojure with other languages, drive `cljfmt` from `treefmt` alongside `nixfmt` and `shfmt`, as `nix-flakes` describes.

## Dev shell contents

Ship every tool a contributor needs, so the README has no "install this globally" step:

- `clj-kondo`, `cljfmt`: lint and format.
- `clojure`, overridden with the pinned JDK.
- `nodejs` and `npm`, for ClojureScript projects.
- `git`, `tree`, `jq`.

## References

- [`clj-nix`](https://github.com/jlesquembre/clj-nix): upstream docs, including the `mkCljApp` and `mkCljsApp` reference.
- [`cljfmt`](https://github.com/weavejester/cljfmt) and [`clj-kondo`](https://github.com/clj-kondo/clj-kondo).
- [shadow-cljs](https://github.com/thheller/shadow-cljs).

## Your preferences

!`cat "${CLAUDE_SKILL_DIR}/../nix-clojure.preferences.md" "${CLAUDE_PROJECT_DIR}/.agents/skills/nix-clojure.preferences.md" 2>/dev/null || true`

If your agent doesn't run the line above, read these files yourself if they
exist: `nix-clojure.preferences.md` next to this skill's folder, then
`.agents/skills/nix-clojure.preferences.md` in the project. A project's
file overrides the user's, and the user's overrides this skill's defaults.

## Related skills

When one of these applies and it's in your skill listing, load it
without asking. If it isn't in your listing, tell the user which skill is
missing and ask whether to install it from the same collection this skill
came from; don't apply it from memory.

- `nix-flakes`: flake conventions this skill builds on: input pinning, `flake-parts`, toolchain pinning, dev shell commands, `treefmt`.
- `nix-java`: JDK pinning across JVM tools, the IDE-stable `nix-jdk` symlink and `lowPrio` for clashing wrappers.
