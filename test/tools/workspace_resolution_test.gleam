//// Tests for the ADR-032 step 3 topology dispatch — the out-of-tree
//// [D] branch of `session.resolve_workspace`.
////
//// The decision is split pure/impure the same way attribution is:
//// `is_out_of_tree_cache_path/2` classifies, `out_of_tree_route_decision/2`
//// chooses, and both are covered here without a live pool. The one
//// pool-backed test pins the floor: with no Ready session to route to,
//// an out-of-tree path must resolve exactly as it did before step 3
//// (plain ascent), because "degraded, never hard failure" is ADR-032's
//// constraint 3. The route-taken path needs a Ready LSP session and is
//// dogfood territory, not gleeunit's.

import gleam/option
import gleeunit/should
import pharos/config
import pharos/lsp/languages.{type LanguageConfig}
import pharos/lsp/pool
import pharos/lsp/registry
import pharos/tools/session

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

@external(erlang, "pharos_ffi_shape_test_support", "set_env")
fn set_env(name: String, value: String) -> Nil

@external(erlang, "pharos_ffi_shape_test_support", "unset_env")
fn unset_env(name: String) -> Nil

/// The bundled config for `id`. Since ADR-032 step 4 the fragment
/// lists live on `LanguageConfig`, so classification is only
/// meaningful relative to one; `registry.for_language` falls back to
/// bundled defaults when `init` was never called, which is what these
/// want to assert.
fn lang(id: String) -> LanguageConfig {
  let assert Ok(config) = registry.for_language(id)
  config
}

// -- is_out_of_tree_cache_path -------------------------------------------

pub fn cargo_registry_classifies_for_rust_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/serde-1.0.200/src/lib.rs",
    lang("rust"),
  )
  |> should.be_true
}

/// The fragment is a structural suffix, not a home-anchored prefix —
/// classification must survive a relocated CARGO_HOME, which is the
/// latent bug ADR-032 step 4 records against the warn-list's
/// `/.cargo/registry/` form.
pub fn relocated_cargo_home_still_classifies_test() {
  session.is_out_of_tree_cache_path(
    "/opt/build-caches/cargo/registry/src/index.crates.io-abc/tokio-1.38.0",
    lang("rust"),
  )
  |> should.be_true
}

pub fn go_module_cache_classifies_for_go_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/go/pkg/mod/github.com/x/y@v1.2.3/file.go",
    lang("go"),
  )
  |> should.be_true

  // Any GOPATH — the suffix carries no home-directory assumption.
  session.is_out_of_tree_cache_path(
    "/data/gopath/pkg/mod/golang.org/x/net@v0.25.0",
    lang("go"),
  )
  |> should.be_true
}

/// The cache directory itself (no deeper component yet) still
/// classifies — same trailing-separator treatment as
/// `is_dependency_path`.
pub fn cache_dir_itself_classifies_test() {
  session.is_out_of_tree_cache_path("/home/u/go/pkg/mod", lang("go"))
  |> should.be_true
}

/// Language gating is the point of the per-language list: step 1
/// cleared exactly rust and go, so a rust-shaped path under a go
/// session (or any path under an unprobed language) must not route.
pub fn fragments_do_not_cross_languages_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
    lang("go"),
  )
  |> should.be_false
  session.is_out_of_tree_cache_path(
    "/home/u/go/pkg/mod/github.com/x/y@v1.2.3",
    lang("rust"),
  )
  |> should.be_false
}

/// In-tree vendor paths are NOT out-of-tree: step 1 found no symptom a
/// rooting change fixes there, so node_modules / site-packages stay on
/// plain ascent for their own languages.
pub fn in_tree_vendor_paths_do_not_classify_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/proj/node_modules/@types/react/index.d.ts",
    lang("typescript"),
  )
  |> should.be_false
  session.is_out_of_tree_cache_path(
    "/home/u/proj/.venv/lib/python3.12/site-packages/requests/api.py",
    lang("python"),
  )
  |> should.be_false
}

pub fn first_party_paths_do_not_classify_test() {
  session.is_out_of_tree_cache_path("/home/u/proj/src/main.rs", lang("rust"))
  |> should.be_false
  session.is_out_of_tree_cache_path("/home/u/proj/cmd/main.go", lang("go"))
  |> should.be_false
}

// -- out_of_tree_route_decision --------------------------------------------

