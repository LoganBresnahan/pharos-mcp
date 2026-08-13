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
import pharos/lsp/pool
import pharos/lsp/registry
import pharos/tools/session

@external(erlang, "pharos_fs_ffi", "shell")
fn shell(cmd: String) -> String

// -- is_out_of_tree_cache_path -------------------------------------------

pub fn cargo_registry_classifies_for_rust_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/serde-1.0.200/src/lib.rs",
    "rust",
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
    "rust",
  )
  |> should.be_true
}

pub fn go_module_cache_classifies_for_go_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/go/pkg/mod/github.com/x/y@v1.2.3/file.go",
    "go",
  )
  |> should.be_true

  // Any GOPATH — the suffix carries no home-directory assumption.
  session.is_out_of_tree_cache_path(
    "/data/gopath/pkg/mod/golang.org/x/net@v0.25.0",
    "go",
  )
  |> should.be_true
}

/// The cache directory itself (no deeper component yet) still
/// classifies — same trailing-separator treatment as
/// `is_dependency_path`.
pub fn cache_dir_itself_classifies_test() {
  session.is_out_of_tree_cache_path("/home/u/go/pkg/mod", "go")
  |> should.be_true
}

/// Language gating is the point of the per-language list: step 1
/// cleared exactly rust and go, so a rust-shaped path under a go
/// session (or any path under an unprobed language) must not route.
pub fn fragments_do_not_cross_languages_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
    "go",
  )
  |> should.be_false
  session.is_out_of_tree_cache_path(
    "/home/u/go/pkg/mod/github.com/x/y@v1.2.3",
    "rust",
  )
  |> should.be_false
}

/// In-tree vendor paths are NOT out-of-tree: step 1 found no symptom a
/// rooting change fixes there, so node_modules / site-packages stay on
/// plain ascent for their own languages.
pub fn in_tree_vendor_paths_do_not_classify_test() {
  session.is_out_of_tree_cache_path(
    "/home/u/proj/node_modules/@types/react/index.d.ts",
    "typescript",
  )
  |> should.be_false
  session.is_out_of_tree_cache_path(
    "/home/u/proj/.venv/lib/python3.12/site-packages/requests/api.py",
    "python",
  )
  |> should.be_false
}

pub fn first_party_paths_do_not_classify_test() {
  session.is_out_of_tree_cache_path("/home/u/proj/src/main.rs", "rust")
  |> should.be_false
  session.is_out_of_tree_cache_path("/home/u/proj/cmd/main.go", "go")
  |> should.be_false
}

// -- out_of_tree_route_decision --------------------------------------------

pub fn sole_live_workspace_routes_test() {
  session.out_of_tree_route_decision("rust", ["/home/u/proj"])
  |> should.equal(option.Some("/home/u/proj"))
}

/// Cold start: no session exists yet, so there is nothing to route to
/// and the floor (ascent) applies — the residue ADR-032 records as
/// unfixable even by option C.
pub fn no_live_workspaces_floors_test() {
  session.out_of_tree_route_decision("rust", [])
  |> should.equal(option.None)
}

/// Ambiguity must NOT import ADR-029's hard error: multiple live
/// workspaces falls through to the floor, where the dependency-rooted
/// answer fires F's note.
pub fn multiple_live_workspaces_floor_not_error_test() {
  session.out_of_tree_route_decision("rust", ["/home/u/proj-a", "/home/u/proj-b"])
  |> should.equal(option.None)
}

/// A live workspace that is itself dependency-rooted is a floor
/// artifact from an earlier cold-start call, not an owning project.
/// Routing a *different* crate's file to it would be worse than the
/// floor, so it is never a candidate.
pub fn dependency_rooted_workspace_is_not_a_candidate_test() {
  session.out_of_tree_route_decision("rust", [
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
  ])
  |> should.equal(option.None)
}

/// ...and filtering it out can leave a sole real candidate: one
/// earlier floor artifact plus one genuine project session still
/// routes to the project.
pub fn floor_artifact_does_not_block_the_real_workspace_test() {
  session.out_of_tree_route_decision("rust", [
    "/home/u/.cargo/registry/src/index.crates.io-abc/serde-1.0.200",
    "/home/u/proj",
  ])
  |> should.equal(option.Some("/home/u/proj"))
}

// -- resolve_workspace floor (integration) ---------------------------------

/// With an empty pool, an out-of-tree cache path resolves exactly as it
/// did before step 3: ascend to the crate's own Cargo.toml. Constraint
/// 3 in code form — the dispatch must never turn today's degraded
/// answer into a hard failure.
pub fn out_of_tree_path_with_empty_pool_floors_to_ascent_test() {
  let root = "/tmp/pharos_workspace_resolution_test"
  let crate_dir = root <> "/cargo-home/registry/src/index.crates.io-abc/dep-1.0.0"
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
