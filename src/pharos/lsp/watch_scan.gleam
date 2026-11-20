//// The watched-files scan's state and walk (ADR-043), without the actor
//// around it (`pharos/lsp/watch`), so it can be tested on its own.
////
//// The state holds every regular file under the workspace root by
//// directory, with its (mtime, ctime, size, inode). A scan visits
//// directories within a time budget, compares each one's listing with
//// what the state holds for it, and returns Created / Changed / Deleted
//// events. A pass is a walk of the whole tree; one that runs out of
//// budget resumes at the next scan. Before the pass, a scan visits the
//// asked file's directory (and below), then each ancestor's own files up
//// to the root, so a change next to the file asked about is found first.
////
//// - The first pass records a baseline and reports only files whose
////   mtime or ctime is at or after the server's spawn second
////   (NewOrChanged): the server may have read them before they changed,
////   or they may be new since it started; file times can't tell which.
//// - A file stamped at or after the second its directory was visited is
////   racy (file times are whole seconds): its SHA-256 is kept, and the
////   next visit that finds its stamps unchanged compares contents. Over
////   `racy_hash_max_bytes`, it is reported Changed instead.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string

pub type Stamp {
  Stamp(mtime: Int, ctime: Int, size: Int, inode: Int)
}

pub type Change {
  Created
  Changed
  Deleted
  /// Found by the first pass, stamped at or after the server's spawn
  /// second: created or changed since the server started, which file
  /// times can't tell apart.
  NewOrChanged
}

/// Names never walked into, wherever they are: version control, editor
/// and tool state, and dependency or cache directories that are never
/// sources.
pub const always_skipped = [
  ".git", ".hg", ".svn", "node_modules", ".venv", "__pycache__", ".gradle",
  ".idea", ".vscode", ".zig-cache", ".mypy_cache", ".pytest_cache",
  ".ruff_cache", ".tox", ".elixir_ls", ".dart_tool", ".next", ".stack-work",
]

/// Names walked into unless their directory holds one of the build files
/// that make them a build's output: `target` beside Cargo.toml or a JVM
/// build file, `_build` and `deps` beside mix.exs or rebar.config (dune's
/// `_build` beside dune-project), `zig-cache` beside build.zig, `build`
/// beside a Gradle, Gleam or CMake build file, `dist-newstyle` beside a
/// Cabal file. Elsewhere they may be sources (a package named `target`,
/// `deps` or `build`; package.json's `build/` and `dist/` are walked). A
/// marker `*.ext` is any file with that extension.
pub const skipped_beside = [
  #(
    "target",
    [
      "Cargo.toml", "pom.xml", "build.sbt", "build.gradle", "build.gradle.kts",
      "project.clj",
    ],
  ),
  #("_build", ["mix.exs", "rebar.config", "dune-project"]),
  #("deps", ["mix.exs", "rebar.config"]),
  #("zig-cache", ["build.zig"]),
  #(
    "build",
    ["build.gradle", "build.gradle.kts", "gleam.toml", "CMakeLists.txt"],
  ),
  #("dist-newstyle", ["*.cabal", "cabal.project"]),
]

