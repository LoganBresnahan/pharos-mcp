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
/// Used by the tool dispatch layer to pick which server to call for
/// a given request.
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

/// Per-method dispatch strategy for the tool layer.
///   - `Primary` — call the first server whose scope covers the
///     method; return its result. Used for hover, goto_*, references,
///     formatting, rename, signature_help — methods whose answer is
///     uniquely owned by one server.
///   - `Merge` — call every server whose scope covers the method,
///     concatenate the response's diagnostic-shaped arrays.
///     Used for `textDocument/diagnostic` so pyright and ruff both
///     contribute items.
///   - `FanOut` — call every server, concatenate the response's
///     code-action-shaped arrays. Used for `textDocument/codeAction`
///     so refactoring servers + linters can both surface fixes.
pub type RouteStrategy {
  Primary
  Merge
  FanOut
}

/// Default routing strategy per LSP method. The tool layer consults
/// this when picking how to dispatch. Values match the ADR-019
/// initial table; future work can make this configurable per
/// language via the override file.
pub fn route_strategy_for_method(method: String) -> RouteStrategy {
  case method {
    "textDocument/diagnostic" -> Merge
    "textDocument/codeAction" -> FanOut
    _ -> Primary
  }
}

/// Pick every server whose `MethodScope` covers `method`, with the
/// **Primary** routing rule applied: `Only`-scope matches win, and
/// `All`-scope is consulted only as a fallback when no `Only`
/// matches. Used by `Primary` and `FanOut` strategies — the former
/// picks `head`, the latter consumes the whole list.
pub fn servers_for_method(
  config: LanguageConfig,
  method: String,
) -> List(ServerConfig) {
  let only_servers =
    list.filter(config.servers, fn(server) {
      case server.methods {
        Only(methods) -> list.any(methods, fn(m) { m == method })
        All -> False
      }
    })
  case only_servers {
    [] ->
      list.filter(config.servers, fn(server) {
        case server.methods {
          All -> True
          Only(_) -> False
        }
      })
    _ -> only_servers
  }
}

/// Pick every server whose scope **could** answer `method` — both
/// `Only`-with-match servers AND every `All`-scope server. Unlike
/// `servers_for_method/2`, this does NOT prefer `Only` over `All`:
/// when a language has both, both contribute. Used by `Merge`
/// strategy methods (`textDocument/diagnostic`) where every
/// claiming server's items concatenate into one response.
pub fn servers_covering_method(
  config: LanguageConfig,
  method: String,
) -> List(ServerConfig) {
  list.filter(config.servers, fn(server) {
    case server.methods {
      All -> True
      Only(methods) -> list.any(methods, fn(m) { m == method })
    }
  })
}

/// Pick the single server that should answer `method` under the
/// `Primary` routing strategy. First server whose scope covers the
/// method (Only-first-then-All) wins.
pub fn primary_server_for_method(
  config: LanguageConfig,
  method: String,
) -> Result(ServerConfig, Nil) {
  case servers_for_method(config, method) {
    [first, ..] -> Ok(first)
    [] -> Error(Nil)
  }
}

