#!/bin/sh
# Smoke-test an installed pharos (ADR-035 §7), the way geex's rel/smoke.sh does: install it into a
# temporary HOME as a user would, then drive it as an MCP client would.
#
#   rel/smoke.sh [--version VERSION] [--lsp pyright]
#
# By default it installs from GitHub: `curl …/releases/latest/download/install.sh | sh`, or, with
# --version, that release's own install.sh. With PHAROS_DOWNLOAD_URL set (a build's _build/package
# as a file:// URL) it installs from there with this checkout's install.sh, so a release job can
# check its tarball before publishing it.
#
# Checks:
#   - `pharos --version` is `pharos VERSION` (or any `pharos X.Y.Z` with no --version);
#   - rel/smoke_mcp.py: initialize, tools/list, a second session joins the daemon, the daemon
#     exits when idle, and with --lsp pyright a hover answered by pyright;
#   - `pharos self prune` keeps the current version;
#   - from file:// only (ADR-036): `pharos self update` to two more versions (repacks of the
#     same release under new version names, which only the shim reads, and the shim answers
#     --version and `self` without booting them), a running daemon keeps its version through an
#     install's prune and `self prune`, and `self prune` removes it once the daemon stops;
#     `self rollback` switches back;
#   - `pharos self uninstall` removes it.
set -eu

REPO=LoganBresnahan/pharos-mcp
here=$(cd "$(dirname "$0")/.." && pwd -P)
version=
lsp=
while [ $# -gt 0 ]; do
  case $1 in
    --version) version=${2#v}; shift 2 ;;
    --lsp) lsp=$2; shift 2 ;;
    *) echo "usage: $0 [--version VERSION] [--lsp pyright]" >&2; exit 2 ;;
  esac
done

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }
ok() { echo "smoke: ok: $*"; }

box=$(mktemp -d)
trap 'PHAROS_RUNTIME_DIR=$box/rt "$HOME/.local/bin/pharos" daemon stop --all >/dev/null 2>&1 || true; rm -rf "$box"' EXIT
HOME=$box/home
XDG_DATA_HOME=$HOME/.local/share
XDG_CONFIG_HOME=$HOME/.config
XDG_STATE_HOME=$HOME/.local/state
XDG_CACHE_HOME=$HOME/.cache
unset PHAROS_INSTALL_DIR PHAROS_BIN_DIR
export HOME XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME
mkdir -p "$HOME"

if [ -n "${PHAROS_DOWNLOAD_URL:-}" ]; then
  [ -n "$version" ] || fail "PHAROS_DOWNLOAD_URL needs --version"
  sh "$here/install.sh" --version "$version"
elif [ -n "$version" ]; then
  curl -fsSL "https://github.com/$REPO/releases/download/v$version/install.sh" | sh -s -- --version "$version"
else
  curl -fsSL "https://github.com/$REPO/releases/latest/download/install.sh" | sh
fi

pharos=$HOME/.local/bin/pharos
[ -L "$pharos" ] || fail "no link at $pharos"

said=$("$pharos" --version)
if [ -n "$version" ]; then
  [ "$said" = "pharos $version" ] || fail "--version says \"$said\", not \"pharos $version\""
else
  case $said in
    "pharos "[0-9]*) version=${said#pharos } ;;
    *) fail "--version says \"$said\"" ;;
  esac
fi
ok "$said"

# The daemon's socket goes in the sandbox too, not the runner's XDG_RUNTIME_DIR.
PHAROS_RUNTIME_DIR=$box/rt
export PHAROS_RUNTIME_DIR
set -- --pharos "$pharos" --idle-exit
[ -z "$lsp" ] || set -- "$@" --lsp "$lsp"
python3 -I "$here/rel/smoke_mcp.py" "$@" || fail "the MCP checks failed"

versions=$XDG_DATA_HOME/pharos/versions
out=$("$pharos" self prune) || fail "self prune failed: $out"
printf '%s\n' "$out"
case $out in *"kept $version (current)"*) ;; *) fail "self prune didn't keep $version" ;; esac
ok "self prune kept the current version"

