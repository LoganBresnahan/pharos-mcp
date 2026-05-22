//// CLI meta-commands: `--doctor` + `--purge-cache`.
////
//// Both run before the supervised tree boots and exit when done.
//// They share the same `Config` resolution path as a normal boot
//// (so the diagnostic surface reflects what `pharos.main` would
//// actually see) but never spawn the LSP pool / HTTP listener.
////
//// Exit codes:
////   0 — success / no issues found
////   1 — at least one diagnostic flagged a problem (doctor only)
////   2 — operation failed outright (purge-cache I/O error, etc.)

import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import pharos/config
import pharos/lsp/instance_track
import pharos/lsp/languages.{type LanguageConfig}
import pharos/lsp/registry as lsp_registry

const server_version: String = "0.0.1"

/// Clear Burrito's extract-cache for pharos. Removes all installed
/// versions under `<user_cache>/burrito_runtime/_/pharos/`. Returns
/// the exit code main should propagate.
pub fn purge_cache() -> Int {
  let path = burrito_cache_root()
  let size_before = dir_size_bytes(path)

  case size_before {
    0 -> {
      io.println("pharos --purge-cache: no Burrito cache at " <> path)
      0
    }
    bytes -> {
      io.println(
        "pharos --purge-cache: removing "
          <> mb_str(bytes)
          <> " from "
          <> path,
      )
      case rm_rf(path) {
        Ok(_) -> {
          io.println(
            "Cleared. Next run will re-extract the Burrito payload "
              <> "(adds ~1-3s to first invocation).",
          )
          0
        }
        Error(reason) -> {
          io.println("error: rm -rf failed: " <> reason)
          2
        }
      }
    }
  }
}

/// Self-diagnostic. Loads Config the same way `pharos.boot` does,
/// then walks every knob and language entry, printing resolved
/// values and flagging anything that would break a normal run.
/// Doubles as a Burrito warmup — running it once after install
/// extracts the payload so the first MCP host spawn does not see
/// the cold-extract latency.
pub fn doctor() -> Int {
  io.println("pharos doctor")
  io.println("=============")
  io.println("")

  // Section: build / runtime
  let beam = beam_version_info()
  io.println("pharos version:      " <> server_version)
  io.println("OTP release:         " <> beam.otp)
  io.println("ERTS version:        " <> beam.erts)

  let cache_path = burrito_cache_root()
  let cache_size = dir_size_bytes(cache_path)
  io.println("Burrito cache:       " <> cache_path)
  io.println("Burrito cache size:  " <> mb_str(cache_size))
  io.println("")

  // Section: resolved Config
  let cfg = config.load()
  io.println("Resolved Config")
  io.println("---------------")
  io.println("transport:           " <> transport_label(cfg.transport))
  io.println(
    "http.bind:port:      " <> cfg.http.bind <> ":" <> int.to_string(cfg.http.port),
  )
  io.println("http.port_file:      " <> opt_str(cfg.http.port_file, "(unset)"))
  io.println(
    "log.filter:          "
      <> case cfg.log.filter_spec {
        "" -> "(default: info)"
        s -> s
      },
  )
  io.println("log.file:            " <> opt_str(cfg.log.file, "(stderr only)"))
  io.println("log.ring_enabled:    " <> bool_str(cfg.log.ring_enabled))
  io.println("log.stderr_enabled:  " <> bool_str(cfg.log.stderr_enabled))
  io.println("lsp.trace:           " <> bool_str(cfg.lsp.trace))
  io.println(
    "runtime.trace_calls: " <> bool_str(cfg.runtime.trace_calls_enabled),
  )
  io.println("tools.filter:        [" <> string.join(cfg.tools.entries, ", ") <> "]")
  io.println("")

  // Section: language registry — probe each server's command on PATH
  let langs = languages_dict_to_list()
  let total_servers =
    list.fold(langs, 0, fn(acc, entry) { acc + list.length({ entry.1 }.servers) })
  io.println(
    "Language registry ("
      <> int.to_string(list.length(langs))
      <> " languages, "
      <> int.to_string(total_servers)
      <> " server(s))",
  )
  io.println(string.repeat("-", 60))

  let lang_failures =
    list.fold(langs, 0, fn(failures, entry) {
      let #(id, lang) = entry
      list.fold(lang.servers, failures, fn(inner_failures, server) {
        case which_executable(server.command) {
          Ok(resolved) -> {
            io.println(
              pad_right(id <> "/" <> server.id, 28)
                <> "  ok     "
                <> server.command
                <> case resolved == server.command {
                  True -> ""
                  False -> " → " <> resolved
                },
            )
            inner_failures
          }
          Error(_) -> {
            io.println(
              pad_right(id <> "/" <> server.id, 28)
                <> "  MISSING  "
                <> server.command
                <> " (not on PATH; install it or override [languages."
                <> id
                <> "] command)",
            )
            inner_failures + 1
          }
        }
      })
    })

  io.println("")

  // Section: summary
  io.println("Summary")
  io.println("-------")
  case lang_failures {
    0 -> {
      io.println("No issues found.")
      0
    }
    n -> {
      io.println(
        int.to_string(n)
          <> " language server binar"
          <> case n {
            1 -> "y"
            _ -> "ies"
          }
          <> " missing. Install per the README install table or "
          <> "override the command in pharos.toml.",
      )
      1
    }
  }
}

