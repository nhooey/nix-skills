---
name: nix-java
description: JVM-specific patterns in Nix flakes. Covers the `nix-jdk` workspace symlink for IDE stability across JDK store-path churn, `clojure.override { jdk = ... }` / `gradle.override` / `maven.override` / `sbt.override` for explicit JDK pinning on JVM tools, and `pkgs.lib.lowPrio` for resolving PATH conflicts between competing JDK-wrapper packages. Use when packaging anything JVM-based with Nix (Java, Kotlin, Scala, Clojure), debugging IDE breakage after a nixpkgs bump, or untangling clashing wrapper binaries on PATH. Pair with the `nix-flakes` skill for generic toolchain-pinning structure.
---

# Nix + JVM / Java

JVM-specific patterns. The general toolchain-pinning advice in the `nix-flakes` skill applies — define one source-of-truth JDK and thread it everywhere. The patterns below are the JVM-specific bits.

## IDE-friendly JDK symlink

JDKs in the Nix store have hash-based paths that change on every nixpkgs update. IDEs (IntelliJ, Cursor, VS Code, Eclipse) cache "the project JDK" by absolute path — when the path changes, they break and the developer has to reconfigure.

Fix: symlink the resolved JDK into the workspace at a stable path from a `devshell.startup` hook. Point the IDE at the symlink, not the store path. Bumping the JDK pin updates the symlink in place; the IDE keeps working.

```nix
devshell.startup.link-jdk.text = ''
  ln -sfn ${pinnedJdk} "$PRJ_ROOT/nix-jdk"
'';
```

Add `nix-jdk` (or whatever you name it) to `.gitignore`.

## Override the JDK on JVM-based tools

Don't rely on the ambient JDK for tools that pin one internally. Override explicitly:

```nix
clojure.override { jdk = pinnedJdk; }
gradle.override  { jdk = pinnedJdk; }
maven.override   { jdk = pinnedJdk; }
sbt.override     { jre = pinnedJdk; }   # note: jre, not jdk, on sbt
```

Combined with the source-of-truth pattern from the `nix-flakes` skill, one constant retargets every consumer (build, test, REPL, IDE).

## `lowPrio` for clashing wrappers

A tool wrapped with one JDK plus another package that re-exports the same binary with the ambient JDK can shadow each other on `PATH`. Demote one with `pkgs.lib.lowPrio` instead of removing it:

```nix
packages = [
  (clojure.override { jdk = pinnedJdk; })
  (lib.lowPrio someOtherToolThatExportsClojure)
];
```

Both stay installed; the high-priority one wins on `PATH`.

## References

- [Nixpkgs JVM module / Java](https://nixos.org/manual/nixpkgs/stable/#java) — official packaging notes, including the `override` arguments accepted by `clojure`, `gradle`, `maven`, `sbt`, etc.
