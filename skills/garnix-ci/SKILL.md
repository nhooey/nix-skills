---
name: garnix-ci
description: Wire up Garnix CI for a Nix flake on GitHub. Covers the basics (garnix.yaml, GitHub App install, badge wrapper, gh CLI verification) and the advanced surface (Actions vs sandbox checks, rootless podman in actions, runner constraints, action sizing, yaml-from-nix regeneration). Use when adding CI to a flake, fixing a broken Garnix badge, writing Actions that need network or containers, or debugging mysterious runner constraints.
---

# Garnix CI for a Nix flake

[Garnix](https://garnix.io) is a hosted Nix builder + binary cache that
registers as a GitHub App. It builds the flake outputs you tell it to (caching
via `cache.garnix.io` <sup>[[cache]](#ref-cache)</sup>), runs `nix flake check`
derivations as GitHub status checks, and runs flake `apps` as **Garnix
Actions** with network and tools <sup>[[actions]](#ref-actions)</sup>.
Surfaces results via the GitHub Checks API
<sup>[[checks-api]](#ref-checks-api)</sup> — no `.github/workflows/` file.

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

1. Drop a `garnix.yaml` at repo root with explicit include patterns <sup>[[yaml]](#ref-yaml)</sup>.
2. User installs the [Garnix GitHub App](https://github.com/apps/garnix-ci/installations/new) on the repo <sup>[[app]](#ref-app)</sup> (you cannot do this for them <sup>[[obs]](#ref-obs)</sup>).
3. Push a commit *after* the install. Pre-install commits are not retroactively built <sup>[[obs]](#ref-obs)</sup>.
4. Add the badge using the **shields.io endpoint wrapper** <sup>[[badges]](#ref-badges)</sup> (raw `garnix.io/api/badges/...` returns JSON, not SVG <sup>[[obs]](#ref-obs)</sup>).
5. Verify with `gh api repos/<owner>/<repo>/commits/<sha>/check-suites` and `/check-runs` <sup>[[checks-api]](#ref-checks-api)</sup>.

For Actions (network/containers/long-running scripts), see "Writing Actions"
below.

## Step 1 — `garnix.yaml`

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
<sup>[[yaml]](#ref-yaml)</sup>. The exact builder coverage for Darwin attrs vs
Linux attrs is not spelled out in the public docs — re-verify against
`/docs/ci/yaml_config/` if your project relies on actual aarch64-darwin or
x86_64-darwin builds rather than just evaluating Darwin configurations.

### Explicit configuration

```yaml
builds:
  include:
    - "packages.x86_64-linux.*"
    - "packages.aarch64-linux.*"
    - "checks.x86_64-linux.*"
    - "checks.aarch64-linux.*"
    - "devShells.x86_64-linux.default"
    - "devShells.aarch64-linux.default"
    - "homeManagerModules.default"
  exclude: []
```

A coarser `'*.x86_64-linux.*'` works too if you want everything for a system
<sup>[[yaml]](#ref-yaml)</sup>. Patterns are flake output paths with `*`
wildcards. `builds.exclude` is applied **after** include, so a match in both
ends up excluded <sup>[[yaml]](#ref-yaml)</sup>.

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

## Step 2 — install the GitHub App

Send the user to https://github.com/apps/garnix-ci/installations/new
<sup>[[app]](#ref-app)</sup>. They choose "All repositories" or per-repo
selection. There is no API or CLI to install a GitHub App on someone else's
behalf <sup>[[obs]](#ref-obs)</sup> — GitHub's permissions flow requires
interactive OAuth.

If you can't see Garnix check-suites after a push, the install is probably
not scoped to this repo — re-check the user's app installation settings
<sup>[[obs]](#ref-obs)</sup>.

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
SHA=$(git rev-parse HEAD)
REPO=<owner>/<repo>

# Suite-level summary (one row per CI app)
gh api "repos/$REPO/commits/$SHA/check-suites" \
  --jq '.check_suites[] | {app: .app.slug, status, conclusion}'

# Per-check detail (filter to Garnix)
gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" \
  --jq '.check_runs[] | select(.app.slug=="garnix-ci")
        | "\(.conclusion // .status)\t\(.name)\t\(.html_url)"'
```

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
| Suite created but only `semaphore-ci-cd` etc. show, no Garnix | Same as above (other GitHub Apps are unrelated) | Same as above | <sup>[[obs]](#ref-obs)</sup> |
| Check-suite shows `success` but check-runs query is empty | Polling raced a fast (~30s) build between intervals | Lengthen poll window OR also fetch `/check-suites` and trust the suite-level conclusion | <sup>[[obs]](#ref-obs)</sup> |
| Badge image broken on GitHub | Using raw `garnix.io/api/badges/...` (returns JSON) | Wrap through `img.shields.io/endpoint.svg?url=...` | <sup>[[badges]](#ref-badges)</sup> <sup>[[obs]](#ref-obs)</sup> |
| Pre-install commits not built | Garnix only triggers on post-install webhook events | Push an empty commit to fire the webhook | <sup>[[obs]](#ref-obs)</sup> |
| Check is consistently "still running" with no log progress | Likely a silent OOM near the 4.5 GB ceiling | Inspect last cached output; restructure to use prebuilt artifacts | <sup>[[notes]](#ref-notes)</sup> |
| Darwin attrs go unbuilt despite being in the include set | Builder coverage for Darwin systems may be partial; docs are ambiguous | Verify against `/docs/ci/yaml_config/` and a probe build before depending on it | <sup>[[yaml]](#ref-yaml)</sup> |

## Watch-loop snippet (for autonomous monitoring)

```bash
SHA=$(git rev-parse HEAD); REPO=<owner>/<repo>
prev=""
while true; do
  runs=$(gh api "repos/$REPO/commits/$SHA/check-runs?per_page=100" \
    --jq '[.check_runs[] | select(.app.slug=="garnix-ci")
           | {name, status, conclusion}]' 2>/dev/null || echo "[]")
  count=$(jq 'length' <<<"$runs")
  [ "$count" = "0" ] && { sleep 30; continue; }
  summary=$(jq -c -S . <<<"$runs")
  [ "$summary" != "$prev" ] && {
    jq -r '[.[] | "\(.name)=\(.status)\(if .conclusion then "/\(.conclusion)" else "" end)"]
           | join(", ")' <<<"$runs"
    prev=$summary
  }
  pending=$(jq '[.[] | select(.status != "completed")] | length' <<<"$runs")
  [ "$pending" = "0" ] && {
    fails=$(jq -c '[.[] | select(.conclusion != "success" and .conclusion != "neutral" and .conclusion != "skipped")]' <<<"$runs")
    [ "$(jq length <<<"$fails")" = "0" ] && echo "all green" || echo "failures: $fails"
    break
  }
  sleep 30
done
```

Filter on `app.slug == "garnix-ci"` <sup>[[obs]](#ref-obs)</sup> — that's the
canonical app slug; don't guess others.

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
