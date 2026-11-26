#!/usr/bin/env bash
# Checks an archive from build.sh before it is published: the FFmpeg configuration compiled into the library has no
# GPL or non-free code and no external library beyond the allowed ones, the removed libraries left no code behind, and
# the encoders the app asks for are there.
#
# Usage: verify.sh <archive.zip> macos|linux|windows
set -euo pipefail

archive=$1 platform=$2
die() { echo "verify.sh: $*" >&2; exit 1; }

# External libraries the build may enable. Everything else from FFmpeg's --enable-lib* list must be absent.
ALLOWED_LIBS=(libopenh264 libkvazaar libdav1d)
# Encoders the ASO.dev app can pick on each platform, plus AAC and MJPEG. They
# are read from the configuration, which also must not enable encoders beyond these.
REQUIRED_ENCODERS=(aac mjpeg libopenh264 libkvazaar)
case $platform in
  macos) REQUIRED_ENCODERS+=(h264_videotoolbox hevc_videotoolbox) ;;
  windows) REQUIRED_ENCODERS+=(h264_mf hevc_mf) ;;
  linux) ;;
  *) die "unknown platform $platform" ;;
esac
# Names only present when the matching component is compiled in: libzvbi's teletext decoder, libcaca's output device,
# zimg's zscale filter, and functions of the GPL-2.0-only libzvbi files (packet-830.c, pdc.c).
FORBIDDEN_MARKERS=(libzvbi_teletextdec vbi_decode_teletext_8302_pdc vbi_decode_vps_pdc caca_create_canvas zscale
  zimg_filter_graph_build)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
unzip -q "$archive" -d "$work"
case $platform in
  macos) binary=$(find "$work" -path '*/lib/libffmpegkit.dylib' -type f | head -1) ;;
  linux) binary=$(find "$work" -path '*/lib/libffmpegkit.so' -type f | head -1) ;;
  windows) binary=$(find "$work" -path '*/bin/libffmpegkit.dll' -type f | head -1) ;;
esac
[[ -n $binary ]] || die "no library in $archive"
strings -a -n 3 "$binary" >"$work/strings.txt"

config=$(grep -m1 -- '--disable-autodetect' "$work/strings.txt" || true)
[[ -n $config ]] || die "no FFmpeg configuration string in $binary"
echo "FFmpeg configuration: $config"
# Encoder names cannot be looked up as strings: the linker merges "mjpeg" into "adpcm_ima_smjpeg" and the like.
enabled_encoders=$(grep -oE -- "--enable-encoder='?[a-z0-9_,]+" <<<"$config" | sed -E "s/--enable-encoder='?//" || true)

problems=()
for flag in --enable-gpl --enable-nonfree; do
  [[ " $config " == *" $flag "* ]] && problems+=("configuration has $flag")
done
for encoder in $(tr ',' ' ' <<<"${enabled_encoders:-}"); do
  [[ " ${REQUIRED_ENCODERS[*]} " == *" $encoder "* ]] || problems+=("configuration enables encoder $encoder")
done
for flag in $config; do
  if [[ $flag == --enable-lib* ]]; then
    lib=${flag#--enable-}
    [[ " ${ALLOWED_LIBS[*]} " == *" $lib "* ]] || problems+=("configuration enables $lib")
  fi
done
for marker in "${FORBIDDEN_MARKERS[@]}"; do
  grep -qx -- "$marker" "$work/strings.txt" && problems+=("$marker found in the library")
done
if [[ $platform == macos ]]; then
  for arch in arm64 x86_64; do
    lipo "$binary" -verify_arch "$arch" || problems+=("no $arch slice")
    symbols=$(nm -arch "$arch" "$binary" 2>/dev/null | grep -E ' _(vbi_|vbi3_|caca_|zimg_)' | head -3 || true)
    [[ -z $symbols ]] || problems+=("$arch has removed-library symbols: $symbols")
  done
fi
paths=$(grep -E '(^|[^A-Za-z])/(Users|home)/' "$work/strings.txt" | head -3 || true)
[[ -z $paths ]] && paths=$(grep -E '[A-Z]:[\\/]Users[\\/]' "$work/strings.txt" | head -3 || true)
[[ -z $paths ]] || problems+=("build-machine paths in the library: $paths")
if [[ $platform == windows ]]; then
  # The archive ships one DLL: MinGW runtime libraries must be linked in, not imported.
  runtime=$(grep -iE '^(libwinpthread-1|libstdc\+\+-6|libgcc_s_[a-z0-9_-]+|libssp-0)\.dll$' "$work/strings.txt" || true)
  [[ -z $runtime ]] || problems+=("imports MinGW runtime DLLs: $(echo $runtime)")
fi
for encoder in "${REQUIRED_ENCODERS[@]}"; do
  [[ ",$enabled_encoders," == *",$encoder,"* ]] || problems+=("encoder $encoder missing")
done

if ((${#problems[@]})); then
  printf 'verify.sh: %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "OK $(basename "$archive"): $(shasum -a 256 "$archive" | cut -d' ' -f1)"
