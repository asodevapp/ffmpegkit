#!/usr/bin/env bash
# Builds the desktop FFmpegKit library ASO.dev ships: FFmpeg cut down to what the app calls, wrapped by FFmpegKit
# (ffmpeg-kit-builders v0.10.5). README.md lists the components and why each one is there.
#
# Usage: build.sh macos|linux|windows [--jobs N]
#   macos     on a Mac with Xcode, tools from bootstrap-macos.sh: arm64 + x86_64, a universal .dylib zip
#   linux     in docker/Dockerfile (Ubuntu 22.04, the app's Linux build image): x86_64 .so zip
#   windows   in docker/Dockerfile with mingw-w64 GCC: x86_64 .dll zip
# On a Mac, linux and windows start the container themselves (Docker or a compatible CLI).
#
# Work files go to $FFKIT_HOME (default ~/.cache/asodev-ffmpegkit), archives to $FFKIT_HOME/out.
set -euo pipefail

TOOL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=release.env
source "$TOOL_DIR/release.env"
FFKIT_HOME=${FFKIT_HOME:-$HOME/.cache/asodev-ffmpegkit}
MACOS_MIN=13.0
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

# --- What FFmpeg keeps -----------------------------------------------------------------------------------------------
# Input side stays complete: every built-in demuxer, decoder, parser and bitstream filter, plus dav1d for AV1, so any
# video a user drops opens. Everything else is a whitelist of what the ASO.dev app calls and what fftools insert on
# their own.

# Encoders: AAC audio, MJPEG previews, H.264/HEVC per platform (the app's encoder preferences).
# libopenh264 and libkvazaar are the software fallbacks and the only H.264/HEVC encoders on Linux: they come first
# there, so hardware encoders after them were never reached.
ENCODERS_COMMON=aac,mjpeg,libopenh264,libkvazaar
ENCODERS_MACOS=h264_videotoolbox,hevc_videotoolbox
ENCODERS_WINDOWS=h264_mf,hevc_mf
# Muxers: .mp4 output, stream-copy trim keeps the store file's container (.mov, .mp4, .m4v), JPEG preview frames.
MUXERS=mp4,mov,ipod,image2
# Filters: scale is the only one the app passes; the rest are inserted by fftools (ffmpeg_filter.c, ffplay.c) and by
# libavfilter format negotiation: graph ends, null graphs, pixel/sample format conversion, -ss/-t trimming,
# container cropping and display-matrix rotation.
FILTERS=buffer,buffersink,abuffer,abuffersink,null,anull,format,aformat,scale,aresample,trim,atrim,crop,transpose,hflip,vflip,rotate
# Only local files: downloads happen in Dart, FFmpeg never opens a URL.
PROTOCOLS=file

die() { echo "build.sh: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

ffmpeg_flags() { # platform -> FFmpeg configure flags, one per line
  local platform=$1 encoders=$ENCODERS_COMMON
  case $platform in
    macos) encoders+=,$ENCODERS_MACOS ;;
    windows) encoders+=,$ENCODERS_WINDOWS ;;
  esac
  printf '%s\n' \
    --disable-autodetect --disable-network --disable-programs --disable-doc --disable-debug \
    --disable-devices --disable-hwaccels \
    --disable-encoders "--enable-encoder=$encoders" \
    --disable-muxers "--enable-muxer=$MUXERS" \
    --disable-filters "--enable-filter=$FILTERS" \
    --disable-protocols "--enable-protocol=$PROTOCOLS" \
    --enable-zlib --enable-libopenh264 --enable-libkvazaar --enable-libdav1d \
    --enable-static --disable-shared --enable-pic \
    "--extra-version=asodev-$FFKIT_RELEASE"
  case $platform in
    macos) printf '%s\n' --enable-pthreads --enable-videotoolbox ;;
    linux) printf '%s\n' --enable-pthreads ;;
    # Windows threads come from winpthreads, as FFmpegKit's own code expects (FFmpeg's w32threads shim redefines
    # pthread_t). The Media Foundation encoder at this FFmpeg commit uses D3D11 types even without d3d11va, so the
    # D3D11 device context comes along; hardware decoding stays off (--disable-hwaccels).
    windows) printf '%s\n' --enable-pthreads --disable-w32threads --enable-mediafoundation --enable-d3d11va ;;
  esac
}

