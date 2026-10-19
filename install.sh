#!/bin/sh
# Install pharos (ADR-035 §4). This is geex's install.sh (geex ADR-0041 §4, at geex 286d128)
# with pharos's names; keep the two in step.
#
#   curl -fsSL https://github.com/LoganBresnahan/pharos-mcp/releases/latest/download/install.sh | sh
#   curl -fsSL …/install.sh | sh -s -- --version 0.2.0
#
#   sh install.sh [--version VERSION] [--force]   install (default: the latest release)
#   sh install.sh --rollback                      switch back to the previous version
#   sh install.sh --prune                         remove the versions an install would remove
#   sh install.sh --uninstall                     remove pharos's program files and its link
#
# Each version unpacks whole into $PHAROS_INSTALL_DIR/versions/VERSION (default
# ${XDG_DATA_HOME:-~/.local/share}/pharos), and $PHAROS_BIN_DIR/pharos (default
# ~/.local/bin/pharos) is a symlink to its bin/pharos, replaced in one rename. The current and the
# previous version are kept; an older one goes once no running process uses it (a pharos daemon
# names its version on its command line until it idles out). PHAROS_DOWNLOAD_URL replaces the
# release's download directory (a file:// directory works, for a local build's _build/package).
#
# POSIX sh, no sudo. It touches nothing but those two places: no shell rc, no MCP client
# config, no pharos settings.
set -eu

REPO=LoganBresnahan/pharos-mcp
APP=pharos

say() { printf '%s\n' "$APP install: $*"; }
die() { printf '%s\n' "$APP install: $*" >&2; exit 1; }

usage() {
  cat <<EOF
usage: install.sh [--version VERSION] [--force] | --rollback | --prune | --uninstall

  --version VERSION    install VERSION instead of the latest release
  --force              install again though VERSION is the current one
  --rollback           switch back to the previous version
  --prune              remove every version but the current and the previous one, unless a
                       running pharos uses it (an install does this too); downloads nothing
  --uninstall          remove pharos's versions and ~/.local/bin/pharos (keeps settings,
                       logs and memories)

  PHAROS_INSTALL_DIR   where versions go (default \${XDG_DATA_HOME:-~/.local/share}/pharos)
  PHAROS_BIN_DIR       where the pharos link goes (default ~/.local/bin)
  PHAROS_DOWNLOAD_URL  where the release files are (default the GitHub release of VERSION)
EOF
}

version=
force=
action=install
while [ $# -gt 0 ]; do
  case $1 in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version=${2#v}; shift 2 ;;
    --version=*) version=${1#--version=}; version=${version#v}; shift ;;
    --force) force=1; shift ;;
    --rollback) action=rollback; shift ;;
    --prune) action=prune; shift ;;
    --uninstall) action=uninstall; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[ -n "${HOME:-}" ] || die "HOME isn't set"
install_dir=${PHAROS_INSTALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/$APP}
bin_dir=${PHAROS_BIN_DIR:-$HOME/.local/bin}
mkdir -p "$install_dir/versions" "$bin_dir"
# Physical paths: the shim resolves its release to one, so a running daemon is found by it, and
# every message spells a directory one way (macOS's /var is /private/var).
install_dir=$(cd "$install_dir" && pwd -P)
versions=$install_dir/versions
bin_dir=$(cd "$bin_dir" && pwd -P)
link=$bin_dir/$APP
previous_file=$install_dir/previous