/// Names walked into unless they hold this file: a `venv` is a Python
/// virtual environment when it has `pyvenv.cfg`.
pub const skipped_holding = [#("venv", "pyvenv.cfg")]

/// How many entries of one directory a visit handles between checks of
/// the budget.
const entries_per_budget_check = 64

pub type Event {
  Event(path: String, change: Change)
}

type Racy {
  NotRacy
  Hashed(BitArray)
  TooBig
}

type Entry {
  FileEntry(stamp: Stamp, racy: Racy)
  DirEntry
}

/// What the scan knows about the freshness of its picture of the tree,
/// for labelling an answer.
pub type Coverage {
  /// A whole pass ran within this question's scan, so every change made
  /// before the question is in it.
  Complete
  /// The first pass hasn't finished: `dirs` directories recorded so far.
  FirstPassRunning(dirs: Int)
  /// The tree wasn't walked whole within this question's scan (it ran out
  /// of budget, or the scan was skipped): `visited` of about `total`
  /// directories were.
  Partial(visited: Int, total: Int)
}

pub opaque type State {
  State(
    root: String,
    skip: Set(String),
    spawn_second: Int,
    /// Extra skips: paths relative to any directory (`/vendor/bundle`),
    /// matched at the end of a directory's path.
    skip_paths: List(String),
    snapshot: Dict(String, Dict(String, Entry)),
    baseline_done: Bool,
    /// Scanned before every question: entered when a whole pass runs in
    /// one scan within half the budget, kept while one still runs in one
    /// scan within the budget, so a single slower pass doesn't flip it.
    cheap: Bool,
    /// Directories left in the pass in progress; [] when none is.
    queue: List(String),
    pass_started_ms: Int,
    /// When the last finished pass began, and how long it took, if it ran
    /// within one scan.
    last_pass_started_ms: Option(Int),
    last_pass_one_scan_ms: Option(Int),
    /// Directories visited since the previous question.
    visited_since_question: Set(String),
    last_question_ms: Int,
    last_scan_ms: Option(Int),
  )
}

/// A file over this size that is racy is re-reported instead of hashed.
pub const racy_hash_max_bytes = 1_048_576

/// `skip`: names to skip besides `always_skipped`, or paths such as
/// `vendor/bundle` that are skipped wherever they end a directory's path.
pub fn new(root: String, skip: List(String), spawn_second: Int) -> State {
  let #(paths, names) = list.partition(skip, fn(s) { string.contains(s, "/") })
  State(
    root: root,
    skip: set.from_list(list.append(always_skipped, names)),
    skip_paths: list.map(paths, fn(p) { "/" <> p }),
    spawn_second: spawn_second,
    snapshot: dict.new(),
    baseline_done: False,
    cheap: False,
    queue: [],
    pass_started_ms: 0,
    last_pass_started_ms: None,
    last_pass_one_scan_ms: None,
    visited_since_question: set.new(),
    last_question_ms: 0,
    last_scan_ms: None,
  )
}

/// Whether the tree is scanned before every question: its last whole
/// pass ran inside one scan, within half the budget to become cheap, and
/// within the budget to stay so.
pub fn cheap(state: State) -> Bool {
  state.cheap
}

/// When the last scan began, if any has.
pub fn last_scan_ms(state: State) -> Option(Int) {
  state.last_scan_ms
}

/// Marks a question at `now_ms` that skipped the scan: coverage since
/// it starts again from nothing.
pub fn note_question(state: State, now_ms: Int) -> #(State, Coverage) {
  let coverage = coverage(state, now_ms)
  #(
    State(..state, last_question_ms: now_ms, visited_since_question: set.new()),
    coverage,
  )
}

/// Scans for a question at `now_ms`, with `budget_ms`, starting at
/// `asked_dir` when the question has a file. Returns the new state, the
/// events found, and the coverage to label the answer by.
pub fn scan(
  state: State,
  asked_dir: Option(String),
  now_ms: Int,
  budget_ms: Int,
  clock: fn() -> Int,
  fs: Fs,
) -> #(State, List(Event), Coverage) {
  let deadline = now_ms + budget_ms
  let state = case state.queue {
    [] -> State(..state, queue: [state.root], pass_started_ms: now_ms)
    _ -> state
  }
  let state = State(..state, last_scan_ms: Some(now_ms))
  // The asked file's directory and below, then its ancestors' own files.
  let priority = case asked_dir {
    Some(dir) ->
      case under(dir, state.root) {
        True -> [#(dir, True), ..ancestors(dir, state.root)]
        False -> []
      }
    None -> []
  }
  let walk = Walk(deadline: deadline, clock: clock, fs: fs)
  let #(state, events, visits) = walk_priority(state, priority, walk, [], 0)
  let #(state, events) = walk_pass(state, walk, events, visits)
  let state = case state.queue {
    [] -> finish_pass(state, now_ms, clock(), budget_ms)
    _ -> State(..state, cheap: False)
  }
  let coverage = coverage(state, now_ms)
  #(
    State(..state, last_question_ms: now_ms, visited_since_question: set.new()),
    list.reverse(events),
    coverage,
  )
}

