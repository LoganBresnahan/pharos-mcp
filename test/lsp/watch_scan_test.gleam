//// ADR-043: the watched-files scan, on an in-memory file system so the
//// whole-second and budget cases are deterministic.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pharos/lsp/watch_scan.{
  Changed, Complete, Created, Deleted, Event, FirstPassRunning, NewOrChanged,
  Partial,
}

/// path -> (contents, mtime, ctime, inode). Directories are implied by
/// the paths.
type Files =
  Dict(String, #(String, Int, Int, Int))

fn fs(files: Files, now_second: Int) -> watch_scan.Fs {
  watch_scan.Fs(
    list_dir: fn(dir) {
      let prefix = dir <> "/"
      let names =
        dict.keys(files)
        |> list.filter_map(fn(path) {
          case string.starts_with(path, prefix) {
            False -> Error(Nil)
            True ->
              case
                string.split(
                  string.drop_start(path, string.length(prefix)),
                  "/",
                )
              {
                [name, ..] -> Ok(name)
                [] -> Error(Nil)
              }
          }
        })
        |> list.unique
      case names, dict.size(files) {
        [], _ -> Error(Nil)
        _, _ -> Ok(names)
      }
    },
    stat: fn(path) {
      case dict.get(files, path) {
        Ok(#(contents, mtime, ctime, inode)) ->
          Ok(#("file", mtime, ctime, string.length(contents), inode))
        Error(_) ->
          case
            list.any(dict.keys(files), fn(p) {
              string.starts_with(p, path <> "/")
            })
          {
            True -> Ok(#("dir", 0, 0, 0, 0))
            False -> Error(Nil)
          }
      }
    },
    hash: fn(path) {
      case dict.get(files, path) {
        Ok(#(contents, _, _, _)) -> Ok(<<contents:utf8>>)
        Error(_) -> Error(Nil)
      }
    },
    now_second: fn() { now_second },
  )
}

fn clock() -> Int {
  0
}

fn scan(state, files, now_second) {
  watch_scan.scan(
    state,
    None,
    now_second * 1000,
    200,
    clock,
    fs(files, now_second),
  )
}

fn tree() -> Files {
  dict.from_list([
    #("/w/a.go", #("package a", 100, 100, 1)),
    #("/w/sub/b.go", #("package b", 100, 100, 2)),
    #("/w/sub/deep/c.go", #("package c", 100, 100, 3)),
  ])
}

pub fn first_pass_reports_only_changes_since_spawn_test() {
  // Spawned at 150: nothing in the tree is newer.
  let state = watch_scan.new("/w", [], 150)
  let #(_, events, coverage) = scan(state, tree(), 200)
  events |> should.equal([])
  coverage |> should.equal(Complete)

  // Spawned at 100: every file's stamps are at the spawn second, so the
  // server may have read them before they changed, or they may be new.
  let state = watch_scan.new("/w", [], 100)
  let #(_, events, _) = scan(state, tree(), 200)
  list.length(events) |> should.equal(3)
  list.all(events, fn(e) { e.change == NewOrChanged }) |> should.be_true
}

pub fn created_changed_deleted_test() {
  let state = watch_scan.new("/w", [], 150)
  let #(state, _, _) = scan(state, tree(), 200)
  let files =
    tree()
    |> dict.insert("/w/new.go", #("package n", 210, 210, 4))
    |> dict.insert("/w/a.go", #("package a // edited", 210, 210, 1))
    |> dict.delete("/w/sub/b.go")
  let #(state, events, _) = scan(state, files, 220)
  list.sort(events, fn(a, b) { string.compare(a.path, b.path) })
  |> should.equal([
    Event("/w/a.go", Changed),
    Event("/w/new.go", Created),
    Event("/w/sub/b.go", Deleted),
  ])
  // A whole directory removed takes its files with it.
  let files = dict.delete(files, "/w/sub/deep/c.go")
  let #(_, events, _) = scan(state, files, 230)
  events |> should.equal([Event("/w/sub/deep/c.go", Deleted)])
}

pub fn restore_with_old_mtime_is_seen_by_ctime_test() {
  let state = watch_scan.new("/w", [], 150)
  let #(state, _, _) = scan(state, tree(), 200)
  // cp -p: same mtime and size, new ctime.
  let files = dict.insert(tree(), "/w/a.go", #("package z", 100, 210, 1))
  let #(_, events, _) = scan(state, files, 220)
  events |> should.equal([Event("/w/a.go", Changed)])
}

pub fn replace_by_rename_is_seen_by_inode_test() {
  let state = watch_scan.new("/w", [], 150)
  let #(state, _, _) = scan(state, tree(), 200)
  let files = dict.insert(tree(), "/w/a.go", #("package a", 100, 100, 99))
  let #(_, events, _) = scan(state, files, 220)
  events |> should.equal([Event("/w/a.go", Changed)])
}

pub fn same_second_change_is_caught_by_contents_test() {
  let state = watch_scan.new("/w", [], 150)
  // a.go written in second 200, and the scan visits in second 200: racy.
  let files = dict.insert(tree(), "/w/a.go", #("package a", 200, 200, 1))
  let #(state, _, _) = scan(state, files, 200)
  // Rewritten in the same second, same size: stamps unchanged.
  let files = dict.insert(files, "/w/a.go", #("package q", 200, 200, 1))
  let #(state, events, _) = scan(state, files, 200)
  events |> should.equal([Event("/w/a.go", Changed)])
  // Unchanged contents are not reported again.
  let #(_, events, _) = scan(state, files, 201)
  events |> should.equal([])
}

pub fn a_new_file_after_the_first_pass_is_created_test() {
  let state = watch_scan.new("/w", [], 150)
  let #(state, _, _) = scan(state, tree(), 200)
  let files = dict.insert(tree(), "/w/sub/deep/x/new.go", #("p", 100, 100, 5))
  let #(_, events, _) = scan(state, files, 220)
  events |> should.equal([Event("/w/sub/deep/x/new.go", Created)])
}

pub fn skipped_names_are_not_walked_test() {
  let files =
    tree() |> dict.insert("/w/node_modules/m/i.js", #("x", 300, 300, 7))
  let state = watch_scan.new("/w", ["node_modules"], 150)
  let #(state, _, _) = scan(state, files, 200)
  let files = dict.insert(files, "/w/node_modules/m/j.js", #("y", 300, 300, 8))
  let #(_, events, _) = scan(state, files, 220)
  events |> should.equal([])
}

@external(erlang, "erlang", "unique_integer")
fn unique(options: List(UniqueOption)) -> Int

type UniqueOption {
  Monotonic
  Positive
}

/// A clock that moves on 1 ms per reading, so a 3 ms budget stops a walk
/// after about three directories.
fn ticking() -> Int {
  unique([Monotonic, Positive])
}

pub fn a_budget_resumes_and_labels_partial_test() {
  let files =
    int.range(1, 31, [], fn(acc, i) { [i, ..acc] })
    |> list.map(fn(i) {
      #("/w/d" <> string.inspect(i) <> "/f.go", #("x", 100, 100, i))
    })
    |> dict.from_list
  let state = watch_scan.new("/w", [], 150)
  let start = ticking()
  let #(state, _, coverage) =
    watch_scan.scan(state, None, start, 3, ticking, fs(files, 200))
  case coverage {
    FirstPassRunning(_) -> Nil
    other ->
      panic as {
        "expected the first pass running, got " <> string.inspect(other)
      }
  }
  // Keep scanning with small budgets until the first pass is done.
  let state = finish(state, files, 50)
  // A later question whose scan runs out of budget isn't Complete.
  let now = ticking()
  let #(_, _, coverage) =
    watch_scan.scan(state, None, now, 3, ticking, fs(files, 200))
  case coverage {
    Partial(..) -> Nil
    other -> panic as { "expected Partial, got " <> string.inspect(other) }
  }
}

fn finish(state, files, tries) {
  case tries {
    0 -> panic as "the first pass never finished"
    _ -> {
      let now = ticking()
      let #(state, _, coverage) =
        watch_scan.scan(state, None, now, 3, ticking, fs(files, 200))
      case coverage {
        FirstPassRunning(_) -> finish(state, files, tries - 1)
        _ -> state
      }
    }
  }
}

pub fn the_asked_directory_is_visited_first_test() {
  let files =
    int.range(1, 31, [], fn(acc, i) { [i, ..acc] })
    |> list.map(fn(i) {
      #("/w/d" <> string.inspect(i) <> "/f.go", #("x", 100, 100, i))
    })
    |> dict.from_list
  let state = watch_scan.new("/w", [], 150)
  let state = finish(state, files, 50)
  let files = dict.insert(files, "/w/d29/new.go", #("y", 300, 300, 99))
  // About one directory's worth of budget: d29 is visited before the pass.
  let now = ticking()
  let #(_, events, _) =
    watch_scan.scan(state, Some("/w/d29"), now, 2, ticking, fs(files, 300))
  events |> should.equal([Event("/w/d29/new.go", Created)])
}

fn dirs(n: Int) -> Files {
  int.range(1, n + 1, [], fn(acc, i) { [i, ..acc] })
  |> list.map(fn(i) {
    #("/w/d" <> string.inspect(i) <> "/f.go", #("x", 100, 100, i))
  })
  |> dict.from_list
}

fn scan_with(state, files, budget) {
  let now = ticking()
  watch_scan.scan(state, None, now, budget, ticking, fs(files, 200))
}

pub fn a_cheap_tree_stays_cheap_through_a_slower_pass_test() {
  // About 22 clock readings per pass of 20 directories.
  let files = dirs(20)
  // Within half of 100: cheap.
  let #(state, _, _) = scan_with(watch_scan.new("/w", [], 150), files, 100)
  watch_scan.cheap(state) |> should.be_true
  // Over half of 30, within 30: stays cheap.
  let #(state, _, coverage) = scan_with(state, files, 30)
  coverage |> should.equal(Complete)
  watch_scan.cheap(state) |> should.be_true
  // The same budget doesn't make a fresh tree cheap.
  let #(fresh, _, _) = scan_with(watch_scan.new("/w", [], 150), files, 30)
  watch_scan.cheap(fresh) |> should.be_false
  // A pass that doesn't fit one scan ends it.
  let #(state, _, _) = scan_with(state, files, 3)
  let state = finish(state, files, 50)
  watch_scan.cheap(state) |> should.be_false
}

pub fn a_wide_directory_stops_at_the_budget_unless_first_test() {
  let wide =
    int.range(1, 301, [], fn(acc, i) { [i, ..acc] })
    |> list.map(fn(i) {
      #("/w/wide/f" <> string.inspect(i) <> ".go", #("x", 100, 100, 1000 + i))
    })
  let files = dict.from_list([#("/w/a/f.go", #("x", 100, 100, 1)), ..wide])
  // /w/wide, not the scan's first visit, is cut short at its first budget
  // check and left for the next scan: it isn't recorded (all three would
  // be otherwise).
  let #(state, _, coverage) = scan_with(watch_scan.new("/w", [], 150), files, 4)
  case coverage {
    FirstPassRunning(recorded) if recorded < 3 -> Nil
    other ->
      panic as { "expected /w/wide cut short, got " <> string.inspect(other) }
  }
  // As a scan's first visit it runs whole, whatever the budget, so tiny
  // budgets still finish the pass.
  let _ = finish(state, files, 10)
  Nil
}

pub fn build_output_names_are_skipped_only_beside_their_build_file_test() {
  let files =
    dict.from_list([
      #("/w/Cargo.toml", #("[package]", 300, 300, 1)),
      #("/w/target/debug/x.rs", #("x", 300, 300, 2)),
      #("/w/pkg/target/y.go", #("y", 300, 300, 3)),
      #("/w/pkg/deps/z.go", #("z", 300, 300, 4)),
      #("/w/vendor/bundle/g.rb", #("g", 300, 300, 5)),
      #("/w/.zig-cache/o/c.zig", #("c", 300, 300, 6)),
    ])
  let state = watch_scan.new("/w", ["vendor/bundle"], 100)
  let #(_, events, _) = scan(state, files, 400)
  list.map(events, fn(e) { e.path })
  |> list.sort(string.compare)
  |> should.equal(["/w/Cargo.toml", "/w/pkg/deps/z.go", "/w/pkg/target/y.go"])
}

pub fn more_build_outputs_and_caches_are_skipped_test() {
  let files =
    dict.from_list([
      #("/w/gleam.toml", #("name", 300, 300, 1)),
      #("/w/build/packages/x.gleam", #("x", 300, 300, 2)),
      #("/w/web/package.json", #("{}", 300, 300, 3)),
      #("/w/web/build/app.js", #("a", 300, 300, 4)),
      #("/w/web/dist/app.js", #("b", 300, 300, 5)),
      #("/w/hs/p.cabal", #("c", 300, 300, 6)),
      #("/w/hs/dist-newstyle/o.hs", #("d", 300, 300, 7)),
      #("/w/py/venv/pyvenv.cfg", #("e", 300, 300, 8)),
      #("/w/py/venv/lib/m.py", #("f", 300, 300, 9)),
      #("/w/py2/venv/m.py", #("g", 300, 300, 10)),
      #("/w/.mypy_cache/c.json", #("h", 300, 300, 11)),
      #("/w/.next/n.js", #("i", 300, 300, 12)),
    ])
  let #(_, events, _) = scan(watch_scan.new("/w", [], 100), files, 400)
  list.map(events, fn(e) { e.path })
  |> list.sort(string.compare)
  |> should.equal([
    "/w/gleam.toml", "/w/hs/p.cabal", "/w/py2/venv/m.py", "/w/web/build/app.js",
    "/w/web/dist/app.js", "/w/web/package.json",
  ])
}

pub fn a_scan_squeezed_by_the_deadline_leaves_a_cheap_tree_cheap_test() {
  let files = dirs(20)
  let #(state, _, _) = scan_with(watch_scan.new("/w", [], 150), files, 100)
  watch_scan.cheap(state) |> should.be_true
  let files = dict.insert(files, "/w/d3/new.go", #("n", 300, 300, 500))
  // No time at all: nothing walked, and the tree stays cheap.
  let now = ticking()
  let #(state, events, coverage) =
    watch_scan.scan_near(state, Some("/w/d3"), now, 0, ticking, fs(files, 300))
  events |> should.equal([])
  coverage |> should.equal(Partial(0, 21))
  watch_scan.cheap(state) |> should.be_true
  // A little time: the asked directory first, within half of it.
  let now = ticking()
  let #(state, events, _) =
    watch_scan.scan_near(state, Some("/w/d3"), now, 4, ticking, fs(files, 300))
  events |> should.equal([Event("/w/d3/new.go", Created)])
  watch_scan.cheap(state) |> should.be_true
}

pub fn squeezed_scans_still_finish_the_first_pass_test() {
  // Every question short (verifier: frozen at 2237 directories): each
  // squeezed scan spends what's left on the first pass, which finishes.
  let files = dirs(20)
  let state = finish_near(watch_scan.new("/w", [], 150), files, 50)
  // After it, short questions still reach a change far from the asked
  // directory: a rotating cursor walks the rest of the tree in turn
  // (verifier: "checked 4 of about 5005 directories" every time).
  let files = dict.insert(files, "/w/d7/new.go", #("n", 300, 300, 600))
  find_far(state, files, 60) |> should.be_true
}

fn find_far(state, files, tries) {
  case tries {
    0 -> False
    _ -> {
      let now = ticking()
      let #(state, events, _) =
        watch_scan.scan_near(
          state,
          Some("/w/d1"),
          now,
          4,
          ticking,
          fs(files, 300),
        )
      case list.contains(events, Event("/w/d7/new.go", Created)) {
        True -> True
        False -> find_far(state, files, tries - 1)
      }
    }
  }
}

fn finish_near(state, files, tries) {
  case tries {
    0 -> panic as "squeezed scans never finished the first pass"
    _ -> {
      let now = ticking()
      let #(state, _, coverage) =
        watch_scan.scan_near(
          state,
          Some("/w/d1"),
          now,
          3,
          ticking,
          fs(files, 200),
        )
      case coverage {
        FirstPassRunning(_) -> finish_near(state, files, tries - 1)
        _ -> state
      }
    }
  }
}
