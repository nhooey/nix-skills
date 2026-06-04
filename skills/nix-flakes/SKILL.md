---
name: nix-flakes
description: Generic, language-agnostic Nix flake conventions. Covers input pinning, input ordering (`nixpkgs` → `flake-parts` → `systems` → alphabetical) and the `@inputs` head convention, `inherit` vs `with`, `flake-parts` + the `nix-systems/default` flake for system iteration, single-source-of-truth toolchain pinning, choosing a `*2nix` strategy per language (with a recommendation table covering Node/Python/Rust/Go/Haskell/Ruby/JVM/Scala/Clojure/Elixir/OCaml/PHP/.NET/R/Crystal), devshell command discipline (lowercase categories, `(category, name)` sort, factoring repeated shell prologues), `treefmt` for formatting, `git ls-files` over `find` for repo-aware file enumeration, keeping non-Nix content (scripts, configs, descriptors) in their own files via `builtins.readFile` / `pkgs.replaceVars` instead of inline `''…''` blocks so editors / linters / LSP can see them, wiring checks into `nix flake check`, and links to authoritative external references. Use when authoring a new `flake.nix`, reviewing one for idiom drift, picking a language-packaging library, or debugging eval/build issues that smell structural.
---

# Nix Flake Best Practices

Generic, language-agnostic guidance for `flake.nix` files. For JVM-specific patterns see the JVM toolchain notes referenced inline; for Clojure / ClojureScript see the companion `nix-clojure` skill.

## On load — what to do *before* explaining anything

When this skill is invoked, treat it as a request to act on the current repo, not just to recite conventions. Decide which mode you're in by inventorying flakes in the working directory:

```sh
scripts/inventory-flakes.sh
```

Emits one TSV line per `flake.nix` with a `tracked` / `untracked` marker; exits 1 if nothing found.

> **Invocation path.** Examples in this file write `scripts/<name>.sh` for brevity, but the agent's cwd at invocation is the user's repo — not this skill's install directory. Prefix each invocation with the skill's installed path (`$CLAUDE_PLUGIN_ROOT` under a plugin, or `~/.claude/skills/nix-flakes` under a user-level install).

Then:

- **Zero flakes found → create one immediately, without asking.** The user invoked the skill from inside a repo that has none; the obvious next step is to author one. Detect the project's primary language(s) with `scripts/detect-project-language.sh` (emits slugs like `rust`, `node-pnpm`, `python-poetry`, `clojure`, `java-gradle`; one per line) and scaffold a `flake.nix` that follows every convention in this skill: pinned + deduped inputs, `flake-parts.lib.mkFlake`, `nix-systems/default`, `numtide/devshell`, `numtide/treefmt-nix`, single-source-of-truth toolchain pinning (read `rust-toolchain.toml` / `.nvmrc` / equivalents when present), sorted devshell commands with categories and `help`, and `result` / `result-*` added to `.gitignore`. If the detector exits 1 (no language signal), scaffold a minimal flake-parts skeleton with just devshell + treefmt and let the user fill in the rest. After writing the file, run `nix flake metadata` (or `nix flake show --all-systems --no-write-lock-file`) to confirm it evaluates, and report what you did.

  **Stop and ask which `*2nix` library to use before generating any package-level Nix code.** As soon as you've identified a language, but *before* writing the `packages.<sys>` outputs that depend on the project's third-party dependencies, present the candidate `*2nix` strategies for that language (see "Language packaging — choosing a `*2nix` strategy" below) and let the user pick. Do not silently default to one — the choice is opinionated, has long-tail consequences (lockfile shape, contributor friction, IDE behaviour, CI cost), and reversing it later is painful. Acceptable shortcuts: if the project clearly already commits to one (e.g. `gemset.nix` exists → bundix; `nuget-deps.nix` exists → buildDotnetModule), use that without asking. The dev-shell + formatter scaffolding can land first; only the dependency-packaging choice needs the user's input.

- **One or more flakes found → ask which to update, don't auto-modify.** Existing flakes belong to the user and the rules in this skill are opinionated, so a silent rewrite is hostile. Print a numbered list of every `flake.nix` found and ask which one(s) to bring into convention with this skill — accept "all", "none", or a subset. For each chosen flake, audit it against this document section by section and either edit in place or summarise the diffs you'd propose (whichever the user asked for). Do not touch flakes the user did not name.

