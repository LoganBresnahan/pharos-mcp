//// Tells servers about files changed on disk (ADR-043).
////
//// Before a question, for each server that relies on its client to watch
//// files (it registered `workspace/didChangeWatchedFiles` watchers, or
//// `watch_files = true`), pharos scans the workspace for changes
//// (`watch_scan`) and sends the server the ones its watchers match. One
//// scanner actor per LSP proc holds the scan's state; it monitors the
//// proc and stops with it, so a restarted server starts a fresh baseline.
////
//// Timing: a workspace whose last whole pass took at most half the
//// budget is scanned before every question (and stays so while a pass
//// fits the budget). Any other is scanned at most once per
//// `scan_interval_ms`, each scan bounded by `scan_budget_ms`, or less
//// when the question's own deadline is nearer, and resuming where the
//// last stopped. While the picture isn't complete for a question (first
//// pass running, a pass cut short, or the scan skipped), the answer gets
//// a note saying so.
////
//// The changes found aren't sent here: they go back to the caller, which
//// sends them in the pool's sync batch for the question (ADR-038), so an
//// answer cached before them counts as carried over, not fresh.

import gleam/dynamic
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import pharos/log
import pharos/log/entry as log_entry
import pharos/lsp/watch_scan.{type Coverage, type Event}
import pharos/lsp/watchers.{type Watcher}
import pharos/workspace_root

/// How long one scan may walk, unless `PHAROS_WATCH_BUDGET_MS` says
/// otherwise.
pub const scan_budget_ms = 200

/// A tree whose whole pass fits in half the budget is scanned before
/// every question.
/// An expensive tree is scanned at most this often.
pub const scan_interval_ms = 2000

/// How long a question waits for its scanner beyond the scan's budget
/// before going on without it, labelled: the scanner may be busy with a
/// slow file system. Never past the question's own deadline.
const scanner_grace_ms = 1000

/// `seq` numbers the reply, for `Delivered`.
pub type Outcome {
  Outcome(events: List(Event), coverage: Coverage, scanned: Bool, seq: Int)
}

pub type Msg {
  /// `capped`: the budget was cut to fit the question's deadline: only
  /// the asked file's surroundings are scanned (`watch_scan.scan_near`).
  Scan(
    asked_dir: Option(String),
    budget_ms: Int,
    capped: Bool,
    reply: Subject(Outcome),
  )
  /// The question sent the server the events of reply `seq` (they're in
  /// a sync batch the proc has written).
  Delivered(seq: Int)
  ProcGone
  /// A scanner that lost the race to register for its proc: stops without
  /// touching the winner's registration or the proc's watchers.
  Stop
}

/// `pending`: the events of the last reply, until the caller says it got
/// them. A caller that gave up waiting never does, and the next reply
/// carries them again: the scan has already recorded those files as
/// seen, so they would otherwise be lost.
type State {
  State(scan: watch_scan.State, proc_pid: Pid, pending: List(Event), seq: Int)
}

/// The scanner for `proc_pid`, started if there is none.
fn scanner(
  proc_pid: Pid,
  root: String,
  skip: List(String),
) -> Result(Subject(Msg), Nil) {
  case lookup(proc_pid) {
    Ok(subject) -> Ok(subject)
    Error(_) -> {
      let initialise = fn(self) {
        let _ = process.monitor(proc_pid)
        let selector =
          process.new_selector()
          |> process.select(self)
          |> process.select_monitors(fn(_down) { ProcGone })
        Ok(
          actor.initialised(State(
            scan: watch_scan.new(root, skip, spawned_second(proc_pid)),
            proc_pid: proc_pid,
            pending: [],
            seq: 0,
          ))
          |> actor.selecting(selector)
          |> actor.returning(self),
        )
      }
      case
        actor.new_with_initialiser(5000, initialise)
        |> actor.on_message(handle)
        |> actor.start()
      {
        Error(_) -> Error(Nil)
        Ok(started) -> {
          // actor.start links it to this request's process: a scanner
          // that fails must not take the question with it, nor a
          // cancelled question the scanner. It lives as long as its proc.
          process.unlink(started.pid)
          case claim(proc_pid, started.data) {
            True -> Ok(started.data)
            // Another question started one first: use it, stop ours.
            // Not ProcGone: that cleans up for the proc, so the winner's
            // registration and the proc's watchers would be dropped, and
            // no scan would run for it again.
            False -> {
              process.send(started.data, Stop)
              lookup(proc_pid)
            }
          }
        }
      }
    }
  }
}

