---
name: nix-flake-recursive-bump-input-versions
description: Recursively bump every flake input matching a user-supplied filter (owner, org, name pattern, branch ref) across a multi-repo lock tree. Compares each locked rev to GitHub HEAD via `gh api`, classifies behind-inputs as direct or transitive, then drives a leaves-first cascade of `nix flake update <input>` PRs — one per consumer flake, each blocked on the merged tip of the one below. Use when the user says "bump versions", "refresh the lock", "propagate the change up the chain", or when you notice a locked rev behind upstream during unrelated work. Pair with `github-pr-mirrors-commit`, `github-pr-watcher`, and `git-commit-message-format`.
---

# Recursive flake-input version bumps

When a flake aggregates other flakes you own — directly **and**
transitively — keeping the lock current is a multi-repo workflow, not
a single `nix flake update`. This skill is the recipe for that
workflow: filter the lock graph down to "inputs I control", check each
against upstream HEAD, classify direct vs transitive, and cascade
lock-bump PRs leaves-first.

For generic single-flake authoring conventions (input pinning, `inherit`
vs `with`, `flake-parts`, etc.) see the companion `nix-flakes` skill.
This skill assumes those conventions are already in place; it focuses on
the cross-repo maintenance loop on top of them.

## Helper scripts

The deterministic steps in this recipe live in `scripts/` next to this
file. Each script takes `--help` for usage. Most assume `gh`, `jq`,
`nix`, and `git` on `PATH`; `run-bump-pull-request.sh` also needs nix
≥2.19 and `fmt`.

**Invocation path.** Examples in this file write the script paths as
`scripts/<name>.sh` for brevity, but the working directory at invocation
is usually the *user's flake repo* — not this skill's install dir. Prefix
each invocation with the skill's installed directory (`$CLAUDE_PLUGIN_ROOT`
when running under a plugin, or `~/.claude/skills/nix-flake-recursive-bump-input-versions`
under a user-level install). The scripts self-locate via `$BASH_SOURCE` so
once invoked with the right absolute path, the cross-script calls between
them resolve correctly.

| Script | Purpose | Steps below |
| --- | --- | --- |
| `list-filtered-inputs.sh` | Apply a jq predicate to the lock graph; emit TSV `key owner repo rev ref` per matching input | §1 |
| `find-behind-inputs.sh` | Wrap the lister + `gh api .../commits/$ref` per input's *own* owner; emit TSV `key owner repo rev head ref` for behind inputs (head=`UNRESOLVED` for refs we couldn't query) | §2 |
| `classify-direct-vs-transitive.sh` | Walk `inputs` edges (including `follows`-style array edges) to surface each node's parents (`root` parent ⇒ direct) | §3 |
| `run-bump-pull-request.sh` | Per-PR execution dance: checkout / `nix flake update` / `flake check` / commit / push / `gh pr create --base "$BASE"`; preflight checks nix ≥2.19 and a free `$BRANCH` | §5 |
| `verify-cascade-complete.sh` | Re-run the behind-input scan after the cascade lands; exit 0 + `all green` or exit 1 + remaining mismatches (UNRESOLVED rows count as still-behind) | §8 |

## On load — decide whether to act

When this skill is invoked, treat it as a request to act on the current
repo, not just to recite conventions. Inventory the working directory:

```sh
git ls-files '*flake.lock' '**/flake.lock'
# also check untracked, in case the user is mid-creation:
git ls-files -o --exclude-standard '*flake.lock' '**/flake.lock'
```

Then:

- **No `flake.lock` found → bail.** Print a one-liner saying there is
  no flake here and exit. Don't scaffold; that's the `nix-flakes`
  skill's job.