# --- Sources ---------------------------------------------------------------------------------------------------------

fetch() { # name -> pristine checkout of the locked commit; prints its path
  local name=$1 url commit dir
  read -r url commit < <(awk -v n="$name" '$1 == n { print $2, $3 }' "$TOOL_DIR/sources.lock")
  [[ -n ${commit:-} ]] || die "no $name in sources.lock"
  dir=$FFKIT_HOME/src/$name-$commit
  if [[ ! -f $dir/.fetched ]]; then
    log "fetching $name $commit"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" fetch -q --depth 1 "$url" "$commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [[ $(git -C "$dir" rev-parse HEAD) == "$commit" ]] || die "$name: checkout is not $commit"
    touch "$dir/.fetched"
  fi
  echo "$dir"
}

copy_source() { # name dest -> a private copy for builds that write into their source tree
  local src
  src=$(fetch "$1")
  rm -rf "$2"
  mkdir -p "$2"
  (cd "$src" && tar --exclude=.git -cf - .) | (cd "$2" && tar -xf -)
}

# --- Per-target toolchain --------------------------------------------------------------------------------------------
# Set by setup_target: TARGET (macos-arm64, ...), WORK, PREFIX, CC, CXX, AR, RANLIB, STRIP, CFLAGS_T, LDFLAGS_T,
# CMAKE_T (array), MESON_CROSS, FF_TARGET (array).

setup_target() { # platform arch
  local platform=$1 arch=$2
  TARGET=$platform-$arch
  WORK=$FFKIT_HOME/build/$FFKIT_RELEASE/$TARGET
  PREFIX=$WORK/prefix
  mkdir -p "$WORK" "$PREFIX/lib/pkgconfig" "$PREFIX/include"
  # Only our prefix, except on Linux, where SDL2 and FFmpegKit need the system's ALSA, PulseAudio and X11 headers.
  export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig
  if [[ $platform == linux ]]; then
    unset PKG_CONFIG_LIBDIR
  else
    export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
  fi
  local cpu_family=$arch system
  # Source paths reach the binary through __FILE__ in assertions; map them so no build-machine path ships.
  local prefix_map="-ffile-prefix-map=$FFKIT_HOME=ffkit"
  case $platform in
    macos)
      export SDKROOT
      SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
      CC=/usr/bin/clang CXX=/usr/bin/clang++ AR=$(xcrun -f ar) RANLIB=$(xcrun -f ranlib) STRIP=$(xcrun -f strip)
      CFLAGS_T="-arch $arch -mmacosx-version-min=$MACOS_MIN"
      LDFLAGS_T=$CFLAGS_T
      [[ $arch == arm64 ]] && cpu_family=aarch64
      system=darwin
      CMAKE_T=(-DCMAKE_SYSTEM_NAME=Darwin "-DCMAKE_SYSTEM_PROCESSOR=$arch" "-DCMAKE_OSX_ARCHITECTURES=$arch"
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN" "-DCMAKE_OSX_SYSROOT=$SDKROOT")
      local ffarch=$arch
      [[ $arch == arm64 ]] && ffarch=aarch64
      FF_TARGET=(--enable-cross-compile "--arch=$ffarch" --target-os=darwin "--cc=$CC" "--cxx=$CXX"
        "--objcc=$CC" "--ar=$AR" "--ranlib=$RANLIB" "--strip=$STRIP")
      ;;
    linux)
      CC=gcc CXX=g++ AR=ar RANLIB=ranlib STRIP=strip
      CFLAGS_T="-fPIC" LDFLAGS_T=""
      system=linux
      CMAKE_T=()
      FF_TARGET=("--cc=$CC" "--cxx=$CXX")
      ;;
    windows)
      local cross=x86_64-w64-mingw32-
      CC=${cross}gcc-posix CXX=${cross}g++-posix AR=${cross}ar RANLIB=${cross}ranlib STRIP=${cross}strip
      CFLAGS_T="" LDFLAGS_T=""
      system=windows
      CMAKE_T=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64 "-DCMAKE_RC_COMPILER=${cross}windres"
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY "-DCMAKE_FIND_ROOT_PATH=/usr/x86_64-w64-mingw32;$PREFIX")
      FF_TARGET=(--enable-cross-compile --arch=x86_64 --target-os=mingw32 "--cross-prefix=$cross"
        "--cc=$CC" "--cxx=$CXX")
      ;;
    *) die "unknown platform $platform" ;;
  esac
  CFLAGS_T="${CFLAGS_T:+$CFLAGS_T }$prefix_map"
  CMAKE_T+=(-G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=$PREFIX" "-DCMAKE_PREFIX_PATH=$PREFIX"
    -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=OFF
    "-DCMAKE_C_COMPILER=$CC" "-DCMAKE_CXX_COMPILER=$CXX" "-DCMAKE_C_FLAGS=$CFLAGS_T" "-DCMAKE_CXX_FLAGS=$CFLAGS_T"
    "-DCMAKE_ASM_NASM_COMPILER=$(command -v nasm)")
  MESON_CROSS=$WORK/meson-cross.ini
  {
    echo '[binaries]'
    echo "c = [$(meson_list "$CC" $CFLAGS_T)]"
    echo "cpp = [$(meson_list "$CXX" $CFLAGS_T)]"
    echo "ar = '$AR'"
    echo "strip = '$STRIP'"
    echo "pkg-config = '$(command -v pkg-config)'"
    echo "nasm = '$(command -v nasm)'"
    [[ $platform == windows ]] && echo "windres = '${cross}windres'"
    echo '[built-in options]'
    echo "c_link_args = [$(meson_list $LDFLAGS_T)]"
    echo "cpp_link_args = [$(meson_list $LDFLAGS_T)]"
    echo '[properties]'
    echo 'needs_exe_wrapper = true'
    echo '[host_machine]'
    echo "system = '$system'"
    echo "cpu_family = '$cpu_family'"
    echo "cpu = '$cpu_family'"
    echo "endian = 'little'"
  } >"$MESON_CROSS"
}

