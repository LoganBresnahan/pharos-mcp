//// Project-local memory tools (ADR-027).
////
//// Four tools: save / get / list / prune. Filesystem-backed,
//// markdown files with strict YAML frontmatter. Two storage layers:
////
////   - user-type memories live at `~/.pharos/memories/user/`
////     (per-user, NOT committed to repo)
////   - project/feedback/reference memories live at `.pharos/memories/`
////     under the project root (committed)
////
//// Both roots honor env-var overrides for test/dogfood isolation:
////   PHAROS_MEMORY_ROOT       — project layer override
////   PHAROS_USER_MEMORY_ROOT  — user layer override

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pharos/tools/memory_frontmatter.{type Frontmatter, Frontmatter}

pub type MemoryEntry {
  MemoryEntry(
    name: String,
    type_: String,
    description: String,
    created: String,
    last_accessed: String,
    body: String,
    layer: String,
  )
}

pub type MemoryError {
  InvalidName(reason: String)
  InvalidType(value: String)
  InvalidDescription(reason: String)
  Conflict(name: String)
  NotFound(name: String, near_misses: List(String))
  QuotaExceeded(type_: String, cap: Int)
  StorageError(reason: String)
  FrontmatterError(reason: String)
}

const known_types = ["user", "project", "feedback", "reference"]

const max_name_length: Int = 64

const max_description_length: Int = 200

/// Per-type hard caps. Soft warning threshold is 80% of these.
pub fn quota_for(type_: String) -> Int {
  case type_ {
    "user" -> 50
    "project" -> 200
    "feedback" -> 100
    "reference" -> 100
    _ -> 100
  }
}