pub fn sole_live_workspace_routes_test() {
  session.out_of_tree_route_decision(lang("rust"), ["/home/u/proj"])
  |> should.equal(option.Some("/home/u/proj"))
}

/// Cold start: no session exists yet, so there is nothing to route to
/// and the floor (ascent) applies — the residue ADR-032 records as
/// unfixable even by option C.
pub fn no_live_workspaces_floors_test() {
  session.out_of_tree_route_decision(lang("rust"), [])
  |> should.equal(option.None)
}

/// Ambiguity must NOT import ADR-029's hard error: multiple live
/// workspaces falls through to the floor, where the dependency-rooted
/// answer fires F's note.
pub fn multiple_live_workspaces_floor_not_error_test() {
  session.out_of_tree_route_decision(lang("rust"), [
    "/home/u/proj-a",
    "/home/u/proj-b",
  ])
  |> should.equal(option.None)
}

/// A live workspace that is itself dependency-rooted is a floor
/// artifact from an earlier cold-start call, not an owning project.
/// Routing a *different* crate's file to it would be worse than the
/// floor, so it is never a candidate.
pub fn dependency_rooted_workspace_is_not_a_candidate_test() {
  session.out_of_tree_route_decision(lang("rust"), [
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
  ])
  |> should.equal(option.None)
}

/// ...and filtering it out can leave a sole real candidate: one
/// earlier floor artifact plus one genuine project session still
/// routes to the project.
pub fn floor_artifact_does_not_block_the_real_workspace_test() {
  session.out_of_tree_route_decision(lang("rust"), [
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
    "/home/u/proj",
  ])
  |> should.equal(option.Some("/home/u/proj"))
}

// -- per-language config plumbing (ADR-032 step 4) -------------------------

/// The keys are only worth having if a user can actually set them, and
/// a typo in the decoder's key string would fail silently — the
/// override would just be ignored. This drives the real path: toml on
/// disk → `config.load` → `registry.init` → classification.
///
/// Mutates process-global state (config + registry persistent_term),
/// so it restores both by re-loading with the env var unset. That
/// restore is not optional: every other test reads the same registry.
pub fn user_config_can_override_the_cache_fragments_test() {
  let path = "/tmp/pharos_step4_override_test.toml"
  let _ =
    shell(
      "printf '[languages.rust]\\ndependency_cache_fragments = [\"/vendored-crates/\"]\\n' > "
      <> path,
    )

  set_env("PHAROS_CONFIG_FILE", path)
  let _ = config.load()
  registry.init()

  let overridden = lang("rust")
  // The user's list replaces the bundled one rather than adding to it,
  // so the default fragment must be gone.
  session.is_out_of_tree_cache_path(
    "/home/u/vendored-crates/serde-1.0.200/src/lib.rs",
    overridden,
  )
  |> should.be_true
  session.is_out_of_tree_cache_path(
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
    overridden,
  )
  |> should.be_false
  // An unmentioned key keeps its bundled value.
  overridden.root_markers |> should.equal(["Cargo.toml", "rust-project.json"])

  unset_env("PHAROS_CONFIG_FILE")
  let _ = config.load()
  registry.init()
  let _ = shell("rm -f " <> path)

  session.is_out_of_tree_cache_path(
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
    lang("rust"),
  )
  |> should.be_true
}

// -- resolve_workspace floor (integration) ---------------------------------

/// With an empty pool, an out-of-tree cache path resolves exactly as it
/// did before step 3: ascend to the crate's own Cargo.toml. Constraint
/// 3 in code form — the dispatch must never turn today's degraded
/// answer into a hard failure.
pub fn out_of_tree_path_with_empty_pool_floors_to_ascent_test() {
  let root = "/tmp/pharos_workspace_resolution_test"
  let crate_dir =
    root <> "/cargo-home/registry/src/index.crates.io-abc/dep-1.0.0"
  let _ = shell("rm -rf " <> root)
  let _ = shell("mkdir -p " <> crate_dir <> "/src")
  let _ = shell("printf '[package]\\n' > " <> crate_dir <> "/Cargo.toml")
  let _ = shell("printf '\\n' > " <> crate_dir <> "/src/lib.rs")

  let assert Ok(p) = pool.start()
  let assert Ok(config) = registry.for_language("rust")
  let file_uri = "file://" <> crate_dir <> "/src/lib.rs"

  let resolved = session.resolve_workspace(p, file_uri, config)

  let _ = shell("rm -rf " <> root)
  resolved |> should.equal(Ok(crate_dir))
}