meson_list() { local out='' item; for item in "$@"; do out+="${out:+, }'$item'"; done; echo "$out"; }

cmake_build() { # source-dir build-dir args...
  local src=$1 build=$2
  shift 2
  cmake -S "$src" -B "$build" "${CMAKE_T[@]}" "$@" >"$build.log" 2>&1 || { tail -40 "$build.log"; die "cmake $src"; }
  cmake --build "$build" -j "$JOBS" >>"$build.log" 2>&1 || { tail -40 "$build.log"; die "build $src"; }
  cmake --install "$build" >>"$build.log" 2>&1 || { tail -40 "$build.log"; die "install $src"; }
}

meson_build() { # source-dir build-dir options...
  local src=$1 build=$2
  shift 2
  rm -rf "$build"
  meson setup "$build" "$src" --cross-file "$MESON_CROSS" --prefix "$PREFIX" --libdir lib --buildtype release \
    --default-library static -Db_pie=false "$@" >"$build.log" 2>&1 || { tail -40 "$build.log"; die "meson $src"; }
  ninja -C "$build" -j "$JOBS" install >>"$build.log" 2>&1 || { tail -40 "$build.log"; die "ninja $src"; }
}

# --- Dependencies ----------------------------------------------------------------------------------------------------

build_zlib() {
  local src=$WORK/zlib
  copy_source zlib "$src"
  log "$TARGET zlib"
  if [[ $TARGET == windows-* ]]; then
    make -C "$src" -f win32/Makefile.gcc PREFIX=x86_64-w64-mingw32- CC="$CC" -j "$JOBS" libz.a >"$src.log" 2>&1
    install -m 644 "$src/libz.a" "$PREFIX/lib/"
    install -m 644 "$src/zlib.h" "$src/zconf.h" "$PREFIX/include/"
  else
    (cd "$src" && CC=$CC CFLAGS="$CFLAGS_T -O2" ./configure --static --prefix="$PREFIX" >"$src.log" 2>&1 &&
      make -j "$JOBS" install >>"$src.log" 2>&1) || { tail -40 "$src.log"; die zlib; }
  fi
}

