---
name: nix-language-packaging
description: Choose, with the user, the `*2nix` library that turns a project's language-native lockfile (`Cargo.lock`, `package-lock.json`, `uv.lock`, `Gemfile.lock`, …) into Nix derivations. Covers asking before writing any package output that depends on third-party dependencies, a table of the recommended library and its alternatives per ecosystem (Node, Python, Rust, Go, Haskell, Ruby, JVM, Clojure, Elixir, OCaml, PHP, .NET, R, Crystal, multi-language monorepos), checking a candidate is still maintained, and shortcuts for first-party builders, specialised tools, existing choices and languages with no good story. Use when a flake needs `packages` outputs for a project's own code, when picking or reviewing a language-packaging library, or when a language's `*2nix` tool has gone stale.
---

# Nix language packaging: choosing a `*2nix` strategy

A "`*2nix` library" here is whatever turns the project's language-native lockfile (`Cargo.lock`, `package-lock.json`, `pdm.lock`, `Gemfile.lock`, `composer.lock`, …) into a Nix derivation. The choice is per project and per language, and it decides the lockfile shape contributors work with, what regenerates when dependencies change, whether evaluation uses IFD (import from derivation), and how well CI caches builds.

## Ask before writing package outputs

Once you know the language, and before writing any `packages.<system>` output that depends on the project's third-party dependencies, present the candidates from the table below and let the user pick. The choice decides the lockfile shape, contributor friction, IDE behaviour and CI cost, and is painful to reverse. Skip the question only when the project already commits to one (`gemset.nix` means bundix, `nuget-deps.nix` means `buildDotnetModule`). The dev shell and formatter can land before the answer.

## Recommendations per ecosystem

The table lists the most reliable, maintained and widely used option per ecosystem, with alternatives where the choice is contested. Verify it before relying on it (see below the table).

| Ecosystem                                  | Recommendation                                                 | Why it's the default                                                                                                         | Notable alternatives                                                                                                  |
| ------------------------------------------ | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Node: npm                                  | `pkgs.buildNpmPackage` (nixpkgs)                               | Lockfile-driven, no extra input, maintained in nixpkgs. Needs only an `npmDepsHash`.                                         | `dream2nix` (more powerful, more complex); `node2nix` (older, commits generated `.nix`); `npmlock2nix` (abandoned)    |
| Node: pnpm                                 | `pkgs.fetchPnpmDeps` + `pkgs.pnpmConfigHook` (nixpkgs)         | First-party, models pnpm's content-addressed store, lockfile-driven. `pnpm.fetchDeps` is deprecated.                         | `pnpm2nix-nzbr` (separate flake; more flexible for unusual workspaces)                                                |
| Node: yarn v1                              | `pkgs.yarnConfigHook` + `yarnBuildHook` (nixpkgs)              | Hook-based, lockfile-driven, same shape as the npm builder.                                                                  | — (`mkYarnPackage` is removed)                                                                                        |
| Node: yarn Berry (v2+)                     | Per project                                                    | No widely accepted `*2nix`; `yarn install --immutable` in a fixed-output derivation is the usual workaround.                 | For a Berry monorepo, consider switching to pnpm, which has a better Nix story.                                       |
| Python: Poetry                             | `poetry2nix` (`nix-community`)                                 | Mature, extensive overrides, works from `pyproject.toml` and `poetry.lock`.                                                  | `pyproject-nix` when moving to a PEP 621 layout                                                                       |
| Python: uv, pip-tools, PDM, generic PEP 621 | `pyproject-nix` + `uv2nix` where applicable                   | Modular, aimed at projects past Poetry; `uv2nix` reads `uv.lock` directly.                                                   | `dream2nix` Python module (in flux); `mach-nix` is dead, don't recommend it                                           |
| Python: manual or vendored                 | `pkgs.python3Packages.buildPythonPackage`                      | Stable, no extra input, fine for small projects with few dependencies.                                                       | —                                                                                                                     |
| Rust: flake-native                         | `crane` (`ipetkov/crane`)                                      | Per-crate caching, composes well in flakes, widely used in production.                                                       | `naersk` (older, similar, less active); `crate2nix` (per-crate Nix files, more friction)                              |
| Rust: simple binaries                      | `pkgs.rustPlatform.buildRustPackage` (nixpkgs)                 | Reads `Cargo.lock`, no extra input, right for one-binary repos.                                                              | `crane` once the project grows past one binary or wants better caching                                                |
| Go                                         | `pkgs.buildGoModule` (nixpkgs)                                 | Reads `go.mod` and `go.sum`, hashes the vendor directory, well maintained.                                                   | `gomod2nix` for a committed lockfile and stricter reproducibility, at the cost of a regeneration step                 |
| Haskell: production                        | `haskell.nix` (IOG)                                            | Powerful and fast; generates the Stackage or Cabal Nix itself.                                                               | Steep learning curve; reach for it only when `haskellPackages` runs out                                               |
| Haskell: small or library                  | `haskellPackages.callCabal2nix` (nixpkgs)                      | First-party and simple, built on cabal2nix.                                                                                  | `stack2nix` (less maintained; avoid for new projects)                                                                 |
| Ruby                                       | `bundix` + `pkgs.bundlerEnv`                                   | `bundix` generates `gemset.nix` from `Gemfile.lock`; `bundlerEnv` builds it.                                                 | —                                                                                                                     |
| Java/Kotlin: Maven                         | `pkgs.maven.buildMavenPackage` (nixpkgs)                       | Lockfile-driven through `mvnHash`, first-party, no extra input.                                                              | `mvn2nix` (older flake approach; avoid for new projects)                                                              |
| Java/Kotlin: Gradle                        | `gradle2nix` (`tadfisher/gradle2nix`)                          | The one widely used option that copes with Gradle's resolver; generates a Nix-side dependency lock.                          | Expect friction between Gradle and Nix; `nix-java` has the JDK side                                                   |
| Scala: sbt                                 | `sbt-derivation` (`zaninime/sbt-derivation`)                   | `mkSbtDerivation` gives lockfile-style dependency resolution; the most active sbt option.                                    | Less polished than Go or Rust; check recent commits against your sbt version                                          |
| Clojure                                    | `clj-nix` (`jlesquembre/clj-nix`)                              | Active, flake-native, `mkCljApp` and `mkCljsApp`, good shadow-cljs support. See `nix-clojure`.                               | —                                                                                                                     |
| Elixir: mix                                | `mix2nix` (nixpkgs)                                            | Generates per-dependency Nix from `mix.lock`. First-party.                                                                   | `dream2nix` Erlang/Elixir module (less mature)                                                                        |
| OCaml: opam                                | `opam-nix` (Tweag)                                             | Actively maintained, works with existing opam workflows.                                                                     | `opam2nix` (older, less maintained; verify before use)                                                                |
| PHP: Composer                              | `pkgs.php.buildComposerProject2` (nixpkgs)                     | Lockfile-driven, first-party; the helper the nixpkgs manual documents.                                                       | `composer2nix` (older external tool, more friction)                                                                   |
| C# / .NET                                  | `pkgs.buildDotnetModule` (nixpkgs)                             | Generates a `nuget-deps.nix` companion, first-party.                                                                         | —                                                                                                                     |
| R: reproducible environment                | `rix` (`b-rodrigues/rix`)                                      | Built for reproducible analysis stacks; growing use among data-science Nix users.                                            | `rPackages` (nixpkgs) for one-off packages                                                                            |
| Crystal                                    | `pkgs.crystal.buildCrystalPackage` (nixpkgs)                   | First-party, reads `shard.lock`.                                                                                             | —                                                                                                                     |
| Generic or multi-language monorepo         | `dream2nix` (`nix-community/dream2nix`)                        | Aims to unify `*2nix` across ecosystems; maturity varies by language (Rust and JS strong, others newer).                     | Per-ecosystem tools above, unless one tool across languages pays for itself                                           |

