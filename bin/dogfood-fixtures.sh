#!/usr/bin/env bash
#
# Clone pinned public repos into tmp/fixtures/ for dogfood testing.
#
# One repo per supported language. Repos are picked for: organization
# ownership (won't move accounts), 5+ year stability, and medium size
# (cold-start signal without 30-min indexing).
#
# Usage:
#   bin/dogfood-fixtures.sh           # clone all (skips existing)
#   bin/dogfood-fixtures.sh --refresh # nuke tmp/fixtures and reclone
#   bin/dogfood-fixtures.sh rust go   # clone only listed languages
#   bin/dogfood-fixtures.sh --list    # print fixture table
#
# Env:
#   FIXTURE_DIR  override target dir (default tmp/fixtures)
#   PIN          'true' (default): checkout SHA below; 'false': use HEAD
#
# Total ~3-4 GB shallow. tmp/ is gitignored.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${FIXTURE_DIR:-$ROOT/tmp/fixtures}"
PIN="${PIN:-true}"

# language|repo|pinned-sha
FIXTURES=(
  "rust|rust-lang/cargo|3ba12d8fbb714c2b720fda2b60f70ad8d7d67217"
  "go|prometheus/prometheus|ecab2f45a8b7a1f12b8a16590a56590c96422f44"
  "typescript|prettier/prettier|704f99687cf797f74523ac2efe0b4f04ee7568e3"
  "elixir|phoenixframework/phoenix|8cbe8172d449fe7b8ab5720a5b448ac1cad36882"
  "ruby|sinatra/sinatra|5236d3459b8b9015e5ce21ddd0c6beb0db4081d4"
  "zig|ziglang/zig|738d2be9d6b6ef3ff3559130c05159ef53336224"
  "cpp|protocolbuffers/protobuf|ac90873facd9d09d849c6617f49faaf7668c9f47"
  "scala|scala/scala3|eb2e0413812eb21372d7a96493c4cff830ee09c7"
  "clojure|clojure/clojure|dd395eaa400767e5579ccd674627664c5c3d33da"
  "haskell|haskell/cabal|4db95b6de6e83919ab39bc208778512ec33e3f57"
  "perl|mojolicious/mojo|faf712bd37fa4e27063fd9f88f396d0a2ad55136"
  "html|mdn/content|44a5fa2aace490e0114349d9d683675b2f5cacce"
  "css|twbs/bootstrap|a583d9a8f3a1027566f3d82f0538d61f6d17f0d3"
  "json|OAI/OpenAPI-Specification|12e4c66e91676e8a8a8280f62526c38e58ec4a38"
  "yaml|ansible/ansible|b7c0900272fd428f336f30714089e3916fcc10f9"
  "markdown|github/docs|e7e8ebbede8c08bcd228e67f2aa3574bbf0b2399"
  "terraform|terraform-aws-modules/terraform-aws-vpc|3ffbd46fb1c7733e1b34d8666893280454e27436"
  "erlang|erlang/rebar3|80b714dbbb49994f21094991e0ad464f24ed5b63"
  "java|apache/kafka|7accdc89e69dae59bdc64d5856be63ab49d95784"
  "gleam|gleam-lang/stdlib|cfa54e3a78166623ee6211b56bd4511d20f1b0f4"
  "lua|kong/kong|58f2daa56b90615f78d5953229936192cd1128e9"
  "bash|ohmyzsh/ohmyzsh|3604dc23e0d95b5ce9a3932838a7b103ef5ff0c1"
  "python|pallets/flask|7374c85ddefc3f4b177a698ab9f0cbb6a5c0b392"
)

usage() {
  sed -n '3,20p' "$0" | sed 's/^# \?//'
}

list_table() {
  printf "%-12s  %-45s  %s\n" "LANG" "REPO" "PINNED SHA"
  printf "%-12s  %-45s  %s\n" "----" "----" "----------"
  for entry in "${FIXTURES[@]}"; do
    IFS='|' read -r lang repo sha <<< "$entry"
    printf "%-12s  %-45s  %s\n" "$lang" "$repo" "${sha:0:12}"
  done
}

