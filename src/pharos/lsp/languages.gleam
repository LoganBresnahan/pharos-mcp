//// Language registry — maps a file URI to one or more LSP servers
//// pharos should drive for that file's language.
////
//// Every language carries a list of `ServerConfig` entries. Today
//// (Stage 1 of ADR-019) every bundled language ships with a single
//// server in that list; Stage 3 will add ruff alongside pyright for
//// python so methods route per-server. The single-server form
//// (`languages.rust = pyright`, etc.) is the canonical shape for
//// languages whose ecosystem provides one capable server.
////
//// `MethodScope` declares which LSP methods a server handles:
////   - `All` — every textDocument/* and workspace/* method (the
////     "main" LSP per language).
////   - `Only(methods)` — explicit list. Used to layer formatters or
////     linters on top of the main server (ruff over pyright).
////
//// Per-method routing strategy (Primary / Merge / FanOut) lives in
//// the tool dispatch layer and lands in Stage 3.

import gleam/dict.{type Dict}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// How the server delivers diagnostics. Affects which transport
/// `tools/tier1/diagnostics` uses.
pub type DiagnosticsMode {
  /// Server pushes `textDocument/publishDiagnostics` notifications
  /// at its own pace. Client drains the stream watching for the URI
  /// it cares about. Used by rust-analyzer, gopls, pyright.
  Push
  /// Server only responds to explicit `textDocument/diagnostic`
  /// requests (LSP 3.17+). Used by typescript-language-server, ruff.
  Pull
}

/// Post-discovery root promotion strategy. After
/// `workspace_root.discover_from_uri` finds the innermost ancestor
/// containing one of `root_markers`, we may want to walk further up
/// to land at a "true" workspace root. Per ADR-015.
pub type RootPromotion {
  /// Use whatever `discover_from_uri` returns. Default for most
  /// languages.
  NoPromotion
  /// Walk up looking for a Cargo.toml whose `[workspace]` heading
  /// is present, and promote to its directory. Falls back to the
  /// originally-discovered root if no ancestor workspace is found.
  /// Default for rust.
  CargoWorkspacePromotion
}

/// Method-scope declaration: which LSP methods a server handles.
/// Used by the tool dispatch layer (Stage 3) to pick which server
/// to call for a given request.
pub type MethodScope {
  /// Server handles every textDocument/* and workspace/* method.
  /// Used for the "main" LSP per language (rust-analyzer, gopls,
  /// pyright, etc.).
  All
  /// Server handles only the listed method names. Used to layer a
  /// formatter or linter on top of the main server (e.g. ruff
  /// declares `Only(["textDocument/formatting", ...])` so its
  /// formatter wins over pyright's `-32601`).
  Only(methods: List(String))
}

/// A single LSP server pharos can spawn. One language may have
/// several. Per ADR-019.
pub type ServerConfig {
  ServerConfig(
    /// Unique within the language — e.g. `"rust-analyzer"` for the
    /// rust primary, `"ruff"` for the python linter overlay. Used
    /// by the pool as part of the cache key (Stage 2) and by tools
    /// that name a specific server (`runtime_kill_lsp`, etc.).
    id: String,
    /// Path to the LSP server executable (or bare name resolved
    /// via PATH). Per ADR-018.
    command: String,
    /// CLI args. Some servers (typescript-language-server, pyright)
    /// require `--stdio`.
    args: List(String),
    /// Server-specific `initializationOptions` payload.
    initialization_options: Json,
    /// Settings sent post-`initialized` via
    /// `workspace/didChangeConfiguration`, AND used by the
    /// `workspace/configuration` server-request handler. `None`
    /// means no configuration push.
    workspace_configuration: Option(Dict(String, Json)),
    /// Which LSP methods this server handles. Drives per-method
    /// routing in the tool dispatch layer (Stage 3).
    methods: MethodScope,
    /// Diagnostics delivery mode for this server.
    diagnostics_mode: DiagnosticsMode,
    /// `$/progress` token name the server emits during readiness
    /// work (typically initial indexing). `None` skips the wait.
    readiness_token: Option(String),
  )
}

pub type LanguageConfig {
  LanguageConfig(
    /// LSP-spec language identifier sent in `textDocument/didOpen`'s
    /// `languageId` field.
    id: String,
    /// File extensions that trigger this language (incl. leading dot).
    file_extensions: List(String),
    /// Files to look for when ascending the directory tree to find
    /// the workspace root. First match wins (innermost ancestor).
    root_markers: List(String),
    /// Post-discovery root promotion. Per ADR-015. Rust uses
    /// `CargoWorkspacePromotion` so sibling-crate files share one
    /// rust-analyzer.
    root_promotion: RootPromotion,
    /// Servers pharos will spawn for this language. Currently every
    /// bundled language ships with one entry; Stage 3 of ADR-019
    /// adds ruff alongside pyright for python. Order matters when
    /// `MethodScope` overlaps — see Stage 3 routing rules.
    servers: List(ServerConfig),
  )
}