build_jsoncpp() {
  log "$TARGET jsoncpp"
  meson_build "$(fetch jsoncpp)" "$WORK/jsoncpp" -Dtests=false
}

build_sdl2() {
  # FFplay needs video, audio, render, events and timers; joystick, haptic, sensors and HID are left out.
  log "$TARGET sdl2"
  cmake_build "$(fetch sdl2)" "$WORK/sdl2" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_STATIC_PIC=ON -DSDL_TEST=OFF \
    -DSDL_TESTS=OFF -DSDL_HIDAPI=OFF -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF -DSDL_POWER=OFF \
    -DSDL_AUDIO=ON -DSDL_VIDEO=ON -DSDL_RENDER=ON
}

build_openh264() {
  log "$TARGET openh264"
  meson_build "$(fetch openh264)" "$WORK/openh264" -Dtests=disabled
  # The static library is C++, but openh264.pc does not say so; FFmpeg's link check needs the C++ runtime.
  local cxx_runtime=-lstdc++
  [[ $TARGET == macos-* ]] && cxx_runtime=-lc++
  sed -i.orig "s|^Libs: \(.*\)$|Libs: \1 $cxx_runtime|" "$PREFIX/lib/pkgconfig/openh264.pc"
}

build_kvazaar() {
  # Kvazaar's CMake writes kvazaar.pc into its source tree, so it builds from a copy.
  local src=$WORK/kvazaar-src
  copy_source kvazaar "$src"
  log "$TARGET kvazaar"
  cmake_build "$src" "$WORK/kvazaar" -DBUILD_TESTS=OFF -DBUILD_KVAZAAR_BINARY=OFF -DGIT_SUBMODULE=OFF -DUSE_CRYPTO=OFF
  # kvazaar.pc lists nothing the static library needs: threads and libm (part of libSystem on macOS). On Windows the
  # header also declares the API dllimport unless KVZ_STATIC_LIB is set.
  case $TARGET in
    linux-*) sed -i 's|^Libs.private:.*$|& -lpthread -lm|' "$PREFIX/lib/pkgconfig/kvazaar.pc" ;;
    windows-*)
      sed -i -e 's|^Cflags: \(.*\)$|Cflags: \1 -DKVZ_STATIC_LIB|' -e 's|^Libs.private:.*$|& -lpthread|' \
        "$PREFIX/lib/pkgconfig/kvazaar.pc"
      ;;
  esac
}

build_dav1d() {
  log "$TARGET dav1d"
  meson_build "$(fetch dav1d)" "$WORK/dav1d" -Denable_tools=false -Denable_tests=false -Denable_examples=false
}

# --- FFmpeg ----------------------------------------------------------------------------------------------------------