# Sets `current` to the version $link points at, or nothing. Stops when $link is something this
# script didn't make.
current=
read_current() {
  if [ -L "$link" ]; then
    target=$(readlink "$link")
    case $target in
      "$versions"/*/bin/$APP) target=${target#"$versions"/}; current=${target%%/*} ;;
      *) die "$link links to $target, not a pharos this script installed; left alone" ;;
    esac
  elif [ -e "$link" ]; then
    # pharos 0.1.x was installed by hand as a single (Burrito) binary here.
    die "$link exists and isn't a link (a pharos 0.1.x binary installed by hand?); remove it and run this again"
  fi
}

previous_version() {
  if [ -f "$previous_file" ]; then cat "$previous_file"; fi
}

# Point $link at VERSION's launcher, in one rename (a symlink to a file: BSD and GNU mv alike
# replace it, where a directory symlink would be moved into).
switch_to() {
  tmp=$bin_dir/.$APP.tmp.$$
  rm -f "$tmp"
  ln -s "$versions/$1/bin/$APP" "$tmp"
  mv -f "$tmp" "$link"
}

remember_previous() {
  printf '%s\n' "$1" >"$previous_file.tmp.$$"
  mv -f "$previous_file.tmp.$$" "$previous_file"
}

# Every running process's command line, read once (a `ps | grep` would see its own grep).
running=
read_running() { running=$(ps -A -ww -o args= 2>/dev/null || true); }

# Whether a running process names DIR in its command line: the VM's -root and -bindir, and the
# programs it starts from erts/bin, all do.
in_use() {
  case $running in
    *"$1/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Keep the current and the previous version; remove the others, and leftovers of an install that
# stopped half-way, unless a running process uses them. A VM loads every module at boot, but it
# still starts programs from its erts/bin later (a host name lookup), so one in use stays until a
# later install finds it unused.
prune() {
  read_running
  keep_current=$1
  keep_previous=$(previous_version)
  for dir in "$versions"/* "$versions"/.old-* "$versions"/.tmp-*; do
    [ -d "$dir" ] || continue
    name=${dir##*/}
    if [ "$name" = "$keep_current" ]; then say "kept $name (current)"; continue; fi
    if [ "$name" = "$keep_previous" ]; then say "kept $name (previous)"; continue; fi
    case $name in
      .tmp-*) kill -0 "${name#.tmp-}" 2>/dev/null && continue ;;
    esac
    if in_use "$dir"; then
      say "kept $name: a running pharos uses it"
    else
      rm -rf "$dir"
      case $name in
        .*) ;;
        *) say "removed $name" ;;
      esac
    fi
  done
}

path_hint() {
  case ":${PATH:-}:" in
    *":$bin_dir:"*) ;;
    *) say "$bin_dir isn't on your PATH; add it in your shell's startup file:"
       # shellcheck disable=SC2016 # the line to paste, with $PATH as it is
       printf '    export PATH="%s:$PATH"\n' "$bin_dir" ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "no sha256sum or shasum to check the download with"; fi
}

platform() {
  case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "this installer is for Linux and macOS, not $(uname -s) (on Windows, run it inside WSL)" ;;
  esac
  case $(uname -m) in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "pharos is built for x64 and arm64, not $(uname -m)" ;;
  esac
  # A shell under Rosetta reports x86_64 on an Apple silicon Mac; the native build is the one.
  if [ "$os-$arch" = darwin-x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then
    arch=arm64
  fi
  if [ $os = linux ]; then
    # The Linux builds link glibc 2.35 (Ubuntu 22.04) and need it or newer; musl can't run them.
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null || true)
    case $libc in
      "glibc "*) ;;
      *) die "pharos 0.2 needs glibc 2.35+ (Alpine/musl and older distros aren't supported yet); pharos-mcp@0.1.4 still runs there" ;;
    esac
    v=${libc#glibc }
    major=${v%%.*}
    minor=${v#*.}
    minor=${minor%%.*}
    if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
      die "pharos 0.2 needs glibc 2.35+ and this system has $v (older distros aren't supported yet); pharos-mcp@0.1.4 still runs there"
    fi
  fi
}

latest_version() {
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") ||
    die "couldn't reach github.com to find the latest release"
  case $url in
    */releases/tag/v*) printf '%s\n' "${url##*/releases/tag/v}" ;;
    *) die "couldn't find the latest release (got $url)" ;;
  esac
}

