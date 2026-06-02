---
name: nix-garnix-ci
description: Wire up Garnix CI for a Nix flake on GitHub. Covers the basics (garnix.yaml scope prompts for arches + branches, GitHub App install, badge wrapper, gh CLI verification) and the advanced surface (Actions vs sandbox checks, rootless podman in actions, runner constraints, action sizing, yaml-from-nix regeneration). Use when adding CI to a flake, fixing a broken Garnix badge, writing Actions that need network or containers, or debugging mysterious runner constraints.
---

# Garnix CI for a Nix flake

[Garnix](https://garnix.io) is a hosted Nix builder + binary cache that
registers as a GitHub App. It builds the flake outputs you tell it to (caching
via `cache.garnix.io` <sup>[[cache]](#ref-cache)</sup>), runs `nix flake check`
derivations as GitHub status checks, and runs flake `apps` as **Garnix
Actions** with network and tools <sup>[[actions]](#ref-actions)</sup>.
Surfaces results via the GitHub Checks API
<sup>[[checks-api]](#ref-checks-api)</sup> — no `.github/workflows/` file.

## Helper scripts

The deterministic procedures in this skill live in `scripts/` next to this
file. Each script takes `--help` for usage. All assume `gh` on `PATH`;
`discover-flake-outputs.sh` and `watch-checks.sh` also need `jq` (and the
former needs `nix`); the install-probe / install-watcher / verify / url
scripts use only `gh --jq` (gh's built-in filter).

**Invocation path.** Examples below show `scripts/<name>.sh` for brevity,
but the agent's working directory at invocation is usually the user's
repo — not this skill's install dir. Prefix each invocation with the
skill's installed directory (`$CLAUDE_PLUGIN_ROOT` when running under a
plugin, or `~/.claude/skills/nix-garnix-ci` under a user-level install).

| Script | Purpose | Section |
| --- | --- | --- |
| `discover-flake-outputs.sh` | Emit one `<class>.<system>.<name>` (or `<class>.<name>` for non-systemed) line per existing flake output — drives `builds.include` authoring. Errors surface on stderr (no swallowing). | "On load" |
| `check-garnix-installed.sh REPO [SHA]` | Probe for a `garnix-ci` check-suite. Distinct exits: 0 installed / 1 not-installed / 2 gh-error (so auth/network failures don't masquerade as "not installed"). | Step 2 |
| `garnix-install-url.sh REPO` | Print the prefilled install URL (`target_id` + `repository_ids[]`). Hard-errors on a failed `gh api` instead of emitting a malformed URL. | Step 2 |
| `watch-install.sh REPO [--branch=B] [--heartbeat=N]` | Background poller for the absent→present transition. `--branch=` to watch a non-default branch (e.g. a PR branch the install commit went to). | Step 2 |
| `watch-checks.sh REPO [SHA]` | Watch Garnix check-runs on a commit until completion; final `all green` or `failures: <json>`. Gives up with exit 2 after 5 consecutive `gh api` failures (no silent infinite spin on dead auth). | Watch loop |
| `verify-cli.sh REPO [SHA]` | Suite-level summary + per-check status filtered to Garnix. | Step 5 |

## On load — what to do *before* explaining anything

When this skill is invoked, treat it as a request to act on the current repo,
not just to recite conventions. Inventory the repo's Garnix configuration
state:

```sh
git ls-files 'garnix.yaml' '**/garnix.yaml'
# also untracked, in case the user is mid-creation:
git ls-files -o --exclude-standard 'garnix.yaml' '**/garnix.yaml'
```

Then:

- **No `garnix.yaml` found → confirm scope with the user, then author one.**
  The user invoked this skill from inside a repo that has none; the obvious
  next step is to write one. Discover the flake outputs available with
  `scripts/discover-flake-outputs.sh` (one `<class>.<system>.<name>` line
  per existing output) and write a `garnix.yaml` at the repo root with
  explicit `builds.include` patterns covering exactly the system / output
  combinations the flake actually defines, restricted to the arches the
  user said they target. After writing, remind the user that:
  1. Garnix only fires on commits pushed *after* the GitHub App is installed
     and scoped to the repo (Step 3); if the App isn't already installed they
     need to install it at https://github.com/apps/garnix-ci/installations/new
     — you cannot do this for them.
  2. The README badge, if any, must use the `img.shields.io/endpoint.svg?url=…`
     wrapper, not the raw `garnix.io/api/badges/…` URL (Step 4).

- **`garnix.yaml` exists → ask whether to update it to follow these
  conventions, don't silently rewrite.** Print the path(s), summarise what's
  there (raw `builds.include` / `builds.exclude` / `actions` / `flakeDir`
  shape), and ask whether to bring it into line with this skill (explicit
  include patterns, no reliance on the default include set, Action bodies
  factored into `nix/garnix.nix`, badge wrapper in the README, etc.). Accept
  "yes / no / specific changes only" and only edit the file if the user
  green-lit it. Do not touch a working CI configuration without permission.

- **Multiple `garnix.yaml` files** (rare — monorepo with `flakeDir` per
  subtree, or several sibling flakes) → list them and ask the same
  update question per file.

After (or during) the `garnix.yaml` decision, also inventory the project's
**test suite**: detect the language(s) (look for `pyproject.toml`,
`package.json`, `go.mod`, `Cargo.toml`, `deps.edn`, `*.bats`, etc.) and
check whether the existing tests are exposed as `flake.checks.<sys>.<name>`
derivations. If they're not, the `checks.*` lines in `garnix.yaml` enforce
nothing. Propose wiring them up — see "Wiring the project's test suite
into `flake.checks`" below for the shape and grouping decision. This is a
flake-level change, not a `garnix.yaml` change, so it's a separate ask
than the yaml edit.

This is a *convention*, not a hook — it relies on you noticing that the skill
was invoked. Treat the create-vs-update decision as the very first thing to do
after reading this file.

> **Reference durability:** Each non-trivial claim below carries a clickable
> superscript link to its source in the [References & verification](#references--verification)
> section (Garnix docs, observed behavior in this repo, or the author's
> prior-project notes). Before relying on any claim that drives a decision,
> re-fetch the source and confirm it still holds.

## The load-bearing distinction: sandbox check vs Action

Almost every Garnix gotcha hinges on which side of this line you're on
<sup>[[actions]](#ref-actions)</sup> <sup>[[yaml]](#ref-yaml)</sup>.

| | Sandbox check (`flake.checks.<sys>.<name>`) | Action (`flake.apps.<sys>.<name>`) |
|---|---|---|
| Runs in | Nix sandbox | Garnix runner micro-VM <sup>[[actions]](#ref-actions)</sup> |
| Network | None | Yes <sup>[[actions]](#ref-actions)</sup> |
| `/dev` | Minimal | Most things, but **no `/dev/net/tun`** <sup>[[notes]](#ref-notes)</sup> |
| Persistent state | None (per-build) | None (ephemeral) |
| Memory ceiling | Whatever the builder has | ~4.5 GB <sup>[[notes]](#ref-notes)</sup> (not in official docs <sup>[[actions]](#ref-actions)</sup>) |
| Trigger | Every git push, included by `builds.include` <sup>[[yaml]](#ref-yaml)</sup> | `actions[*].run` in `garnix.yaml` <sup>[[yaml]](#ref-yaml)</sup> |
| Use for | Pure tests, deterministic builds | Tests needing network, containers, or `/proc` |

Anything that touches the network, runs `git clone`, or uses `podman` must be
an **Action**, not a check <sup>[[actions]](#ref-actions)</sup>.

## Quick checklist (basic flake, no Actions)

1. Before writing `garnix.yaml`, confirm two scope choices with the user — **architectures to build** (default to the host arch) and **branches to build on** (default to the default branch) — see "Decisions to confirm" under Step 1. Both directly affect Garnix minute consumption.
2. Drop a `garnix.yaml` at repo root with explicit include patterns <sup>[[yaml]](#ref-yaml)</sup>.
3. User installs the [Garnix GitHub App](https://github.com/apps/garnix-ci/installations/new) on the repo <sup>[[app]](#ref-app)</sup> (you cannot do this for them <sup>[[obs]](#ref-obs)</sup>).
4. Push a commit *after* the install. Pre-install commits are not retroactively built <sup>[[obs]](#ref-obs)</sup>.
5. Add the badge using the **shields.io endpoint wrapper** <sup>[[badges]](#ref-badges)</sup> (raw `garnix.io/api/badges/...` returns JSON, not SVG <sup>[[obs]](#ref-obs)</sup>).
6. Verify with `gh api repos/<owner>/<repo>/commits/<sha>/check-suites` and `/check-runs` <sup>[[checks-api]](#ref-checks-api)</sup>.

For Actions (network/containers/long-running scripts), see "Writing Actions"
below.

## Step 1 — `garnix.yaml`

### Decisions to confirm with the user before writing the file

Two scope decisions directly burn Garnix minutes and have no good default in
the abstract — prompt the user before generating `garnix.yaml`.

**1. Which architectures to build for.** "Host arch" here means **the arch of
the system running the checks** — i.e., the Garnix builder, not the developer's
laptop. Garnix runs its own builder pool with separate machines per arch; a
project's `uname -sm` on the dev machine tells you nothing about what Garnix
should build.

The right default is **`x86_64-linux`**: it's the arch Garnix's own default
include set targets when no `garnix.yaml` is present
<sup>[[yaml]](#ref-yaml)</sup>, and it matches the deploy target for most
server projects. Each additional arch in `builds.include` (e.g., adding
`aarch64-linux`, `aarch64-darwin`, `x86_64-darwin`) provisions a separate
Garnix builder per build and roughly multiplies minute consumption. Only opt
in to more arches when the project actually ships binaries to those targets
(Mac app → `aarch64-darwin`, ARM Linux deploy → `aarch64-linux`, etc.).

For context only, you can detect the dev machine's arch with `uname -sm`
(`Darwin arm64 → aarch64-darwin`, `Linux x86_64 → x86_64-linux`, etc.) — but
don't anchor the recommendation on it. Phrase the prompt as:

> "Which arches does this project run on in production? `x86_64-linux` is
> Garnix's default and cheapest builder and is right for most server
> projects. Add `aarch64-darwin`/`x86_64-darwin` only if you ship Mac
> binaries, `aarch64-linux` only if you deploy to ARM Linux."

**2. Which branches to build on.** By default Garnix builds **every push to
every branch**, including PR branches
<sup>[[getting-started]](#ref-getting-started)</sup>. The `builds.branch` key
restricts this <sup>[[yaml]](#ref-yaml)</sup>:

```yaml
builds:
  branch: main         # only builds on pushes to `main`
  include: [...]
```

Detect the git host first so the prompt names the right workflow events:

```bash
git remote -v | awk 'NR==1 {print $2}'
```

- **GitHub** (`github.com`) — Garnix is a GitHub App
  <sup>[[app]](#ref-app)</sup>, so triggers are GitHub events. With
  `branch: <default>` you get a build on each push to the default branch
  **and** on the merge commit that lands when a PR is merged (because the
  merge commit *is* a push to the default branch). PR branches themselves
  get **no pre-merge CI** under this restriction — call this trade-off out
  explicitly, since most teams want PR feedback.
- **GitLab / Bitbucket / other** — Garnix is currently GitHub-only
  <sup>[[app]](#ref-app)</sup>. If no remote points at `github.com`, stop
  and tell the user Garnix won't work here.

Phrase the prompt as:

> "Restrict builds to `<default-branch>` only, or build on every branch
> including PR pushes?
> – Default-branch only: builds run on pushes to `<default-branch>` and on
>   the merge commit when a PR lands. No pre-merge PR CI. Saves Garnix
>   minutes.
> – Every branch (Garnix default): builds run on every push, including PR
>   branch updates. Full PR feedback, higher minute usage."

### Default include set <sup>[[yaml]](#ref-yaml)</sup>

If you ship no `garnix.yaml`, Garnix builds:

- `*.x86_64-linux.*`
- `defaultPackage.x86_64-linux`
- `devShell.x86_64-linux`
- `homeConfigurations.*`
- `darwinConfigurations.*`
- `nixosConfigurations.*`

So Darwin-system NixOS-style configurations **are** in the default set, and
`packages.aarch64-darwin.*` appears in the docs' include examples
<sup>[[yaml]](#ref-yaml)</sup>. Garnix does build arbitrary
`packages.*-darwin.*` and `checks.*-darwin.*` outputs in practice
<sup>[[obs]](#ref-obs)</sup> — earlier ambiguity was about how exhaustive the
docs were, not whether Darwin works. Verify against `/docs/ci/yaml_config/`
if you hit a specifically odd attr (e.g. cross-system or IFD-heavy) that
won't build.

### Explicit configuration

List one row per `(output-class, arch)` pair the user actually targets.
Example for an `x86_64-linux`-only project:

```yaml
builds:
  include:
    - "packages.x86_64-linux.*"
    - "checks.x86_64-linux.*"
    - "devShells.x86_64-linux.default"
    - "homeManagerModules.default"
  exclude: []
```

Listing an attr that doesn't exist for the target arch will fail evaluation
<sup>[[obs]](#ref-obs)</sup>, so only include arch / output combinations
the flake actually exposes.

### Wildcard discipline — minimise lines without catching too much

Patterns are flake output paths with `*` wildcards
<sup>[[yaml]](#ref-yaml)</sup>. The sweet spot is **one wildcard per
`(output-class, arch)` pair** the flake actually exposes — the form in the
example above (`packages.x86_64-linux.*`, `checks.x86_64-linux.*`, …). It
covers newly-added attrs without editing `garnix.yaml`, while still
bounding what each push builds to the axes you intentionally opted into.

Avoid the two failure modes:

- **Too narrow** — listing each output by name
  (`packages.x86_64-linux.foo`, `packages.x86_64-linux.bar`, …). New
  packages silently drop out of CI until someone remembers to update
  `garnix.yaml`. Reserve this form for deliberately curating a subset,
  e.g. excluding one slow integration package from PR builds.
- **Too broad** — wildcards that span output classes or arches you didn't
  intentionally opt into:
  - `*.x86_64-linux.*` sweeps in `nixosConfigurations`,
    `homeManagerModules`, `legacyPackages`, and anything else with a
    system axis. Fine for a one-attr flake; turns into a silent
    minute-burner as the flake grows.
  - `packages.*.*` builds every arch — multiplies minute consumption
    against the architectures decision the user just made in Step 1.
  - `*` catches everything Garnix can evaluate.

`builds.exclude` is applied **after** include, so a match in both ends up
excluded <sup>[[yaml]](#ref-yaml)</sup>. Use it for the rare carve-out
(one expensive package, one Darwin-broken check) rather than building up
a long deny-list under a too-broad include.

`homeManagerModules.*` is non-systemed; Garnix evaluates rather than builds
it. Eval errors still fail the suite via the umbrella `Evaluate flake.nix`
check <sup>[[obs]](#ref-obs)</sup>.

`builds.include` controls what gets **prebuilt** <sup>[[yaml]](#ref-yaml)</sup>
— that's how packages become substituter hits via `cache.garnix.io`
<sup>[[cache]](#ref-cache)</sup> for downstream Actions.

By default Garnix builds on **every git push**, including PR branches
<sup>[[getting-started]](#ref-getting-started)</sup>. Confirm the default
branch matches where commits land:

```bash
gh api repos/<owner>/<repo> --jq .default_branch
```

### Per-system FOD bring-up: narrow first, expand once hashes are pinned

When the flake exposes a fixed-output derivation with a per-system hash
table (typical pattern: `nodeModulesHash.<sys>` for vendored
`node_modules`, `cargoHash.<sys>` for a Rust workspace, or any FOD whose
output is platform-specific because postinstalls pull native binaries),
only the dev machine's hash is typically pinned at any moment — the
other systems are empty placeholders that Nix resolves to
`sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=` and fails with
`hash mismatch ... specified: sha256-AAA… got: sha256-<actual>`
<sup>[[obs]](#ref-obs)</sup>.

If `garnix.yaml` lists all four arches on the FOD's first push, Garnix
red-Xes three of four on every iteration while you ferry hashes one at
a time. Narrow `builds.include` to the system whose hash is already
pinned, ship that scope-down as its own PR, merge, then expand the
matrix:

1. **Initial prep PR**: `builds.include` covers only the pinned arch
   (e.g. `x86_64-linux`). Merge before pushing the FOD PR.
2. **FOD PR** builds against that scope. Green.
3. **Expansion PR**: add the next arch's row to `builds.include`.
   Garnix fails with `hash mismatch ... got: sha256-<actual>`. Paste
   the `got:` value back into the flake's per-system hash table — fix
   in the commit that introduced the FOD, force-push, repeat.
4. Repeat per arch. Cost is one CI round per arch, but each round is
   a single Garnix build with a single fix, not a four-way red.

This is faster and quieter than running the FOD locally under
`qemu-user` / `nix build --system <foreign>` to discover hashes on a
single machine.

### Actions block

```yaml
actions:
  - on: push                # only `push` documented [yaml]
    run: my-action          # must match an attr in flake.apps.<sys> [yaml]
    withRepoContents: true  # default: false [yaml]
```

`withRepoContents: true` grants the action's script access to the entire git
repo at run time <sup>[[actions]](#ref-actions)</sup>. Without it, only the
closure of the action is available <sup>[[yaml]](#ref-yaml)</sup> — fine for
"phone-home" actions, fatal for anything reading fixtures or templates from
the repo. You can also use Nix path interpolation (e.g. `"${./docs}"`) to
expose only specific subtrees <sup>[[actions]](#ref-actions)</sup>.

A `flakeDir` field at the top level of `garnix.yaml` lets you point at a
flake somewhere other than the repo root <sup>[[yaml]](#ref-yaml)</sup>.

## Wiring the project's test suite into `flake.checks`

Listing `checks.<sys>.*` in `garnix.yaml` is necessary but not sufficient —
those patterns enforce nothing if the flake's `checks` attrset is empty
<sup>[[yaml]](#ref-yaml)</sup>. To get Garnix to gate PRs on the project's
real tests, the test invocation has to live inside a Nix derivation under
`flake.checks.<sys>.<name>`. Each such derivation surfaces in the GitHub
Checks UI as `check <name> [<system>]` <sup>[[obs]](#ref-obs)</sup>.

### The shape

A check is just a derivation that fails the build (non-zero exit, or no
`$out`) when tests fail. The simplest wrapper is `pkgs.runCommand`:

```nix
# flake.nix (sketch)
checks = forAllSystems (system: let
  pkgs = nixpkgs.legacyPackages.${system};
in {
  tests-unit = pkgs.runCommand "tests-unit" {
    nativeBuildInputs = [ pkgs.python3 pkgs.python3Packages.pytest ];
    src = self;
  } ''
    cp -r $src/* .
    pytest tests/unit -v
    touch $out
  '';
});
```

It runs in the Nix sandbox <sup>[[actions]](#ref-actions)</sup> — **no
network, no `/proc` mount, no nested containers**. Tests that need any of
those belong as Actions instead (see "The load-bearing distinction" above).

### Per-language idioms

| Language | Test runner | Idiomatic Nix wrapper |
|---|---|---|
| Python | pytest | `runCommand` with `python3.withPackages (p: [ p.pytest p.<deps> ])`; or `buildPythonPackage` with `nativeCheckInputs = [ pytest ]` |
| Node | jest, vitest, mocha | Hard mode — npm install needs network. Use `pkgs.buildNpmPackage` (lockfile-driven, sandbox-safe) and put the test command in `checkPhase` |
| Go | `go test ./...` | `pkgs.buildGoModule { doCheck = true; }` runs the suite in `checkPhase` automatically — no extra wrapping needed |
| Rust | `cargo test` | `pkgs.rustPlatform.buildRustPackage { doCheck = true; }` — same pattern as Go |
| Clojure | kaocha, clojure.test | clj-nix's `mkCljApp`; tests via a separate `runCommand` invoking `bin/kaocha`. Tag network tests with kaocha metadata so they route to Actions |
| Bash / shell | bats | `runCommand` with `pkgs.bats` and a `bats tests/` invocation |
| Nix itself | `lib.runTests` | `runCommand` that runs `lib.runTests` and asserts the result is `[]` |
| Treefmt / formatters | treefmt-nix | `treefmt-nix` exposes `flake.checks.<sys>.treefmt` directly — wire it once, free formatting check |

For language packaging conventions in flakes (toolchain pinning, override
patterns, deps lockfiles), the sibling `nix-flakes`, `nix-clojure`,
`nix-java` skills cover the project-side details. This skill cares about
the *check derivation* boundary.

### Grouping — when to split, when to merge

Each `flake.checks.<sys>.<name>` becomes one row in the GitHub Checks UI
and one Garnix builder allocation. Both have fixed cost (Nix evaluation +
runner provisioning, ~5–15s per check <sup>[[obs]](#ref-obs)</sup>), so
naive sharding makes the suite slower, not faster.

Default to **one check per logical test partition** — not one per file,
not one per test:

- **Slow vs fast** is the most common useful split: `tests-unit` and
  `tests-integration` (or `tests-fast` / `tests-slow`). Lets a re-run on a
  flake of the slow suite skip re-running the fast one.
- **Per top-level package** in a monorepo, when each package's tests are
  independent and individually meaningful (>30s each). Matches how
  developers run them locally.
- **Per language** if the project is polyglot (e.g. `tests-python`,
  `tests-clojure`). Keeps failures legible.
- **Sandbox vs Action partition** is a hard split: pure tests stay in
  `flake.checks`, network/container tests move to `flake.apps` and run as
  Actions. Use the test runner's existing tag system as the boundary —
  pytest markers, kaocha metadata, Go build tags, Rust `#[cfg(test)]` with
  feature flags — so reclassifying a single test is one annotation, not a
  flake refactor.
- **Formatting and linting** as their own checks (`treefmt`, `clj-kondo`,
  `eslint`, `ruff`) — they fail differently from tests and reviewers want
  to know which kind of red they're looking at.

Don't split when:

- The whole suite finishes in <2 minutes — one `tests` check is fine, the
  UI noise from sharding outweighs any parallelism win.
- The runner already does intra-suite parallelism (`pytest-xdist`,
  `cargo test --jobs N`, `go test ./...`). Splitting at the Nix level on
  top is double-counting and usually a wash.
- Tests share expensive setup (database fixtures, JVM warmup, large
  artifact loads). Splitting forces the setup to repeat per check; merge
  instead.

Do split when:

- One file or module dominates wall time (e.g. a 15-minute suite where
  one file accounts for 12 minutes). Isolate the slow one so flake re-runs
  don't redo cheap work.
- The same code paths run in multiple modes you want surfaced separately
  (e.g. `tests-pg` vs `tests-sqlite`, `tests-jvm17` vs `tests-jvm21`).

Avoid:

- A check per individual test case. Nix won't help; the check-suite UI
  becomes unscannable.
- Sharding by hash bucket (`tests-shard-1` … `tests-shard-N`). Buckets
  obscure what failed, lose the slow-vs-fast signal, and rarely beat the
  test runner's own parallelism.

### Make the check required

Once `flake.checks.<sys>.<name>` is wired up and matches your
`garnix.yaml` `checks.*` include pattern, it appears as `check <name>
[<system>]` on every PR <sup>[[obs]](#ref-obs)</sup>. To actually gate
merges, mark it as required in branch protection:

```bash
# List current required checks
gh api "repos/<owner>/<repo>/branches/<branch>/protection/required_status_checks" \
  --jq '.contexts'
```

Garnix's umbrella roll-up is `All Garnix checks` — making *that* required
gates on the whole suite without naming each check individually
<sup>[[obs]](#ref-obs)</sup>, and survives adding/renaming checks without
re-editing branch protection.

## Step 2 — install the GitHub App

Send the user to https://github.com/apps/garnix-ci/installations/new
<sup>[[app]](#ref-app)</sup>. They choose "All repositories" or per-repo
selection. There is no API or CLI to install a GitHub App on someone else's
behalf <sup>[[obs]](#ref-obs)</sup> — GitHub's permissions flow requires
interactive OAuth.

### Already installed but not scoped to this repo

If Garnix is already installed on the account but the new repo isn't
covered by the install (common with "Only select repositories"), the user
needs to add it. They can't grant access from the API either — same OAuth
constraint <sup>[[obs]](#ref-obs)</sup>.

- **User account installs:** list all installations at https://github.com/settings/installations <sup>[[obs]](#ref-obs)</sup>, then click into "Garnix CI". The per-installation URL is `https://github.com/settings/installations/<install-id>` <sup>[[obs]](#ref-obs)</sup> — but the `<install-id>` is account-specific (e.g. `126117906` for one observed user), so don't share a hardcoded link with someone else; send them through `/settings/installations` and let them click in.
- **Org installs:** the equivalent listing lives at `https://github.com/organizations/<org>/settings/installations` <sup>[[obs]](#ref-obs)</sup>.
- **Web nav path:** `[user avatar] > Settings > Integrations > Applications > Garnix CI` <sup>[[obs]](#ref-obs)</sup>.

On the Garnix CI install page, under **Repository access**, pick either
**All repositories** or **Only select repositories** and add the new repo,
then click **Save** <sup>[[obs]](#ref-obs)</sup>. After saving, push a new
commit (an empty commit is fine — see Step 3) to fire a webhook for the
just-scoped repo; existing commits aren't backfilled
<sup>[[obs]](#ref-obs)</sup>.

If you can't see Garnix check-suites after a push, the install is probably
not scoped to this repo — re-check the user's app installation settings
<sup>[[obs]](#ref-obs)</sup>.

### Detecting install state programmatically

There is no way to ask "is Garnix installed and scoped to this repo?" with a
classic `gh` user PAT. Every endpoint that exposes the answer requires
either a GitHub App JWT or an installation access token
<sup>[[apps-rest]](#ref-apps-rest)</sup>:

| Endpoint | Auth required | Result with classic user PAT |
|---|---|---|
| `GET /user/installations` | App user-to-server token | 403 "must authenticate as a GitHub App" <sup>[[obs]](#ref-obs)</sup> |
| `GET /user/installations/<id>/repositories` | App user-to-server token | 403 even after `gh auth refresh -s read:user,user` <sup>[[obs]](#ref-obs)</sup> |
| `GET /installation/repositories` | Installation access token | 403 "must authenticate with an installation access token" <sup>[[obs]](#ref-obs)</sup> |
| `GET /repos/<owner>/<repo>/installation` | App JWT | 401 "JSON web token could not be decoded" <sup>[[obs]](#ref-obs)</sup> |

The `gh` CLI's "needs the X scope" hint on these 403s is misleading — adding
the scope it suggests still produces a 403, just with a different "must
authenticate as a GitHub App" message. Don't keep chasing scopes.

### Workable monitoring approaches

1. **Push, then probe check-suites for the `garnix-ci` slug.** The only
   API-driven signal a classic user PAT can read:

   ```bash
   scripts/check-garnix-installed.sh <owner>/<repo>
   ```

   Exit 0 + `installed` → Garnix has accepted this commit. Exit 1 +
   `not-installed-or-not-scoped` → either not installed, not scoped to
   this repo, or the webhook hasn't fired yet. If you get the latter
   ~30s after a fresh push, the most likely cause is "installed at the
   user level but this repo isn't selected". Pre-install commits are not
   retroactively built — push an empty commit *after* the install is
   scoped (Step 3) to fire a webhook the new install can see
   <sup>[[obs]](#ref-obs)</sup>.

2. **Background install-watcher.** When you can run a long-lived watcher
   (the harness's Monitor tool, a tmux pane, etc.):

   ```bash
   scripts/watch-install.sh <owner>/<repo> --heartbeat=300
   ```

   Polls the repo's HEAD commit on a 60s cadence; emits `GARNIX_DETECTED
   head=<sha>` on the absent→present transition and exits 0. Emits a
   heartbeat line every 5 minutes by default so the monitor isn't silent
   during a long wait — silence is indistinguishable from a crashed
   watcher <sup>[[obs]](#ref-obs)</sup>. If the user installs but does
   not push, the watcher will stay silent forever; pair it with an
   explicit "tell me when you've installed" instruction or an empty-
   commit retry on a slow cadence (e.g. every 15 min) so installation
   always gets tested.

3. **Have the user confirm in-band.** No automation; they say "installed",
   you push an empty commit and start the per-run monitor (the "Watch
   loop" section below — `scripts/watch-checks.sh`). Faster and more
   reliable when the user is interactive.

4. **Prefilled install URL.**

   ```bash
   scripts/garnix-install-url.sh <owner>/<repo>
   ```

   Emits a one-click `installations/new/permissions?target_id=...&
   repository_ids[]=...` link the user opens. `target_id` is the owner's
   numeric ID; `repository_ids[]` (the `[]` is part of the query-string
   key) prefills the repo selection. The same URL pattern works to *add*
   a repo to an existing installation, not just to create new ones
   <sup>[[obs]](#ref-obs)</sup>.

5. **Don't bother with fine-grained PATs for this.** They expose a
   "GitHub Apps installations" permission category, but the listing
   endpoints remain gated on app-context auth in practice. Treat as
   last resort and verify on a throwaway fine-grained PAT before
   automating around it.

## Step 3 — fire the first build

**Gotcha:** Garnix only builds commits pushed *after* the install webhook
fires <sup>[[obs]](#ref-obs)</sup>. Pre-install commits are not retroactively
picked up <sup>[[obs]](#ref-obs)</sup>. Force a fresh webhook with an empty
commit:

```bash
git commit --allow-empty -m "ci: trigger Garnix build"
git push
```

Once the suite is green you can squash this away if it bothers you (force-push
with lease) <sup>[[obs]](#ref-obs)</sup>.

## Step 4 — the badge (the gotcha that wastes 5 minutes)

The "natural" badge URL renders broken on GitHub:

```markdown
<!-- WRONG — returns Content-Type: application/json; GitHub shows a broken image -->
[![Built with Garnix](https://garnix.io/api/badges/<owner>/<repo>)](https://garnix.io/repo/<owner>/<repo>)
```

The `garnix.io/api/badges/...` endpoint returns a [shields.io endpoint badge](https://shields.io/badges/endpoint-badge)
JSON payload (`{"label", "message", "color", "logoSvg"}`)
<sup>[[obs]](#ref-obs)</sup>, not an SVG. GitHub's image proxy rejects
non-image content types <sup>[[obs]](#ref-obs)</sup>. The official Garnix docs
publish the wrapper form <sup>[[badges]](#ref-badges)</sup>:

```markdown
[![built with garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2F<owner>%2F<repo>)](https://garnix.io/repo/<owner>/<repo>)
```

You can append `&label=<text>` to override the badge label (which is otherwise
empty); shields.io supports the standard endpoint-badge query parameters
<sup>[[shields-endpoint]](#ref-shields-endpoint)</sup>.
`https://garnix.io/repo/<owner>/<repo>` 302s to `app.garnix.io/...`; either
form works as the link target <sup>[[obs]](#ref-obs)</sup>.

> Re-verify the canonical badge URL annually — shields.io has tweaked
> endpoint URL conventions in the past, and the Garnix docs page is the
> authoritative source.

## Step 5 — verify from the CLI

```bash
scripts/verify-cli.sh <owner>/<repo>            # uses HEAD
scripts/verify-cli.sh <owner>/<repo> <sha>      # specific commit
```

Emits a suite-level summary (one JSON row per CI app) followed by
per-check `<conclusion-or-status>\t<name>\t<url>` lines filtered to
Garnix.

A healthy basic flake produces ~10 check-runs in 30–60s
<sup>[[obs]](#ref-obs)</sup>:

- `Evaluate flake.nix` — umbrella eval; fails on syntax/eval errors.
- `package <name> [<system>]` — one per package per arch.
- `check <name> [<system>]` — one per `flake.checks.<sys>.<name>`.
- `devShell <name> [<system>]`.
- `All Garnix checks` — aggregate roll-up.

Each Action posts under **two** check-run names: `app <name>` and
`action <name>` <sup>[[notes]](#ref-notes)</sup>. Same run, two surface names.
The canonical app slug to filter on is `garnix-ci`
<sup>[[obs]](#ref-obs)</sup> — confirmed by the `app.slug` field in
`/check-runs` responses.

## Writing Actions in `nix/garnix.nix`

Convention: keep action script bodies in `nix/garnix.nix`, expose them as
`flake.apps.<sys>.<name>`, and let `garnix.yaml` reference them by name
<sup>[[notes]](#ref-notes)</sup>.

### Skeleton <sup>[[notes]](#ref-notes)</sup>

```nix
# nix/garnix.nix
{ pkgs, self, system ? "x86_64-linux" }:
let
  # The cache.garnix.io URL + key are the official substituter creds [cache].
  setupEnv = ''
    export HOME=$(mktemp -d)
    cd "$PWD"

    export NIX_CONFIG="experimental-features = nix-command flakes
    accept-flake-config = true
    extra-substituters = https://cache.garnix.io
    extra-trusted-public-keys = cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g="
  '';

  # Dependency ordering trick: interpolating ${self.checks...} into the
  # script body creates a real Nix build dependency. The leading '#' makes
  # the line a no-op at script runtime. Garnix won't run an action whose
  # dep build failed.
  sandboxChecksDep = ''
    # Sandbox checks (must succeed before this action runs):
    #   ${self.checks.${system}.tests-unit}
    #   ${self.checks.${system}.tests-integration}
  '';

  prebuiltArtifactsDep = ''
    # Prebuilt and cached:
    #   ${self.packages.${system}.fake-git}
    #   ${self.packages.${system}.babashka}
  '';

  # Diagnostic dump on EXIT. Garnix has no artifact upload, so on failure
  # we cat files into the action log [notes].
  withDiagnostics = name: body: pkgs.writeShellScript name ''
    set -uo pipefail
    cleanup() {
      local rc=$?
      for f in /tmp/test-report.xml /tmp/last-stderr.log; do
        [ -f "$f" ] && { echo "--- $f ---"; cat "$f"; }
      done
      exit $rc
    }
    trap cleanup EXIT

    ${body}
  '';

  myActionScript = withDiagnostics "my-action" ''
    ${sandboxChecksDep}
    ${prebuiltArtifactsDep}
    ${setupEnv}
    export PATH="${pkgs.lib.makeBinPath [ pkgs.git pkgs.coreutils ]}:$PATH"

    ./run-tests.sh
  '';

in {
  apps.my-action = {
    type = "app";
    program = toString myActionScript;
  };
}
```

Two patterns worth memorising <sup>[[notes]](#ref-notes)</sup>: **`${self.X}`
interpolation for dep ordering** and **`trap cleanup EXIT` for log capture**.
Neither is documented upstream — they're field workarounds.

## Action runner constraints — the things that bite <sup>[[notes]](#ref-notes)</sup>

Not in official Garnix docs <sup>[[actions]](#ref-actions)</sup>. They show up
the first time you try to run anything containerised or memory-heavy. All of
these were observed during real-world Garnix Actions usage and may shift if
Garnix's runner changes — re-verify by running a probe action that exercises
the suspected limit.

| Symptom | Cause | Fix | Source |
|---|---|---|---|
| `pasta: open(/dev/net/tun): No such device` | Default rootless networking needs `/dev/net/tun`; sandbox doesn't expose it | Force `slirp4netns` in `containers.conf` | <sup>[[notes]](#ref-notes)</sup> |
| `cgroup: cannot create cgroup ... read-only` | `/sys/fs/cgroup` is read-only | `podman run --cgroups=disabled` | <sup>[[notes]](#ref-notes)</sup> |
| `mount /proc: operation not permitted` | OCI runtime can't mount `/proc` even with cgroups off | Cannot run nested rootless containers — `skip` those tests | <sup>[[notes]](#ref-notes)</sup> |
| `OutOfMemoryError` building large native images | Runner has ~4.5 GB; native-image / GraalVM needs more | Use prebuilt artifact via cache, or skip | <sup>[[notes]](#ref-notes)</sup> |
| `experimental-features` errors on `nix run` | Action's `NIX_CONFIG` doesn't enable them | Set `NIX_CONFIG` in `setupEnv` (above) | <sup>[[notes]](#ref-notes)</sup> |
| `no policy.json file found` from podman | Upstream default isn't shipped | Write your own `policy.json` (see below) | <sup>[[notes]](#ref-notes)</sup> |
| `command not found: git` etc. | `HOME` doesn't exist; PATH is minimal | `export HOME=$(mktemp -d)` and use `makeBinPath` | <sup>[[notes]](#ref-notes)</sup> |
| Cache miss on artifact you "know" Garnix prebuilt | `withRepoContents: true` makes the action's flake input have a different narHash than the prebuilder saw — derivation hash diverges | Either accept the rebuild or restructure so the artifact doesn't depend on `self` | <sup>[[notes]](#ref-notes)</sup> |

### Rootless podman setup (only when you need it) <sup>[[notes]](#ref-notes)</sup>

```nix
e2eToolsPodman = [ pkgs.podman ]
  ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.shadow      # newuidmap, newgidmap
    pkgs.slirp4netns # pasta substitute
  ];

setupPodman = ''
  export XDG_RUNTIME_DIR=$(mktemp -d)

  # No overlayfs in the sandbox; vfs works but is slow.
  export CONTAINERS_STORAGE_CONF=$(mktemp)
  cat > "$CONTAINERS_STORAGE_CONF" <<EOF
  [storage]
  driver = "vfs"
  runroot = "$XDG_RUNTIME_DIR/containers"
  graphroot = "$XDG_RUNTIME_DIR/storage"
  EOF

  mkdir -p "$HOME/.config/containers"
  cat > "$HOME/.config/containers/policy.json" <<EOF
  { "default": [ { "type": "insecureAcceptAnything" } ] }
  EOF
  export CONTAINERS_POLICY="$HOME/.config/containers/policy.json"

  cat > "$HOME/.config/containers/containers.conf" <<EOF
  [network]
  default_rootless_network_cmd = "slirp4netns"
  EOF
'';
```

`podman build` and `podman load` work in this setup. `podman run` does **not**
— the OCI runtime's `/proc` mount fails with EPERM
<sup>[[notes]](#ref-notes)</sup>. Skip tests that need to actually execute
container processes.

**Don't pull in `setupPodman`, `slirp4netns`, `shadow`, or `pkgs.podman`** in
actions that don't run containers. The setup is heavy and runner-specific.

## Action sizing — what to split, what to merge <sup>[[notes]](#ref-notes)</sup>

- **One action per heavyweight test file** when each file has independent
  containers / long setup that benefits from parallelism.
- **Group light tests into one action** if each individual test is
  sub-minute. The fixed cost per Garnix Action (runner provisioning + flake
  eval + JVM/runtime startup) often exceeds the test's runtime.
- **Don't split fast network tests across actions.** Multi-test JVM suites
  share classpath load, dependency cache, and runtime warmup — splitting
  destroys that.
- **Sandbox checks split naturally.** Tag-based partitioning (e.g. Kaocha's
  `:skip-meta [:network]` / `:focus-meta [:network]`) is a clean boundary;
  let it drive the check vs action split.

## Keeping `garnix.yaml` in sync with `nix/garnix.nix` <sup>[[notes]](#ref-notes)</sup>

Two sources of truth (yaml + nix) drift fast. Make `nix/garnix.nix` the
source and have a script `nix eval` it into yaml:

```nix
# flake.nix (selected)
garnixActionNames = eachSystem ({ garnix, ... }: garnix.actionNames);
```

```bash
# scripts/regen-garnix-yaml.sh
mapfile -t actions < <(nix eval --json .#garnixActionNames.x86_64-linux | jq -r '.[]')
for name in "${actions[@]}"; do
  cat <<EOF >> garnix.yaml
  - on: push
    run: ${name}
    withRepoContents: true

EOF
done
```

### Eval-time guardrails <sup>[[notes]](#ref-notes)</sup>

- `assert` that every test file is covered by some action — a new test file
  can't be silently uncovered.
- Expose `actionNames` so external tooling can verify yaml ↔ nix consistency.

```nix
# flake.nix snippet
in
assert lib.assertMsg (ungroupedFiles == [ ])
  "garnix.nix: test files not assigned to any group: ${toString ungroupedFiles}";
{
  # ...flake outputs...
}
```

## Where the runs live in the GitHub UI

Garnix uses the **Checks API** <sup>[[checks-api]](#ref-checks-api)</sup>, not
GitHub Actions. The runs do **not** appear in the Actions tab
<sup>[[obs]](#ref-obs)</sup>. Click into them via:

- Commit page: `https://github.com/<owner>/<repo>/commit/<sha>` <sup>[[obs]](#ref-obs)</sup> — checks panel near the bottom.
- Commits list: `https://github.com/<owner>/<repo>/commits/<branch>` <sup>[[obs]](#ref-obs)</sup> — status icon per row.
- Individual run page: `https://github.com/<owner>/<repo>/runs/<id>` <sup>[[obs]](#ref-obs)</sup>. There is **no** `/runs/` index page (404s) <sup>[[obs]](#ref-obs)</sup>; runs are always scoped to a commit context.
- Inside a PR: the **Checks** tab and the status block at the bottom of the conversation <sup>[[checks-api]](#ref-checks-api)</sup>.
- Full action log (with the diagnostic dump): click through to `app.garnix.io/run/<id>` <sup>[[notes]](#ref-notes)</sup> from the status check link.

## Common setup pitfalls

| Symptom | Cause | Fix | Source |
|---|---|---|---|
| No Garnix check-suite ever appears | App not installed on this repo | User installs at https://github.com/apps/garnix-ci/installations/new | <sup>[[app]](#ref-app)</sup> |
| App installed on the account but new repo not building | Install was scoped to "Only select repositories" and this repo isn't in the set | User goes to https://github.com/settings/installations → Garnix CI → Repository access → add the repo → Save, then pushes a new commit | <sup>[[obs]](#ref-obs)</sup> |
| Suite created but only `semaphore-ci-cd` etc. show, no Garnix | Same as above (other GitHub Apps are unrelated) | Same as above | <sup>[[obs]](#ref-obs)</sup> |
| Check-suite shows `success` but check-runs query is empty | Polling raced a fast (~30s) build between intervals | Lengthen poll window OR also fetch `/check-suites` and trust the suite-level conclusion | <sup>[[obs]](#ref-obs)</sup> |
| Badge image broken on GitHub | Using raw `garnix.io/api/badges/...` (returns JSON) | Wrap through `img.shields.io/endpoint.svg?url=...` | <sup>[[badges]](#ref-badges)</sup> <sup>[[obs]](#ref-obs)</sup> |
| Pre-install commits not built | Garnix only triggers on post-install webhook events | Push an empty commit to fire the webhook | <sup>[[obs]](#ref-obs)</sup> |
| Check is consistently "still running" with no log progress | Likely a silent OOM near the 4.5 GB ceiling | Inspect last cached output; restructure to use prebuilt artifacts | <sup>[[notes]](#ref-notes)</sup> |
| A specific Darwin attr won't build despite being in the include set | The output is gated to a non-Darwin system, requires IFD that the Darwin builder rejects, or simply doesn't exist for that arch | Confirm the attr resolves locally with `nix eval .#packages.<sys>.<name>.outPath`; if it does, file a probe and verify against `/docs/ci/yaml_config/` | <sup>[[yaml]](#ref-yaml)</sup> |
| `curl https://app.garnix.io/build/<id>/log` returns 404, and `WebFetch` on the same URL shows only nav chrome (no build output) | The Garnix build page is a client-side SPA; logs aren't on a stable URL the way GitHub Actions logs are | Go through the GitHub check-run URL, not the Garnix one. `gh api "repos/<owner>/<repo>/commits/<sha>/check-runs" --jq '.check_runs[] \| select(.app.slug=="garnix-ci") \| .html_url'` returns a `github.com/<owner>/<repo>/runs/<run-id>` URL whose page renders server-side. `WebFetch` it to extract `hash mismatch ... got: sha256-…` and similar error text | <sup>[[obs]](#ref-obs)</sup> |

## Watch loop (for autonomous monitoring)

```bash
scripts/watch-checks.sh <owner>/<repo>          # watch HEAD
scripts/watch-checks.sh <owner>/<repo> <sha>    # watch a specific commit
```

Polls `/check-runs` on a 30s cadence, filtered to `app.slug=="garnix-ci"`
<sup>[[obs]](#ref-obs)</sup>. Emits one summary line per state change
(`<name>=<status>[/<conclusion>], ...`). Exits 0 + `all green` when every
check ends in success / neutral / skipped; exits 1 + `failures: <json>`
otherwise. Pipe into a Monitor or background it from a tmux pane.

## Skipping tests on Garnix specifically <sup>[[notes]](#ref-notes)</sup>

```bash
# bats
@test "runs container with nested rootless podman" {
  skip "skipped on Garnix: nested rootless podman blocked by /proc EPERM"
  # ...
}
```

Document the reason inline. Future-you will need it when re-evaluating
whether the constraint still holds.

## What Garnix does not give you

- A standalone web UI listing every build for a repo without going through GitHub. Use `https://garnix.io/repo/<owner>/<repo>` (which redirects to `app.garnix.io`) <sup>[[obs]](#ref-obs)</sup>.
- Per-output skip/include based on commit message tags. The whole `garnix.yaml` include set runs every push <sup>[[yaml]](#ref-yaml)</sup>.
- Free private-repo builds. Free tier is public-only <sup>[[badges]](#ref-badges)</sup> (badges page notes "Badges do not work with private repos"); private repos require a paid plan — verify on `/pricing/`.
- Artifact upload from Actions <sup>[[actions]](#ref-actions)</sup>. Use the **diagnostic dump on EXIT** pattern <sup>[[notes]](#ref-notes)</sup> — that's the only way to surface test outputs into the run log.
- Documented memory/cpu limits <sup>[[actions]](#ref-actions)</sup>. Limits in this skill (~4.5 GB) come from observation <sup>[[notes]](#ref-notes)</sup>, not docs.

## Relative `path:` flake inputs break transitive / Garnix consumption

Garnix builds a flake from an **archived closure** copied to its remote
builder (`nix flake archive` semantics) — not from your working tree. A
relative `path:` flake input (e.g. `inputs.foo.url = "path:../../pkgs"`) is
**not reliably captured in that closure** when the flake is consumed
transitively or via `?dir=`, so the build can fail to resolve the input even
though everything works locally <sup>[[path-inputs]](#ref-path-inputs)</sup>.

### Why it passes locally but breaks on Garnix

Observed on Nix 2.34.7 against `github:nhooey/skillspkgs?dir=sources/combinations`,
whose sub-flake declared `vendored.url = "path:../../pkgs"`
<sup>[[path-inputs]](#ref-path-inputs)</sup>:

- Fetching `github:owner/repo?dir=<subdir>` captures **only `<subdir>`** as the
  flake's `sourceInfo` store path. A relative `path:../../<sibling>` then points
  **outside** that store path — the target does not exist relative to the
  fetched tree.
- `nix flake lock` and `nix eval` **succeed locally anyway**, because the local
  machine resolves the parent repo out-of-band (eval cache / flake registry /
  re-fetch from GitHub). The bug is invisible on the author's machine.
- `nix flake archive` does **not** give the relative-`path:` input its own store
  path in the manifest — its `github:` sub-inputs are captured, but the
  path-input flake source itself is absent from the closure. A builder fed only
  that closure (Garnix's remote builder, or a deep transitive consumer like a
  NUR / aggregator flake) has nothing to resolve `../../<sibling>` against.

So **"green locally, red on Garnix"** is the signature. The same applies to any
consumer that builds from the archived closure rather than your checkout.

### Rule

For any flake or sub-flake meant to be consumed transitively — as a
dependency-of-a-dependency, or via `github:owner/repo?dir=<subdir>` — make every
input **independently fetchable**: use `github:owner/repo?dir=<sibling>`
references for sibling subdirectories instead of relative `path:` inputs, so each
input travels in the closure on its own. Reserve relative `path:` inputs for
flakes consumed **only** directly at the repo root and never transitively
<sup>[[path-inputs]](#ref-path-inputs)</sup>.

## References & verification

Each superscript link in the body resolves to a subsection here. Re-verify
before relying on a fact for a production decision.

<a id="ref-yaml"></a>

### `[yaml]` — garnix.yaml format

- **Source:** https://garnix.io/docs/ci/yaml_config/
- **Last verified:** 2026-04-25 by WebFetch.
- **Re-verify:** Fetch the URL and confirm `builds.include` / `builds.exclude` / `actions[*].on` / `actions[*].run` / `actions[*].withRepoContents` / `flakeDir` are still the documented fields, the default include set still lists `*.x86_64-linux.*`, `defaultPackage.x86_64-linux`, `devShell.x86_64-linux`, `homeConfigurations.*`, `darwinConfigurations.*`, `nixosConfigurations.*`, and the example mentions `packages.aarch64-darwin.*`.

<a id="ref-badges"></a>

### `[badges]` — Garnix build status badges

- **Source:** https://garnix.io/docs/ci/badges/
- **Last verified:** 2026-04-25 by WebFetch.
- **Re-verify:** Fetch the URL; the canonical wrapper is `https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2F<owner>%2F<repo>`. Also confirm `curl -sI 'https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2F<owner>%2F<repo>'` still returns `Content-Type: image/svg+xml`. The note "Badges do not work with private repos" is on the same page.

<a id="ref-cache"></a>

### `[cache]` — `cache.garnix.io` substituter

- **Source:** https://garnix.io/docs/ci/caching/
- **Last verified:** 2026-04-25 by WebFetch.
- **Substituter URL:** `https://cache.garnix.io`
- **Public key:** `cache.garnix.io:CTFPyKSLcx5RMJKfLo5EEPUObbA78b0YQ2DTCJXqr9g=`
- **Re-verify:** Fetch the URL; if the key changes, every action's `NIX_CONFIG` block needs updating.

<a id="ref-actions"></a>

### `[actions]` — Garnix Actions overview

- **Source:** https://garnix.io/docs/actions/
- **Last verified:** 2026-04-25 by WebFetch.
- **Re-verify:** Confirm Actions still: run in a "micro VM with Nix installed", have internet access, support `withRepoContents: true` for full repo access, and support `${./subdir}` interpolation for partial repo access. Memory/cpu limits and `/dev/net/tun` are **not** documented here; if Garnix later publishes them, update the constraints table to cite this URL instead of `[notes]`.

<a id="ref-getting-started"></a>

### `[getting-started]` — build triggers

- **Source:** https://garnix.io/docs/getting-started/
- **Last verified:** 2026-04-25 by WebFetch.
- **Re-verify:** Confirm "every git push to the repo will be picked up by garnix" still appears.

<a id="ref-app"></a>

### `[app]` — Garnix GitHub App

- **Source:** https://github.com/apps/garnix-ci
- **Install URL:** https://github.com/apps/garnix-ci/installations/new
- **Last verified:** 2026-04-25 by visiting (returns 200).
- **Re-verify:** Visit; the slug `garnix-ci` is what shows up in `gh api` `app.slug` fields.

<a id="ref-obs"></a>

### `[obs]` — observed in this session

- **Source:** Recorded during the initial CI bring-up of `nhooey/skillspkgs`, 2026-04-25.
- **Re-verify:** Re-run the original probes:
  - `gh api repos/<owner>/<repo>/commits/<sha>/check-runs --jq '.check_runs[] | select(.app.slug=="garnix-ci")'` on a current commit.
  - `curl -sI https://garnix.io/api/badges/<owner>/<repo>` to confirm the JSON content-type.
  - `curl -sI https://garnix.io/repo/<owner>/<repo>` to confirm the redirect to `app.garnix.io`.
- The "10 check-runs in ~44s" timing is environment-dependent and will drift; treat the count and shape (Evaluate / package / check / devShell / aggregate) as the durable claim.

<a id="ref-notes"></a>

### `[notes]` — author's prior-project notes

- **Source:** Passed in via this conversation, 2026-04-25. **Not** from Garnix's own docs.
- **Re-verify:** Reproduce the behaviour on a fresh Garnix Action run — a probe action that prints memory limits, attempts a `mount /proc`, runs `pasta`, etc. Specifically the `${self.X}` interpolation pattern, `trap cleanup EXIT` log capture, ~4.5 GB memory ceiling, `/dev/net/tun` absence, `/proc` mount EPERM, podman storage/policy/network workarounds, action-sizing trade-offs, the `app <name>` + `action <name>` dual-naming, and the `withRepoContents` narHash drift — all of these would benefit from a probe rerun before trusting them in a new project.

<a id="ref-checks-api"></a>

### `[checks-api]` — GitHub Checks API

- **Source:** https://docs.github.com/en/rest/checks
- **Last verified:** 2026-04-25 by URL pattern matching documented endpoints (`/repos/{owner}/{repo}/commits/{ref}/check-suites`, `/check-runs`).
- **Re-verify:** Fetch the endpoint reference page if call signatures change.

<a id="ref-shields-endpoint"></a>

### `[shields-endpoint]` — shields.io endpoint badge format

- **Source:** https://shields.io/badges/endpoint-badge
- **Last verified:** 2026-04-25.
- **Re-verify:** Fetch the URL if endpoint URL conventions change (e.g., `endpoint.svg` vs `endpoint`).

<a id="ref-apps-rest"></a>

### `[apps-rest]` — GitHub Apps REST API authentication

- **Source:** https://docs.github.com/en/rest/apps/installations
- **Last verified:** 2026-04-27.
- **Re-verify:** Fetch the URL; confirm the listing endpoints (`/user/installations`, `/user/installations/{id}/repositories`, `/installation/repositories`, `/repos/{owner}/{repo}/installation`) still require GitHub App authentication (JWT or installation token), not user PATs. If GitHub adds a fine-grained PAT scope that genuinely unlocks the listing endpoints, update Workable monitoring approaches #5 to a positive recommendation.

<a id="ref-path-inputs"></a>

### `[path-inputs]` — relative `path:` flake inputs under transitive / archive consumption

- **Sources:**
  - NixOS/nix#12438 — `nix flake archive` errors fetching relative `path` inputs (2.26 regression): https://github.com/NixOS/nix/issues/12438
  - NixOS/nix#14762 — relative path input in a nested subflake resolves against the wrong source tree: https://github.com/nixos/nix/issues/14762
  - In-session empirical test (2026-06-03) against `github:nhooey/skillspkgs?dir=sources/combinations` (`vendored.url = "path:../../pkgs"`) on Nix 2.34.7: the `?dir=` `sourceInfo` captured only the subdir; `nix flake archive --dry-run --json` omitted a store `path` for the relative-path input node; local `nix eval` of the dependent output nonetheless succeeded via out-of-band refetch.
- **Last verified:** 2026-06-03 (in-session empirical test + WebSearch of the two nix issues).
- **Re-verify:** The decisive test is to push a throwaway consumer flake that takes such a sub-flake as an input to a Garnix-enabled repo and confirm the eval/build fails on the builder — the in-session work *inferred* this from the archived closure but did **not** push to Garnix. Locally: `nix flake metadata 'github:owner/repo?dir=<subdir>' --json` and confirm the relative `path:` target lies outside the reported `path`; `nix flake archive --dry-run --json` and confirm the path-input node has no `path` of its own. Also check whether the two nix issues are fixed in your Nix version, which may change the behavior.