build_ffmpeg() {
  local platform=$1 src build=$WORK/ffmpeg
  src=$(fetch ffmpeg)
  log "$TARGET ffmpeg"
  rm -rf "$build"
  mkdir -p "$build"
  local flags=()
  while IFS= read -r line; do flags+=("$line"); done < <(ffmpeg_flags "$platform")
  (cd "$build" && "$src/configure" --prefix="$PREFIX" "${FF_TARGET[@]}" "${flags[@]}" \
    --pkg-config="$(command -v pkg-config)" --pkg-config-flags=--static --x86asmexe="$(command -v nasm)" \
    --extra-cflags="$CFLAGS_T -I$PREFIX/include" --extra-cxxflags="$CFLAGS_T -I$PREFIX/include" \
    --extra-ldflags="$LDFLAGS_T -L$PREFIX/lib" >"$build.log" 2>&1) || { tail -60 "$build/ffbuild/config.log"; die "configure ffmpeg"; }
  if [[ $platform == windows ]]; then
    # Same quirk ffmpeg-kit-builders patches for MinGW: the CPU affinity call is not available there.
    sed -i 's/#define HAVE_SCHED_GETAFFINITY 1/#define HAVE_SCHED_GETAFFINITY 0/' "$build/config.h"
  fi
  # The configuration string and data directory in config.h name the work directory; keep it out of the binary.
  sed -i.orig "s|$FFKIT_HOME|ffkit|g" "$build/config.h"
  make -C "$build" -j "$JOBS" >>"$build.log" 2>&1 || { tail -60 "$build.log"; die "make ffmpeg"; }
  make -C "$build" install >>"$build.log" 2>&1 || { tail -60 "$build.log"; die "install ffmpeg"; }
  # FFmpegKit compiles its own fftools copies, which need the configuration and these internal headers.
  cp "$build/config.h" "$build/config_components.h" "$PREFIX/include/"
  local header
  for header in libavcodec/mathops.h libavcodec/x86/mathops.h libavcodec/arm/mathops.h libavformat/network.h \
    libavformat/os_support.h libavformat/url.h libavutil/attributes_internal.h libavutil/bprint.h \
    libavutil/getenv_utf8.h libavutil/internal.h libavutil/libm.h libavutil/reverse.h libavutil/thread.h \
    libavutil/timer.h libavutil/x86/asm.h libavutil/x86/timer.h libavutil/arm/timer.h libavutil/aarch64/timer.h \
    libavutil/wchar_filename.h; do
    mkdir -p "$(dirname "$PREFIX/include/$header")"
    cp "$src/$header" "$PREFIX/include/$header"
  done
  mkdir -p "$PREFIX/include/libavutil/compat" "$PREFIX/include/stdbit"
  cp "$src/compat/w32pthreads.h" "$PREFIX/include/libavutil/compat/"
  cp "$src/compat/stdbit/stdbit.h" "$PREFIX/include/stdbit/"
}

# --- FFmpegKit -------------------------------------------------------------------------------------------------------

