---
name: nix-clojure
description: Clojure / ClojureScript packaging in Nix flakes via clj-nix. Covers `mkCljApp` / `mkCljsApp`, `deps-lock.json` discipline, deterministic `node_modules` for shadow-cljs, override-comment hygiene, wiring `cljfmt` + `clj-kondo` + tests as flake checks, JDK pinning via `clojure.override`, and dev-shell tool inventory. Use when packaging a Clojure project with Nix, debugging clj-nix builds, or adding ClojureScript / shadow-cljs to a flake. Pair with the `nix-flakes` skill for generic flake structure.
---

# Nix + Clojure / ClojureScript

Specific to Clojure and ClojureScript projects packaged with [`clj-nix`](https://github.com/jlesquembre/clj-nix). For the generic flake conventions this skill builds on (input pinning, `flake-parts`, devshell discipline, `treefmt`, `git ls-files`, etc.), see the companion `nix-flakes` skill.

## Packaging

- Use `clj-nix.lib.mkCljApp` (JVM) or `mkCljsApp` (ClojureScript) with `projectSrc = ./.`. Declarative Clojure-to-Nix packaging without a custom derivation.
- Set defaults explicitly (`nativeImage.enable = false`, `customJdk.enable = false`, `buildId`, `buildTarget`) so intent is visible in the file rather than implicit. A future reader shouldn't have to consult the clj-nix README to understand what your build *is*.
- Override `clojure` with the project's pinned JDK rather than relying on the ambient one — guarantees the same JDK at build time, test time, REPL, and IDE:

  ```nix
  clojure.override { jdk = pinnedJdk; }
  ```

  Combine with the source-of-truth toolchain-pinning pattern from the `nix-flakes` skill so one constant retargets every consumer.

## Lockfiles

- `deps-lock.json` (clj-nix's companion lockfile for Maven deps) is committed alongside `flake.lock`. Without both, dependency resolution isn't fully reproducible.
- Promote `update-deps` (regenerate `deps-lock.json`) and `update-flake` (`nix flake update`) to first-class dev-shell commands. Don't make new contributors guess.

## ClojureScript / shadow-cljs

- Build `node_modules` deterministically with `pkgs.importNpmLock.buildNodeModules { npmRoot = ./.; }` and symlink it in `preBuild`. No network at build time, fully captured by `package-lock.json`.
- When overriding `mkCljsApp`'s `buildCommand`, leave a comment explaining *why* the default was insufficient (e.g. "the default `clj-builder cljs-compile` runs shadow-cljs directly and wouldn't see the `:shadow-cljs` alias's deps"). Future readers shouldn't have to reverse-engineer the override.
- Guard the `node_modules` relink in dev commands: only `rm` it if it currently points into the Nix store (`readlink -f` starts with `${builtins.storeDir}`). Don't blow away a developer's local `npm install`.

## Lint, format, test as flake checks

Wire the standard Clojure tooling as `checks.${system}` so `nix flake check` is your CI entry point — runs the same way locally and in CI:

- `cljfmt check` — formatting verification
- `clj-kondo` — linting
- the project's test runner (`clojure -M:test`, `bb test`, etc.)

For repo-wide formatting that mixes Clojure with other languages, prefer `treefmt` (see the `nix-flakes` skill) — it can drive `cljfmt` alongside `nixfmt`, `shfmt`, and others under one `nix fmt` command.

## Dev shell contents

Ship every tool a contributor needs:

- `clj-kondo`, `cljfmt` — lint and format
- `clojure` (overridden with the pinned JDK)
- `nodejs`, `npm` — for ClojureScript projects
- `git`, `tree`, `jq` — generic ergonomics

No "install this globally" instructions in the README.

## References

- [`clj-nix`](https://github.com/jlesquembre/clj-nix) — upstream docs, including `mkCljApp` / `mkCljsApp` reference
- [`cljfmt`](https://github.com/weavejester/cljfmt) and [`clj-kondo`](https://github.com/clj-kondo/clj-kondo)
- [shadow-cljs](https://github.com/thheller/shadow-cljs)