fn handle(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    ProcGone -> {
      drop(state.proc_pid)
      watchers.forget(state.proc_pid)
      actor.stop()
    }
    Stop -> actor.stop()
    Delivered(seq) ->
      case seq == state.seq {
        True -> actor.continue(State(..state, pending: []))
        False -> actor.continue(state)
      }
    Scan(asked_dir, budget_ms, True, reply) -> {
      let now = now_ms()
      let #(scan, events, coverage) =
        watch_scan.scan_near(
          state.scan,
          asked_dir,
          now,
          budget_ms,
          now_ms,
          real_fs(),
        )
      let events = list.append(state.pending, events)
      let seq = state.seq + 1
      process.send(reply, Outcome(events, coverage, True, seq))
      actor.continue(State(..state, scan:, pending: events, seq:))
    }
    Scan(asked_dir, budget_ms, False, reply) -> {
      let now = now_ms()
      let due = case watch_scan.cheap(state.scan) {
        True -> True
        False ->
          case watch_scan.last_scan_ms(state.scan) {
            None -> True
            Some(last) -> now - last >= scan_interval_ms
          }
      }
      case due {
        True -> {
          let #(scan, events, coverage) =
            watch_scan.scan(
              state.scan,
              asked_dir,
              now,
              budget_ms,
              now_ms,
              real_fs(),
            )
          let events = list.append(state.pending, events)
          let seq = state.seq + 1
          process.send(reply, Outcome(events, coverage, True, seq))
          actor.continue(State(..state, scan:, pending: events, seq:))
        }
        False -> {
          let #(scan, coverage) = watch_scan.note_question(state.scan, now)
          let seq = state.seq + 1
          process.send(reply, Outcome(state.pending, coverage, False, seq))
          actor.continue(State(..state, scan:, seq:))
        }
      }
    }
  }
}

fn real_fs() -> watch_scan.Fs {
  watch_scan.Fs(
    list_dir: list_dir,
    stat: stat,
    hash: fn(path) { hash_file(path, watch_scan.racy_hash_max_bytes) },
    now_second: now_second,
  )
}

/// What a question's caller needs to know about one server.
pub type Server {
  Server(
    proc_pid: Pid,
    mode: WatchMode,
    root: String,
    /// Names, or paths such as `vendor/bundle`, skipped besides
    /// `watch_scan.always_skipped`.
    skip: List(String),
    extensions: List(String),
    /// How long a scan may walk.
    budget_ms: Int,
    /// What's left of the question's own deadline, when it has one: the
    /// scan and the wait for it never go past it.
    time_left_ms: Option(Int),
  )
}

/// What a scan before a question found.
pub type BeforeQuestion {
  BeforeQuestion(
    /// The `workspace/didChangeWatchedFiles` notification to send the
    /// server, encoded, if any change matched its watchers.
    notifications: List(String),
    /// A note for the answer while its picture isn't complete.
    note: Option(String),
    /// Call once `notifications` are in a batch the proc has written:
    /// until then the scanner keeps the events and sends them again.
    ack: fn() -> Nil,
  )
}

fn no_ack() -> Nil {
  Nil
}

pub type WatchMode {
  IfRegistered
  Always
  Never
}