build_kit() {
  local platform=$1 src=$WORK/ffmpegkit-src build=$WORK/ffmpegkit kit=$WORK/kit ffsrc
  ffsrc=$(fetch ffmpeg)
  copy_source "ffmpegkit-$platform" "$src"
  src=$src/FFmpegKit
  log "$TARGET ffmpegkit"
  # Our bundle has no iconv, bzip2 or lzma: take the dependency list FFmpegKit uses for its base bundle.
  sed -i.orig 's/if(FFMPEG_KIT_BUNDLE_TYPE STREQUAL "base")/if(FFMPEG_KIT_BUNDLE_TYPE STREQUAL "base" OR FFMPEG_KIT_BUNDLE_TYPE STREQUAL "asodev")/' \
    "$src/cmake/FfmpegKitDependencies.cmake"
  grep -q 'STREQUAL "asodev"' "$src/cmake/FfmpegKitDependencies.cmake" || die "FFmpegKit dependency list not patched"
  # -ld64 picked the classic Apple linker in Xcode 15-16; newer clang reads it as -l d64.
  sed -i.orig '/"-ld64"/d' "$src/CMakeLists.txt"
  # On Windows FFmpegKit wraps pthread_t for PThreads4W, where it is a struct. We use MinGW's winpthreads everywhere
  # (FFmpeg, kvazaar, SDL2 already link it), where pthread_t is an integer, so the wrapper stays off.
  perl -0pi -e 's/#ifdef __cplusplus\n#include <stdbool.h>/#if defined(__cplusplus) && !defined(WIN_PTHREADS_H)\n#include <stdbool.h>/' \
    "$src/src/pthread_compat.h"
  grep -q '!defined(WIN_PTHREADS_H)' "$src/src/pthread_compat.h" || die "FFmpegKit pthread_compat.h not patched"
  # Its 64-bit time shims serve MinGW 15+ headers, which redirect to *64 functions; the Ubuntu 22.04 MinGW headers
  # neither redirect nor define struct _timespec64.
  perl -0pi -e 's|/\*\*\n \* 64-bit redirection|#if defined(__MINGW64_VERSION_MAJOR) && __MINGW64_VERSION_MAJOR >= 15\n/**\n * 64-bit redirection|; s|\n#endif\s*\z|\n#endif // MinGW 15+\n#endif\n|' \
    "$src/src/pthread_compat.c"
  grep -q 'MinGW 15+$' "$src/src/pthread_compat.c" || die "FFmpegKit pthread_compat.c not patched"
  rm -rf "$build" "$kit"
  # The fftools copies include FFmpeg's private headers from its source tree.
  local flags="$CFLAGS_T -I$ffsrc -I$ffsrc/compat" args=("${CMAKE_T[@]}")
  if [[ $platform == windows ]]; then
    # FFmpegKit compiles with DLL_EXPORT, which makes this MinGW's pthread.h declare its API dllimport, while
    # winpthreads is linked statically. Include pthread.h first without DLL_EXPORT; its guard keeps it that way.
    cat >"$WORK/winpthread_static.h" <<'HEADER'
#ifdef DLL_EXPORT
#undef DLL_EXPORT
#include <pthread.h>
#define DLL_EXPORT 1
#else
#include <pthread.h>
#endif
HEADER
    flags+=" -include $WORK/winpthread_static.h"
  fi
  args=("${args[@]/-DCMAKE_INSTALL_PREFIX=*/-DCMAKE_INSTALL_PREFIX=$kit}")
  args=("${args[@]/-DBUILD_SHARED_LIBS=OFF/-DBUILD_SHARED_LIBS=ON}")
  args=("${args[@]/-DCMAKE_C_FLAGS=*/-DCMAKE_C_FLAGS=$flags}")
  args=("${args[@]/-DCMAKE_CXX_FLAGS=*/-DCMAKE_CXX_FLAGS=$flags}")
  if [[ $platform == windows ]]; then
    # -lpthread would pick winpthreads' import library and make the DLL need libwinpthread-1.dll. Our prefix comes
    # first on the library path, so static copies there are linked instead.
    local winpthread=/usr/x86_64-w64-mingw32/lib/libwinpthread.a
    [[ -f $winpthread ]] || die "no static winpthreads at $winpthread"
    cp "$winpthread" "$PREFIX/lib/libwinpthread.a"
    cp "$winpthread" "$PREFIX/lib/libpthread.a"
    # FFmpegKit builds with -fstack-protector-strong; with this MinGW the guard lives in libssp, linked statically so
    # no libssp-0.dll has to ship. fftools' benchmark needs psapi, which FFmpeg only links into its own programs.
    # The rest is CMake's default MinGW list.
    local system_libs='-l:libssp.a -lpsapi -lkernel32 -luser32 -lgdi32 -lwinspool -lshell32 -lole32 -loleaut32'
    system_libs+=' -luuid -lcomdlg32 -ladvapi32'
    args+=("-DCMAKE_C_STANDARD_LIBRARIES=$system_libs" "-DCMAKE_CXX_STANDARD_LIBRARIES=$system_libs")
  fi
  LDFLAGS="$LDFLAGS_T -L$PREFIX/lib" \
    cmake -S "$src" -B "$build" "${args[@]}" "-DFFMPEG_SRC_DIR=$ffsrc" "-DFFMPEG_BUILD_DIR=$PREFIX" \
    "-DDEPENDENCY_BUILD_DIR=$PREFIX" -DFFMPEG_KIT_BUNDLE_TYPE=asodev -DFFMPEG_KIT_VERSION=0.10.5 -DBUILD_TESTS=OFF \
    >"$build.log" 2>&1 || { tail -60 "$build.log"; die "cmake ffmpegkit"; }
  cmake --build "$build" -j "$JOBS" >>"$build.log" 2>&1 || { tail -60 "$build.log"; die "build ffmpegkit"; }
  cmake --install "$build" >>"$build.log" 2>&1 || { tail -60 "$build.log"; die "install ffmpegkit"; }
}

step() { # name command...: runs once per target; --clean or deleting $WORK/.done-<name> runs it again
  local name=$1
  shift
  [[ -f $WORK/.done-$name ]] && return
  "$@"
  touch "$WORK/.done-$name"
}