/// A scan squeezed by the question's deadline: visits the asked file's
/// directory (and below) and its ancestors within half of `budget_ms`,
/// then spends the rest on the first pass, so questions that are all
/// short still finish it. The interval, whether the tree is cheap, and
/// any later pass are left as they were, so a short timeout doesn't
/// make a small tree look expensive.
pub fn scan_near(
  state: State,
  asked_dir: Option(String),
  now_ms: Int,
  budget_ms: Int,
  clock: fn() -> Int,
  fs: Fs,
) -> #(State, List(Event), Coverage) {
  let priority = case asked_dir {
    Some(dir) ->
      case under(dir, state.root) {
        True -> [#(dir, True), ..ancestors(dir, state.root)]
        False -> []
      }
    None -> []
  }
  // The asked file's surroundings get half the budget, the first pass the
  // rest: they would otherwise take it all on every short question, and
  // the pass would never move (on a 50k-file tree it stayed at 2237
  // directories).
  let walk = Walk(deadline: now_ms + budget_ms, clock: clock, fs: fs)
  let near = Walk(..walk, deadline: now_ms + budget_ms / 2)
  let #(state, events, visits) = walk_priority(state, priority, near, [], 0)
  // The first pass only: a later pass is the full scans' to run, and
  // finishing one here would count it toward cheapness from a squeezed
  // budget.
  let #(state, events) = case state.baseline_done {
    True -> #(state, events)
    False -> {
      let state = case state.queue {
        [] -> State(..state, queue: [state.root], pass_started_ms: now_ms)
        _ -> state
      }
      let #(state, events) = walk_pass(state, walk, events, visits)
      case state.queue {
        [] -> #(
          State(
            ..state,
            baseline_done: True,
            last_pass_started_ms: Some(state.pass_started_ms),
          ),
          events,
        )
        _ -> #(state, events)
      }
    }
  }
  // Complete only when this scan ran a whole first pass.
  let coverage = coverage(state, now_ms)
  #(
    State(..state, last_question_ms: now_ms, visited_since_question: set.new()),
    list.reverse(events),
    coverage,
  )
}

fn finish_pass(
  state: State,
  scan_started_ms: Int,
  now_ms: Int,
  budget_ms: Int,
) -> State {
  let one_scan = case state.pass_started_ms >= scan_started_ms {
    True -> Some(now_ms - state.pass_started_ms)
    False -> None
  }
  let cheap = case one_scan, state.cheap {
    Some(ms), True -> ms <= budget_ms
    Some(ms), False -> ms <= budget_ms / 2
    None, _ -> False
  }
  State(
    ..state,
    baseline_done: True,
    cheap: cheap,
    last_pass_started_ms: Some(state.pass_started_ms),
    last_pass_one_scan_ms: one_scan,
  )
}

/// One scan's limits.
type Walk {
  Walk(deadline: Int, clock: fn() -> Int, fs: Fs)
}

fn coverage(state: State, scan_started_ms: Int) -> Coverage {
  case state.baseline_done, state.last_pass_started_ms {
    False, _ -> FirstPassRunning(dict.size(state.snapshot))
    True, Some(started) if started >= scan_started_ms -> Complete
    True, _ ->
      Partial(
        visited: set.size(state.visited_since_question),
        total: int.max(dict.size(state.snapshot), 1),
      )
  }
}