pub type LookupError {
  /// File extension does not match any registered language.
  UnknownLanguage(uri: String)
  /// URI did not start with `file://` — caller passed something else.
  NotAFileUri(uri: String)
}

/// Convenience accessor for the (currently universal) single-server
/// case: returns the first `ServerConfig` in the language's `servers`
/// list. Stage 1 of ADR-019 leaves every callsite that still wants a
/// single server using this helper; Stage 3 introduces explicit
/// per-method routing for callers that need it.
pub fn primary_server(lang: LanguageConfig) -> Result(ServerConfig, Nil) {
  case lang.servers {
    [first, ..] -> Ok(first)
    [] -> Error(Nil)
  }
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
      let configs = dict.values(registry)
      case
        list.find(configs, fn(config) {
          list.any(config.file_extensions, fn(ext) {
            string.ends_with(uri, ext)
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
    file_extensions: [".rs"],
    root_markers: ["Cargo.toml", "rust-project.json"],
    root_promotion: CargoWorkspacePromotion,
    servers: [
      ServerConfig(
        id: "rust-analyzer",
        command: "rust-analyzer",
        args: [],
        initialization_options: json.object([
          #("checkOnSave", json.bool(True)),
          #("check", json.object([#("command", json.string("check"))])),
          #("procMacro", json.object([#("enable", json.bool(True))])),
        ]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: Some("rustAnalyzer/Indexing"),
      ),
    ],
  )
}

fn go() -> LanguageConfig {
  LanguageConfig(
    id: "go",
    file_extensions: [".go"],
    root_markers: ["go.mod", "go.work"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        id: "gopls",
        command: "gopls",
        args: [],
        initialization_options: json.object([
          #("usePlaceholders", json.bool(True)),
          #("completeUnimported", json.bool(True)),
        ]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: Some("setup"),
      ),
    ],
  )
}

fn typescript() -> LanguageConfig {
  LanguageConfig(
    id: "typescript",
    file_extensions: [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"],
    root_markers: ["tsconfig.json", "jsconfig.json", "package.json"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        id: "typescript-language-server",
        command: "typescript-language-server",
        args: ["--stdio"],
        initialization_options: json.object([
          #("hostInfo", json.string("pharos")),
        ]),
        // typescript-language-server gates publishDiagnostics on
        // `workspace/didChangeConfiguration` arriving post-`initialized`
        // and on `workspace/configuration` server-pull requests being
        // answered.
        workspace_configuration: Some(
          dict.from_list([
            #("typescript", typescript_section_settings()),
            #("javascript", typescript_section_settings()),
            #(
              "completions",
              json.object([#("completeFunctionCalls", json.bool(False))]),
            ),
            #(
              "diagnostics",
              json.object([
                #("ignoredCodes", json.preprocessed_array([])),
              ]),
            ),
          ]),
        ),
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
      ),
    ],
  )
}

/// Shared body of the `typescript` and `javascript` sections of
/// typescript-language-server's workspace_configuration.
fn typescript_section_settings() -> Json {
  json.object([
    #(
      "preferences",
      json.object([
        #("importModuleSpecifier", json.string("shortest")),
        #("quoteStyle", json.string("auto")),
      ]),
    ),
    #(
      "suggest",
      json.object([
        #("completeFunctionCalls", json.bool(False)),
      ]),
    ),
    #(
      "format",
      json.object([
        #("enable", json.bool(True)),
      ]),
    ),
    #(
      "tsserver",
      json.object([
        #("useSyntaxServer", json.string("auto")),
        #("experimental", json.object([])),
      ]),
    ),
    #(
      "implementationsCodeLens",
      json.object([#("enabled", json.bool(True))]),
    ),
    #(
      "referencesCodeLens",
      json.object([#("enabled", json.bool(True))]),
    ),
  ])
}

fn python() -> LanguageConfig {
  LanguageConfig(
    id: "python",
    file_extensions: [".py", ".pyi"],
    root_markers: [
      "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt",
      ".python-version",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        id: "pyright",
        command: "pyright-langserver",
        args: ["--stdio"],
        // pyright's main config is in pyrightconfig.json or pyproject.toml.
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        // Pyright advertises `diagnosticProvider` (LSP 3.17 pull) but
        // does not reliably push notifications. Pull mode wins.
        diagnostics_mode: Pull,
        readiness_token: Some("Indexing"),
      ),
    ],
  )
}