build_target() { # platform arch
  # FFmpegKit's post-build script calls gsed for a plain substitution that any sed does the same way.
  mkdir -p "$FFKIT_HOME/shims"
  [[ -x $FFKIT_HOME/shims/gsed ]] || ln -sf "$(command -v sed)" "$FFKIT_HOME/shims/gsed"
  export PATH=$FFKIT_HOME/shims:$PATH
  setup_target "$1" "$2"
  step zlib build_zlib
  step jsoncpp build_jsoncpp
  step sdl2 build_sdl2
  step openh264 build_openh264
  step kvazaar build_kvazaar
  step dav1d build_dav1d
  # FFmpeg and the wrapper depend on everything above, so they rebuild whenever a dependency did.
  if [[ ! -f $WORK/.done-ffmpeg || -n $(find "$WORK" -maxdepth 1 -name '.done-*' ! -name .done-ffmpeg \
    ! -name .done-kit -newer "$WORK/.done-ffmpeg") ]]; then
    rm -f "$WORK/.done-ffmpeg" "$WORK/.done-kit"
  fi
  step ffmpeg build_ffmpeg "$1"
  step kit build_kit "$1"
}

# --- Packaging -------------------------------------------------------------------------------------------------------

write_licenses() { # dest-dir: the license texts of everything linked in
  local dest=$1 name ffsrc
  ffsrc=$(fetch ffmpeg)
  mkdir -p "$dest"
  # FFmpeg itself is LGPL-2.1-or-later here (no --enable-version3); the FFmpegKit wrapper is LGPL-3.0, which comes
  # with the GPLv3 text it supplements.
  cp "$ffsrc/COPYING.LGPLv2.1" "$dest/ffmpeg_license.txt"
  cp "$ffsrc/COPYING.LGPLv3" "$dest/lgpl-3.0.txt"
  cp "$ffsrc/COPYING.GPLv3" "$dest/gpl-3.0.txt"
  cp "$(fetch ffmpegkit-macos)/LICENSE" "$dest/ffmpeg-kit_license.txt"
  for name in zlib jsoncpp sdl2 openh264 kvazaar dav1d; do
    local src file
    src=$(fetch "$name")
    for file in LICENSE LICENSE.txt COPYING LICENSE.md; do
      [[ -f $src/$file ]] && { cp "$src/$file" "$dest/${name}_license.txt"; break; }
    done
    [[ -f $dest/${name}_license.txt ]] || die "no license file in $name"
  done
  # zlib keeps its license in README.
  [[ -s $dest/zlib_license.txt ]] || sed -n '/Copyright notice:/,$p' "$(fetch zlib)/README" >"$dest/zlib_license.txt"
  cp "$TOOL_DIR/sources.lock" "$dest/SOURCES.lock"
}

package_macos() { # one universal lib/libffmpegkit.dylib; the build hook thins it to the target architecture
  local name=ffmpegkit-$FFKIT_RELEASE-macos-universal stage
  stage=$FFKIT_HOME/build/$FFKIT_RELEASE/package-macos
  rm -rf "$stage"
  mkdir -p "$stage/$name/lib" "$FFKIT_HOME/out"
  local arm=$FFKIT_HOME/build/$FFKIT_RELEASE/macos-arm64/kit x86=$FFKIT_HOME/build/$FFKIT_RELEASE/macos-x86_64/kit
  local dylib=$stage/$name/lib/libffmpegkit.dylib
  lipo -create "$arm/lib/libffmpegkit.dylib" "$x86/lib/libffmpegkit.dylib" -output "$dylib"
  install_name_tool -id @rpath/libffmpegkit.dylib "$dylib"
  codesign --force --sign - "$dylib" >/dev/null
  cp -R "$arm/include" "$stage/$name/include"
  write_licenses "$stage/$name/licenses"
  rm -f "$FFKIT_HOME/out/$name.zip"
  (cd "$stage" && zip -qry "$FFKIT_HOME/out/$name.zip" "$name")
  echo "$FFKIT_HOME/out/$name.zip"
}