/// ADR-043: before a question on `server`, scan for files changed on
/// disk; returns the notification for the changes the server watches,
/// for the caller to send in the question's sync batch, and a note for
/// the answer while its picture isn't complete. `asked_file` is the
/// question's file path, when it has one; `open` gives the paths pharos
/// holds open on the server (their changes travel as didChange,
/// ADR-038), asked only when there are events to filter.
pub fn before_question(
  server: Server,
  asked_file: Option(String),
  open: fn() -> List(String),
) -> BeforeQuestion {
  let registered = watchers.for_proc(server.proc_pid)
  let watching = case server.mode, registered {
    Never, _ -> None
    IfRegistered, [] -> None
    IfRegistered, ws -> Some(ws)
    Always, [] ->
      Some(
        list.map(server.extensions, fn(ext) {
          watchers.Watcher("**/*" <> ext, None, 7)
        }),
      )
    Always, ws -> Some(ws)
  }
  case watching {
    None -> {
      trace_scan(server, list.length(registered), "not watched", 0)
      BeforeQuestion([], None, no_ack)
    }
    Some(ws) ->
      case scanner(server.proc_pid, server.root, server.skip) {
        Error(_) -> {
          trace_scan(server, list.length(registered), "no scanner", 0)
          BeforeQuestion([], Some(note(server.root, NotChecked)), no_ack)
        }
        Ok(subject) -> {
          let asked_dir = option.map(asked_file, parent_dir)
          let #(budget_ms, wait_ms) = scan_limits(server)
          // A send and a bounded receive, not process.call: a call that
          // times out raises, which would take the question with it. The
          // reply goes to an alias, dropped after a timeout, so a reply
          // that comes too late never lands in this process's mailbox.
          let tag = new_tag()
          let alias = new_alias()
          process.send(
            subject,
            Scan(
              asked_dir,
              budget_ms,
              budget_ms < server.budget_ms,
              process.unsafely_create_subject(alias, tag),
            ),
          )
          let inbox: Subject(Outcome) =
            process.unsafely_create_subject(process.self(), tag)
          let received = safe_call(fn() { process.receive(inbox, wait_ms) })
          drop_alias(alias)
          let received = case received {
            Ok(Ok(outcome)) -> Ok(outcome)
            // A reply that raced in before the alias went.
            _ -> process.receive(inbox, 0)
          }
          case received {
            Error(_) -> {
              trace_scan(server, list.length(registered), "no reply", 0)
              BeforeQuestion([], Some(note(server.root, NotChecked)), no_ack)
            }
            Ok(outcome) -> {
              trace_scan(
                server,
                list.length(registered),
                case outcome.scanned {
                  True -> "scanned"
                  False -> "too soon"
                },
                list.length(outcome.events),
              )
              // The asked file is synced right after (didOpen or a
              // re-sync, ADR-038), like the open ones.
              BeforeQuestion(
                notifications: changes_notification(ws, outcome.events, fn() {
                  list.append(option.values([asked_file]), open())
                }),
                note: case
                  outcome_progress(outcome, budget_ms < server.budget_ms)
                {
                  Ok(progress) -> Some(note(server.root, progress))
                  Error(Nil) -> None
                },
                ack: fn() { process.send(subject, Delivered(outcome.seq)) },
              )
            }
          }
        }
      }
  }
}

/// One debug line per question's scan (pharos/lsp/watch=debug), so a
/// test or a support log can tell a scan skipped from a scan that found
/// nothing.
fn trace_scan(
  server: Server,
  registered: Int,
  outcome: String,
  events: Int,
) -> Nil {
  log.fields_at("pharos/lsp/watch", log_entry.Debug, "watched-files scan", [
    #("root", server.root),
    #("registered", int.to_string(registered)),
    #("outcome", outcome),
    #("events", int.to_string(events)),
  ])
}

@external(erlang, "pharos_watch_ffi", "new_alias")
fn new_alias() -> Pid

@external(erlang, "pharos_watch_ffi", "drop_alias")
fn drop_alias(alias: Pid) -> Nil

@external(erlang, "erlang", "make_ref")
fn new_tag() -> dynamic.Dynamic

/// The scan's budget and how long the question waits for its reply.
/// With a deadline, the scan gets at most half the time left, so the
/// reply has the other half to arrive; the wait never passes the
/// deadline. A reply that comes too late is resent with the next one.
pub fn scan_limits(server: Server) -> #(Int, Int) {
  case server.time_left_ms {
    None -> #(server.budget_ms, server.budget_ms + scanner_grace_ms)
    Some(left) -> {
      let left = int.max(left, 0)
      #(
        int.min(server.budget_ms, left / 2),
        int.max(int.min(server.budget_ms + scanner_grace_ms, left), 1),
      )
    }
  }
}

/// How far a question's scan got, for its note; Error for a complete
/// picture.
pub type Progress {
  /// The first pass hasn't finished: `dirs` directories recorded so far.
  FirstPass(dirs: Int)
  /// A pass is under way: `visited` of about `total` directories checked
  /// for this question.
  Checked(visited: Int, total: Int)
  /// The same, in a scan the question's short timeout squeezed: such
  /// scans move on through the tree with every question, not every 2 s.
  CheckedSqueezed(visited: Int, total: Int)
  /// Not scanned: the last scan was under `scan_interval_ms` ago.
  TooSoon
  /// Not scanned: no time left before the question's deadline.
  NoTime
  /// The scanner didn't answer in time, or couldn't start.
  NotChecked
}

fn outcome_progress(outcome: Outcome, squeezed: Bool) -> Result(Progress, Nil) {
  case outcome.coverage, outcome.scanned {
    watch_scan.Complete, _ -> Error(Nil)
    watch_scan.FirstPassRunning(_), False -> Ok(TooSoon)
    watch_scan.FirstPassRunning(0), True -> Ok(NoTime)
    watch_scan.FirstPassRunning(dirs), True -> Ok(FirstPass(dirs))
    watch_scan.Partial(..), False -> Ok(TooSoon)
    watch_scan.Partial(0, _), True -> Ok(NoTime)
    watch_scan.Partial(visited, total), True ->
      case squeezed {
        True -> Ok(CheckedSqueezed(visited, total))
        False -> Ok(Checked(visited, total))
      }
  }
}

