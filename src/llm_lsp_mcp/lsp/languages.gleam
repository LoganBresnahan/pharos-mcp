//// Language registry — maps a file URI to the LSP we should drive.
////
//// The bridge supports an unbounded set of languages by holding a
//// table of `LanguageConfig` records, one per language we know how
//// to launch. `for_uri/2` picks a config based on file extension;
//// `default_registry/0` ships a sensible bundle covering Rust, Go,
//// TypeScript/JavaScript, and Python.
////
//// `command` is the path to the LSP server binary. v0.1 hardcodes
//// absolute paths matching the developer's local install — cleaner
//// PATH lookup via `os:find_executable/1` will land in a later
//// milestone, alongside user-provided overrides via config file.
////
//// initialization_options is server-defined per LSP spec — each
//// upstream documents its own shape. The defaults here surface the
//// settings most consumers want without forcing them to read
//// upstream docs (e.g. rust-analyzer's `checkOnSave`, gopls's
//// `usePlaceholders`).

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/string

/// How the server delivers diagnostics. Affects which transport
/// `tools/tier1/diagnostics` uses.
pub type DiagnosticsMode {
  /// Server pushes `textDocument/publishDiagnostics` notifications
  /// at its own pace. Client drains the stream watching for the URI
  /// it cares about. Used by rust-analyzer, gopls, pyright.
  Push
  /// Server only responds to explicit `textDocument/diagnostic`
  /// requests (LSP 3.17+). Used by typescript-language-server.
  Pull
}

pub type LanguageConfig {
  LanguageConfig(
    /// LSP-spec language identifier sent in `textDocument/didOpen`'s
    /// `languageId` field. See
    /// https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#textDocumentItem
    id: String,
    /// Absolute path to the LSP server executable.
    command: String,
    /// CLI args. Some servers (typescript-language-server, pyright)
    /// require `--stdio`; others take none.
    args: List(String),
    /// File extensions that trigger this language (incl. leading dot).
    file_extensions: List(String),
    /// Files to look for when ascending the directory tree to find
    /// the workspace root. First match wins (innermost ancestor).
    root_markers: List(String),
    /// Server-specific `initializationOptions` payload. Pass-through
    /// to the LSP at the `initialize` request.
    initialization_options: Json,
    /// Diagnostics delivery mode for this server.
    diagnostics_mode: DiagnosticsMode,
  )
}

pub type LookupError {
  /// File extension does not match any registered language.
  UnknownLanguage(uri: String)
  /// URI did not start with `file://` — caller passed something else.
  NotAFileUri(uri: String)
}

/// Bundle of defaults for the four languages we commonly support.
pub fn default_registry() -> Dict(String, LanguageConfig) {
  dict.from_list([
    #("rust", rust()),
    #("go", go()),
    #("typescript", typescript()),
    #("python", python()),
  ])
}

/// Pick a `LanguageConfig` for the file at `uri`. First match by
/// extension wins; iteration order over the registry is dict-defined
/// (unspecified) so consumers should keep extension sets disjoint.
pub fn for_uri(
  registry: Dict(String, LanguageConfig),
  uri: String,
) -> Result(LanguageConfig, LookupError) {
  case string.starts_with(uri, "file://") {
    False -> Error(NotAFileUri(uri))
    True -> {
      let path = uri
      let configs = dict.values(registry)
      case
        list.find(configs, fn(config) {
          list.any(config.file_extensions, fn(ext) {
            string.ends_with(path, ext)
          })
        })
      {
        Ok(config) -> Ok(config)
        Error(Nil) -> Error(UnknownLanguage(uri))
      }
    }
  }
}

// -- Bundled defaults ----------------------------------------------------

fn rust() -> LanguageConfig {
  LanguageConfig(
    id: "rust",
    command: "/home/oof/.cargo/bin/rust-analyzer",
    args: [],
    file_extensions: [".rs"],
    root_markers: ["Cargo.toml", "rust-project.json"],
    initialization_options: json.object([
      #("checkOnSave", json.bool(True)),
      #("check", json.object([#("command", json.string("check"))])),
      #("procMacro", json.object([#("enable", json.bool(True))])),
    ]),
    diagnostics_mode: Push,
  )
}

fn go() -> LanguageConfig {
  LanguageConfig(
    id: "go",
    command: "/home/oof/.asdf/shims/gopls",
    args: [],
    file_extensions: [".go"],
    root_markers: ["go.mod", "go.work"],
    initialization_options: json.object([
      #("usePlaceholders", json.bool(True)),
      #("completeUnimported", json.bool(True)),
    ]),
    diagnostics_mode: Push,
  )
}

fn typescript() -> LanguageConfig {
  LanguageConfig(
    id: "typescript",
    command: "/home/oof/.nvm/versions/node/v25.4.0/bin/typescript-language-server",
    args: ["--stdio"],
    file_extensions: [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"],
    root_markers: ["tsconfig.json", "jsconfig.json", "package.json"],
    initialization_options: json.object([
      #("hostInfo", json.string("llm_lsp_mcp")),
    ]),
    // typescript-language-server does NOT implement
    // `textDocument/diagnostic` (returns -32601 "Unhandled method")
    // and does not push publishDiagnostics until a
    // `workspace/didChangeConfiguration` notification with TS-server
    // settings has been sent. Both routes are unimplemented as of
    // M4 — get_diagnostics will return NoDiagnosticsObserved for
    // .ts files until a follow-up milestone wires up the
    // configuration sync. hover / goto_definition /
    // find_references / document_symbols / workspace_symbols all
    // work normally.
    diagnostics_mode: Push,
  )
}

fn python() -> LanguageConfig {
  LanguageConfig(
    id: "python",
    command: "/home/oof/.nvm/versions/node/v25.4.0/bin/pyright-langserver",
    args: ["--stdio"],
    file_extensions: [".py", ".pyi"],
    root_markers: [
      "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt",
      ".python-version",
    ],
    // pyright's main config is in pyrightconfig.json or pyproject.toml.
    initialization_options: json.object([]),
    diagnostics_mode: Push,
  )
}
