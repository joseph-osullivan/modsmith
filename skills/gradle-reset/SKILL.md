---
name: gradle-reset
description: "Nuke the local Gradle build state of a Minecraft mod repo — stops the daemon, deletes .gradle/ and build/, then recompiles. Use when Gradle's cache or daemon is suspected bad: 'cannot find symbol' on classes that demonstrably exist on the resolved classpath, or behavior that does not match a clean checkout."
when_to_use: "The user says 'gradle reset', 'nuke the build', 'clean gradle state', or a build fails in ways a clean checkout would not reproduce. Not for ordinary compile errors — fix those."
user-invocable: true
disable-model-invocation: true
allowed-tools: Bash
---

# /modsmith:gradle-reset

The nuclear option for a wedged Gradle build in the current working
directory. It deletes local build state only; nothing under `src/` or
version control is touched.

1. Confirm the cwd is a Gradle project (`gradlew` present). If not, stop
   and say so.
2. Run, in order, each as its own command:

```bash
./gradlew --stop
rm -rf .gradle build
./gradlew compileJava
```

   In a multi-loader layout (`common/`, `fabric/`, `neoforge/`
   subprojects) also remove each subproject's `build/` and `.gradle/`.

3. Report one line:
   - Success → "Reset complete; compileJava passed."
   - Failure → the first compiler error verbatim, and the note that the
     error now reproduces from a clean state, so it is a real code or
     dependency problem, not cache corruption.

Do not re-run `--stop` in a loop and do not touch `~/.gradle` (the global
cache); if the failure looks like a corrupted global artifact, say so and
let the user decide.
