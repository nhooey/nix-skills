#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
detect-project-language.sh — guess the project's primary language(s).

Usage:
  detect-project-language.sh

Reads the current directory's tracked-or-untracked-not-gitignored files and
emits one detected language per line. Patterns match the manifest filename
*anywhere* in the repo (so monorepos with `crates/foo/Cargo.toml`,
`services/api/pyproject.toml`, `apps/web/package.json` are detected too).
Where the *2nix choice is ecosystem-specific within a language (e.g. Node has
npm/pnpm/yarn-v1/yarn-berry), the detected variant is included as a
`<lang>-<variant>` slug. Exits 0 if anything found; exit 1 otherwise.

Detected slugs:
  rust              Cargo.toml
  node-npm          package-lock.json (or package.json fallback)
  node-pnpm         pnpm-lock.yaml
  node-yarn-v1      yarn.lock without .yarnrc.yml
  node-yarn-berry   .yarnrc.yml
  python-poetry     poetry.lock or [tool.poetry] in any pyproject.toml
  python-uv         uv.lock
  python-pdm        pdm.lock
  python-generic    pyproject.toml without recognised tool
  go                go.mod
  ruby              Gemfile.lock
  php               composer.lock
  dotnet            *.csproj / *.fsproj / *.sln
  clojure           deps.edn or project.clj
  java-maven        pom.xml
  java-gradle       build.gradle(.kts) / settings.gradle(.kts)
  scala             build.sbt
  haskell           cabal.project, stack.yaml, or *.cabal
  elixir            mix.exs
  ocaml             dune-project or *.opam
  crystal           shard.yml
  r                 DESCRIPTION or rix.nix

Requires: git (falls back to plain `ls -1` outside a repo).
EOF
}

case "${1-}" in -h | --help)
  usage
  exit 0
  ;;
esac

found=0
emit() {
  echo "$1"
  found=1
}

if files=$(git ls-files -co --exclude-standard 2>/dev/null) && [[ -n $files ]]; then
  :
else
  files=$(ls -1)
fi

# Match a filename anywhere in the file list — `(^|/)foo$` so `crates/foo/Cargo.toml`
# matches `Cargo.toml`, but `notCargo.toml` doesn't.
has() {
  printf '%s\n' "$files" | grep -qE "(^|/)$1\$"
}

has 'Cargo\.toml' && emit rust

if has '\.yarnrc\.yml'; then
  emit node-yarn-berry
elif has 'yarn\.lock'; then
  emit node-yarn-v1
elif has 'pnpm-lock\.yaml'; then
  emit node-pnpm
elif has 'package-lock\.json'; then
  emit node-npm
elif has 'package\.json'; then
  emit node-npm
fi

if has 'poetry\.lock'; then
  emit python-poetry
elif has 'uv\.lock'; then
  emit python-uv
elif has 'pdm\.lock'; then
  emit python-pdm
elif has 'pyproject\.toml'; then
  if printf '%s\n' "$files" | grep -E '(^|/)pyproject\.toml$' |
    xargs -I{} grep -l '\[tool\.poetry\]' {} 2>/dev/null | grep -q .; then
    emit python-poetry
  else
    emit python-generic
  fi
fi

has 'go\.mod' && emit go
has 'Gemfile\.lock' && emit ruby
has 'composer\.lock' && emit php
printf '%s\n' "$files" | grep -qE '\.(csproj|fsproj|sln)$' && emit dotnet
{ has 'deps\.edn' || has 'project\.clj'; } && emit clojure
has 'pom\.xml' && emit java-maven
printf '%s\n' "$files" | grep -qE '(^|/)(build|settings)\.gradle(\.kts)?$' && emit java-gradle
has 'build\.sbt' && emit scala
{ has 'cabal\.project' || has 'stack\.yaml' || printf '%s\n' "$files" | grep -qE '\.cabal$'; } && emit haskell
has 'mix\.exs' && emit elixir
{ has 'dune-project' || printf '%s\n' "$files" | grep -qE '\.opam$'; } && emit ocaml
has 'shard\.yml' && emit crystal
{ has 'DESCRIPTION' || has 'rix\.nix'; } && emit r

[[ $found -eq 1 ]]
