---
name: nix-flakes
description: "Write and audit `flake.nix` files to one set of language-agnostic conventions, and scaffold a flake where a repo has none. Covers pinning inputs in `flake.lock` rather than in URLs, `follows`, input order (`nixpkgs`, `flake-parts`, `systems`, then alphabetical) and the `@inputs` head, `inherit` over `with`, `flake-parts` with the `nix-systems/default` flake, one constant per pinned toolchain, choosing a `*2nix` library per language (asking the user first), numtide devshell commands, `treefmt`, checks in `nix flake check`, `git ls-files` over `find`, file contents kept out of Nix, `stdenv.hostPlatform.isDarwin` over the deprecated `stdenv.isDarwin`, and two Nix pitfalls: relative `path:` sub-flake inputs and `path:` flakerefs under a symlinked directory such as macOS `/tmp`. Bundled scripts inventory a repo's flakes, detect its languages and check whether Nix still rejects symlinked `path:` flakerefs. Use when authoring a new `flake.nix`, reviewing one for drift from these conventions, picking a language-packaging library, or debugging an evaluation or build problem that looks structural."
---

# Nix flake conventions

Language-agnostic guidance for `flake.nix` files. JVM specifics are in `nix-java`, Clojure and ClojureScript in `nix-clojure`.

## On load: create or update

Invoking this skill is a request to act on the current repo. Inventory its flakes first:

```sh
"${CLAUDE_SKILL_DIR}/scripts/inventory-flakes.sh"
```

It emits one TSV line per `flake.nix` with a `tracked` or `untracked` marker, and exits 1 if there are none. The scripts read the working directory, so run them by absolute path from the user's repo; an agent that doesn't substitute `${CLAUDE_SKILL_DIR}` uses the skill's installed folder.

Then:

- **No flakes: create one without asking.** Detect the project's languages with `"${CLAUDE_SKILL_DIR}/scripts/detect-project-language.sh"`, which emits one slug per line (`rust`, `node-pnpm`, `python-poetry`, `clojure`, `java-gradle`, …), and scaffold a `flake.nix` that follows this skill:
  - pinned, deduplicated inputs;
  - `flake-parts.lib.mkFlake` with `nix-systems/default`;
  - `numtide/devshell` and `numtide/treefmt-nix`;
  - one pinned toolchain constant, read from `rust-toolchain.toml`, `.nvmrc` or the like when present;
  - sorted devshell commands with categories and `help`;
  - `result` and `result-*` in `.gitignore`.

  If the detector exits 1 (no language found), scaffold a minimal flake-parts skeleton with only devshell and treefmt. Then run `nix flake metadata` (or `nix flake show --all-systems --no-write-lock-file`) to confirm it evaluates, and report what you did.

  **Ask which `*2nix` library to use before writing package outputs.** Once you know the language, and before writing any `packages.<system>` output that depends on the project's third-party dependencies, present the candidates from [Language packaging](#language-packaging-choosing-a-2nix-strategy) and let the user pick. The choice decides the lockfile shape, contributor friction, IDE behaviour and CI cost, and is painful to reverse. Skip the question only when the project already commits to one (`gemset.nix` means bundix, `nuget-deps.nix` means `buildDotnetModule`). The dev shell and formatter can land before the answer.

- **One or more flakes: ask which to update.** These rules are opinionated and the flakes are the user's, so don't rewrite any unasked. List every `flake.nix` found, numbered, and ask which to bring into line: all, none or a subset. Audit each chosen flake against this skill section by section, then edit it in place or summarise the changes you'd propose, whichever the user asked for. Leave the others alone.

- **The user wants a new sub-flake** ("add a flake to `tools/`"): create it as above, without asking about the existing flake.

## Input management