/// Spawn-time readiness probe (ADR-024). After the LSP's `initialize`
/// handshake + optional `$/progress` drain, pool's spawner fires a
/// real query and waits for a non-error / non-null response before
/// marking the proc Ready. The probe is a direct test of "can this
/// LSP answer a question?" — server-agnostic and stronger than the
/// existing proxy signals (initialize done, progress-token drain).
pub type WarmupProbe {
  /// Default — `workspace/symbol` with empty query. Forces the LSP
  /// to walk its symbol index at least once. Works across
  /// rust-analyzer, gopls, pyright, marksman, terraform-ls,
  /// clojure-lsp, metals, jdtls, HLS, PLS, ELP, lua-LS, ruby-lsp,
  /// vscode-*-language-server.
  ProbeWorkspaceSymbol(query: String)
  /// `textDocument/documentSymbol` against `<workspace>/<rel>`. For
  /// LSPs where `workspace/symbol` is unreliable.
  ProbeDocumentSymbol(uri_relative_to_workspace: String)
  /// Opt-out. The LSP is considered Ready as soon as the readiness
  /// drain completes (legacy behavior). Reserved for servers where
  /// no useful probe exists.
  ProbeNone
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
    /// Per ADR-024: total wall-clock budget for the spawn-time
    /// `$/progress` drain + readiness probe loop combined. `None`
    /// uses the global default (60s — see `default_ready_timeout_ms`).
    /// Servers with slow indexing on big workspaces (rust-analyzer,
    /// jdtls) can override to e.g. 90000-180000.
    ready_timeout_ms: Option(Int),
    /// How long to wait for the `initialize` handshake response
    /// before failing. `None` uses the global default
    /// (90s — see `default_initialize_timeout_ms`). jdtls cold start
    /// can take 30-60s, so the global default already accommodates;
    /// override here to TIGHTEN the budget for fast servers if a
    /// faster fail-fast is desired.
    initialize_timeout_ms: Option(Int),
    /// Spawn-time readiness probe (ADR-024). Default
    /// `ProbeWorkspaceSymbol("")` works for ~all bundled servers;
    /// override per-language only when empirical testing shows the
    /// default probe is unreliable.
    warmup_probe: WarmupProbe,
  )
}

/// Used when a `ServerConfig.ready_timeout_ms` is `None`. Per
/// ADR-024 this bounds drain + probe combined; bumped from 30s
/// to 60s so the probe has room to retry on slow indexers.
pub const default_ready_timeout_ms: Int = 60_000

/// Used when a `ServerConfig.initialize_timeout_ms` is `None`.
/// Matches what `pool.gleam` previously hard-coded (after the M12
/// wave-2 jdtls bump from 30s to 90s).
pub const default_initialize_timeout_ms: Int = 90_000

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
    /// ADR-029. Custom URI schemes this language's server emits and
    /// accepts (e.g. `jdt://` for jdtls JAR-contents). Map key is the
    /// scheme name without `://`. Empty for languages whose deps
    /// materialise to disk (rust, go, python, ts, etc.). Read by
    /// session.gleam to whitelist non-`file://` URIs and route them
    /// through this language's session; read by `fetch_uri_contents`
    /// to dispatch the per-scheme LSP method. User-overridable from
    /// toml is post-v1.0 — defaults baked here for now.
    custom_uri_schemes: Dict(String, CustomUriScheme),
  )
}

