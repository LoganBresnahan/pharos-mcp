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
#   - `install.sh --uninstall` removes it.
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

if [ -n "${PHAROS_DOWNLOAD_URL:-}" ]; then
  sh "$here/install.sh" --uninstall
else
  curl -fsSL "https://github.com/$REPO/releases/download/v$version/install.sh" | sh -s -- --uninstall
fi
[ ! -e "$pharos" ] || fail "--uninstall left $pharos"
ok "uninstalled"
echo "smoke: pharos $version passed"