/// `dir`'s ancestors up to `root`, each to be visited for its own files.
fn ancestors(dir: String, root: String) -> List(#(String, Bool)) {
  case dir == root {
    True -> []
    False -> {
      let parent = parent_of(dir)
      case parent == dir || !under(parent, root) {
        True -> []
        False -> [#(parent, False), ..ancestors(parent, root)]
      }
    }
  }
}

/// `visits`: directories visited so far in this scan. The first visit
/// always finishes, so every scan makes progress; a later one gives up
/// part-way through a wide directory once the budget is spent, and the
/// directory is visited again whole next time.
fn walk_priority(
  state: State,
  items: List(#(String, Bool)),
  walk: Walk,
  events: List(Event),
  visits: Int,
) -> #(State, List(Event), Int) {
  case items {
    [] -> #(state, events, visits)
    [#(dir, recurse), ..rest] ->
      case walk.clock() >= walk.deadline {
        True -> #(state, events, visits)
        False ->
          case visit(state, dir, walk, visits > 0, events) {
            Error(Nil) -> #(state, events, visits)
            Ok(#(state, subdirs, events)) -> {
              let rest = case recurse {
                True ->
                  list.append(list.map(subdirs, fn(d) { #(d, True) }), rest)
                False -> rest
              }
              walk_priority(state, rest, walk, events, visits + 1)
            }
          }
      }
  }
}

fn walk_pass(
  state: State,
  walk: Walk,
  events: List(Event),
  visits: Int,
) -> #(State, List(Event)) {
  case state.queue {
    [] -> #(state, events)
    [dir, ..rest] ->
      case walk.clock() >= walk.deadline {
        True -> #(state, events)
        False ->
          case
            visit(State(..state, queue: rest), dir, walk, visits > 0, events)
          {
            // Left at the front of the queue, for the next scan.
            Error(Nil) -> #(state, events)
            Ok(#(state, subdirs, events)) -> {
              let state =
                State(..state, queue: list.append(subdirs, state.queue))
              walk_pass(state, walk, events, visits + 1)
            }
          }
      }
  }
}

/// The file-system calls a scan makes, so tests can count or fake them.
pub type Fs {
  Fs(
    list_dir: fn(String) -> Result(List(String), Nil),
    stat: fn(String) -> Result(#(String, Int, Int, Int, Int), Nil),
    hash: fn(String) -> Result(BitArray, Nil),
    now_second: fn() -> Int,
  )
}

/// Visits one directory: compares its listing with the snapshot, records
/// it, and returns its subdirectories to walk. With `may_stop`, gives up
/// (Error, nothing recorded) when the budget runs out part-way through.
fn visit(
  state: State,
  dir: String,
  walk: Walk,
  may_stop: Bool,
  events: List(Event),
) -> Result(#(State, List(String), List(Event)), Nil) {
  let fs = walk.fs
  let visit_second = fs.now_second()
  let old = case dict.get(state.snapshot, dir) {
    Ok(entries) -> entries
    Error(_) -> dict.new()
  }
  let known_dir = dict.has_key(state.snapshot, dir)
  let names = case fs.list_dir(dir) {
    Ok(names) ->
      list.filter(names, fn(n) { !skipped(state, dir, n, names, fs) })
    Error(_) -> []
  }
  let #(new_entries, subdirs, events, _, stopped) =
    list.fold(names, #(dict.new(), [], events, 0, False), fn(acc, name) {
      let #(entries, subdirs, events, n, stopped) = acc
      let stopped =
        stopped
        || may_stop
        && n > 0
        && n % entries_per_budget_check == 0
        && walk.clock() >= walk.deadline
      case stopped {
        True -> #(entries, subdirs, events, n + 1, True)
        False -> {
          let #(entries, subdirs, events) =
            visit_entry(state, dir, name, old, known_dir, visit_second, fs, #(
              entries,
              subdirs,
              events,
            ))
          #(entries, subdirs, events, n + 1, False)
        }
      }
    })
  case stopped {
    True -> Error(Nil)
    False -> Ok(record_visit(state, dir, old, new_entries, subdirs, events))
  }
}

fn visit_entry(
  state: State,
  dir: String,
  name: String,
  old: Dict(String, Entry),
  known_dir: Bool,
  visit_second: Int,
  fs: Fs,
  acc: #(Dict(String, Entry), List(String), List(Event)),
) -> #(Dict(String, Entry), List(String), List(Event)) {
  let #(entries, subdirs, events) = acc
  let path = join(dir, name)
  case fs.stat(path) {
    Ok(#("dir", _, _, _, _)) -> #(
      dict.insert(entries, name, DirEntry),
      [path, ..subdirs],
      events,
    )
    Ok(#("file", mtime, ctime, size, inode)) -> {
      let stamp = Stamp(mtime, ctime, size, inode)
      let previous = dict.get(old, name)
      let change = case previous {
        Ok(FileEntry(old_stamp, racy)) ->
          case old_stamp == stamp {
            False -> Some(Changed)
            True ->
              case racy {
                NotRacy -> None
                TooBig -> Some(Changed)
                Hashed(hash) ->
                  case fs.hash(path) {
                    Ok(now) if now == hash -> None
                    _ -> Some(Changed)
                  }
              }
          }
        // A file where a directory was, or a file not seen before.
        _ ->
          case state.baseline_done || known_dir {
            True -> Some(Created)
            False ->
              case mtime >= state.spawn_second || ctime >= state.spawn_second {
                True -> Some(NewOrChanged)
                False -> None
              }
          }
      }
      let racy = case mtime >= visit_second || ctime >= visit_second {
        False -> NotRacy
        True ->
          case size > racy_hash_max_bytes {
            True -> TooBig
            False ->
              case fs.hash(path) {
                Ok(hash) -> Hashed(hash)
                Error(_) -> TooBig
              }
          }
      }
      let events = case change {
        Some(c) -> [Event(path, c), ..events]
        None -> events
      }
      #(dict.insert(entries, name, FileEntry(stamp, racy)), subdirs, events)
    }
    _ -> #(entries, subdirs, events)
  }
}

/// Whether `name`, listed in `dir` beside `siblings`, is skipped.
fn skipped(
  state: State,
  dir: String,
  name: String,
  siblings: List(String),
  fs: Fs,
) -> Bool {
  set.contains(state.skip, name)
  || case list.key_find(skipped_beside, name) {
    Ok(markers) ->
      list.any(markers, fn(m) {
        case string.starts_with(m, "*.") {
          True ->
            list.any(siblings, fn(s) {
              string.ends_with(s, string.drop_start(m, 1))
            })
          False -> list.contains(siblings, m)
        }
      })
    Error(Nil) -> False
  }
  || case list.key_find(skipped_holding, name) {
    Ok(inside) ->
      case fs.stat(join(join(dir, name), inside)) {
        Ok(#("file", _, _, _, _)) -> True
        _ -> False
      }
    Error(Nil) -> False
  }
  || case state.skip_paths {
    [] -> False
    paths -> {
      let path = join(dir, name)
      list.any(paths, fn(p) { string.ends_with(path, p) })
    }
  }
}

/// Records a visited directory's listing, and the events for what is
/// gone from it.
fn record_visit(
  state: State,
  dir: String,
  old: Dict(String, Entry),
  new_entries: Dict(String, Entry),
  subdirs: List(String),
  events: List(Event),
) -> #(State, List(String), List(Event)) {
  // What was there and isn't now: a file is Deleted; a directory takes
  // every file recorded under it with it.
  let #(snapshot, events) =
    dict.fold(old, #(state.snapshot, events), fn(acc, name, entry) {
      let #(snapshot, events) = acc
      case dict.get(new_entries, name), entry {
        Ok(FileEntry(..)), FileEntry(..) | Ok(DirEntry), DirEntry -> acc
        _, FileEntry(..) -> #(snapshot, [
          Event(join(dir, name), Deleted),
          ..events
        ])
        _, DirEntry -> drop_tree(snapshot, join(dir, name), events)
      }
    })
  let state =
    State(
      ..state,
      snapshot: dict.insert(snapshot, dir, new_entries),
      visited_since_question: set.insert(state.visited_since_question, dir),
    )
  #(state, list.reverse(subdirs), events)
}

/// Removes `dir` and everything recorded under it, as Deleted events.
fn drop_tree(
  snapshot: Dict(String, Dict(String, Entry)),
  dir: String,
  events: List(Event),
) -> #(Dict(String, Dict(String, Entry)), List(Event)) {
  let prefix = dir <> "/"
  dict.fold(snapshot, #(snapshot, events), fn(acc, path, entries) {
    let #(snapshot, events) = acc
    case path == dir || string.starts_with(path, prefix) {
      False -> acc
      True -> {
        let events =
          dict.fold(entries, events, fn(events, name, entry) {
            case entry {
              FileEntry(..) -> [Event(join(path, name), Deleted), ..events]
              DirEntry -> events
            }
          })
        #(dict.delete(snapshot, path), events)
      }
    }
  })
}

fn join(dir: String, name: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir <> name
    False -> dir <> "/" <> name
  }
}

fn under(path: String, root: String) -> Bool {
  path == root || string.starts_with(path, root <> "/")
}

fn parent_of(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] if rest != [] && rest != [""] ->
      string.join(list.reverse(rest), "/")
    _ -> "/"
  }
}