do_install() {
  platform
  if [ -z "$version" ]; then
    [ -z "${PHAROS_DOWNLOAD_URL:-}" ] || die "PHAROS_DOWNLOAD_URL needs --version"
    version=$(latest_version)
  fi
  read_current
  if [ "$version" = "$current" ] && [ -z "$force" ]; then
    say "pharos $version is already installed (--force installs it again)"
    path_hint
    exit 0
  fi

  if [ -d "$versions/$version" ] && [ -z "$force" ]; then
    say "pharos $version is already unpacked; switching to it"
  else
    fetch_and_unpack
  fi

  if [ -n "$current" ] && [ "$current" != "$version" ]; then remember_previous "$current"; fi
  switch_to "$version"
  say "installed pharos $version at $versions/$version, linked from $link"
  prune "$version"
  path_hint
}

fetch_and_unpack() {
  name=$APP-$version-$os-$arch
  base=${PHAROS_DOWNLOAD_URL:-https://github.com/$REPO/releases/download/v$version}
  stage=$versions/.tmp-$$
  rm -rf "$stage"
  mkdir -p "$stage"
  trap 'rm -rf "$stage"' EXIT
  trap 'exit 130' INT TERM

  say "downloading $name.tar.gz"
  curl -fsSL --retry 3 -o "$stage/SHA256SUMS" "$base/SHA256SUMS" ||
    die "couldn't download $base/SHA256SUMS (is there a pharos $version?)"
  curl -fsSL --retry 3 -o "$stage/$name.tar.gz" "$base/$name.tar.gz" ||
    die "couldn't download $base/$name.tar.gz (is there a pharos $version for $os-$arch?)"

  # Fail closed: no line for the file, or a different hash, and nothing is unpacked.
  want=$(awk -v f="$name.tar.gz" '$2 == f || $2 == "*" f { print $1 }' "$stage/SHA256SUMS")
  [ -n "$want" ] || die "SHA256SUMS has no line for $name.tar.gz"
  got=$(sha256_of "$stage/$name.tar.gz")
  [ "$got" = "$want" ] || die "$name.tar.gz has sha256 $got, but SHA256SUMS says $want"

  tar -xzf "$stage/$name.tar.gz" -C "$stage"
  [ -x "$stage/$name/bin/$APP" ] || die "$name.tar.gz has no bin/$APP"
  said=$("$stage/$name/bin/$APP" --version 2>&1) || die "the new pharos didn't start: $said"
  [ "$said" = "pharos $version" ] || die "the new pharos says \"$said\", not \"pharos $version\""

  # A reinstall of the same version moves the old one aside first: a running daemon resolves its
  # programs by path, and finds the new copy's, of the same version.
  if [ -d "$versions/$version" ]; then mv "$versions/$version" "$versions/.old-$version-$$"; fi
  mv "$stage/$name" "$versions/$version"
  rm -rf "$stage" "$versions/.old-$version-$$"
  trap - EXIT INT TERM
}

do_rollback() {
  read_current
  prev=$(previous_version)
  if [ -z "$prev" ] || [ ! -d "$versions/$prev" ]; then die "no previous version to roll back to"; fi
  switch_to "$prev"
  if [ -n "$current" ]; then remember_previous "$current"; fi
  say "rolled back to pharos $prev (pharos $current is now the previous version)"
}

# No current version (no link, or one to another layout) is nothing to prune: the current one is
# what decides what stays.
do_prune() {
  read_current
  if [ -z "$current" ]; then
    say "no pharos installed at $link; nothing to prune"
    return 0
  fi
  prune "$current"
}

do_uninstall() {
  read_current
  read_running
  if in_use "$versions"; then
    die "a running pharos uses $versions; stop it (pharos daemon stop --all, and quit MCP clients that run it), then run --uninstall again (nothing was removed)"
  fi
  if [ -n "$current" ]; then rm -f "$link"; fi
  rm -rf "$versions" "$previous_file"
  say "removed pharos from $install_dir/versions and $link"
  say "kept: settings (${XDG_CONFIG_HOME:-~/.config}/pharos), logs (${XDG_STATE_HOME:-~/.local/state}/pharos),"
  say "memories (~/.pharos/memories) and instance tracking ($install_dir/instances); remove those by hand if you like"
  say "MCP client configs that name pharos are yours to edit"
}

case $action in
  install) do_install ;;
  rollback) do_rollback ;;
  prune) do_prune ;;
  uninstall) do_uninstall ;;
esac
