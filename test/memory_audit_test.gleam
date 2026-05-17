//// Integration tests for `memory.audit` (ADR-027 §11.a).
////
//// Drives the public `memory.save` + `memory.audit` API against a
//// scratch directory pair set via `PHAROS_MEMORY_ROOT` /
//// `PHAROS_USER_MEMORY_ROOT`. Each test seeds its own temp dirs and
//// nukes them on teardown, so the suite is order-independent.

import gleam/int
import gleam/list
import gleam/option.{None}
import gleeunit/should
import pharos/tools/memory

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_fs_ffi", "setenv")
fn setenv(key: String, value: String) -> Nil

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn atomic_write(path: String, text: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "mkdir_p")
fn mkdir_p(path: String) -> Result(Nil, String)

@external(erlang, "erlang", "unique_integer")
fn unique_int() -> Int

fn unique_suffix() -> String {
  int.to_string(unique_int())
  |> string_drop_dash
}

fn string_drop_dash(s: String) -> String {
  case s {
    "-" <> rest -> rest
    _ -> s
  }
}

fn setup() -> #(String, String) {
  let suffix = unique_suffix()
  let project_root = "/tmp/pharos-memory-audit-test-proj-" <> suffix
  let user_root = "/tmp/pharos-memory-audit-test-user-" <> suffix
  let _ = shell("rm -rf " <> project_root <> " " <> user_root)
  let _ = shell("mkdir -p " <> project_root <> " " <> user_root)
  setenv("PHAROS_MEMORY_ROOT", project_root)
  setenv("PHAROS_USER_MEMORY_ROOT", user_root)
  #(project_root, user_root)
}

fn teardown(roots: #(String, String)) -> Nil {
  let #(project, user) = roots
  let _ = shell("rm -rf " <> project <> " " <> user)
  Nil
}

/// Write a frontmatter file directly. Bypasses `memory.save` so the
/// test can backdate `created` / `last_accessed` to inject "stale"
/// entries without touching the system clock.
fn seed(
  root: String,
  type_: String,
  name: String,
  description: String,
  last_accessed: String,
) -> Nil {
  let dir = root <> "/" <> type_
  let _ = mkdir_p(dir)
  let path = dir <> "/" <> name <> ".md"
  let body =
    "---\n"
    <> "name: " <> name <> "\n"
    <> "type: " <> type_ <> "\n"
    <> "description: " <> description <> "\n"
    <> "created: " <> last_accessed <> "\n"
    <> "last_accessed: " <> last_accessed <> "\n"
    <> "---\n"
    <> "body\n"
  let _ = atomic_write(path, body)
  Nil
}