/// ADR-029. Per-scheme metadata the server needs to materialise
/// content from a custom URI.
pub type CustomUriScheme {
  CustomUriScheme(
    /// LSP method to call with `{uri: <full-uri>}` to fetch the
    /// virtual content. For jdtls: `"java/classFileContents"`.
    fetch_method: String,
    /// JSON path (currently single key only) inside the LSP
    /// response result whose value is the textual contents. For
    /// jdtls's `java/classFileContents`, the response IS the string,
    /// so this is empty. For servers that wrap content in
    /// `{contents: "..."}`, this would be `"contents"`. Empty string
    /// means "the response is the content directly."
    fetch_response_field: String,
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
    // M12 wave 1 — owner ecosystem languages plus easy-LSP additions.
    #("elixir", elixir()),
    #("gleam", gleam()),
    #("lua", lua()),
    #("bash", bash()),
    // M12 wave 2 — broader-coverage languages.
    #("ruby", ruby()),
    #("zig", zig()),
    #("cpp", cpp()),
    #("java", java()),
    // BEAM-native — pharos itself runs on the BEAM, so erlang
    // support is in our wheelhouse.
    #("erlang", erlang()),
    // M12 wave 3 — JVM polyglot + LISP + functional + universals.
    #("scala", scala()),
    #("clojure", clojure()),
    #("haskell", haskell()),
    #("perl", perl()),
    #("html", html()),
    #("css", css()),
    #("json", json_lang()),
    #("yaml", yaml()),
    #("markdown", markdown()),
    #("terraform", terraform()),
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

/// ADR-029. Look up the language + scheme metadata for a custom URI.
/// Walks `registry` and returns the first language whose
/// `custom_uri_schemes` contains a key matching the URI's scheme
/// (the substring before `://`). Returns `Error(Nil)` when no
/// language claims the scheme or when the URI shape is malformed.
///
/// Callers in `session.gleam` use this to route a `jdt://` URI to
/// the java language's active sessions; `fetch_uri_contents` uses it
/// to dispatch the per-scheme LSP method.
pub fn for_custom_uri(
  registry: Dict(String, LanguageConfig),
  uri: String,
) -> Result(#(LanguageConfig, CustomUriScheme), Nil) {
  case string.split_once(uri, "://") {
    Error(_) -> Error(Nil)
    Ok(#(scheme, _rest)) -> {
      let configs = dict.values(registry)
      list.find_map(configs, fn(config) {
        case dict.get(config.custom_uri_schemes, scheme) {
          Ok(meta) -> Ok(#(config, meta))
          Error(_) -> Error(Nil)
        }
      })
    }
  }
}

/// ADR-029. Enumerate every (scheme, language_id) pair across the
/// registry. Used by MCP server startup to generate the
/// `instructions` string advert for custom URI schemes.
pub fn all_custom_schemes(
  registry: Dict(String, LanguageConfig),
) -> List(#(String, String)) {
  dict.values(registry)
  |> list.flat_map(fn(config) {
    config.custom_uri_schemes
    |> dict.keys
    |> list.map(fn(scheme) { #(scheme, config.id) })
  })
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
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
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
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
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
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
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

fn elixir() -> LanguageConfig {
  LanguageConfig(
    id: "elixir",
    file_extensions: [".ex", ".exs"],
    root_markers: ["mix.exs"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // next-ls. Active fork of the Elixir LSP space, faster cold
        // start than elixir-ls (drops dialyzer integration on
        // purpose). Install via release tarball from
        // https://github.com/elixir-tools/next-ls/releases — pre-built
        // binaries for darwin/linux/windows, no mix-archive compile.
        // The official `expert` LSP (elixir-lang/expert) is alpha;
        // milestone 0.2 brings it to next-ls feature parity, 0.3 to
        // elixir-ls parity. Re-evaluate default when expert ships 0.2.
        id: "next-ls",
        command: "next-ls",
        args: ["--stdio"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        // next-ls's progress token shape varies; skip drain. Pharos's
        // content-modified retry catches cold-start races.
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn ruby() -> LanguageConfig {
  LanguageConfig(
    id: "ruby",
    file_extensions: [".rb"],
    root_markers: ["Gemfile", "Rakefile", ".ruby-version"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // ruby-lsp (Shopify). Install via `gem install ruby-lsp`.
        // Modern, supersedes solargraph for most users. Future M13
        // could layer standardrb-lsp via ADR-019 routing; not yet.
        id: "ruby-lsp",
        command: "ruby-lsp",
        args: [],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn zig() -> LanguageConfig {
  LanguageConfig(
    id: "zig",
    file_extensions: [".zig", ".zon"],
    root_markers: ["build.zig", "build.zig.zon"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // zls (zigtools/zls). Per-zig-version; install via asdf
        // plugin or download release matching local zig.
        id: "zls",
        command: "zls",
        args: [],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn cpp() -> LanguageConfig {
  LanguageConfig(
    id: "cpp",
    // Cover both C and C++ extensions; clangd handles both via
    // compile_commands.json (or .clangd config).
    file_extensions: [".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"],
    root_markers: [
      "compile_commands.json", "compile_flags.txt", ".clangd",
      "CMakeLists.txt", ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // clangd ships with LLVM. `apt install clangd-18` (or the
        // bundled-with-LLVM tarball). `--background-index` builds an
        // on-disk index in `.cache/clangd/` so subsequent starts are
        // fast.
        id: "clangd",
        command: "clangd",
        args: ["--background-index"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn scala() -> LanguageConfig {
  LanguageConfig(
    id: "scala",
    file_extensions: [".scala", ".sbt", ".sc", ".mill"],
    root_markers: [
      "build.sbt", "build.sc", "build.mill", "project.scala", ".scala-build",
      ".bsp", ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // metals — Scala Meta. Install via coursier:
        // `cs install metals scala-cli`. First-run on a fresh project
        // bootstraps Bloop (downloads via coursier) before LSP
        // initialize replies — 180s ceiling covers that. Subsequent
        // runs are fast (<10s) because the bootstrap is cached.
        id: "metals",
        command: "metals",
        args: [],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        // metals + Bloop bootstrap on scala3 mainline: `initialize`
        // returns in ~1s but `workspace/symbol` doesn't reply until
        // bloop has imported the build (2-3 min on first run, faster
        // on cached). M14 dogfood showed every probe attempt time
        // out as `transport error during probe` for the full 240s
        // ready_timeout. Same shape as gleam-lsp's deps-download
        // case (ADR-024 follow-up): `ProbeNone` lets pool return
        // the Proc as soon as the initialize handshake completes;
        // the first real tool call carries the cold-bootstrap cost
        // instead of failing the entire spawn. Subsequent tool calls
        // are fast because the Proc is cached.
        ready_timeout_ms: Some(240_000),
        initialize_timeout_ms: Some(180_000),
        warmup_probe: ProbeNone,
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn clojure() -> LanguageConfig {
  LanguageConfig(
    id: "clojure",
    file_extensions: [".clj", ".cljs", ".cljc", ".edn"],
    root_markers: [
      "deps.edn", "project.clj", "shadow-cljs.edn", "build.boot",
      "bb.edn", ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // clojure-lsp native binary (no JVM cold-start). Download from
        // https://github.com/clojure-lsp/clojure-lsp/releases.
        id: "clojure-lsp",
        command: "clojure-lsp",
        args: [],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn haskell() -> LanguageConfig {
  LanguageConfig(
    id: "haskell",
    file_extensions: [".hs", ".lhs"],
    root_markers: [
      "stack.yaml", "cabal.project", "package.yaml", "*.cabal", "hie.yaml",
      ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // HLS via ghcup. The `-wrapper` script picks the right
        // haskell-language-server-X.Y.Z to match the project's GHC
        // version.
        id: "hls",
        command: "haskell-language-server-wrapper",
        args: ["--lsp"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn perl() -> LanguageConfig {
  LanguageConfig(
    id: "perl",
    file_extensions: [".pl", ".pm", ".t", ".pod"],
    root_markers: [
      "Makefile.PL", "Build.PL", "cpanfile", "dist.ini", ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // PerlNavigator (bsmppe-personal/PerlNavigator). Replaces
        // PLS (FractalBoy/perl-language-server), which depended on
        // the abandoned Coro module and single-threaded its parse
        // loop, holding the first request until cold-index finished
        // (~5 min on Mojolicious). PerlNavigator is a node-based
        // VSCode-style LSP — `npm i -g perlnavigator-server` installs
        // the bin at `perlnavigator`. Requires `--stdio` per
        // vscode-languageserver protocol selector.
        id: "perlnavigator",
        command: "perlnavigator",
        args: ["--stdio"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn html() -> LanguageConfig {
  LanguageConfig(
    id: "html",
    file_extensions: [".html", ".htm"],
    root_markers: ["package.json", ".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // vscode-html-language-server, shipped via the
        // `vscode-langservers-extracted` npm package alongside CSS
        // and JSON LSPs.
        id: "vscode-html",
        command: "vscode-html-language-server",
        args: ["--stdio"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn css() -> LanguageConfig {
  LanguageConfig(
    id: "css",
    file_extensions: [".css", ".scss", ".sass", ".less"],
    root_markers: ["package.json", ".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        id: "vscode-css",
        command: "vscode-css-language-server",
        args: ["--stdio"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

/// `json` is a Gleam stdlib module name, so the local helper avoids
/// shadowing.
fn json_lang() -> LanguageConfig {
  LanguageConfig(
    id: "json",
    file_extensions: [".json", ".jsonc", ".json5"],
    root_markers: ["package.json", ".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        id: "vscode-json",
        command: "vscode-json-language-server",
        args: ["--stdio"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn yaml() -> LanguageConfig {
  LanguageConfig(
    id: "yaml",
    file_extensions: [".yaml", ".yml"],
    root_markers: [".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // yaml-language-server (RedHat). Separate npm package from
        // vscode-langservers-extracted.
        id: "yaml-language-server",
        command: "yaml-language-server",
        args: ["--stdio"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn markdown() -> LanguageConfig {
  LanguageConfig(
    id: "markdown",
    file_extensions: [".md", ".markdown"],
    root_markers: [".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // marksman — Rust binary, single download. Excellent for
        // wiki-style docs with cross-references.
        id: "marksman",
        command: "marksman",
        args: ["server"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn terraform() -> LanguageConfig {
  LanguageConfig(
    id: "terraform",
    file_extensions: [".tf", ".tfvars", ".hcl"],
    root_markers: [
      ".terraform.lock.hcl", "main.tf", "versions.tf", ".terraform", ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // HashiCorp's terraform-ls. Distributed via
        // releases.hashicorp.com (NOT GitHub Releases).
        id: "terraform-ls",
        command: "terraform-ls",
        args: ["serve"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn erlang() -> LanguageConfig {
  LanguageConfig(
    id: "erlang",
    file_extensions: [".erl", ".hrl"],
    root_markers: ["rebar.config", "erlang.mk", "rebar3.config", ".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // ELP (WhatsApp/erlang-language-platform). Rust-based; built
        // for WhatsApp's massive Erlang codebase but works on any
        // rebar3/erlang.mk project. Pre-built binaries shipped per
        // OTP version at https://github.com/WhatsApp/erlang-language-platform/releases.
        // Alternative: erlang_ls (mature, BEAM-native) — override via
        // pharos.toml if preferred. ELP is the default because
        // releases are recent and active.
        id: "elp",
        command: "elp",
        args: ["server"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        // ELP emits `-32801 content modified` during the initial
        // workspace-symbol walk on rebar3 (and other multi-app
        // projects). M14 Pass 1c–4 dogfood saw 14 probe attempts
        // burn the full 180s budget without elp ever leaving the
        // indexing window. 300s covers it on the kafka-sized
        // fixture.
        ready_timeout_ms: Some(300_000),
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn java() -> LanguageConfig {
  LanguageConfig(
    id: "java",
    file_extensions: [".java"],
    root_markers: [
      "pom.xml", "build.gradle", "build.gradle.kts", ".project", ".classpath",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // jdtls (Eclipse JDT Language Server). Heavy — full Eclipse
        // JDT engine in-process. Cold start 10-30s on small projects,
        // longer on big. Install via Eclipse tarball
        // (https://download.eclipse.org/jdtls/snapshots/), the
        // `bin/jdtls` shell launcher handles JDK + classpath.
        //
        // ADR-029: `extendedClientCapabilities.classFileContentsSupport`
        // is the opt-in flag that tells jdtls "this client handles
        // `jdt://contents/...` URIs". Without it, goto-def into JDK
        // classes / JAR deps silently returns `[]` even when source is
        // attached (src.zip + sources jars). With it, jdtls emits
        // `jdt://` URIs that pharos's `fetch_uri_contents` /
        // navigation tools then resolve through the
        // `java/classFileContents` extension method.
        id: "jdtls",
        command: "jdtls",
        args: [],
        initialization_options: json.object([
          #(
            "extendedClientCapabilities",
            json.object([
              #("classFileContentsSupport", json.bool(True)),
            ]),
          ),
        ]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        // jdtls + Gradle daemon cold-build on a real project (kafka,
        // spring-boot) takes minutes to walk every Gradle subproject
        // before workspace/symbol returns. 360s covers the typical
        // case; truly massive monorepos may need TOML override.
        ready_timeout_ms: Some(360_000),
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    // ADR-029. jdtls returns `jdt://contents/...` URIs for class files
    // inside JARs (compiled deps, no on-disk source). The
    // `java/classFileContents` extension method returns the
    // decompiled source as a plain string — pharos's
    // `fetch_uri_contents` tool routes through this entry. Pharos's
    // session.gleam also uses this map to whitelist `jdt://` for
    // passthrough to existing navigation tools (hover,
    // find_references, goto_definition).
    custom_uri_schemes: dict.from_list([
      #(
        "jdt",
        CustomUriScheme(
          fetch_method: "java/classFileContents",
          fetch_response_field: "",
        ),
      ),
    ]),
  )
}

fn gleam() -> LanguageConfig {
  LanguageConfig(
    id: "gleam",
    file_extensions: [".gleam"],
    root_markers: ["gleam.toml"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // The gleam compiler ships an LSP. `gleam lsp` boots it on
        // stdio. Requires `gleam` on PATH.
        id: "gleam-lsp",
        command: "gleam",
        args: ["lsp"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        // gleam-lsp doesn't reply to `workspace/symbol` until the
        // compiler finishes downloading the project's dependency
        // manifest (visible as `window/workDoneProgress/create` for
        // the `downloading-dependencies` token before any tool
        // response). On the stdlib fixture this stretches past
        // every probe budget we set. ADR-024 explicitly supports
        // `ProbeNone` for LSPs where the probe is more harmful
        // than the slow-first-call experience; gleam falls into
        // that bucket. First tool call carries the cold-start cost
        // instead of failing the entire spawn.
        ready_timeout_ms: Some(180_000),
        initialize_timeout_ms: None,
        warmup_probe: ProbeNone,
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn lua() -> LanguageConfig {
  LanguageConfig(
    id: "lua",
    file_extensions: [".lua"],
    // sumneko's `.luarc.json` family + selene/stylua TOMLs cover most
    // configured projects; `.git` is the fallback for bare scripts.
    root_markers: [
      ".luarc.json", ".luarc.jsonc", "selene.toml", ".stylua.toml", ".git",
    ],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // sumneko/luals — install via release tarball or
        // `brew install lua-language-server` / asdf. Boots on stdio
        // by default.
        id: "lua-language-server",
        command: "lua-language-server",
        args: [],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}

fn bash() -> LanguageConfig {
  LanguageConfig(
    id: "bash",
    // bash-language-server happily handles plain `.sh` and bash-only
    // `.bash` scripts. POSIX `sh` overlap is acceptable —
    // bash-language-server reports compatibility mode itself.
    file_extensions: [".sh", ".bash"],
    // Bare shell scripts often live in a wider project; `.git` keeps
    // us pointing at the repo root. Power users can override via
    // pharos.toml when their layout differs.
    root_markers: [".git"],
    root_promotion: NoPromotion,
    servers: [
      ServerConfig(
        // npm package: `npm install -g bash-language-server`. The
        // `start` subcommand boots stdio mode.
        id: "bash-language-server",
        command: "bash-language-server",
        args: ["start"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: All,
        diagnostics_mode: Push,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
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
    // Stage 3 of ADR-019: dual-server python. Pyright owns
    // hover/goto/types; ruff owns formatting + lint diagnostics +
    // import-sort + lint-fix code actions. Both contribute to
    // `textDocument/diagnostic` (Merge strategy) and
    // `textDocument/codeAction` (FanOut). Order matters — ruff is
    // listed second so pyright wins as the `All` fallback for
    // unscoped methods, and ruff's `Only` declarations target only
    // its strengths.
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
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
      ServerConfig(
        id: "ruff",
        command: "ruff",
        args: ["server"],
        initialization_options: json.object([]),
        workspace_configuration: None,
        methods: Only([
          "textDocument/formatting",
          "textDocument/codeAction",
          "textDocument/diagnostic",
        ]),
        diagnostics_mode: Pull,
        readiness_token: None,
        ready_timeout_ms: None,
        initialize_timeout_ms: None,
        warmup_probe: ProbeWorkspaceSymbol(""),
      ),
    ],
    custom_uri_schemes: dict.new(),
  )
}
