---
name: nix-flake-recursive-bump-input-versions
description: Bump every flake input that matches a filter (owner, org, name pattern, branch ref) across a tree of flakes in several repos. Compares each locked rev to the tip of its branch on GitHub, sorts the inputs that are behind into direct and transitive, then opens one `nix flake update` pull request per consumer flake, leaves first, each waiting for the one below it to merge. Bundled scripts do the filtering, the comparison, the classification, each bump and the final check. Use when the user says "bump versions", "refresh the lock" or "propagate the change up the chain", or when a locked rev turns out to be behind upstream during other work.
allowed-tools:
  - 'Bash(gh api *)'
---

# Recursive flake-input version bumps

When a flake aggregates other flakes you own, directly and transitively, keeping its lock current takes a pull request in each repo along the chain, not one `nix flake update`. The recipe:

1. Filter the lock graph down to the inputs you control.
2. Check each against the tip of its branch on GitHub.
3. Classify each behind input as direct or transitive.
4. Cascade lock-bump pull requests, leaves first.

The single-flake conventions this assumes (input pinning, `follows`, `flake-parts`) are in `nix-flakes`.

## Helper scripts

The deterministic steps are scripts in this skill's `scripts/` folder. Each takes `--help`. They need `gh`, `jq`, `nix` and `git` on `PATH`; `run-bump-pull-request.sh` also needs Nix 2.19 or later and `awk`.

Run them by absolute path, `"${CLAUDE_SKILL_DIR}/scripts/<name>.sh"` (an agent that doesn't substitute that variable uses the skill's installed folder), from the flake repo being bumped, since they read the flake in the working directory. They find each other relative to their own path.

| Script                             | Purpose                                                                                                                                                       | Step |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- |
| `list-filtered-inputs.sh`          | Apply a jq predicate to the lock graph; emit TSV `key owner repo rev ref` per matching input                                                                  | 1    |
| `find-behind-inputs.sh`            | Run the lister and query `gh api .../commits/$ref` under each input's own owner; emit TSV `key owner repo rev head ref` per behind input (`head=UNRESOLVED` when the ref can't be queried) | 2    |
| `classify-direct-vs-transitive.sh` | Walk `inputs` edges, `follows` arrays included, to list each node's parents (`root` among them means direct)                                                  | 3    |
| `run-bump-pull-request.sh`         | One bump: fetch, branch, `nix flake update`, `nix flake check`, commit, push, `gh pr create --base "$BASE"`; checks Nix ≥2.19 and that `$BRANCH` is free first | 5    |
| `verify-cascade-complete.sh`       | Re-run the behind-input scan after the cascade; exit 0 with `all green`, or 1 with the remaining mismatches (`UNRESOLVED` rows count as behind)                | 8    |

## On load: decide whether to act

Invoking this skill is a request to act on the current repo. Inventory its lock files first:

```sh
git ls-files '*flake.lock' '**/flake.lock'
git ls-files -o --exclude-standard '*flake.lock' '**/flake.lock'   # untracked, in case one is new
```

Then:

- **No `flake.lock`:** say there is no flake here and stop. Scaffolding one is `nix-flakes`' job.
- **`gh` not authenticated** (`gh auth status` exits non-zero): say so and stop; every later step needs the GitHub API.
- **One or more `flake.lock` files:** get two things from the user, or from earlier context:
  1. **Filter predicate:** a jq expression evaluated against each lock node's `value`. The default is "owner equals the GitHub user `gh` is authenticated as" (`gh api user --jq .login`). Examples are in [Filter recipe library](#filter-recipe-library).
  2. **Branch overrides, optional:** a ref per input whose `original.ref` is missing from the lock or out of date, such as a fork branch only the user knows about.

Fixed choices:

- **One pull request per consumer flake**, bundling every behind input in that consumer.
- **A person merges each pull request** before the next one in the chain starts. No `gh pr merge --auto`.
- **The agent drives the recipe** from its session with the scripts; there is no wrapper CLI.

## 1. Filter the lock graph