/// The notification for the events `ws` wants, leaving out the open
/// documents (`open`, asked only when there are events); [] for none.
pub fn changes_notification(
  ws: List(Watcher),
  events: List(Event),
  open: fn() -> List(String),
) -> List(String) {
  let open = case events {
    [] -> []
    _ -> open()
  }
  let changes =
    list.filter_map(events, fn(event) {
      // A file the first pass can't place goes as Created where the
      // server watches creations (it re-reads a file it already had),
      // else as Changed.
      let candidates = case event.change {
        watch_scan.Created -> [1]
        watch_scan.Changed -> [2]
        watch_scan.Deleted -> [3]
        watch_scan.NewOrChanged -> [1, 2]
      }
      case list.contains(open, event.path) {
        True -> Error(Nil)
        False ->
          case
            list.find(candidates, fn(change) {
              watchers.wanted(ws, event.path, change)
            })
          {
            Ok(change) ->
              Ok(
                json.object([
                  #("uri", json.string(workspace_root.path_to_uri(event.path))),
                  #("type", json.int(change)),
                ]),
              )
            Error(Nil) -> Error(Nil)
          }
      }
    })
  case changes {
    [] -> []
    _ -> {
      log.fields_at(
        "pharos/lsp/watch",
        log_entry.Debug,
        "files changed on disk",
        [#("count", int.to_string(list.length(changes)))],
      )
      [
        json.to_string(
          json.object([
            #("jsonrpc", json.string("2.0")),
            #("method", json.string("workspace/didChangeWatchedFiles")),
            #(
              "params",
              json.object([#("changes", json.preprocessed_array(changes))]),
            ),
          ]),
        ),
      ]
    }
  }
}

/// The one sentence an unsure answer carries.
pub fn note(root: String, progress: Progress) -> String {
  let interval = int.to_string(scan_interval_ms / 1000) <> " s"
  let what = case progress {
    FirstPass(dirs) ->
      "pharos is building its first record of the tree ("
      <> int.to_string(dirs)
      <> " directories so far) and adds to it on later questions, at most every "
      <> interval
    Checked(visited, total) ->
      "pharos checked "
      <> int.to_string(visited)
      <> " of about "
      <> int.to_string(total)
      <> " directories before this answer and checks more on later questions, at most every "
      <> interval
    CheckedSqueezed(visited, total) ->
      "pharos checked "
      <> int.to_string(visited)
      <> " of about "
      <> int.to_string(total)
      <> " directories before this answer (its short timeout left little time) and checks more with each later question"
    TooSoon ->
      "pharos checks a tree this size at most every "
      <> interval
      <> " and didn't check before this answer"
    NoTime ->
      "pharos had no time left in this question's timeout to check for them"
    NotChecked -> "pharos couldn't check for them before this answer"
  }
  "Files changed on disk under "
  <> root
  <> " may not have reached the server yet: "
  <> what
  <> ". Ask again in a few seconds if this answer looks out of date."
}

fn parent_dir(path: String) -> String {
  case string.split(path, "/") |> list.reverse {
    [_, ..rest] if rest != [] && rest != [""] ->
      string.join(list.reverse(rest), "/")
    _ -> "/"
  }
}

@external(erlang, "pharos_watch_ffi", "list_dir")
fn list_dir(dir: String) -> Result(List(String), Nil)

@external(erlang, "pharos_watch_ffi", "stat")
fn stat(path: String) -> Result(#(String, Int, Int, Int, Int), Nil)

@external(erlang, "pharos_watch_ffi", "hash_file")
fn hash_file(path: String, max_bytes: Int) -> Result(BitArray, Nil)

@external(erlang, "pharos_watch_ffi", "now_seconds")
fn now_second() -> Int

@external(erlang, "pharos_watch_ffi", "spawned_second")
fn spawned_second(proc_pid: Pid) -> Int

@external(erlang, "pharos_watch_ffi", "scanners_init")
pub fn init() -> Nil

@external(erlang, "pharos_watch_ffi", "scanner_lookup")
fn lookup(proc_pid: Pid) -> Result(Subject(Msg), Nil)

@external(erlang, "pharos_watch_ffi", "scanner_claim")
fn claim(proc_pid: Pid, subject: Subject(Msg)) -> Bool

@external(erlang, "pharos_watch_ffi", "scanner_drop")
fn drop(proc_pid: Pid) -> Nil

@external(erlang, "pharos_watch_ffi", "safe_call")
fn safe_call(f: fn() -> a) -> Result(a, Nil)

@external(erlang, "pharos_watch_ffi", "now_ms")
fn now_ms() -> Int