- **Pin everything.** Use named inputs (`nixpkgs`, `flake-parts`, `devshell`, …), not the registry, so builds are the same on every machine.
- **Pin revisions in `flake.lock`, not in input URLs.** Write inputs without a rev (`url = "github:owner/repo";`) and let `nix flake update <input>` write the rev and `narHash` into the lock. A rev in the URL (`github:owner/repo/<sha>`) pins twice: the URL wins over the lock, `nix flake update` does nothing for that input, and bumping means editing source. Each sub-flake in a monorepo carries its own `flake.lock`; if one is missing, run `nix flake lock` in that directory instead of adding a URL rev.

  When auditing, treat a rev in a URL as drift to remove, not a convention to copy to other inputs. It shows up most on non-flake source inputs (`*-src`, vendored upstreams), where the author wanted control over the commit; that control belongs in `flake.lock`. Removing the rev and re-running `nix flake lock` moves the input to upstream's tip, which is what `nix flake update` would do anyway. To keep the old rev through the move, delete `rev` from the input's `original` block in `flake.lock` and leave `locked.rev` and `locked.narHash` alone; usually, accept the re-lock.

- **Avoid relative `path:` sub-flake inputs (`url = "path:./subdir"`) in a flake other flakes consume.** A relative input resolves when its flake is the root or a direct input, but once that flake is reached through an intermediate flake with its own committed `flake.lock`, Nix resolves `./subdir` against the intermediate's source tree, and locking fails with `path '«…»/subdir/flake.nix' does not exist` ([NixOS/nix#14762](https://github.com/NixOS/nix/issues/14762), open; the related `nix flake archive` regression is [NixOS/nix#12438](https://github.com/NixOS/nix/issues/12438)). Sandboxed builders fail another way: they archive the consumer's closure without the working tree and reject it with `flake inputs of type 'path:' not allowed`. No setting on the consumer's side fixes the relative form.

  For a sub-flake in the same repo, inline its inputs into the consuming flake's `inputs`, build the combined output in `outputs` (with the library's combiner, for example), and delete the sub-flake directory. The root `flake.lock` grows, and every consumer carries those inputs, but the graph has no relative paths and no self-references.
  - **Don't point the input at your own repo by URL** (`url = "github:owner/repo?dir=subdir"`). The self-reference breaks on a rename, owner change or host move, and resolves only a subdirectory already on the remote's default branch, so adding the subdirectory and switching the input can't happen in one pull request.
  - **A `?dir=` input into a different repo is fine**: it is an ordinary fetchable input.
  - **`import ./subdir` as plain Nix** works when the sub-flake is pure logic with no inputs of its own.

  When inlining, watch for version skew the sub-flake's own lock hid. If an inlined source `follows` a shared library input that the root pins at a different revision, a check that passed in isolation can fail against the root's revision. Letting each inlined source follow only `nixpkgs`, not the shared library, keeps its compatible revision, while the combiner still runs from the root's library. A bare `path:` output and a same-repo build are fine; the hazard is a relative path used as a flake input that is consumed from outside the repo.