- **One or more `flake.lock` files found → proceed.** Ask the user for
  two things (or accept from prior context):

  1. **Filter predicate.** A jq expression evaluated against each lock
     node's `value`. Defaults to "owner equals the GitHub user the
     agent is authenticated as" — derive it from `gh api user --jq
     .login`. Examples in the "Filter recipe library" section below.
  2. **Optional explicit branch overrides.** Per-input ref pinning for
     inputs whose `original.ref` is missing in the lock or out-of-band
     (e.g., a fork branch only the user knows about).

- **`gh` not authenticated** (`gh auth status` non-zero) → bail with a
  clear message. The rest of the recipe needs the GitHub API.

The decisions are baked into this skill's behaviour:

- **One PR per consumer flake**, bundling every behind-input in that
  consumer into a single bump.
- **Wait for human merge** between PRs in the chain. No
  `gh pr merge --auto`.
- **No CLI wrapper.** The recipe is shell-driven from the agent
  session.

## 1. Filter the lock graph

```sh
scripts/list-filtered-inputs.sh '<jq predicate against each .value>'
```

The script defaults the predicate to `.locked.owner == "<gh login>"` if
none is passed (the `<gh login>` is derived at runtime via `gh api user
--jq .login`). Emits TSV `key owner repo rev ref` per matching input —
the five columns the rest of the recipe consumes. See the "Filter recipe
library" below for predicate examples.

## 2. Discover what's behind

For each filtered input, query GitHub for the tip of its pinned branch:

```sh
scripts/find-behind-inputs.sh '<predicate>'
```

Wraps step 1 and queries `gh api repos/<owner>/<repo>/commits/<ref>` per
input — using **each input's own `.locked.owner`** so predicates that
match multiple owners work. Set `OWNER=<owner>` in env only to *override*
the per-input owner (e.g. when chasing forks under a different account).
Emits TSV `key owner repo rev head ref` for behind inputs and inputs
whose ref couldn't be resolved (those get `head=UNRESOLVED`; the warning
explaining why is on stderr).

For each behind-input, fetch the commit range so the user sees what will
land. Variables below come from the TSV row of the input being enriched —
they are not exported by `find-behind-inputs.sh`; the agent feeds them in
per call:

```sh
gh api "repos/$owner/$repo/compare/$rev...$head" \
  --jq '.commits[] | "\(.sha[0:10])  \(.commit.author.date[0:10])  \(.commit.message | split("\n")[0])"'
```

(Kept inline because per-input enrichment is ad-hoc — wrap further only
if you find yourself doing it many times.)

## 3. Classify direct vs transitive

A node is **direct** if it appears under `.locks.nodes.root.inputs`,
**transitive** otherwise.

```sh
scripts/classify-direct-vs-transitive.sh '<predicate>'
```

Emits `<key>: <parent1>, <parent2>, ...` per matching node. `root` in
the parent list means the node is a direct input; an empty parent list
means the node is unreferenced. Leaves of the dependency tree go first
in the cascade, roots last.

## 4. Plan the cascade — leaves first

For each behind-input:

- **Direct** → bumps in this repo only. 1 PR.
- **Transitive via consumer X** → bump in X first, then in this repo.
  2 PRs (or N+1 hops for deeper trees).

Multiple inputs behind in the same consumer share one PR. Example
shape: a single PR in `consumer-x` that bumps `lib-a`, `lib-b`, and
`lib-c` together — three inputs, one PR.

Before executing anything, print a **PR plan table** and ask the user
for go/no-go:

```
| # | consumer       | branch                        | inputs to bump          | blocked on |
| - | -------------- | ----------------------------- | ----------------------- | ---------- |
| 1 | lib-a          | bump-flake-skills             | flake-skills            | —          |
| 2 | consumer-x     | bump-lib-a-lib-b-lib-c        | lib-a, lib-b, lib-c     | PR #1      |
| 3 | aggregator     | bump-consumer-x               | consumer-x              | PR #2      |
```

## 5. Per-PR execution loop

For each PR in the plan:

```sh
CONSUMER_REPO=<path> BRANCH=<topic> BASE=<default-branch> \
  SUBJECT='Bump <inputs>' BODY='<paragraphs>' \
  scripts/run-bump-pull-request.sh <input1> [<input2> ...]