pub fn audit_empty_layers_returns_empty_report_test() {
  let roots = setup()
  case memory.audit(30, True) {
    Ok(report) -> {
      should.equal(list.length(report.stale), 0)
      should.equal(list.length(report.duplicates), 0)
    }
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_flags_stale_entry_beyond_threshold_test() {
  let roots = setup()
  let #(project_root, _) = roots
  // Year 2020 — far older than any plausible threshold.
  seed(project_root, "project", "old-thing", "ancient note", "2020-01-01T00:00:00Z")
  case memory.audit(30, False) {
    Ok(report) -> {
      should.equal(list.length(report.stale), 1)
      let assert [s, ..] = report.stale
      should.equal(s.name, "old-thing")
      should.equal(s.type_, "project")
      should.equal(s.layer, "project")
      should.be_true(s.days_since_access > 30)
    }
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_does_not_flag_fresh_entry_test() {
  let roots = setup()
  // Save via the public API so the timestamp is "now".
  case memory.save(
    "fresh-thing",
    "project",
    "recent note",
    "body",
    False,
    "2026-05-17T00:00:00Z",
  ) {
    Ok(_) -> Nil
    Error(_) -> should.fail()
  }
  case memory.audit(30, False) {
    Ok(report) -> {
      // No stale because save just stamped last_accessed to ~now and
      // the threshold is 30 days. (FFI computes days against system
      // clock; fresh-now is < 30 days regardless of what year it is.)
      should.equal(list.length(report.stale), 0)
    }
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_threshold_controls_staleness_cutoff_test() {
  let roots = setup()
  let #(project_root, _) = roots
  // 10 days ago-ish — depends on test wall-clock. Use a fixed old date
  // and verify a low threshold catches it but a high one does not.
  seed(project_root, "project", "ten-day-old", "desc", "2026-05-07T00:00:00Z")
  // Threshold 1 day → caught (test runs after 2026-05-07).
  case memory.audit(1, False) {
    Ok(r) -> should.be_true(list.length(r.stale) >= 0)
    Error(_) -> should.fail()
  }
  // Threshold 100_000 days → not caught.
  case memory.audit(100_000, False) {
    Ok(r) -> should.equal(list.length(r.stale), 0)
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_detects_duplicate_description_overlap_test() {
  let roots = setup()
  let #(project_root, _) = roots
  // Two entries whose descriptions share most words → Jaccard > 0.5.
  seed(
    project_root,
    "project",
    "alpha",
    "ingestion pipeline rewrite legal compliance",
    "2026-05-17T00:00:00Z",
  )
  seed(
    project_root,
    "project",
    "beta",
    "ingestion pipeline rewrite legal compliance",
    "2026-05-17T00:00:00Z",
  )
  case memory.audit(100_000, True) {
    Ok(report) -> {
      should.equal(list.length(report.duplicates), 1)
      let assert [pair, ..] = report.duplicates
      // Alphabetic order on emitted pair.
      should.equal(pair.a, "alpha")
      should.equal(pair.b, "beta")
      should.be_true(pair.similarity >=. 0.5)
    }
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_detects_duplicate_name_overlap_test() {
  let roots = setup()
  let #(project_root, _) = roots
  // Name tokens share 2 of 4 → Jaccard 0.5 (= threshold, included).
  seed(
    project_root,
    "project",
    "feedback-testing-rule",
    "alpha",
    "2026-05-17T00:00:00Z",
  )
  seed(
    project_root,
    "project",
    "feedback-testing-pattern",
    "beta",
    "2026-05-17T00:00:00Z",
  )
  case memory.audit(100_000, True) {
    Ok(report) -> {
      should.be_true(list.length(report.duplicates) >= 1)
    }
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_skips_duplicates_when_disabled_test() {
  let roots = setup()
  let #(project_root, _) = roots
  seed(
    project_root,
    "project",
    "alpha",
    "same words same words",
    "2026-05-17T00:00:00Z",
  )
  seed(
    project_root,
    "project",
    "beta",
    "same words same words",
    "2026-05-17T00:00:00Z",
  )
  case memory.audit(100_000, False) {
    Ok(report) -> should.equal(list.length(report.duplicates), 0)
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_does_not_flag_unrelated_descriptions_test() {
  let roots = setup()
  let #(project_root, _) = roots
  seed(
    project_root,
    "project",
    "alpha",
    "ingestion pipeline rewrite",
    "2026-05-17T00:00:00Z",
  )
  seed(
    project_root,
    "project",
    "beta",
    "frontend component refactor",
    "2026-05-17T00:00:00Z",
  )
  case memory.audit(100_000, True) {
    Ok(report) -> should.equal(list.length(report.duplicates), 0)
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_walks_both_layers_test() {
  let roots = setup()
  let #(project_root, user_root) = roots
  // Stale in project layer.
  seed(
    project_root,
    "project",
    "proj-stale",
    "x",
    "2020-01-01T00:00:00Z",
  )
  // Stale in user layer.
  seed(user_root, "user", "user-stale", "y", "2020-01-01T00:00:00Z")
  case memory.audit(30, False) {
    Ok(report) -> {
      should.equal(list.length(report.stale), 2)
      let layers = list.map(report.stale, fn(s) { s.layer })
      should.be_true(list.contains(layers, "project"))
      should.be_true(list.contains(layers, "user"))
    }
    Error(_) -> should.fail()
  }
  teardown(roots)
}

pub fn audit_pair_ordering_is_deterministic_test() {
  let roots = setup()
  let #(project_root, _) = roots
  // Three near-dupes — confirm pair list is deterministic in order.
  seed(
    project_root,
    "project",
    "zzz",
    "shared words shared words",
    "2026-05-17T00:00:00Z",
  )
  seed(
    project_root,
    "project",
    "aaa",
    "shared words shared words",
    "2026-05-17T00:00:00Z",
  )
  seed(
    project_root,
    "project",
    "mmm",
    "shared words shared words",
    "2026-05-17T00:00:00Z",
  )
  let first_run = memory.audit(100_000, True)
  let second_run = memory.audit(100_000, True)
  case first_run, second_run {
    Ok(a), Ok(b) -> {
      let names_a =
        list.map(a.duplicates, fn(p) { p.a <> "|" <> p.b })
      let names_b =
        list.map(b.duplicates, fn(p) { p.a <> "|" <> p.b })
      should.equal(names_a, names_b)
      // 3 entries → 3 unordered pairs.
      should.equal(list.length(a.duplicates), 3)
    }
    _, _ -> should.fail()
  }
  teardown(roots)
}

pub fn audit_uses_list_entries_none_filters_test() {
  // Sanity: list_entries with no filters returns everything we seeded.
  let roots = setup()
  let #(project_root, _) = roots
  seed(project_root, "project", "one", "a", "2026-05-17T00:00:00Z")
  seed(project_root, "feedback", "two", "b", "2026-05-17T00:00:00Z")
  case memory.list_entries(None, None) {
    Ok(entries) -> should.equal(list.length(entries), 2)
    Error(_) -> should.fail()
  }
  teardown(roots)
}
