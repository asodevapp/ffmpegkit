#!/bin/sh
# SPDX-License-Identifier: LGPL-3.0-or-later
# Copyright (c) 2026 ASO.dev
# Installs the tools build.sh needs on a Mac into $FFKIT_HOME/tools, without Homebrew or sudo: CMake, Ninja and Meson
# in a Python venv, and NASM, pkgconf and Bash 5 (FFmpegKit's post-build script needs Bash 4+) built from source.
# Xcode (clang, lipo, codesign, xcodebuild) must already be installed.
set -eu

FFKIT_HOME=${FFKIT_HOME:-$HOME/.cache/asodev-ffmpegkit}
TOOLS=$FFKIT_HOME/tools
JOBS=$(getconf _NPROCESSORS_ONLN)
mkdir -p "$TOOLS/src" "$TOOLS/bin"
cd "$TOOLS/src"

fetch() { # url sha256 file
  [ -f "$3" ] || curl -fsSL -o "$3.part" "$1"
  [ -f "$3.part" ] && mv "$3.part" "$3"
  echo "$2  $3" | shasum -a 256 -c - >/dev/null || { echo "bootstrap: $3 does not match its SHA-256" >&2; rm -f "$3"; exit 1; }
}

if [ ! -x "$TOOLS/venv/bin/meson" ]; then
  python3 -m venv "$TOOLS/venv"
  "$TOOLS/venv/bin/pip" install -q 'cmake==3.31.6' 'ninja==1.11.1.4' 'meson==1.7.2'
fi

if [ ! -x "$TOOLS/bin/nasm" ]; then
  fetch https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/nasm-2.16.03.tar.xz \
    1412a1c760bbd05db026b6c0d1657affd6631cd0a63cddb6f73cc6d4aa616148 nasm-2.16.03.tar.xz
  rm -rf nasm-2.16.03 && tar -xf nasm-2.16.03.tar.xz
  (cd nasm-2.16.03 && ./configure --prefix="$TOOLS" >/dev/null && make -j "$JOBS" >/dev/null && make install >/dev/null)
fi

if [ ! -x "$TOOLS/bin/bash" ]; then
  fetch https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz \
    9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff bash-5.2.37.tar.gz
  rm -rf bash-5.2.37 && tar -xzf bash-5.2.37.tar.gz
  (cd bash-5.2.37 && ./configure --prefix="$TOOLS" --without-bash-malloc --disable-nls >/dev/null &&
    make -j "$JOBS" >/dev/null && make install >/dev/null)
fi

if [ ! -x "$TOOLS/bin/pkgconf" ]; then
  rm -rf pkgconf && git init -q pkgconf
  git -C pkgconf fetch -q --depth 1 https://github.com/pkgconf/pkgconf.git a88c0d962a987c62d98ede5a738e37ec71005cbd
  git -C pkgconf -c advice.detachedHead=false checkout -q FETCH_HEAD # pkgconf-2.3.0
  (cd pkgconf && PATH=$TOOLS/venv/bin:$PATH meson setup build --prefix="$TOOLS" -Ddefault_library=static \
    -Dtests=disabled >/dev/null && PATH=$TOOLS/venv/bin:$PATH ninja -C build install >/dev/null)
  ln -sf pkgconf "$TOOLS/bin/pkg-config"
fi

echo "Tools ready in $TOOLS"