**Verify before you commit.** Projects get archived, forks overtake upstreams, and the recommended way can change within a year. Before writing a `*2nix` choice into a flake, check the candidate's repo for a commit in the last 6 months or so, a responsive issue tracker, and a README that still matches your use. Cross-check [search.nixos.org](https://search.nixos.org/), the nixpkgs manual and recent NixOS Discourse threads for the language, and `nix-clojure` or `nix-java` for theirs.

## Decision shortcuts

- **A first-party builder in nixpkgs meets your needs:** use it. No extra input, it follows nixpkgs' release cadence, and it is less likely to rot than a third-party flake.
- **You need granular caching, several cross-cutting outputs, or hermetic CI builds:** reach for `crane`, `haskell.nix`, `clj-nix` or similar specialised tools; they pay off once the build matrix is non-trivial.
- **The project already uses a tool:** keep it, unless the user has put it up for review.
- **The language has no good story** (Swift, R packages outside CRAN, niche DSLs): say so, and propose a fixed-output derivation that vendors the dependencies, or `dream2nix`. Don't invent a recommendation.

## Your preferences

!`cat "${CLAUDE_SKILL_DIR}/../nix-language-packaging.preferences.md" "${CLAUDE_PROJECT_DIR}/.agents/skills/nix-language-packaging.preferences.md" 2>/dev/null || true`

If your agent doesn't run the line above, read these files yourself if they
exist: `nix-language-packaging.preferences.md` next to this skill's folder, then
`.agents/skills/nix-language-packaging.preferences.md` in the project. A project's
file overrides the user's, and the user's overrides this skill's defaults.

## Related skills

When one of these applies and it's in your skill listing, load it
without asking. If it isn't in your listing, tell the user which skill is
missing and ask whether to install it from the same collection this skill
came from; don't apply it from memory.

- `nix-flakes`: the language-agnostic flake conventions the package outputs sit in, and scaffolding a flake with the project's languages detected.
- `nix-java`: the JDK side of JVM packaging: one pinned JDK passed to each tool's `override`.
- `nix-clojure`: Clojure and ClojureScript packaging with clj-nix.
