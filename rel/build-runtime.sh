#!/usr/bin/env bash
# Build the runtime a geex release carries (ADR-0041): Erlang/OTP from source, with OpenSSL and
# (on Linux) ncurses linked in statically, plus Elixir's precompiled release. CI runs it once per
# target and caches the result; it also runs on a developer machine.
#
#   rel/build-runtime.sh PREFIX
#
# PREFIX gets:
#   PREFIX/bin/erl, PREFIX/lib/erlang   OTP
#   PREFIX/elixir/bin/elixir, mix …     Elixir
#   PREFIX/deps                         the static OpenSSL (and ncurses) OTP links in
#
# Every source is downloaded from its own project and checked against the sha256 pinned here.
# Changing a version or a flag here changes the CI cache key (it hashes this file).
#
# Why each piece, and what the release may link dynamically: ADR-0041 §1.
set -euo pipefail

OTP_VSN=28.1.1
OTP_SHA256=03e1b26e846b2cc1b49271656da6d5ecf4d5f4c2e34224d869a23c61a3d5660a
ELIXIR_VSN=1.19.5
ELIXIR_SHA256=ca481510feb6dabc875bba43e44b25c7abafa53bd7a103639851b7aeace8a022
OPENSSL_VSN=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
NCURSES_VSN=6.5
NCURSES_SHA256=136d91bc269a9a5785e5f9e980bc76ab57428f604ce3e5a5a90cebc767971cc6

[ $# -eq 1 ] || { echo "usage: $0 PREFIX" >&2; exit 2; }
mkdir -p "$1"
PREFIX=$(cd "$1" && pwd -P)
DEPS=$PREFIX/deps
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

OS=$(uname -s)
case $OS in
  Darwin) JOBS=$(sysctl -n hw.ncpu) ;;
  *) JOBS=$(nproc) ;;
esac

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch URL SHA256: download into $WORK, fail unless it hashes to SHA256.
fetch() {
  local file=$WORK/${1##*/}
  curl -fsSL --retry 3 -o "$file" "$1"
  local got
  got=$(sha256 "$file")
  if [ "$got" != "$2" ]; then
    echo "build-runtime: $1 has sha256 $got, expected $2" >&2
    exit 1
  fi
  echo "$file"
}

# OpenSSL, static only: the crypto NIF links it in, so the release needs no libcrypto.
src=$(fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VSN/openssl-$OPENSSL_VSN.tar.gz" "$OPENSSL_SHA256")
tar -xzf "$src" -C "$WORK"
(
  cd "$WORK/openssl-$OPENSSL_VSN"
  ./Configure --prefix="$DEPS" --libdir=lib no-shared no-tests no-docs no-module
  make -j"$JOBS" >/dev/null
  make install_sw >/dev/null
)

# ncurses, static only (Linux): `:prim_tty` looks the terminal up with tgetent, so OTP needs a
# termcap library, and a static one leaves no libtinfo to depend on. The terminfo database is the
# system's, in the directories glibc distributions keep it (Debian keeps xterm's in /lib); the
# common terminals are compiled in as fallbacks too (from this machine's database, so it needs
# their entries and `infocmp`), so they work with no database at all. macOS has ncurses in the OS.
CPPFLAGS=-I$DEPS/include
LDFLAGS=-L$DEPS/lib
if [ "$OS" = Linux ]; then
  src=$(fetch "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VSN.tar.gz" "$NCURSES_SHA256")
  tar -xzf "$src" -C "$WORK"
  (
    cd "$WORK/ncurses-$NCURSES_VSN"
    # A separate libtinfo.a (and no "w" suffix): OTP's configure tries -ltinfo first, and finding
    # this one ahead of the system's libtinfo.so is what makes the link static.
    ./configure --prefix="$DEPS" --without-shared --with-termlib --disable-widec \
      --without-debug --without-cxx \
      --without-cxx-binding --without-ada --without-progs --without-tests --without-manpages \
      --enable-pc-files=no \
      --with-default-terminfo-dir=/usr/share/terminfo \
      --with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo \
      --with-fallbacks=xterm-256color,xterm,screen-256color,screen,tmux-256color,tmux,linux,vt100 \
      CFLAGS="-O2 -fPIC" >/dev/null
    make -j"$JOBS" >/dev/null
    # The library and headers only: the terminfo database stays the system's.
    make install.libs install.includes >/dev/null
  )
  # The C++ runtime the JIT is written against goes in statically too, so beam.smp needs only
  # the C library (and libgcc_s, ADR-0041 §1).
  LDFLAGS="$LDFLAGS -static-libstdc++ -static-libgcc"
fi

src=$(fetch "https://github.com/erlang/otp/releases/download/OTP-$OTP_VSN/otp_src_$OTP_VSN.tar.gz" "$OTP_SHA256")
tar -xzf "$src" -C "$WORK"
(
  cd "$WORK/otp_src_$OTP_VSN"
  ./configure --prefix="$PREFIX" \
    --with-ssl="$DEPS" --disable-dynamic-ssl-lib \
    --with-termcap --enable-builtin-zlib \
    --without-javac --without-jinterface --without-odbc --without-wx \
    --without-debugger --without-observer --without-et \
    CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
)

src=$(fetch "https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR_VSN/elixir-otp-28.zip" "$ELIXIR_SHA256")
rm -rf "$PREFIX/elixir"
mkdir -p "$PREFIX/elixir"
unzip -q "$src" -d "$PREFIX/elixir"

"$PREFIX/bin/erl" -noshell -eval \
  'io:format("build-runtime: OTP ~s (erts ~s), crypto with ~s~n", [erlang:system_info(otp_release), erlang:system_info(version), element(3, hd(crypto:info_lib()))]), halt().'
PATH=$PREFIX/bin:$PATH "$PREFIX/elixir/bin/elixir" --version | tail -1