```sh
"${CLAUDE_SKILL_DIR}/scripts/list-filtered-inputs.sh" '<jq predicate against each .value>'
```

With no predicate it uses `.locked.owner == "<gh login>"`. It emits TSV `key owner repo rev ref` per matching input, the five columns the later steps read.

## 2. Discover what's behind

```sh
"${CLAUDE_SKILL_DIR}/scripts/find-behind-inputs.sh" '<predicate>'
```

Runs step 1, then queries `gh api repos/<owner>/<repo>/commits/<ref>` for each input under its own `.locked.owner`, so a predicate matching several owners works. `OWNER=<owner>` in the environment replaces every input's owner; use it only for forks under one other account. It emits TSV `key owner repo rev head ref` for inputs that are behind and for inputs whose ref couldn't be resolved (`head=UNRESOLVED`, with the reason on stderr).

For each behind input, show the user what will land. Fill the variables from that input's TSV row; the script doesn't export them:

```sh
gh api "repos/$owner/$repo/compare/$rev...$head" \
  --jq '.commits[] | "\(.sha[0:10])  \(.commit.author.date[0:10])  \(.commit.message | split("\n")[0])"'
```

## 3. Classify direct vs transitive

A node is **direct** if it appears under `.locks.nodes.root.inputs`, and **transitive** otherwise.

```sh
"${CLAUDE_SKILL_DIR}/scripts/classify-direct-vs-transitive.sh" '<predicate>'
```

Emits `<key>: <parent1>, <parent2>, ...` per matching node. `root` among the parents means the node is a direct input; an empty list means nothing references it.

## 4. Plan the cascade, leaves first

For each behind input:

- **Direct:** bump it in this repo only. 1 pull request.
- **Transitive through consumer X:** bump it in X first, then bump X in this repo. 2 pull requests, or one per hop in a deeper tree.

Inputs behind in the same consumer share one pull request: one pull request in `consumer-x` bumps `lib-a`, `lib-b` and `lib-c` together.

Before running anything, show the plan as a table and ask the user for go or no-go:

| #   | Consumer   | Branch                 | Inputs to bump      | Blocked on |
| --- | ---------- | ---------------------- | ------------------- | ---------- |
| 1   | lib-a      | bump-flake-skills      | flake-skills        | —          |
| 2   | consumer-x | bump-lib-a-lib-b-lib-c | lib-a, lib-b, lib-c | PR #1      |
| 3   | aggregator | bump-consumer-x        | consumer-x          | PR #2      |

## 5. Per-pull-request loop

For each pull request in the plan:

```sh
CONSUMER_REPO=<path> BRANCH=<topic> BASE=<default-branch> \
  SUBJECT='Bump <inputs>' BODY='<paragraphs>' \
  "${CLAUDE_SKILL_DIR}/scripts/run-bump-pull-request.sh" <input1> [<input2> ...]
```

The script runs `git fetch`, `checkout -b`, `nix flake update`, `nix flake check`, `commit`, `push` and `gh pr create --base "$BASE"`, stopping at the first failure, and prints the pull request's URL. The judgement calls (branch name, base branch, subject, body, which inputs go together) come in as environment variables and arguments.

Before it starts, it checks for Nix 2.19 or later, since older Nix ignores the input names given to `nix flake update` and updates every input. It also stops if `$BRANCH` already exists locally, as it does after a half-finished run: delete it with `git -C "$CONSUMER_REPO" branch -D "$BRANCH"` and run it again.

Wait for green checks and the merge before starting the next pull request in the chain. Arm the Monitor from `github-workflow-pull-request-watcher` to follow check runs, comments and the merge in one loop.

## 6. Commit and pull request text

Follow `git-hygiene-commit-message-format` and `github-hygiene-pull-request-mirrors-commit`:

- **Subject:** `Bump <input1>, <input2>, <input3>`, the inputs in alphabetical order.
- **Body:** one paragraph per input, with a blank line between paragraphs. The script joins the lines of each paragraph for the pull request body with `awk` in paragraph mode (`RS=""`); without the blank lines, every paragraph becomes one block of text. It uses `awk` rather than `fmt -w`, because a dev shell's `fmt` command can shadow coreutils `fmt` and blank the body.
- **Each paragraph:** `<input>: <pull request number(s)> — <what changed>`, linking to the upstream pull requests that landed in that input.

After amending a bump commit behind an open pull request, re-sync the title and body as `github-hygiene-pull-request-mirrors-commit` says; GitHub doesn't update them itself.

## 7. Edge cases

| Case                                                                                                          | Handling                                                                                                                                                                                                                        |
| ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Non-default branch, such as a fork branch like `gradle2nix`'s `v2_bugfix-remove-param-console-plain`          | Read `original.ref` from the lock and use it as the GitHub API ref, not `HEAD`.                                                                                                                                                 |
| Fork branch the user rebases and force-pushes                                                                 | Lock the new tip; no upstream pull request exists for it. A locked rev that is unreachable from `origin/<ref>` means a force-push happened; skip looking up the pull request that merged it. `git-hygiene-push-force-safely` covers the rebase itself. |
| Input behind, but its consumer's lock already points at the tip                                               | Treat the consumer as current and bump only this repo.                                                                                                                                                                          |
| Filter matches nothing                                                                                        | Say so and stop. Don't open an empty pull request.                                                                                                                                                                              |
| `narHash` mismatch after `nix flake update`                                                                   | Show the mismatch to the user; go on only once they say how.                                                                                                                                                                     |

## 8. Final verification

After the last pull request in the chain merges, check that every filtered input is at its branch tip:

```sh
"${CLAUDE_SKILL_DIR}/scripts/verify-cascade-complete.sh" '<predicate>'
```

It exits 0 with `all green` on a clean cascade, and 1 with one line per input still behind otherwise. Show those to the user instead of declaring success: each is a hop the plan missed. Then clean up the merged bump branches with `git-workflow-tidy-branches`.

## Filter recipe library

| Goal                                 | jq predicate, against each node's `.value`                                        |
| ------------------------------------ | --------------------------------------------------------------------------------- |
| All your repos                       | `.locked.owner == "<your-login>"`                                                 |
| One org                              | `.locked.owner == "<org>"`                                                        |
| Repos by name pattern                | `.locked.repo \| startswith("internal-")`                                         |
| Repos on one branch                  | `.original.ref == "release-2026"`                                                 |
| Forks pinned to non-default branches | `.original.ref != null`                                                           |
| Everything except a denylist         | `.locked.owner == "<you>" and (.locked.repo \| IN("frozen", "archived") \| not)` |

## Your preferences

!`cat "${CLAUDE_SKILL_DIR}/../nix-flake-recursive-bump-input-versions.preferences.md" "${CLAUDE_PROJECT_DIR}/.agents/skills/nix-flake-recursive-bump-input-versions.preferences.md" 2>/dev/null || true`

If your agent doesn't run the line above, read these files yourself if they
exist: `nix-flake-recursive-bump-input-versions.preferences.md` next to this skill's folder, then
`.agents/skills/nix-flake-recursive-bump-input-versions.preferences.md` in the project. A project's
file overrides the user's, and the user's overrides this skill's defaults.

## Related skills

When one of these applies and it's in your skill listing, load it
without asking. If it isn't in your listing, tell the user which skill is
missing and ask whether to install it from the same collection this skill
came from; don't apply it from memory.

- `nix-flakes`: single-flake conventions this skill builds on, and scaffolding a flake where there is none.
- `github-workflow-pull-request-watcher`: the Monitor loop that follows each bump pull request's checks, comments and merge.
- `git-hygiene-commit-message-format`: subject and body format for each bump commit.
- `github-hygiene-pull-request-mirrors-commit`: a pull request's title and body mirror its commit, re-synced after an amend.
- `git-workflow-tidy-branches`: deleting the merged bump branches after the cascade.
- `git-hygiene-push-force-safely`: force-pushing a rebased fork branch before the cascade.