- **Resolve symlinked directories before a `path:` flakeref or input.** Since 2.20, Nix refuses a path when it or any parent directory is a symlink: `error: path '//tmp' is a symlink` (or `//var`, `//private/var/…/link`). Since 2.27, bare-path flakerefs (`nix build /tmp/x#a`) work, but `nix build path:/tmp/x#a`, a `path:` input and `builtins.getFlake "path:…"` still fail. It bites on macOS, where `/tmp` and `/var` (so `$TMPDIR`, `mktemp -d` and bats' `$BATS_FILE_TMPDIR`) are symlinks into `/private`: a test that copies a flake to a temporary directory and evaluates `path:$dir` passes on Linux and fails on macOS. Hand Nix the physical path:

  ```sh
  dir="$(cd "$BATS_FILE_TMPDIR" && pwd -P)/my-flake"   # or: realpath
  nix build "path:$dir#default"
  ```

  `"${CLAUDE_SKILL_DIR}/scripts/check-symlinked-parent-path-flakeref.sh"` tests the installed Nix: exit 0 (`still-broken`) means this advice applies, 1 (`fixed`) means this bullet is stale, 2 is inconclusive. Sources and the last check are under [`[symlinked-path]`](#symlinked-path-path-flakerefs-under-a-symlinked-directory).

- **Deduplicate the dependency graph.** Set `inputs.<x>.inputs.nixpkgs.follows = "nixpkgs"` on every secondary input: a smaller closure, and no drift between a dependency's nixpkgs and yours.
- **Write an input with more than one attribute as a nested attrset.** Group `url`, `inputs.*.follows`, `flake = false` and the rest under one `<name> = { … };` block. A lone `<name>.url = …;` line is fine; repeated dotted paths scatter related facts and drift when one line moves without the others.
- **Choose a channel deliberately.** Pin the current stable release branch (`nixos-YY.MM`, or its non-NixOS equivalent) for builds that keep working untouched, or the rolling `unstable` branch for recent toolchains. Say which in a comment, so a reader knows whether moving to the next release is a project decision or a routine update.
- **Order inputs `nixpkgs`, `flake-parts`, `systems`, then alphabetical.** The three foundational inputs lead, in that order, when present; the rest sort alphabetically. The `outputs = { ... }@inputs:` head follows the same order, with `self` first when destructured, since it isn't in `inputs`. Why these lead: `nixpkgs` is the package set every other input `follows`, `flake-parts` is the framework that consumes the rest, and `systems` sets the fanout everything in `perSystem` depends on. Alphabetical order for the rest makes a new input's place mechanical. Keep an existing deliberate grouping (blank-line-separated clusters of related inputs); re-sort only an incidental order.

## The `outputs = { ... }@inputs` convention

Bind the whole inputs attrset:

```nix
outputs = { self, nixpkgs, flake-parts, ... }@inputs: ...
```

You get the inputs you name destructured and one `inputs` name for the whole set, which is what `flake-parts.lib.mkFlake { inherit inputs; } { ... }` takes. Adding an input then doesn't touch the function head.

## Use `inherit` over `with`

`with pkgs;` brings every nixpkgs attribute into scope. A reader can't tell where `lib.foo` came from (`pkgs.lib`? `nixpkgs.lib`? a `let` binding?), and static analysis can't either. Prefer:

```nix
inherit (pkgs) coreutils findutils git;
inherit (pkgs.lib) optional optionals;
```

over

```nix
with pkgs;
with pkgs.lib;
```

Keep `with` for a tight scope of one or two attributes, such as `meta = with lib.licenses; { ... }`, and consider `inherit` even there.

## Never inline a file's contents in Nix

Put a script, config or template in its own file. Read it with `builtins.readFile`, or fill in values with `pkgs.replaceVars ./file { … }` and `@name@` placeholders. A one-line command can stay inline.

## Structure

- **Use `flake-parts.lib.mkFlake` for every flake, small ones included.** `perSystem` replaces the system-fanout boilerplate (`forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system); pkgs = nixpkgs.legacyPackages.${system};`), and ecosystem modules (`easyOverlay`, `devshell.flakeModule`, `treefmt-nix.flakeModule`, `pre-commit-hooks-nix.flakeModule`, …) compose through `imports = [ … ];`. A small flake rarely stays small: a second check, a dev shell or a formatter is two `imports` lines under flake-parts and a restructure under `genAttrs`. The cost is one input and a four-line wrapper, less than the boilerplate it replaces, and a repo with one style everywhere is easier to read. The only fair exception is a one-shot fixture flake that will never grow a second output.
- **Iterate systems through the `nix-systems/default` flake** rather than declaring the system list in every flake:

  ```nix
  inputs.systems.url = "github:nix-systems/default";
  outputs = { systems, flake-parts, ... }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = import systems;
      perSystem = { pkgs, ... }: { ... };
    };
  ```

  The flake-utils equivalent is `flake-utils.lib.eachDefaultSystem`. Either way, a consumer can override the `systems` input to add or remove systems without forking your flake.
- **Resolve `pkgs` once.** Bind it in the `let` (or `_module.args.pkgs` under flake-parts) and reuse it, rather than repeating the lookup at each call site.

## Platform checks: `stdenv.hostPlatform`, not `stdenv.is*`

Test the platform through `stdenv.hostPlatform`: `pkgs.stdenv.hostPlatform.isDarwin`, `.isLinux`, `.isAarch64`, `.isx86_64`, or `lib.optionals pkgs.stdenv.hostPlatform.isDarwin [ … ]`. The shorthands on `stdenv` itself are deprecated aliases, and each use prints a warning on every evaluation:

```text
evaluation warning: stdenv.isDarwin is deprecated, use stdenv.hostPlatform.isDarwin instead
```

- **Which names:** every `stdenv.is*` platform test: `isDarwin`, `isLinux`, `isSunOS`, `isCygwin`, `isBSD`, `isFreeBSD`, `isOpenBSD`, `isi686`, `isx86_32`, `isx86_64`, `is32bit`, `is64bit`, `isAarch32`, `isAarch64`, `isMips` and `isBigEndian`, listed in nixpkgs' `pkgs/stdenv/generic/default.nix`. `stdenv.system` is not deprecated; it already means the host platform's system.
- **Why host, not build:** these tests ask what the package will run on, the host platform. `stdenv.buildPlatform` is the machine doing the build; it differs only when cross-compiling, so switching to it would break cross builds.
- **Fix every occurrence:** `git grep -nE 'stdenv\.is[A-Za-z0-9_]+'` lists them, including `pkgs.stdenv.is…` and `stdenv.is…` bound through `inherit (pkgs) stdenv`. With `config.allowAliases = false`, which some CI sets, the aliases are gone and the old form fails to evaluate instead of warning.
- **When the warning isn't from your code:** an input's Nix can print it too. Make the warning an error and print the trace: `nix eval --option abort-on-warn true --show-trace .#<attr>` (or `nix build` with the same options). If the code belongs to an input, update the input or report it upstream rather than patching around it.

## Toolchain pinning

A toolchain gets a single-source-of-truth constant only when both hold:

1. **It has a version axis in nixpkgs:** two or more versions you could switch between, such as `pkgs.nodejs_22` and `pkgs.nodejs_20`, `pkgs.jdk21` and `pkgs.jdk17`, or a `rust-bin` channel. An unversioned attribute (`pkgs.bun`, `pkgs.ripgrep`, `pkgs.git`) has no axis and doesn't qualify, however often it appears.
2. **More than one consumer uses it:** the production build, the dev shell, the IDE, CI checks.

Then define the pinned version once and thread it through every consumer, so one edit retargets the project:

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

The trigger is the pinned version written in more than one place, not the same package referenced more than once. If either condition fails, don't hoist:

- **No version axis:** the rule doesn't apply. `pkgs.bun` at three `nativeBuildInputs` sites has no `bun_1_0` to switch to, so there is no pinned version to centralise. Hoisting it is a separate de-duplication; if you do it, say that's why, and keep it out of a change scoped to following this skill.
- **One consumer:** a versioned attribute used in one place is already its own single source; pin it inline.

Before hoisting, name the other version this one edit would switch to. `pkgs.nodejs_22` to `pkgs.nodejs_20`: a real axis, hoist. `pkgs.bun` to nothing: leave it inline.

Two related patterns, with their JVM forms in `nix-java`:

- **Clashing wrappers:** when two packages in the dev shell put the same binary on `PATH`, demote one with `lib.lowPrio` instead of removing it.
- **A stable path for the IDE:** when an IDE caches the toolchain's store path, symlink the resolved toolchain into the workspace from a dev shell startup hook, and gitignore the link.

## Language packaging: choosing a `*2nix` strategy

A "`*2nix` library" here is whatever turns the project's language-native lockfile (`Cargo.lock`, `package-lock.json`, `pdm.lock`, `Gemfile.lock`, `composer.lock`, …) into a Nix derivation. The choice is per project and per language, and it decides the lockfile shape contributors work with, what regenerates when dependencies change, whether evaluation uses IFD (import from derivation), and how well CI caches builds. **Ask the user before picking one.**

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

### Decision shortcuts

- **A first-party builder in nixpkgs meets your needs:** use it. No extra input, it follows nixpkgs' release cadence, and it is less likely to rot than a third-party flake.
- **You need granular caching, several cross-cutting outputs, or hermetic CI builds:** reach for `crane`, `haskell.nix`, `clj-nix` or similar specialised tools; they pay off once the build matrix is non-trivial.
- **The project already uses a tool:** keep it, unless the user has put it up for review.
- **The language has no good story** (Swift, R packages outside CRAN, niche DSLs): say so, and propose a fixed-output derivation that vendors the dependencies, or `dream2nix`. Don't invent a recommendation.

## Dev shell ergonomics

Use `numtide/devshell` rather than `mkShell`, for its `menu` command, help text and command categories.

### Command discipline

- **Every command has a `category`.**
- **Don't shadow a name the shell already resolves.** Devshell puts each command on `PATH` as a wrapper, but bash resolves keywords and built-ins before `PATH`, so a command named `test`, `time` or `cd` shows in `menu` and evaluates, yet typing it runs the built-in. `test` is the usual trap for "run the tests"; use `tests`. Check a candidate with `type -a <name>` in a clean shell, and rename it if anything resolves.
- **Category names are lowercase**, since the menu shows them as `[lowercase]`.
- **Sort commands by `(category, name)`** in the source, so diffs stay small and a reader finds a command without searching.
- **Mark each category with a header comment.** Once sorted, put a one-line comment naming the category above each run, so the source reads like the menu and category boundaries stand out in review:

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

  One blank line goes between categories, and the comment matches the `category` field exactly, so drift shows in the diff.
- **Every command has a `help` string**, so `menu` tells a newcomer what's there without reading the flake.
- **Ship every tool a contributor needs in the shell** (linters, formatters, language tools, system utilities), so the README has no "install this globally" step.
- **Make dependency refreshes commands:** `update-deps`, `update-flake`, `update-lockfile` and the like.
- **Factor out repeated shell preambles.** When two commands share one (find the workspace root, source helpers, check tools), put it in a script file read by `pkgs.writeShellApplication`, put that on the dev shell's `PATH`, and call it from each command.
- **`motd` greets and points at `menu`, without printing it.** Greet with the shell's name, which tells nested shells apart, and say that `menu` lists the commands. Printing the whole list on entry scrolls the terminal, interleaves with parallel `direnv` reloads, and repeats on every re-entry; `menu` is there when wanted.

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
- **Guard commands that touch developer state.** If a command relinks `./node_modules` (or any local path) into the Nix store, `rm` it only if it points into the store (`readlink -f` starts with the store directory, which the script gets as `runtimeEnv = { STORE_DIR = builtins.storeDir; }`), so a developer's own `npm install` survives.

### Portability of command bodies

A one-line devshell `command` runs under bash, so bashisms (`${@:-default}`, `[[ ... ]]`, arrays, process substitution) are fine there. Anything longer is a script file in the command's `package = pkgs.writeShellApplication { … }`, which gives it a bash shebang, so the same bashisms keep working when someone runs it outside the shell.

## Formatting

Use `treefmt` through `numtide/treefmt-nix` rather than wiring each formatter separately: one `nix fmt` runs them all (Nix, shell, JSON, YAML, JS, Clojure, Rust, …) under one config and one file-discovery rule.

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

The module sets `formatter.${system}`, so `nix fmt` works. Avoid hand-rolled loops like `find . -name '*.nix' | while read -r f; do nixfmt "$f"; done`; see [Touching files in the repo](#touching-files-in-the-repo).

## Checks

Wire formatters, linters and tests as `checks.${system}`, so `nix flake check` is the CI entry point and runs the same locally as in CI.

## Touching files in the repo

When a script or dev shell command enumerates the repo's files, use `git ls-files` rather than `find`:

```sh
git ls-files -z '*.nix' | while IFS= read -rd '' f; do nixfmt "$f"; done
```

A flake sees only git-tracked files when it evaluates, so commands that act on "the project" should match. `find` descends into `node_modules/`, `.git/`, `result-*` symlinks and untracked scratch files; `git ls-files` sees only what's tracked, and is faster.

```sh
git ls-files '*.nix'                                 # tracked .nix files
git ls-files -z | while IFS= read -rd '' f; do sh -c '...' _ "$f"; done   # null-safe iteration
git ls-files -co --exclude-standard '*.nix'          # tracked + untracked, but not gitignored
```

The exception is a task that deliberately works on untracked files, such as building artifacts or generating files into ignored paths. `find` is fine there; say so in a comment.

## Half-adopted modules

If `flake-parts`, or any other module, is in `inputs` but never imported in `outputs`, drop it or migrate to it. A half-adopted module leaves readers unsure whether the flake is mid-migration, carries dead code, or expects them to use the module somehow.

## References

Resources for cross-checking this skill; where one conflicts with it, the upstream source wins, so re-read it and update the skill:

- [nix.dev](https://nix.dev/): official tutorials from the Nix team, authoritative for language and CLI semantics.
- [Zero to Nix](https://zero-to-nix.com/): Determinate Systems' flakes-first introduction.
- [Practical Nix Flakes (Serokell)](https://serokell.io/blog/practical-nix-flakes): an opinionated walkthrough of a real project layout.
- [NixOS & Flakes Book](https://nixos-and-flakes.thiscute.world/): Ryan Yin's free book on flake patterns and home-manager.
- [flake.parts](https://flake.parts/): `flake-parts` docs and module index.
- [NixOS Wiki: Flakes](https://wiki.nixos.org/wiki/Flakes): community reference.
- [`nix-systems/default`](https://github.com/nix-systems/default): the systems flake used above.
- [`numtide/treefmt-nix`](https://github.com/numtide/treefmt-nix): treefmt's flake integration.
- [`numtide/devshell`](https://github.com/numtide/devshell): the dev shell module.

### `[symlinked-path]`: `path:` flakerefs under a symlinked directory

- **Introduced by:** [NixOS/nix#9497](https://github.com/NixOS/nix/pull/9497), "Move restricted/pure-eval access control out of the evaluator and into the accessor" (in 2.20).
- **Fixed for `nix-env` only:** [NixOS/nix#10247](https://github.com/NixOS/nix/issues/10247), "'/var is a symlink' error on macOS when using `nix-env -iA` under root" (fixed in 2.20.6).
- **Fixed for bare paths only:** [NixOS/nix#12286](https://github.com/NixOS/nix/pull/12286), "Fix flakes follow symlinks" (in 2.27.0), resolves symlinks in `parsePathFlakeRefWithFragment`, so `nix build /tmp/x#a` works; `path:` URLs, `path:` inputs and `builtins.getFlake` still go through `PosixSourceAccessor::assertNoSymlinks`.
- **Still open, nearest match:** [NixOS/nix#11567](https://github.com/NixOS/nix/issues/11567), "`path:` flake reference has some weird behavior" (its repro fails with `path '/var' is a symlink`, though it is mostly about the `.git/fsmonitor` socket). Also related: [NixOS/nix#5831](https://github.com/NixOS/nix/issues/5831), "Can't pass symlinks as flakerefs", and [NixOS/nix#9253](https://github.com/NixOS/nix/issues/9253), "Symlinks to flakes have poor UX". None covers a symlinked parent directory of a `path:` URL; once a dedicated issue exists, cite it here.
- **Last verified:** 2026-11-16 on Nix 2.34.9 (aarch64-darwin), by `scripts/check-symlinked-parent-path-flakeref.sh`, which printed `still-broken` and `error: path '//private/var/…/link' is a symlink`. A `path:` input and `builtins.getFlake "path:…"` fail the same way; the bare path works.
- **Re-verify:** run the script. Exit 1 (`fixed`) means the bullet in [Input management](#input-management) is stale: record the first fixed Nix version there and here, and keep the `pwd -P` advice only for older Nix.
- **When Nix updates:** besides running the script, check the release notes for changes to `path:` flakerefs, symlinks or `assertNoSymlinks`, and the state of [NixOS/nix#11567](https://github.com/NixOS/nix/issues/11567) and any dedicated issue cited above. When one closes or a release fixes it, record the first fixed version and update **Last verified**.

## Your preferences

!`cat "${CLAUDE_SKILL_DIR}/../nix-flakes.preferences.md" "${CLAUDE_PROJECT_DIR}/.agents/skills/nix-flakes.preferences.md" 2>/dev/null || true`

If your agent doesn't run the line above, read these files yourself if they exist: `nix-flakes.preferences.md` next to this skill's folder, then `.agents/skills/nix-flakes.preferences.md` in the project.
A project's file overrides the user's, and the user's overrides this skill's defaults.

## Related skills

When one of these applies and it's in your skill listing, load it without asking.
If it isn't in your listing, tell the user which skill is missing and ask whether to install it from the same collection this skill came from; don't apply it from memory.

- `nix-java`: JVM specifics: the JDK override argument per tool, the IDE-stable `nix-jdk` symlink and `lowPrio` for clashing wrappers.
- `nix-clojure`: Clojure and ClojureScript packaging with clj-nix.
- `nix-flake-recursive-bump-input-versions`: bumping owned inputs across a multi-repo tree of flakes, leaves first.