- **One flake but the user clearly wants a *new* sub-flake** (e.g. "add a flake to `tools/`") → create-mode applies to that path; don't pester the user about the existing one.

This is a *convention*, not a hook — it relies on you noticing that the skill was invoked. Treat the create-vs-update decision as the very first thing to do after reading this file.

## Input management

- **Pin everything.** Use namespaced inputs (`nixpkgs`, `flake-parts`, `devshell`, …) rather than the registry. Reproducible across machines, no surprise updates.
- **Pin revisions in `flake.lock`, not in input URLs.** Write inputs without a rev (`url = "github:owner/repo";`) and let `nix flake update <input>` write the rev (and `narHash`) into the lock. Embedding a rev in the URL — `github:owner/repo/<sha>` — double-pins: the URL silently wins over the lock entry, `nix flake update` becomes a no-op for that input, and bumping requires hand-editing source. The lock is already checked into git, diffs cleanly on update, and records strictly more information than a URL fragment. Subflakes in a monorepo each carry their own `flake.lock` — if one is missing, run `nix flake lock` in that directory rather than papering over it with a URL rev.

  When auditing an existing flake, treat URL-pinned revs as drift to remove, not a project convention to copy onto other inputs. The trap shows up most on `*-src` non-flake source inputs (`anthropics-skills-src`, `humanizer-src`, vendored upstreams, …) where the original author wanted "explicit control over which commit" — but `flake.lock` is where that control belongs, not the URL. Stripping the URL rev and re-running `nix flake lock` re-resolves the input to upstream HEAD: that's the correct behaviour, and the bump is exactly what `nix flake update` would have done anyway. If you genuinely need to preserve the prior rev across this move, edit `flake.lock`'s `original` block to drop its `rev` without touching `locked.rev` / `locked.narHash` — but the common case is to accept the re-lock and move on.
