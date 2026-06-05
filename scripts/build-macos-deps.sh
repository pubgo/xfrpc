#!/usr/bin/env bash
# Build xfrpc's C dependencies (zlib, OpenSSL, libevent, json-c) as static
# libraries for macOS, into a per-arch sysroot. The resulting archives let
# `zig build -Ddep-static` produce a portable macOS binary that links the deps
# statically and only depends on the system libSystem (no Homebrew required).
#
#   scripts/build-macos-deps.sh                 # native arch
#   ARCH=x86_64 scripts/build-macos-deps.sh     # Intel (cross from Apple Silicon)
#   ARCH=arm64  scripts/build-macos-deps.sh     # Apple Silicon
#
# Then:
#   zig build -Dtarget=aarch64-macos \
#             -Ddep-prefix="$HOME/.cache/xfrpc-macos/arm64/sysroot" \
#             -Doptimize=ReleaseSmall -Ddep-static
#
# Requirements on the build host: macOS with Xcode CLT (clang, ar), cmake,
# make, curl, tar.
set -euo pipefail

ARCH="${ARCH:-$(uname -m)}"   # arm64 | x86_64
case "$ARCH" in
  arm64|aarch64) ARCH=arm64; OPENSSL_PLATFORM=darwin64-arm64-cc;  HOST_TRIPLE=aarch64-apple-darwin ;;
  x86_64|amd64)  ARCH=x86_64; OPENSSL_PLATFORM=darwin64-x86_64-cc; HOST_TRIPLE=x86_64-apple-darwin ;;
  *) echo "Unsupported ARCH '$ARCH' (use arm64 or x86_64)" >&2; exit 1 ;;
esac

ROOT="${ROOT:-$HOME/.cache/xfrpc-macos/$ARCH}"
SYSROOT="$ROOT/sysroot"
SRC="$ROOT/src"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

ZLIB_VER="${ZLIB_VER:-1.3.1}"
OPENSSL_VER="${OPENSSL_VER:-3.0.15}"
LIBEVENT_VER="${LIBEVENT_VER:-2.1.12-stable}"
JSONC_VER="${JSONC_VER:-0.18-20240915}"

# Idempotent short-circuit: skip the (slow) rebuild when every dep is already
# present (e.g. a restored CI cache). Set FORCE=1 to rebuild from scratch.
have_all_libs() {
  [ -f "$SYSROOT/lib/libz.a" ] &&
  [ -f "$SYSROOT/lib/libevent.a" ] &&
  [ -f "$SYSROOT/lib/libjson-c.a" ] &&
  { [ -f "$SYSROOT/lib/libssl.a" ] || [ -f "$SYSROOT/lib64/libssl.a" ]; } &&
  { [ -f "$SYSROOT/lib/libcrypto.a" ] || [ -f "$SYSROOT/lib64/libcrypto.a" ]; }
}
if [ "${FORCE:-0}" != "1" ] && have_all_libs; then
  echo ">>> deps already built for macOS/$ARCH at $SYSROOT (set FORCE=1 to rebuild)"
  exit 0
fi

rm -rf "$SYSROOT"
mkdir -p "$SYSROOT" "$SRC"

export CC="clang"
export CXX="clang++"
export CFLAGS="-arch $ARCH -mmacosx-version-min=11.0 -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=11.0 -L$SYSROOT/lib"
export CPPFLAGS="-I$SYSROOT/include"

cd "$SRC"

dl() { # url outfile
  if [ -s "$2" ]; then echo ">>> cached $2"; return; fi
  echo ">>> downloading $2"
  curl -fsSL "$1" -o "$2"
}

# --- zlib --------------------------------------------------------------------
echo "================ zlib $ZLIB_VER ================"
dl "https://github.com/madler/zlib/releases/download/v$ZLIB_VER/zlib-$ZLIB_VER.tar.gz" zlib.tar.gz
rm -rf "zlib-$ZLIB_VER"
tar xf zlib.tar.gz
( cd "zlib-$ZLIB_VER"
  ./configure --static --prefix="$SYSROOT"
  make -j"$JOBS"
  make install )

# --- OpenSSL -----------------------------------------------------------------
echo "================ openssl $OPENSSL_VER ================"
dl "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" openssl.tar.gz
rm -rf "openssl-$OPENSSL_VER"
tar xf openssl.tar.gz
( cd "openssl-$OPENSSL_VER"
  ./Configure "$OPENSSL_PLATFORM" no-shared no-tests \
    --prefix="$SYSROOT" --openssldir="$SYSROOT/ssl"
  make -j"$JOBS" build_libs
  make install_dev )

# --- libevent ----------------------------------------------------------------
echo "================ libevent $LIBEVENT_VER ================"
dl "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz" libevent.tar.gz
rm -rf "libevent-$LIBEVENT_VER"
tar xf libevent.tar.gz
( cd "libevent-$LIBEVENT_VER"
  ./configure --host="$HOST_TRIPLE" --disable-shared --enable-static \
    --disable-samples --disable-libevent-regress --disable-debug-mode \
    --prefix="$SYSROOT" \
    CPPFLAGS="-I$SYSROOT/include" LDFLAGS="-L$SYSROOT/lib"
  make -j"$JOBS"
  make install )

# --- json-c ------------------------------------------------------------------
echo "================ json-c $JSONC_VER ================"
dl "https://github.com/json-c/json-c/archive/refs/tags/json-c-$JSONC_VER.tar.gz" json-c.tar.gz
rm -rf "json-c-json-c-$JSONC_VER"
tar xf json-c.tar.gz
( cd "json-c-json-c-$JSONC_VER"
  cmake -S . -B build \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DDISABLE_WERROR=ON \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j"$JOBS"
  cmake --install build )

echo
echo "================ DONE ================"
echo "Arch   : $ARCH"
echo "Sysroot: $SYSROOT"
echo
echo "Build a portable macOS xfrpc with:"
echo "  zig build -Dtarget=${HOST_TRIPLE/aarch64-apple-darwin/aarch64-macos} -Ddep-prefix=$SYSROOT -Doptimize=ReleaseSmall -Ddep-static"
