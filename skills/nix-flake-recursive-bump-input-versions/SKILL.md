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
nix flake metadata --json | jq -r '
  .locks.nodes | to_entries[] |
  select(.value.locked.owner == "nhooey") |
  [.key, .value.locked.repo, .value.locked.rev,
   (.value.original.ref // "HEAD")] | @tsv
'
```

Replace the `select(...)` clause with whatever predicate the user
chose. The four returned columns — key, repo, rev, ref — are
everything the rest of the recipe consumes.

## 2. Discover what's behind

For each filtered input, query GitHub for the tip of its pinned branch:

```sh
while IFS=$'\t' read -r key repo rev ref; do
  head=$(gh api "repos/$OWNER/$repo/commits/$ref" --jq .sha)
  [ "$head" != "$rev" ] && printf '%s\t%s\t%s\t%s\n' "$key" "$repo" "$rev" "$head"
done < <(...filter recipe above...)
```

For each behind-input, fetch the commit range so the user sees what
will land:

```sh
gh api "repos/$OWNER/$repo/compare/$rev...$head" \
  --jq '.commits[] | "\(.sha[0:10])  \(.commit.author.date[0:10])  \(.commit.message | split("\n")[0])"'
```

## 3. Classify direct vs transitive

A node is **direct** if it appears under `.locks.nodes.root.inputs`,
**transitive** otherwise. Walk the `inputs` edges to recover ancestry:

```sh
nix flake metadata --json | jq -r '
  def parents(target):
    .locks.nodes | to_entries[] |
    select(.value.inputs[]? == target) | .key;
  .locks.nodes | to_entries[] |
  select(.value.locked.owner == "nhooey") |
  .key as $k | "\($k): \([parents($k)] | join(", "))"
'
```

The parents-per-node output tells you which consumer flake to bump
first — leaves of the dependency tree go first, roots last.

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
cd "$CONSUMER_REPO"
git fetch --quiet origin
git checkout -b "$BRANCH" origin/master
nix flake update $INPUTS_TO_BUMP
nix flake check                       # gate
git add flake.lock
git commit -m "$SUBJECT" -m "$BODY"
git push -u origin "$BRANCH"
gh pr create --title "$SUBJECT" --body "$(echo "$BODY" | fmt -w 2500)"
```

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
nix flake metadata --json | jq -r '
  .locks.nodes | to_entries[] |
  select(.value.locked.owner == "nhooey") |
  .key as $k | $k + " " + .value.locked.rev[0:10]
'
# cross-check each against: gh api repos/$OWNER/<repo>/commits/<ref>
```

Any remaining mismatch indicates a chain hop the plan missed — surface
it to the user rather than declaring success.

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
