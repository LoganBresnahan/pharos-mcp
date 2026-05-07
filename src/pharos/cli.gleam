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
import gleam/string
import pharos/config
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

  // Section: language registry — probe each command on PATH
  let langs = languages_dict_to_list()
  io.println("Language registry (" <> int.to_string(list.length(langs)) <> ")")
  io.println(string.repeat("-", 60))

  let lang_failures =
    list.fold(langs, 0, fn(failures, entry) {
      let #(id, lang) = entry
      let probe = which_executable(lang.command)
      case probe {
        Ok(resolved) -> {
          io.println(
            pad_right(id, 16)
              <> "  ok     "
              <> lang.command
              <> case resolved == lang.command {
                True -> ""
                False -> " → " <> resolved
              },
          )
          failures
        }
        Error(_) -> {
          io.println(
            pad_right(id, 16)
              <> "  MISSING  "
              <> lang.command
              <> " (not on PATH; install it or override [languages."
              <> id
              <> "] command)",
          )
          failures + 1
        }
      }
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
