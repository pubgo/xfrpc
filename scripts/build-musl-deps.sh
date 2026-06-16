#!/usr/bin/env bash
# Cross-compile xfrpc's C dependencies (zlib, OpenSSL, libevent, json-c) as
# static libraries for a musl/Linux target using Zig as the cross toolchain.
#
# The result is a self-contained sysroot that `zig build` can consume via
# -Ddep-prefix to produce a fully static xfrpc binary:
#
#   scripts/build-musl-deps.sh                       # x86_64-linux-musl
#   TARGET=aarch64-linux-musl scripts/build-musl-deps.sh
#
#   zig build -Dtarget=x86_64-linux-musl \
#             -Ddep-prefix="$HOME/.cache/xfrpc-musl/sysroot" \
#             -Doptimize=ReleaseSmall -Dstatic
#
# Requirements on the build host: zig (>= 0.16), cmake, make, curl, tar.
set -euo pipefail

TARGET="${TARGET:-x86_64-linux-musl}"
ROOT="${ROOT:-$HOME/.cache/xfrpc-musl}"
SYSROOT="$ROOT/sysroot"
SRC="$ROOT/src"
TC="$ROOT/tc"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

ZLIB_VER="${ZLIB_VER:-1.3.1}"
OPENSSL_VER="${OPENSSL_VER:-3.0.15}"
LIBEVENT_VER="${LIBEVENT_VER:-2.1.12-stable}"
JSONC_VER="${JSONC_VER:-0.18-20240915}"

# Map the Zig target to an OpenSSL Configure platform.
case "$TARGET" in
  x86_64-linux-*)  OPENSSL_PLATFORM=linux-x86_64 ;;
  aarch64-linux-*) OPENSSL_PLATFORM=linux-aarch64 ;;
  arm-linux-*)     OPENSSL_PLATFORM=linux-armv4 ;;
  mips-linux-*|mipsel-linux-*) OPENSSL_PLATFORM=linux-mips32 ;;
  *) echo "!! Unknown TARGET '$TARGET'; set OPENSSL_PLATFORM manually" >&2
     OPENSSL_PLATFORM="${OPENSSL_PLATFORM:-linux-generic64}" ;;
esac
CMAKE_PROCESSOR="${TARGET%%-*}"

# Idempotent short-circuit: if every dep is already present (e.g. a restored CI
# cache), skip the (slow) rebuild. Set FORCE=1 to rebuild from scratch.
have_all_libs() {
  [ -f "$SYSROOT/lib/libz.a" ] &&
  [ -f "$SYSROOT/lib/libevent.a" ] &&
  [ -f "$SYSROOT/lib/libjson-c.a" ] &&
  { [ -f "$SYSROOT/lib/libssl.a" ] || [ -f "$SYSROOT/lib64/libssl.a" ]; } &&
  { [ -f "$SYSROOT/lib/libcrypto.a" ] || [ -f "$SYSROOT/lib64/libcrypto.a" ]; }
}
if [ "${FORCE:-0}" != "1" ] && have_all_libs; then
  echo ">>> deps already built for $TARGET at $SYSROOT (set FORCE=1 to rebuild)"
  exit 0
fi

rm -rf "$SYSROOT"
mkdir -p "$SYSROOT" "$SRC" "$TC"

# --- Zig toolchain wrappers --------------------------------------------------
cat > "$TC/cc" <<EOF
#!/bin/sh
exec zig cc -target $TARGET "\$@"
EOF
cat > "$TC/c++" <<EOF
#!/bin/sh
exec zig c++ -target $TARGET "\$@"
EOF
cat > "$TC/ar" <<'EOF'
#!/bin/sh
exec zig ar "$@"
EOF
cat > "$TC/ranlib" <<'EOF'
#!/bin/sh
exec zig ranlib "$@"
EOF
chmod +x "$TC"/*

export CC="$TC/cc"
export CXX="$TC/c++"
export AR="$TC/ar"
export RANLIB="$TC/ranlib"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig:$SYSROOT/lib64/pkgconfig"
export CPPFLAGS="-I$SYSROOT/include"
export LDFLAGS="-L$SYSROOT/lib"

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
  CC="$CC" AR="$AR" RANLIB="$RANLIB" ./configure --static --prefix="$SYSROOT"
  # Force our ar/ranlib: zlib's configure may otherwise pick the host's
  # (Apple) libtool, which cannot create ELF archives.
  make -j"$JOBS" libz.a AR="$TC/ar" ARFLAGS="rcs" RANLIB="$TC/ranlib"
  make install AR="$TC/ar" ARFLAGS="rcs" RANLIB="$TC/ranlib" )

# --- OpenSSL -----------------------------------------------------------------
echo "================ openssl $OPENSSL_VER ================"
dl "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" openssl.tar.gz
rm -rf "openssl-$OPENSSL_VER"
tar xf openssl.tar.gz
( cd "openssl-$OPENSSL_VER"
  ./Configure "$OPENSSL_PLATFORM" no-shared no-tests no-asm \
    --prefix="$SYSROOT" --openssldir="$SYSROOT/ssl" \
    CC="$CC" AR="$AR" RANLIB="$RANLIB"
  make -j"$JOBS" build_libs
  make install_dev )

# --- libevent ----------------------------------------------------------------
echo "================ libevent $LIBEVENT_VER ================"
dl "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER/libevent-$LIBEVENT_VER.tar.gz" libevent.tar.gz
rm -rf "libevent-$LIBEVENT_VER"
tar xf libevent.tar.gz
( cd "libevent-$LIBEVENT_VER"
  ./configure --host="$TARGET" --disable-shared --enable-static \
    --disable-samples --disable-libevent-regress --disable-debug-mode \
    --prefix="$SYSROOT" \
    CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CPPFLAGS="-I$SYSROOT/include" LDFLAGS="-L$SYSROOT/lib"
  make -j"$JOBS"
  make install )

# --- json-c ------------------------------------------------------------------
echo "================ json-c $JSONC_VER ================"
dl "https://github.com/json-c/json-c/archive/refs/tags/json-c-$JSONC_VER.tar.gz" json-c.tar.gz
rm -rf "json-c-json-c-$JSONC_VER"
tar xf json-c.tar.gz
( cd "json-c-json-c-$JSONC_VER"
  # CMAKE_POLICY_VERSION_MINIMUM works around json-c's vendored apps/ CMake
  # files that still request cmake_minimum_required < 3.5; BUILD_APPS=OFF skips
  # the demo apps we don't need.
  cmake -S . -B build \
    -DCMAKE_C_COMPILER="$TC/cc" -DCMAKE_AR="$TC/ar" -DCMAKE_RANLIB="$TC/ranlib" \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR="$CMAKE_PROCESSOR" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DDISABLE_WERROR=ON \
    -DCMAKE_INSTALL_PREFIX="$SYSROOT" -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j"$JOBS"
  cmake --install build )

echo
echo "================ DONE ================"
echo "Target : $TARGET"
echo "Sysroot: $SYSROOT"
echo
echo "Build a fully static xfrpc with:"
echo "  zig build -Dtarget=$TARGET -Ddep-prefix=$SYSROOT -Doptimize=ReleaseSmall -Dstatic"