/// Save a new memory. Refuses to overwrite an existing entry unless
/// `overwrite` is True. Strips `<private>...</private>` blocks from
/// the body before writing. Updates `MEMORY.md` index in the
/// appropriate layer.
pub fn save(
  name: String,
  type_: String,
  description: String,
  content: String,
  overwrite: Bool,
  now_iso8601: String,
) -> Result(MemoryEntry, MemoryError) {
  use _ <- result.try(validate_name(name))
  use _ <- result.try(validate_type(type_))
  use _ <- result.try(validate_description(description))
  let body = strip_private_blocks(content)
  let layer = layer_for(type_)
  let dir = type_dir(layer, type_)
  let path = entry_path(dir, name)
  use _ <- result.try(ensure_dir(dir))
  use existing_count <- result.try(count_in_dir(dir))
  use _ <- result.try(case existing_count >= quota_for(type_) && !already_exists(path) {
    True -> Error(QuotaExceeded(type_: type_, cap: quota_for(type_)))
    False -> Ok(Nil)
  })
  let created = case overwrite {
    True ->
      case read_entry_raw(path) {
        Ok(#(fm, _)) -> fm.created
        Error(_) -> now_iso8601
      }
    False -> now_iso8601
  }
  let fm =
    Frontmatter(
      name: name,
      type_: type_,
      description: description,
      created: created,
      last_accessed: now_iso8601,
    )
  let serialized = memory_frontmatter.serialize(fm, body)
  use _ <- result.try(case overwrite {
    True -> atomic_write(path, serialized)
    False -> exclusive_write(path, serialized, name)
  })
  use _ <- result.try(update_index(layer))
  Ok(MemoryEntry(
    name: fm.name,
    type_: fm.type_,
    description: fm.description,
    created: fm.created,
    last_accessed: fm.last_accessed,
    body: body,
    layer: layer,
  ))
}

/// Fetch by name. Checks project layer first, falls back to user
/// layer. Bumps `last_accessed`. Returns near-miss suggestions on
/// not-found.
pub fn get(
  name: String,
  now_iso8601: String,
) -> Result(MemoryEntry, MemoryError) {
  case find_entry(name) {
    Ok(#(path, layer, fm, body)) -> {
      let updated_fm = Frontmatter(..fm, last_accessed: now_iso8601)
      let serialized = memory_frontmatter.serialize(updated_fm, body)
      // Best-effort write to bump last_accessed. If the write fails,
      // still return the entry — read path stays usable even on a
      // read-only filesystem.
      let _ = atomic_write(path, serialized)
      Ok(MemoryEntry(
        name: updated_fm.name,
        type_: updated_fm.type_,
        description: updated_fm.description,
        created: updated_fm.created,
        last_accessed: updated_fm.last_accessed,
        body: body,
        layer: layer,
      ))
    }
    Error(_) -> Error(NotFound(name: name, near_misses: near_misses_for(name)))
  }
}

/// List memories. Optional type filter and substring query (matches
/// name or description). Merges both layers; entries carry `layer`.
/// Sorted by last_accessed descending.
pub fn list_entries(
  type_filter: Option(String),
  query: Option(String),
) -> Result(List(MemoryEntry), MemoryError) {
  let project = collect_layer("project")
  let user = collect_layer("user")
  let merged = list.append(project, user)
  let filtered =
    merged
    |> list.filter(fn(e) {
      case type_filter {
        None -> True
        Some(t) -> e.type_ == t
      }
    })
    |> list.filter(fn(e) {
      case query {
        None -> True
        Some(q) ->
          string.contains(e.name, q) || string.contains(e.description, q)
      }
    })
  let sorted =
    list.sort(filtered, fn(a, b) {
      string.compare(b.last_accessed, a.last_accessed)
    })
  Ok(sorted)
}

/// Delete a memory by name.
pub fn prune(name: String) -> Result(Nil, MemoryError) {
  case find_entry(name) {
    Error(_) -> Error(NotFound(name: name, near_misses: near_misses_for(name)))
    Ok(#(path, layer, _, _)) -> {
      case delete_file_raw(path) {
        Ok(_) -> update_index(layer)
        Error(reason) -> Error(StorageError(reason))
      }
    }
  }
}

pub fn describe_error(err: MemoryError) -> String {
  case err {
    InvalidName(r) -> "invalid name: " <> r
    InvalidType(t) ->
      "invalid type '" <> t <> "' (must be user|project|feedback|reference)"
    InvalidDescription(r) -> "invalid description: " <> r
    Conflict(n) ->
      "memory '" <> n <> "' already exists (pass overwrite=true to replace)"
    NotFound(n, []) -> "memory not found: " <> n
    NotFound(n, near) ->
      "memory not found: " <> n <> " (near misses: " <> string.join(near, ", ") <> ")"
    QuotaExceeded(t, cap) ->
      "quota exceeded for type '" <> t <> "' (cap " <> int.to_string(cap) <> "); use memory_prune to free space"
    StorageError(r) -> "storage error: " <> r
    FrontmatterError(r) -> "frontmatter error: " <> r
  }
}

// -- Validation ---------------------------------------------------------

fn validate_name(name: String) -> Result(Nil, MemoryError) {
  let trimmed = string.trim(name)
  case string.length(trimmed) {
    0 -> Error(InvalidName("name must not be empty"))
    n if n > max_name_length ->
      Error(InvalidName(
        "name too long (max " <> int.to_string(max_name_length) <> ")",
      ))
    _ ->
      case is_kebab_case(trimmed) {
        True -> Ok(Nil)
        False ->
          Error(InvalidName(
            "name must be kebab-case (lowercase letters, digits, dashes)",
          ))
      }
  }
}

fn is_kebab_case(s: String) -> Bool {
  s
  |> string.to_graphemes
  |> list.all(fn(g) {
    case g {
      "-" -> True
      _ -> {
        let is_lower =
          string.lowercase(g) == g && string.uppercase(g) != g
          && string.length(g) == 1
        let is_digit = case int.parse(g) {
          Ok(_) -> True
          Error(_) -> False
        }
        is_lower || is_digit
      }
    }
  })
}

fn validate_type(t: String) -> Result(Nil, MemoryError) {
  case list.contains(known_types, t) {
    True -> Ok(Nil)
    False -> Error(InvalidType(t))
  }
}

fn validate_description(d: String) -> Result(Nil, MemoryError) {
  case string.length(d) {
    0 -> Error(InvalidDescription("description must not be empty"))
    n if n > max_description_length ->
      Error(InvalidDescription(
        "description too long (max "
        <> int.to_string(max_description_length)
        <> ")",
      ))
    _ -> Ok(Nil)
  }
}

/// Remove `<private>...</private>` blocks from `text`. Borrowed from
/// cavemem's redaction approach.
pub fn strip_private_blocks(text: String) -> String {
  strip_loop(text, "")
}

fn strip_loop(text: String, acc: String) -> String {
  case string.split_once(text, "<private>") {
    Error(_) -> acc <> text
    Ok(#(before, after)) ->
      case string.split_once(after, "</private>") {
        Error(_) -> acc <> before
        Ok(#(_, rest)) -> strip_loop(rest, acc <> before)
      }
  }
}

// -- Layer / path helpers -----------------------------------------------

fn layer_for(type_: String) -> String {
  case type_ {
    "user" -> "user"
    _ -> "project"
  }
}

fn layer_root(layer: String) -> String {
  case layer {
    "user" -> user_root()
    _ -> project_root()
  }
}

fn project_root() -> String {
  case getenv("PHAROS_MEMORY_ROOT") {
    Some(p) -> p
    None -> ".pharos/memories"
  }
}

fn user_root() -> String {
  case getenv("PHAROS_USER_MEMORY_ROOT") {
    Some(p) -> p
    None -> home_dir_ffi() <> "/.pharos/memories"
  }
}

fn type_dir(layer: String, type_: String) -> String {
  layer_root(layer) <> "/" <> type_
}

fn entry_path(dir: String, name: String) -> String {
  dir <> "/" <> name <> ".md"
}

// -- Storage ops --------------------------------------------------------

fn ensure_dir(path: String) -> Result(Nil, MemoryError) {
  case mkdir_p_ffi(path) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(StorageError(reason))
  }
}

fn atomic_write(path: String, text: String) -> Result(Nil, MemoryError) {
  case atomic_write_ffi(path, text) {
    Ok(_) -> Ok(Nil)
    Error(reason) -> Error(StorageError(reason))
  }
}

fn exclusive_write(
  path: String,
  text: String,
  name: String,
) -> Result(Nil, MemoryError) {
  case write_excl_ffi(path, text) {
    Ok(_) -> Ok(Nil)
    Error("eexist") -> Error(Conflict(name))
    Error(reason) -> Error(StorageError(reason))
  }
}

fn already_exists(path: String) -> Bool {
  is_regular_file_ffi(path)
}

fn read_entry_raw(
  path: String,
) -> Result(#(Frontmatter, String), MemoryError) {
  case read_file_ffi(path) {
    Error(reason) -> Error(StorageError(reason))
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Error(_) -> Error(StorageError("file is not valid UTF-8: " <> path))
        Ok(text) ->
          case memory_frontmatter.parse(text) {
            Ok(parsed) -> Ok(parsed)
            Error(err) ->
              Error(FrontmatterError(memory_frontmatter.describe_error(err)))
          }
      }
  }
}

fn find_entry(
  name: String,
) -> Result(#(String, String, Frontmatter, String), Nil) {
  case find_in_layer(name, "project") {
    Ok(r) -> Ok(r)
    Error(_) -> find_in_layer(name, "user")
  }
}

fn find_in_layer(
  name: String,
  layer: String,
) -> Result(#(String, String, Frontmatter, String), Nil) {
  let root = layer_root(layer)
  let candidates = case layer {
    "user" -> ["user"]
    _ -> ["project", "feedback", "reference"]
  }
  list.fold(candidates, Error(Nil), fn(acc, t) {
    case acc {
      Ok(_) -> acc
      Error(_) -> {
        let path = root <> "/" <> t <> "/" <> name <> ".md"
        case is_regular_file_ffi(path) {
          False -> Error(Nil)
          True ->
            case read_entry_raw(path) {
              Ok(#(fm, body)) -> Ok(#(path, layer, fm, body))
              Error(_) -> Error(Nil)
            }
        }
      }
    }
  })
}

fn collect_layer(layer: String) -> List(MemoryEntry) {
  let root = layer_root(layer)
  let type_dirs = case layer {
    "user" -> ["user"]
    _ -> ["project", "feedback", "reference"]
  }
  list.flat_map(type_dirs, fn(t) {
    let dir = root <> "/" <> t
    case list_dir_ffi(dir) {
      Error(_) -> []
      Ok(names) ->
        names
        |> list.filter(fn(n) { string.ends_with(n, ".md") })
        |> list.filter_map(fn(filename) {
          let path = dir <> "/" <> filename
          case read_entry_raw(path) {
            Error(_) -> Error(Nil)
            Ok(#(fm, body)) ->
              Ok(MemoryEntry(
                name: fm.name,
                type_: fm.type_,
                description: fm.description,
                created: fm.created,
                last_accessed: fm.last_accessed,
                body: body,
                layer: layer,
              ))
          }
        })
    }
  })
}

fn count_in_dir(dir: String) -> Result(Int, MemoryError) {
  case list_dir_ffi(dir) {
    Error(_) -> Ok(0)
    Ok(names) -> {
      let n =
        names
        |> list.filter(fn(name) { string.ends_with(name, ".md") })
        |> list.length
      Ok(n)
    }
  }
}

fn near_misses_for(name: String) -> List(String) {
  let all =
    list.append(
      collect_layer("project") |> list.map(fn(e) { e.name }),
      collect_layer("user") |> list.map(fn(e) { e.name }),
    )
  all
  |> list.filter(fn(other) {
    string.contains(other, name) || string.contains(name, other)
  })
  |> list.take(5)
}

fn update_index(layer: String) -> Result(Nil, MemoryError) {
  let entries = collect_layer(layer)
  let header = "# MEMORY index (" <> layer <> " layer)\n\n"
  let body =
    entries
    |> list.map(fn(e) {
      "- **" <> e.type_ <> "** `" <> e.name <> "` — " <> e.description
    })
    |> string.join("\n")
  let content = header <> body <> "\n"
  let path = layer_root(layer) <> "/MEMORY.md"
  case ensure_dir(layer_root(layer)) {
    Error(e) -> Error(e)
    Ok(_) -> atomic_write(path, content)
  }
}

// -- env ----------------------------------------------------------------

fn getenv(key: String) -> Option(String) {
  case getenv_ffi(key) {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
}

// -- FFI ----------------------------------------------------------------

@external(erlang, "pharos_fs_ffi", "read_file")
fn read_file_ffi(path: String) -> Result(BitArray, String)

@external(erlang, "pharos_fs_ffi", "atomic_write_text")
fn atomic_write_ffi(path: String, text: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "mkdir_p")
fn mkdir_p_ffi(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "list_dir")
fn list_dir_ffi(path: String) -> Result(List(String), String)

@external(erlang, "pharos_fs_ffi", "delete_file")
fn delete_file_raw(path: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "write_excl")
fn write_excl_ffi(path: String, text: String) -> Result(Nil, String)

@external(erlang, "pharos_fs_ffi", "is_regular_file")
fn is_regular_file_ffi(path: String) -> Bool

@external(erlang, "pharos_fs_ffi", "home_dir")
fn home_dir_ffi() -> String

@external(erlang, "pharos_fs_ffi", "getenv")
fn getenv_ffi(key: String) -> Result(String, Nil)