clone_one() {
  local lang="$1" repo="$2" sha="$3"
  local target="$FIXTURE_DIR/$lang"

  if [[ -d "$target/.git" ]]; then
    echo "[$lang] already cloned at $target"
    post_clone_setup "$lang" "$target"
    return 0
  fi

  echo "[$lang] cloning $repo into $target"
  mkdir -p "$FIXTURE_DIR"

  if [[ "$PIN" == "true" ]]; then
    # Shallow init + fetch the exact SHA. Cheaper than full shallow
    # clone for repos where the SHA isn't in the most recent commits.
    git init --quiet "$target"
    (
      cd "$target"
      git remote add origin "https://github.com/$repo.git"
      git fetch --quiet --depth 1 origin "$sha"
      git checkout --quiet FETCH_HEAD
    )
  else
    git clone --quiet --depth 1 "https://github.com/$repo.git" "$target"
  fi

  post_clone_setup "$lang" "$target"

  echo "[$lang] done: $(du -sh "$target" | cut -f1)"
}

# Per-language setup needed before pharos's LSP can spawn against the
# fixture. Idempotent — runs whether the clone is fresh or already
# present (a re-run after `bundle install` etc. should not re-do work).
post_clone_setup() {
  local lang="$1" target="$2"

  case "$lang" in
    ruby)
      # ruby-lsp inspects the workspace's Gemfile.lock at handshake
      # time; if `ruby-lsp` is not declared as a dev dependency the
      # server dies on init with "client transport failure" (M13
      # 23-lang dogfood Run 4). Fix: add it to the dev group and
      # `bundle install` so a `Gemfile.lock` mentioning ruby-lsp is
      # present. Skip if the fixture already has it.
      if [[ -f "$target/Gemfile" ]] && ! grep -qE 'ruby-lsp' "$target/Gemfile"; then
        if command -v bundle >/dev/null 2>&1; then
          echo "[$lang] adding ruby-lsp to Gemfile dev group..."
          ( cd "$target" && bundle add --group=development ruby-lsp >/dev/null 2>&1 ) \
            || echo "[$lang] WARN: bundle add failed; ruby-lsp may not start" >&2
        else
          echo "[$lang] WARN: 'bundle' not found; install bundler first" >&2
        fi
      fi
      ;;
    terraform)
      # terraform-ls needs `.terraform/` to exist for some queries
      # (it parses the lock file + provider schemas before answering
      # workspace_symbols et al.). Run `terraform init` if the binary
      # is available; skip on warn if not.
      if [[ -f "$target/main.tf" ]] && [[ ! -d "$target/.terraform" ]]; then
        if command -v terraform >/dev/null 2>&1; then
          echo "[$lang] running terraform init..."
          ( cd "$target" && terraform init -backend=false -input=false >/dev/null 2>&1 ) \
            || echo "[$lang] WARN: terraform init failed; provider tools may not work" >&2
        else
          echo "[$lang] WARN: 'terraform' not found; some tools may flake" >&2
        fi
      fi
      ;;
  esac
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --list) list_table; exit 0 ;;
    --refresh)
      shift
      echo "removing $FIXTURE_DIR"
      rm -rf "$FIXTURE_DIR"
      ;;
  esac

  local filter=("$@")
  local matched=0

  for entry in "${FIXTURES[@]}"; do
    IFS='|' read -r lang repo sha <<< "$entry"

    if [[ ${#filter[@]} -gt 0 ]]; then
      local skip=true
      for f in "${filter[@]}"; do
        [[ "$f" == "$lang" ]] && skip=false && break
      done
      $skip && continue
    fi

    matched=1
    clone_one "$lang" "$repo" "$sha"
  done

  if [[ ${#filter[@]} -gt 0 && $matched -eq 0 ]]; then
    echo "no fixtures matched: ${filter[*]}" >&2
    echo "available languages:" >&2
    for entry in "${FIXTURES[@]}"; do
      IFS='|' read -r lang _ _ <<< "$entry"
      echo "  $lang" >&2
    done
    exit 1
  fi

  echo
  echo "fixtures ready under $FIXTURE_DIR"
  echo "total: $(du -sh "$FIXTURE_DIR" 2>/dev/null | cut -f1)"
}

main "$@"