```

The script runs the deterministic `git fetch` → `checkout -b` →
`nix flake update` → `nix flake check` → `commit` → `push` →
`gh pr create --base "$BASE"` chain, failing fast on any step. The
per-PR judgment calls (branch name, base branch, subject, body, which
inputs to bump together) are passed in as env / args. PR URL is printed
on stdout.

Preflight: the script requires nix ≥2.19 (older nix silently ignores
positional `nix flake update <input>` args), and fails fast if
`$BRANCH` already exists locally — typical when retrying a half-finished
run. Recovery is `git -C "$CONSUMER_REPO" branch -D "$BRANCH"` and
re-invoke.

**Wait for green checks + merge before the next PR** in the chain.
Use the `github-pr-watcher` skill's Monitor pattern to react to
check-runs, comments, and the merge event in one polling loop.

## 6. Commit + PR text

Follow `git-commit-message-format` and `github-pr-mirrors-commit`:

- **Subject:** `Bump <input1>, <input2>, <input3>` (alphabetical).
- **Body:** one paragraph per input, **blank line between paragraphs**.
  `fmt -w 2500` collapses adjacent non-empty lines — without the blank
  line, three paragraphs become one wall of text in the PR body.
- **Each paragraph:** `<input>: <PR number(s)> — <what changed>`,
  linking back to the upstream PR(s) that landed in the consumer.

## 7. Edge cases

| Case | Handling |
| --- | --- |
| **Non-default branch** (e.g., fork branch like `gradle2nix`'s `v2_bugfix-remove-param-console-plain`) | Read `original.ref` from the lock; use that as the GitHub API ref. Don't assume `HEAD`. |
| **Fork branch the user rebases + force-pushes** | The new tip is fine to lock — no upstream PR exists for that input. Detect by reading `original.ref` and checking if the locked rev is *unreachable* from `origin/<ref>` (force-push happened). Skip "find merging PR" enrichment in that case. |
| **Input behind, but its consumer's lock already points at HEAD** | (Rare.) Treat the consumer as up-to-date; only bump this repo. |
| **Filter matches nothing** | Report and exit. Don't open a no-op PR. |
| **`gh` not authenticated** | Detect early (`gh auth status`), bail with a clear message. |
| **`narHash` mismatch after `flake update`** | Surface the mismatch, don't silently proceed. |

## 8. Final verification

After the last PR in the chain merges, re-check that every filtered
input is now at upstream HEAD:

```sh
OWNER=<github-owner> scripts/verify-cascade-complete.sh '<predicate>'
```

Exits 0 + `all green` on a clean cascade. Exits 1 + one line per still-
behind input otherwise — surface those to the user rather than declaring
success; they indicate a chain hop the plan missed.

## Filter recipe library

| Goal | jq predicate (against each node's `.value`) |
| --- | --- |
| All your repos | `.locked.owner == "<your-login>"` |
| Specific org | `.locked.owner == "<org>"` |
| Repos by name pattern | `.locked.repo \| startswith("internal-")` |
| Repos on a specific branch | `.original.ref == "release-2026"` |
| Forks pinned to non-default branches | `.original.ref != null` |
| Everything except a denylist | `.locked.owner == "<you>" and (.locked.repo \| IN("frozen", "archived") \| not)` |

## Companion skills

- **`nix-flakes`** — generic flake conventions this skill builds on.
- **`github-pr-mirrors-commit`** — title/body discipline + REST PATCH
  on amend (since `gh pr edit` doesn't always work).
- **`github-pr-watcher`** — Monitor loop for state, check-runs, and
  comments while waiting for a PR to merge.
- **`git-commit-message-format`** — 72-col subject, blank-line
  paragraph discipline in the body.
- **`git-cleanup-merged-branches`** — post-cascade local + remote
  branch deletion.
- **`git-push-force-safely`** — for fork branches that need a rebase
  before the cascade (rare).
