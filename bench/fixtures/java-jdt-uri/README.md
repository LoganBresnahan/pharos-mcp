# java-jdt-uri — ADR-029 dogfood fixture

Minimal Maven-shaped Java project used by
[`bin/dogfood-adr-029.py`](../../../bin/dogfood-adr-029.py) to
exercise pharos's custom-URI scheme support (`jdt://` from jdtls).
JDK classes only — no external deps — so the fixture works without
`mvn` on the box. The `pom.xml` is here purely as a workspace
root-marker for jdtls.

## Layout

```
java-jdt-uri/
├── pom.xml                                  workspace root marker
├── README.md
└── src/main/java/com/example/Probe.java    uses java.util.ArrayList
```

## Probe target

`Probe.java` imports `java.util.ArrayList` and uses it inside
`main`. Goto-definition on `ArrayList` (line 3 of the import line,
or any call site in the body) should return a `jdt://contents/...`
URI representing the class file inside the JDK's `java.base` module.

## Prereqs

- Java 21 on `PATH`.
- `jdtls` on `PATH` — Eclipse JDT.LS snapshot from
  <https://download.eclipse.org/jdtls/snapshots/>. Extract anywhere
  and symlink `bin/jdtls` into a `PATH` directory (e.g. `~/.local/bin`).
- No Maven needed — the POM has no deps to resolve. jdtls uses the
  system JDK to find `java.util.ArrayList`.

`bin/dogfood-adr-029.py` skips its Java cells (clear message) when
either prereq is missing.

## What this fixture deliberately does NOT exercise

- **External JAR deps.** A real Maven fixture with e.g.
  `commons-lang3` would also produce `jdt://` URIs and is a fuller
  test, but adds a Maven install requirement we currently sidestep.
  If JDK-only proves insufficient (e.g. jdtls turns out to use a
  different scheme for JDK classes vs JAR deps), promote to a
  full Maven fixture and document the `mvn dependency:resolve` step.
- **Multi-module / multi-workspace setups.** The ambiguity
  branch (`AmbiguousSessionForLanguage`) requires two Java
  workspaces; that fixture is a sibling directory the harness
  spins up only for the ambiguity cell.
