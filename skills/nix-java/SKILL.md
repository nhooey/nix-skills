---
name: nix-java
description: Pin the JDK for JVM projects packaged with Nix (Java, Kotlin, Scala, Clojure). Covers a `nix-jdk` symlink in the workspace that keeps IDEs working when the JDK's store path changes, the argument each JVM tool's `override` takes for its JDK (`jdk` on clojure, `java` on gradle, `jdk_headless` on maven, `jre` on sbt), and `lib.lowPrio` for two packages that put the same binary on `PATH`. Use when packaging anything JVM-based with Nix, when an IDE loses its JDK after a nixpkgs bump, or when JDK wrapper binaries clash on `PATH`.
---

# Nix + JVM / Java

The toolchain-pinning rule in `nix-flakes` applies: define one JDK and thread it through every consumer. This skill adds the JVM-specific parts.

## IDE-friendly JDK symlink

A JDK's Nix store path changes on every nixpkgs update. IDEs (IntelliJ, Cursor, VS Code, Eclipse) store the project JDK by absolute path, so each update breaks them until the developer reconfigures.

Symlink the resolved JDK into the workspace at a stable path from a `devshell.startup` hook, and point the IDE at the symlink. Bumping the JDK pin updates the symlink in place.

```nix
devshell.startup.link-jdk.text = ''
  ln -sfn ${pinnedJdk} "$PRJ_ROOT/nix-jdk"
'';
```

Add `nix-jdk` to `.gitignore`.

## Override the JDK on JVM-based tools

Each tool picks its own default JDK. Override it explicitly; the argument name differs per tool:

```nix
clojure.override { jdk = pinnedJdk; }
gradle.override  { java = pinnedJdk; }
maven.override   { jdk_headless = pinnedJdk; }
sbt.override     { jre = pinnedJdk; }
```

- **gradle:** the wrapper passes every argument on to `gradle-unwrapped` and ignores any it doesn't know, so `gradle.override { jdk = … }` builds the default JDK without an error. Use `java`.
- **maven:** `maven.override { jdk = … }` fails to evaluate; the argument is `jdk_headless`.

With the single toolchain constant from `nix-flakes`, one edit retargets the build, tests, REPL and IDE.

## `lowPrio` for clashing wrappers

A tool wrapped with the pinned JDK and another package that re-exports the same binary can shadow each other on `PATH`. Demote one with `lib.lowPrio` instead of removing it:

```nix
packages = [
  (clojure.override { jdk = pinnedJdk; })
  (lib.lowPrio someOtherToolThatExportsClojure)
];
```

Both stay installed, and the other one wins on `PATH`.

## References

- [Nixpkgs manual: Java](https://nixos.org/manual/nixpkgs/stable/#sec-language-java): JDK and JRE packages, and overriding the JRE a package uses.

## Your preferences

!`cat "${CLAUDE_SKILL_DIR}/../nix-java.preferences.md" "${CLAUDE_PROJECT_DIR}/.agents/skills/nix-java.preferences.md" 2>/dev/null || true`

If your agent doesn't run the line above, read these files yourself if they
exist: `nix-java.preferences.md` next to this skill's folder, then
`.agents/skills/nix-java.preferences.md` in the project. A project's
file overrides the user's, and the user's overrides this skill's defaults.

## Related skills

When one of these applies and it's in your skill listing, load it
without asking. If it isn't in your listing, tell the user which skill is
missing and ask whether to install it from the same collection this skill
came from; don't apply it from memory.

- `nix-flakes`: flake conventions this skill builds on, single-source toolchain pinning among them.
- `nix-clojure`: Clojure and ClojureScript packaging with clj-nix, which takes the pinned JDK through `clojure.override`.