if [ -n "${PHAROS_DOWNLOAD_URL:-}" ]; then
  # Two more versions, from repacks of this one: VERSION-s1 and VERSION-s2.
  src=${PHAROS_DOWNLOAD_URL#file://}
  pkg=$box/pkg
  mkdir -p "$pkg" "$box/mk"
  cp "$here/install.sh" "$src/SHA256SUMS" "$pkg/"
  for tarball in "$src"/pharos-"$version"-*.tar.gz; do
    [ -f "$tarball" ] || fail "no pharos-$version-*.tar.gz in $src"
    cp "$tarball" "$pkg/"
    name=${tarball##*/}
    name=${name%.tar.gz}
    plat=${name#pharos-"$version"-}
    for s in s1 s2; do
      v=$version-$s
      rm -rf "$box/mk/$name" "$box/mk/pharos-$v-$plat"
      tar -xzf "$tarball" -C "$box/mk"
      rel=$box/mk/pharos-$v-$plat
      mv "$box/mk/$name" "$rel"
      erts=$(cut -d' ' -f1 "$rel/releases/start_erl.data")
      printf '%s %s\n' "$erts" "$v" >"$rel/releases/start_erl.data"
      mv "$rel/releases/$version" "$rel/releases/$v"
      tar -C "$box/mk" -czf "$pkg/pharos-$v-$plat.tar.gz" "pharos-$v-$plat"
      (cd "$pkg" && if command -v sha256sum >/dev/null; then sha256sum "pharos-$v-$plat.tar.gz"; else shasum -a 256 "pharos-$v-$plat.tar.gz"; fi) >>"$pkg/SHA256SUMS"
    done
  done

  # A daemon of VERSION, as an MCP session would have left running.
  "$versions/$version/bin/pharos" daemon >"$box/daemon.log" 2>&1 &
  daemon=$!
  i=0
  until "$versions/$version/bin/pharos" daemon status >/dev/null 2>&1; do
    i=$((i + 1))
    [ $i -lt 60 ] || { cat "$box/daemon.log" >&2; fail "the $version daemon didn't start"; }
    sleep 1
  done
  ok "a $version daemon is running"

  for s in s1 s2; do
    out=$(PHAROS_DOWNLOAD_URL=file://$pkg "$pharos" self update --version "$version-$s" 2>&1) ||
      fail "self update --version $version-$s failed: $out"
    printf '%s\n' "$out"
    [ "$("$pharos" --version)" = "pharos $version-$s" ] || fail "self update didn't switch to $version-$s"
  done
  case $out in *"kept $version: a running pharos uses it"*) ;; *) fail "the install's prune didn't keep $version for its daemon" ;; esac
  ok "self update installed $version-s1 and $version-s2; the install kept $version for its daemon"

  out=$("$pharos" self prune) || fail "self prune failed: $out"
  printf '%s\n' "$out"
  case $out in *"kept $version: a running pharos uses it"*) ;; *) fail "self prune didn't keep $version for its daemon" ;; esac
  case $out in *"kept $version-s2 (current)"*) ;; *) fail "self prune didn't keep the current version" ;; esac
  case $out in *"kept $version-s1 (previous)"*) ;; *) fail "self prune didn't keep the previous version" ;; esac
  [ -d "$versions/$version" ] || fail "self prune removed $version under its daemon"
  ok "self prune kept $version while its daemon ran"

  "$versions/$version/bin/pharos" daemon stop >/dev/null || fail "daemon stop failed"
  wait "$daemon" || true
  out=$("$pharos" self prune) || fail "self prune failed: $out"
  printf '%s\n' "$out"
  [ ! -d "$versions/$version" ] || fail "self prune left $version after its daemon stopped"
  ok "self prune removed $version once its daemon stopped"

  out=$("$pharos" self rollback) || fail "self rollback failed: $out"
  printf '%s\n' "$out"
  [ "$("$pharos" --version)" = "pharos $version-s1" ] || fail "self rollback didn't switch to $version-s1"
  ok "self rollback switched back to $version-s1"
fi

out=$("$pharos" self uninstall) || fail "self uninstall failed: $out"
printf '%s\n' "$out"
[ ! -e "$pharos" ] || fail "self uninstall left $pharos"
[ ! -d "$versions" ] || fail "self uninstall left $versions"
ok "self uninstall removed it"
echo "smoke: pharos $version passed"