- **Avoid relative `path:` sub-flake inputs (`url = "path:./subdir"`) in any flake other flakes will consume.** A relative path input resolves correctly when its declaring flake is the root or a *direct* input, but Nix mis-resolves it once that flake is reached transitively through an intermediate that ships its own committed `flake.lock`: the `./subdir` is rebased against the *intermediate's* source tree instead of the declaring flake's, so locking fails with `path '«…»/subdir/flake.nix' does not exist`. This is a known Nix lock-composition bug: [NixOS/nix#14762](https://github.com/NixOS/nix/issues/14762) (open — the relative input is resolved against the parent flake's source tree) and the related `nix flake archive` fetch regression in [NixOS/nix#12438](https://github.com/NixOS/nix/issues/12438). Isolated/sandboxed builders fail a second way: they archive the consuming flake's closure *without* the working tree the relative path needs and reject it outright with `flake inputs of type 'path:' not allowed`. The companion `nix-garnix-ci` skill's `[path-inputs]` reference covers the same hazard from the Garnix-builder angle. No consumer-side config fixes the *relative* form.

  The robust fix for the common **same-repo** case is to **inline the sub-flake's inputs into the consuming flake's own `inputs`** and build the combined output in `outputs` (e.g. via the library's combiner), then delete the sub-flake directory. Inlining trades a larger root `flake.lock` — the former sub-flake inputs now travel in every consumer's closure — for an input graph with no relative paths and no self-references at all. Do **not** reach for the tempting shortcut of pointing the input at *your own repo* by URL (`url = "github:owner/repo?dir=subdir"`): a self-referential repo URL is brittle (it silently breaks on any repo rename, owner change, or host move) and can only resolve a subdir that already exists on the remote *default* branch, so you cannot add the subdir and switch the input in one PR. A `?dir=` reference to a **different** repo's subdirectory is fine — that is an ordinary fetchable input, not a self-reference — and `import ./subdir` as plain Nix (no flake input) also works when the sub-flake is pure logic with no inputs of its own.

  When you inline, watch for version skew the sub-flake's isolated lock was hiding: if an inlined source `follows` a shared library input that the root pins at a different (e.g. newer, stricter) revision than the sub-flake's own lock used, a check that passed under isolation can suddenly fail (a real example: a combiner that grew a strict owner-namespace check rejecting an ownerless aggregate key). Letting each inlined source follow only `nixpkgs` — not the shared library — keeps its own compatible revision and reproduces the old isolated behaviour, while the combiner still runs from the root's pinned library. A bare `path:` *output* or a same-repo build is fine; the hazard is specifically a *relative* path used as a flake **input** that gets consumed from outside the repo.
- **Deduplicate the dependency graph.** Set `inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"` on every secondary input. Smaller closure, no version drift between a transitive dep's pinned nixpkgs and yours.
- **When an input has more than one attribute, write it as a nested attrset, not repeated dotted paths.** Group `url`, `inputs.*.follows`, `flake = false`, etc. under one `<name> = { … };` block. A single `<name>.url = …;` line is fine on its own; the dotted-path form only becomes a problem once it repeats, scattering related facts and inviting drift when one line is moved without the others.
- **Choose a channel deliberately.** Pin to the *current* stable release branch (`nixos-XX.YY` or equivalent for non-NixOS) when you want builds to keep working untouched, and to the rolling `unstable` branch when you need recent toolchains. Document the choice in a comment so future-you knows whether bumping to the next release is a project decision or a routine update. Don't lock a specific version number into long-lived guidance — they age out fast; the *pattern* is what matters.
- **Order inputs `nixpkgs` → `flake-parts` → `systems` → alphabetical.** The three foundational inputs lead in that order when they're present; everything else sorts alphabetically. The `outputs = { ... }@inputs:` head mirrors the same order, with `self` first if it's destructured (since `self` doesn't appear in `inputs` itself). Why these three lead: `nixpkgs` is the ambient package set every other input transitively `follows`; `flake-parts` is the framework that consumes the rest; `systems` parameterises the fanout that everything inside `perSystem` depends on. Alphabetical for the rest keeps additions mechanical — no debate about where a new input goes. Preserve any pre-existing intentional grouping (e.g. blank-line-separated clusters of related language-tool inputs); only re-sort when the order is incidental, not load-bearing.

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

## Don't embed non-Nix content inline

When a Nix expression produces or references content in another language, keep that content in its own file on disk and reference it from Nix. Don't paste the body inline as a multi-line `''…''` string.

Why externalising matters:

- Editors and IDEs apply syntax highlighting, structural navigation, and language-aware indentation only to files with the right extension. They cannot see content inside a Nix `''…''` block.
- Formatters and linters (`shellcheck`, `shfmt`, language-native style tools, anything wired into `treefmt`) operate per-file by extension. Embedded content is invisible to them.
- LSP servers only attach to recognised file types — embedded code gets no completion, no go-to-definition, no diagnostics.
- A diff to a standalone file is reviewable on its own; a diff to a long literal block inside a Nix expression obscures the change and disables `git blame` at file granularity.
- Nix's `''` indentation-stripping rules quietly mangle content where leading whitespace is significant — a footgun for heredocs, YAML, and other indent-sensitive formats.

### Reference, don't paste

When Nix only needs to pass the content through unchanged, read it from disk:

```nix
pkgs.writeShellApplication {
  name = "deploy";
  runtimeInputs = [ pkgs.kubectl ];
  text = builtins.readFile ./scripts/deploy.sh;
}
```

The corresponding `scripts/deploy.sh` lives in the repo with its native shebang, syntax, and tooling intact.

### Template when values need to be injected

When Nix needs to inject computed values into the file, keep the file on disk with `@varname@` placeholders and let `pkgs.replaceVars` (or its older sibling `pkgs.substituteAll`) produce the substituted output:

```nix
# scripts/deploy.sh.in contains, verbatim:
#   kubectl --context=@cluster@ apply -f @manifestPath@
pkgs.replaceVars ./scripts/deploy.sh.in {
  cluster = cfg.cluster;
  manifestPath = "${manifest}/k8s.yaml";
}
```

The `.in` suffix is the long-standing autotools / nixpkgs convention for "this is a template, not the final file". Editors still recognise the underlying language (`.sh.in` is parsed as shell, `.json.in` as JSON, etc.), but the suffix signals to humans and to build scripts that the file isn't directly usable until substitution has run. The `@varname@` token convention is what `replaceVars` / `substituteAll` expect — don't invent a different one.

### The line where it's worth externalising

A one-line literal is fine inline. Externalise once any of the following kicks in:

- The content is more than ~3 lines.
- Whitespace is significant (heredoc bodies, indent-sensitive formats).
- The content needs `${…}` or `$$` escaping to survive Nix string interpolation.
- A linter, formatter, or LSP exists for the embedded language and the project would otherwise miss its diagnostics.
- The content has its own test surface or change history worth tracking separately from the Nix file that consumes it.

### Exception: Nix is genuinely the source of truth

Don't externalise content that Nix is *computing* — an attrset rendered to JSON via `builtins.toJSON`, a config composed from typed module options, a unit file assembled from per-package fragments. There, the on-disk file is a build output, not an input; putting it under `scripts/` would invert the dependency direction and lose the type information Nix is enforcing.

## Structure

- **Default to `flake-parts.lib.mkFlake` for every flake — even small ones.** `perSystem` collapses the system-fanout boilerplate (`forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system); pkgs = nixpkgs.legacyPackages.${system};`) into one signature, and ecosystem modules (`easyOverlay`, `devshell.flakeModule`, `treefmt-nix.flakeModule`, `pre-commit-hooks-nix.flakeModule`, …) compose via `imports = [ … ];` rather than being open-coded. The "small flake" rarely stays small: adding a second check, a devshell, or a formatter is two `imports` lines under flake-parts versus restructuring under plain `genAttrs`. The marginal cost is one extra input and a four-line wrapper — strictly less code than the boilerplate it replaces. The only honest opt-out is a one-shot fixture flake that will never grow a second output. A repo that mixes flake-parts flakes and `genAttrs` flakes also pays an ongoing context-switch tax on every read; picking one default removes it.
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

A toolchain qualifies for single-source-of-truth pinning only when **both** of these hold:

1. **It has a version axis in nixpkgs** — two or more selectable versions you could retarget *between*, e.g. `pkgs.nodejs_22` ↔ `pkgs.nodejs_20`, `pkgs.jdk21` ↔ `pkgs.jdk17`, a `rust-bin` channel. An *unversioned* attr — `pkgs.bun`, `pkgs.ripgrep`, `pkgs.git`, anything nixpkgs exposes under a single bare name — has no axis and does **not** qualify, no matter how many times it appears.
2. **It is used by more than one consumer** in the flake — the production build, the dev shell, the IDE, CI checks.

When both hold, define a single source of truth for the pinned version (a compiler, runtime, or build tool) and thread it through every consumer. One edit retargets the whole project.

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

The trigger is **writing the pinned *version* in more than one place** — not merely referencing the same package more than once. Both conditions above are load-bearing; if either fails, do not hoist:

- **No version axis → the rule does not apply**, regardless of how many call sites. `pkgs.bun` written at three `nativeBuildInputs` sites is not a violation: there is no `bun_1_0` to switch to, so there is no "pinned version" to make a single source of truth *for*. Hoisting it to a `let` binding is an unrequested DRY refactor, not this rule. (Plain de-duplication may be worth doing on its own merits — but if you do it, say *that's* why; don't attribute it to toolchain pinning, and don't smuggle it into a change set scoped to "follow the skill.")
- **Single consumer → no indirection needed.** A versioned attr used in exactly one place is already its own single source of truth; pin it inline.

Litmus test before hoisting: **name the other version this one edit would switch to.** `pkgs.nodejs_22 → pkgs.nodejs_20`: real axis, hoist. `pkgs.bun → ?`: nothing to name, leave it inline.

If two packages on PATH inside the dev shell would shadow each other (e.g. a wrapper that re-exports the same tool name), use `pkgs.lib.lowPrio` to demote one rather than removing it. Both stay available; only one wins on `PATH`.

If an IDE needs a stable filesystem path to the toolchain (because the Nix store path changes on every update and the IDE caches it), symlink the resolved toolchain into the workspace from a dev-shell startup hook. The JVM ecosystem has a canonical version of this pattern (a `nix-jdk` symlink in the workspace, gitignored, kept in sync from `devshell.startup`). Apply the same shape to other toolchains as needed.

## Language packaging — choosing a `*2nix` strategy

The "**`*2nix` library**" in this section is shorthand for whatever Nix-side tool turns the project's *language-native* lockfile (`Cargo.lock`, `package-lock.json`, `pdm.lock`, `Gemfile.lock`, `composer.lock`, …) into a buildable Nix derivation. The choice is **per-project, per-language, and load-bearing**: it dictates the lockfile shape contributors interact with, what regenerates when deps change, whether IFD (import-from-derivation) shows up in evaluation, and how cleanly CI caches builds. **Ask the user before picking one.**

The table below is current as of the author's last verification — see the disclaimer below the table — and lists the most reliable / actively maintained / commonly used option per ecosystem, plus one or two close alternatives where the choice is genuinely contested.

| Ecosystem | Recommendation | Why it's the default | Notable alternatives |
|---|---|---|---|
| **Node — npm** | `pkgs.buildNpmPackage` (in nixpkgs) | Lockfile-driven, no extra flake input, well-maintained because it lives in nixpkgs. Just needs an `npmDepsHash`. | `dream2nix` (more powerful, more complex); `node2nix` (older, generates committed `.nix` files); `npmlock2nix` (largely abandoned) |
| **Node — pnpm** | `pkgs.pnpm.fetchDeps` + `stdenv.mkDerivation` (in nixpkgs) | First-party in nixpkgs, models pnpm's content-addressed store accurately, lockfile-driven. | `pnpm2nix-nzbr` (separate flake; slightly more flexible for edge-case workspaces) |
| **Node — yarn (v1)** | `pkgs.yarnConfigHook` + `yarnBuildHook` (in nixpkgs) | Newer hook-based API in nixpkgs is lockfile-driven and matches the npm pattern. | `mkYarnPackage` (deprecated — avoid for new projects) |
| **Node — yarn Berry (v2+)** | `yarn-berry` flakes / per-project | No widely accepted *2nix yet; `yarn install --immutable` inside a fixed-output derivation is the common workaround. | If consolidating a Berry monorepo, evaluate switching to pnpm — better Nix story. |
| **Python — Poetry** | `poetry2nix` (`nix-community`) | Mature, extensive override support, works with `pyproject.toml` + `poetry.lock`. | `pyproject-nix` if migrating to PEP-621 / non-Poetry layout. |
| **Python — uv / pip-tools / PDM / generic PEP 621** | `pyproject-nix` + `uv2nix` (where applicable) | Modular framework that targets the post-Poetry world; `uv2nix` reads `uv.lock` directly. Very current. | `dream2nix` Python module (under iteration); `mach-nix` is **dead** — don't recommend |
| **Python — manual / vendored** | `pkgs.python3Packages.buildPythonPackage` | Stable, no third-party flake input, fine for small projects with few deps. | — |
| **Rust — flake-native** | `crane` (`ipetkov/crane`) | Granular per-crate caching, flake-friendly composition, used in production by many. | `naersk` (older, similar shape, less active); `crate2nix` (per-crate Nix files, more friction) |
| **Rust — simple binaries** | `pkgs.rustPlatform.buildRustPackage` (in nixpkgs) | Reads `Cargo.lock`, no extra flake input, perfect for one-binary repos. | Use `crane` once the project grows past one binary or wants better caching. |
| **Go** | `pkgs.buildGoModule` (in nixpkgs) | Reads `go.mod` + `go.sum`, hashes the vendor dir, well-maintained. | `gomod2nix` if you want a committed lockfile and stricter reproducibility — adds a regen step. |
| **Haskell — production** | `haskell.nix` (IOG / IOHK) | Powerful, fast, used by Cardano-scale projects. Generates per-stackage / cabal Nix automatically. | Steep learning curve; reach for it only if `nixpkgs.haskellPackages` runs out of road. |
| **Haskell — small / library** | `nixpkgs.haskellPackages.callCabal2nix` | First-party, simple, leans on cabal2nix internally. | `stack2nix` (less maintained); avoid for new projects. |
| **Ruby** | `bundix` + `pkgs.bundlerEnv` | The de facto pair: `bundix` generates `gemset.nix` from `Gemfile.lock`; `bundlerEnv` builds it. | — |
| **Java/Kotlin — Maven** | `pkgs.maven.buildMavenPackage` (in nixpkgs) | Lockfile-driven via `mvnHash`, first-party, no extra flake input. | `mvn2nix` (older flake-based approach; avoid for new projects). |
| **Java/Kotlin — Gradle** | `gradle2nix` (`tadfisher/gradle2nix`) | The only widely-used option that survives Gradle's resolver chaos. Generates a Nix-side dependency lock. | Be ready for the Gradle/Nix relationship to be flaky — see the `nix-java` skill for survival tips. |
| **Scala — sbt** | `sbt-derivation` (`zaninime/sbt-derivation`) | `mkSbtDerivation` provides lockfile-style dep resolution; the most actively maintained sbt+Nix option. | Less polished than the Go / Rust stories — verify recent commits and your sbt version. |
| **Clojure** | `clj-nix` (`jlesquembre/clj-nix`) | Active, flake-native, supports `mkCljApp` / `mkCljsApp`, good shadow-cljs integration. See the companion `nix-clojure` skill. | — |
| **Elixir — mix** | `mix2nix` (in nixpkgs) | Generates per-dep Nix from `mix.lock`. First-party. | `dream2nix` Erlang/Elixir module (less mature). |
| **OCaml — opam** | `opam-nix` (Tweag) | Modern, actively maintained, integrates with existing opam workflows. | `opam2nix` (older, less maintained — verify before using). |
| **PHP — Composer** | `pkgs.php.buildComposerProject` (in nixpkgs) | Lockfile-driven, first-party, well-supported since ~2023. | `composer2nix` (older external tool — works but more friction). |
| **C# / .NET** | `pkgs.buildDotnetModule` (in nixpkgs) | Generates a `nuget-deps.nix` companion, first-party. | — |
| **R — reproducible env** | `rix` (`b-rodrigues/rix`) | Aimed at reproducible analysis stacks; growing adoption in the data-science Nix community. | `nixpkgs.rPackages` for ad-hoc per-package needs. |
| **Crystal** | `pkgs.crystal.buildCrystalPackage` (in nixpkgs) | First-party, reads `shard.lock`. | — |
| **Generic / multi-language monorepo** | `dream2nix` (`nix-community/dream2nix`) | Explicit goal of unifying *2nix across ecosystems; subsystem maturity varies (Rust/JS strong, others newer). Worth it when you genuinely need one tool spanning languages. | Default to per-ecosystem tools above unless dream2nix's cross-language story specifically pays for itself. |

> **Verify before you commit.** This space moves fast — projects get archived, forks supersede upstreams, and "the recommended way" can flip in 6–12 months. Before you write a `*2nix` choice into a flake, check the candidate's repo for: a commit in the last ~6 months, an open-and-responsive issue tracker, and that the README still matches what you're trying to do. Cross-reference against [search.nixos.org](https://search.nixos.org/) and recent NixOS Discourse threads for the language. The companion language skills (`nix-clojure`, `nix-java`) carry deeper recency notes for their ecosystems — check them when relevant.

### Decision shortcuts

- **A first-party (in-nixpkgs) builder exists and meets your needs → use it.** No extra flake input, follows nixpkgs's release cadence, far less likely to bitrot than a third-party flake.
- **You need granular caching, multiple cross-cutting outputs, or hermetic builds for CI → reach for `crane` / `haskell.nix` / `clj-nix` / similar specialised tooling.** The investment pays off once the build matrix is non-trivial.
- **The project already commits to a tool → use it.** Don't impose a different choice on a working flake unless the user has flagged it as up for review.
- **The language doesn't have a good story (e.g. Swift, R packages outside CRAN, niche DSLs) → say so, and propose either a fixed-output derivation that vendors deps or pulling in `dream2nix`.** Don't fake a recommendation.

## Dev shell ergonomics

Use `numtide/devshell` rather than raw `mkShell` — you get the `menu` command, structured help text, and per-command categories out of the box.

### Command discipline

- **Every command belongs to a `category`.** No uncategorized commands.
- **Don't shadow names that already resolve in the shell.** Devshell publishes each command as a wrapper on `PATH`, but bash resolves reserved words, built-ins, and keywords *before* `PATH` — so a command named `test`, `time`, `cd`, etc. shows up in `menu` and evaluates fine, but typing the name at the prompt silently runs the built-in instead. The classic offender is `test` (POSIX equivalent to `[`), which makes `test` a tempting and broken name for "run the project's tests" — prefer `tests`. Check candidate names with `type -a <name>` in a clean shell before locking them in; if anything resolves, rename.
- **Category names are lowercase** — they render as `[lowercase]` in the menu and look right when bracketed.
- **Keep commands sorted by `(category, name)`** in the source file. Diff noise stays low; readers can find a command without grepping.
- **Mark each category boundary with a header comment.** Once commands are sorted by `(category, name)`, add a single-line comment naming the category at the top of each run, so the source reads like the menu. Without this, a long list of `{ category = "build"; ... } { category = "build"; ... } { category = "ci"; ... }` is a wall of noise where the boundary between categories is easy to miss in review. Example:

  ```nix
  commands = [
    # build
    { category = "build"; name = "compile";   help = "..."; command = "..."; }
    { category = "build"; name = "package";   help = "..."; command = "..."; }

    # ci
    { category = "ci"; name = "check";        help = "..."; command = "..."; }
    { category = "ci"; name = "fmt-check";    help = "..."; command = "..."; }

    # dev
    { category = "dev"; name = "watch";       help = "..."; command = "..."; }
  ];
  ```

  Keep one blank line between categories. Header text matches the `category` field exactly, so the comment can't drift away from the truth without an obvious diff.
- **Every command has a `help` string.** A newcomer running `menu` should learn what's available without reading the flake source.
- **Ship every tool a contributor needs in the shell** (linters, formatters, language tooling, system utilities). No "install this globally" instructions in the README.
- **Promote dependency-refresh tasks to first-class commands.** `update-deps`, `update-flake`, `update-lockfile` etc. — not tribal knowledge buried in a Slack channel.
- **Factor out repeated shell patterns.** When two commands share a preamble (e.g. "find the workspace root, source helpers, check tool availability"), extract it to a shared helper script in the dev shell rather than copy-pasting. `pkgs.writeShellApplication` is the right tool — wrap the helper, put it on `PATH` via the dev shell, call it from each command.
- **`motd` greets on entry and points at `menu` — but does not print it.** Greet with the shell name (useful for distinguishing nested shells) and tell the user that running `menu` will list the available commands. Do **not** dump the full command list at entry: it scrolls the terminal, races output with parallel `direnv` reloads, and goes stale the moment the shell is re-entered. The whole point of having `menu` as a command is that it's there when wanted and silent when not. Example:

  ```nix
  devshells.default = {
    name = "myproject";
    motd = ''
      {bold}{14}🚀 Entering myproject dev shell{reset}
      Run {bold}menu{reset} to list available commands.
    '';
    # ...
  };
  ```
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

The flake's `formatter.${system}` is set automatically, so `nix fmt` just works. Avoid hand-rolled `find . -name '*.nix' | while read -r f; do nixfmt "$f"; done` — see [Touching files in the repo](#touching-files-in-the-repo).

## Checks

Wire formatters, linters, and tests as `checks.${system}` so `nix flake check` is your CI entry point. Same command runs locally and in CI; no "but it passes on my machine" because of an out-of-band lint runner.

## Touching files in the repo

When a script or dev-shell command needs to enumerate files in the repo, **default to `git ls-files`** rather than `find`:

```sh
git ls-files -z '*.nix' | while IFS= read -rd '' f; do nixfmt "$f"; done
```

Why: a Nix flake is inherently version-control-aware (the flake itself only sees git-tracked files at evaluation time), so commands that operate on "the project" should match. `find` will silently descend into `node_modules/`, `.git/`, `result-*` symlinks, untracked scratch files, and anything else lying around. `git ls-files` only sees what's tracked, which is almost always what you want. It's also faster.

Common patterns:

```sh
git ls-files '*.nix'                                 # tracked .nix files
git ls-files -z | while IFS= read -rd '' f; do sh -c '...' _ "$f"; done   # null-safe iteration
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