package_zip() { # platform: linux -> lib/libffmpegkit.so, windows -> bin/libffmpegkit.dll
  local platform=$1 name=ffmpegkit-$FFKIT_RELEASE-$1-x86_64 stage kit
  stage=$FFKIT_HOME/build/$FFKIT_RELEASE/package-$platform
  kit=$FFKIT_HOME/build/$FFKIT_RELEASE/$platform-x86_64/kit
  rm -rf "$stage"
  mkdir -p "$stage/$name" "$FFKIT_HOME/out"
  if [[ $platform == windows ]]; then
    mkdir -p "$stage/$name/bin"
    cp "$kit/bin/libffmpegkit.dll" "$stage/$name/bin/"
    x86_64-w64-mingw32-strip --strip-unneeded "$stage/$name/bin/libffmpegkit.dll"
  else
    mkdir -p "$stage/$name/lib"
    cp "$kit/lib/libffmpegkit.so" "$stage/$name/lib/"
    strip --strip-unneeded "$stage/$name/lib/libffmpegkit.so"
  fi
  cp -R "$kit/include" "$stage/$name/include"
  write_licenses "$stage/$name/licenses"
  rm -f "$FFKIT_HOME/out/$name.zip"
  (cd "$stage" && zip -qry "$FFKIT_HOME/out/$name.zip" "$name")
  echo "$FFKIT_HOME/out/$name.zip"
}

# --- Entry -----------------------------------------------------------------------------------------------------------

run_in_container() { # platform: re-runs this script in docker/Dockerfile with the package mounted
  local platform=$1 docker=${DOCKER:-docker} container_platform
  if ! command -v "$docker" >/dev/null; then
    [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]] || die "$platform builds run in Docker; set DOCKER"
    # Docker Desktop without its CLI on PATH: its credential helper sits next to the CLI.
    export PATH=/Applications/Docker.app/Contents/Resources/bin:$PATH
    docker=docker
  fi
  # Linux builds natively for x86_64 (emulated on Apple silicon); MinGW cross-compiles from the host architecture.
  if [[ $platform == linux ]]; then
    container_platform=linux/amd64
  else
    container_platform=linux/$("$docker" version --format '{{.Server.Arch}}')
  fi
  local image=asodev-ffmpegkit-build:22.04-${container_platform#linux/}
  "$docker" build --platform "$container_platform" -t "$image" "$TOOL_DIR/docker"
  mkdir -p "$FFKIT_HOME/linux-home"
  "$docker" run --rm --platform "$container_platform" -e FFKIT_HOME=/ffkit -e FFKIT_IN_CONTAINER=1 \
    -v "$TOOL_DIR:/recipe:ro" -v "$FFKIT_HOME/linux-home:/ffkit" "$image" \
    bash /recipe/build.sh "$platform" --jobs "$JOBS"
  mkdir -p "$FFKIT_HOME/out"
  cp "$FFKIT_HOME/linux-home/out/ffmpegkit-$FFKIT_RELEASE-$platform-"*.zip "$FFKIT_HOME/out/"
}

main() {
  local platform=${1:-}
  shift || true
  while [[ $# -gt 0 ]]; do
    case $1 in
      --jobs) JOBS=$2; shift 2 ;;
      --clean) rm -rf "$FFKIT_HOME/build/$FFKIT_RELEASE"; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  case $platform in
    macos)
      [[ $(uname -s) == Darwin ]] || die "macos builds need a Mac"
      export PATH=$FFKIT_HOME/tools/bin:$FFKIT_HOME/tools/venv/bin:$PATH
      for tool in cmake ninja meson nasm pkg-config; do
        command -v $tool >/dev/null || die "$tool missing: run ./bootstrap-macos.sh"
      done
      ((BASH_VERSINFO[0] >= 4)) || exec "$FFKIT_HOME/tools/bin/bash" "$0" "$platform" --jobs "$JOBS"
      build_target macos arm64
      build_target macos x86_64
      package_macos
      ;;
    sources)
      # Fetches every locked source, for publish.sh's corresponding-source archive.
      local name
      for name in $(awk '$1 !~ /^#/ && NF { print $1 }' "$TOOL_DIR/sources.lock"); do
        fetch "$name" >/dev/null
      done
      ;;
    linux | windows)
      if [[ -z ${FFKIT_IN_CONTAINER:-} ]]; then
        run_in_container "$platform"
      else
        build_target "$platform" x86_64
        package_zip "$platform"
      fi
      ;;
    *) die "usage: build.sh macos|linux|windows|sources [--jobs N] [--clean]" ;;
  esac
}

main "$@"