// -- Helpers --------------------------------------------------------------

fn languages_dict_to_list() -> List(#(String, LanguageConfig)) {
  // Make sure the registry persistent_term has been populated even
  // when pharos was invoked solely for `--doctor` (no boot path).
  lsp_registry.init()
  lsp_registry.cached()
  |> dict.to_list
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn transport_label(t: config.Transport) -> String {
  case t {
    config.Stdio -> "stdio"
    config.Http -> "http"
    config.Both -> "both"
  }
}

fn opt_str(o: option.Option(String), default: String) -> String {
  case o {
    None -> default
    Some(s) -> s
  }
}

fn bool_str(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn mb_str(bytes: Int) -> String {
  case bytes {
    0 -> "0 bytes (empty / not yet extracted)"
    n if n < 1024 -> int.to_string(n) <> " bytes"
    n if n < 1_048_576 -> int.to_string(n / 1024) <> " KB"
    n -> int.to_string(n / 1_048_576) <> " MB"
  }
}

fn pad_right(s: String, width: Int) -> String {
  let len = string.length(s)
  case len >= width {
    True -> s
    False -> s <> string.repeat(" ", width - len)
  }
}

// -- cleanup (ADR-030 Layer 3) -------------------------------------------

/// Reap LSP children belonging to dead pharos instances. Walks
/// `~/.local/share/pharos/instances/`, identifies subdirs whose
/// owner pharos PID is gone, and removes them (after killing the
/// listed LSP children).
///
/// `apply` distinguishes preview from actual reap:
///   - `False` — dry-run: print findings and exit. Default.
///   - `True`  — invoked with `--yes`: SIGTERM each LSP, wait
///     `grace_ms`, SIGKILL survivors, remove the instance dir.
///
/// Exit codes:
///   0 — operation completed (orphans reaped or none found)
///   2 — at least one signal call failed unexpectedly
pub fn cleanup(apply: Bool, grace_ms: Int) -> Int {
  let root = instance_track.instances_root()
  io.println("pharos cleanup")
  io.println("==============")
  io.println("instance root: " <> root)
  io.println("")

  let dirs = instance_track.list_instance_dirs()
  case dirs {
    [] -> {
      io.println("no instance directories found.")
      0
    }
    _ -> {
      let #(orphans, alive_count) =
        list.fold(dirs, #([], 0), fn(acc, entry) {
          let #(found_orphans, alive) = acc
          let #(owner_pid, dir_path) = entry
          case instance_track.is_pid_alive(owner_pid) {
            True -> #(found_orphans, alive + 1)
            False -> {
              let pid_files = instance_track.list_pid_files(dir_path)
              #(
                [#(owner_pid, dir_path, pid_files), ..found_orphans],
                alive,
              )
            }
          }
        })

      io.println(
        "alive pharos instances (skipped): "
        <> int.to_string(alive_count),
      )
      case orphans {
        [] -> {
          io.println("no orphan instance directories.")
          0
        }
        _ -> {
          let n_orphans = list.length(orphans)
          io.println(
            "orphan instances (owner PID dead): "
            <> int.to_string(n_orphans),
          )
          io.println("")
          list.each(orphans, fn(orphan) {
            let #(owner_pid, dir_path, pid_files) = orphan
            io.println(
              "  - pharos PID " <> int.to_string(owner_pid) <> " (dead)",
            )
            io.println("    dir: " <> dir_path)
            case pid_files {
              [] -> io.println("    no LSP children recorded.")
              _ ->
                list.each(pid_files, fn(pf) {
                  let #(lsp_pid, file_path) = pf
                  let meta = instance_track.read_pid_file(file_path)
                  let binary = lookup_meta(meta, "lsp_binary")
                  let server_id = lookup_meta(meta, "server_id")
                  let alive_marker = case
                    instance_track.is_pid_alive(lsp_pid)
                  {
                    True -> "alive"
                    False -> "gone"
                  }
                  io.println(
                    "      LSP "
                    <> int.to_string(lsp_pid)
                    <> " ("
                    <> alive_marker
                    <> ") "
                    <> server_id
                    <> " "
                    <> binary,
                  )
                })
            }
          })
          io.println("")
          case apply {
            False -> {
              io.println(
                "(dry-run) re-invoke with `--yes` to reap these orphans.",
              )
              0
            }
            True -> {
              io.println("reaping...")
              let failures =
                list.fold(orphans, 0, fn(acc, orphan) {
                  acc + reap_orphan(orphan, grace_ms)
                })
              case failures {
                0 -> {
                  io.println("done.")
                  0
                }
                _ -> {
                  io.println(
                    "completed with "
                    <> int.to_string(failures)
                    <> " signal failures (see above).",
                  )
                  2
                }
              }
            }
          }
        }
      }
    }
  }
}

fn lookup_meta(meta: List(#(String, String)), key: String) -> String {
  meta
  |> list.find(fn(pair) { pair.0 == key })
  |> result.map(fn(pair) { pair.1 })
  |> result.unwrap("?")
}

/// Reap one orphan: SIGTERM each listed LSP, wait `grace_ms`,
/// SIGKILL anyone still alive, then remove the instance directory.
/// Returns the number of unexpected signal failures (always >= 0).
fn reap_orphan(
  orphan: #(Int, String, List(#(Int, String))),
  grace_ms: Int,
) -> Int {
  let #(owner_pid, dir_path, pid_files) = orphan

  // Phase 1: SIGTERM every LSP whose PID is still alive.
  let alive_lsps =
    list.filter(pid_files, fn(pf) {
      instance_track.is_pid_alive(pf.0)
    })
  list.each(alive_lsps, fn(pf) {
    let #(lsp_pid, _path) = pf
    io.println(
      "  SIGTERM pharos="
      <> int.to_string(owner_pid)
      <> " lsp="
      <> int.to_string(lsp_pid),
    )
    case instance_track.signal_pid(lsp_pid, "TERM") {
      Ok(_) -> Nil
      Error(_) -> io.println("    (signal failed)")
    }
  })

  // Phase 2: wait the grace period, then SIGKILL any survivors.
  case alive_lsps {
    [] -> Nil
    _ -> instance_track.sleep_ms(grace_ms)
  }
  let kill_failures =
    list.fold(alive_lsps, 0, fn(acc, pf) {
      let #(lsp_pid, _path) = pf
      case instance_track.is_pid_alive(lsp_pid) {
        False -> acc
        True -> {
          io.println(
            "  SIGKILL lsp="
            <> int.to_string(lsp_pid)
            <> " (survived TERM)",
          )
          case instance_track.signal_pid(lsp_pid, "KILL") {
            Ok(_) -> acc
            Error(_) -> {
              io.println("    (signal failed)")
              acc + 1
            }
          }
        }
      }
    })

  // Phase 3: remove the instance directory.
  instance_track.remove_dir_recursive(dir_path)
  io.println("  removed " <> dir_path)
  kill_failures
}

// -- BEAM / FFI ----------------------------------------------------------

pub type BeamInfo {
  BeamInfo(erts: String, otp: String, system: String)
}

@external(erlang, "pharos_runtime_ffi", "beam_version_info")
fn beam_version_info_raw() -> Result(BeamInfo, Nil)

fn beam_version_info() -> BeamInfo {
  case beam_version_info_raw() {
    Ok(info) -> info
    Error(_) -> BeamInfo(erts: "?", otp: "?", system: "?")
  }
}

@external(erlang, "pharos_runtime_ffi", "burrito_cache_root")
fn burrito_cache_root() -> String

@external(erlang, "pharos_fs_ffi", "rm_rf")
fn rm_rf(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "dir_size_bytes")
fn dir_size_bytes(path: String) -> Int

@external(erlang, "pharos_fs_ffi", "which_executable")
fn which_executable(cmd: String) -> Result(String, Nil)
