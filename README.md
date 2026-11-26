# FFmpegKit for ASO.dev

The recipe for the `libffmpegkit` shared library the ASO.dev desktop app ships on macOS, Windows and Linux: FFmpeg
reduced to what the app uses, wrapped by [FFmpegKit](https://github.com/akashskypatel/ffmpeg-kit-builders) 0.10.5.
Builds are published as [releases](https://github.com/asodevapp/ffmpegkit/releases) together with their complete
corresponding source.

The app loads `libffmpegkit` as a separate shared library, so it can be replaced by one rebuilt from this recipe or
from modified sources.

## What is inside

| Part | Kept | Why |
| --- | --- | --- |
| Demuxers, decoders, parsers, bitstream filters | all built into FFmpeg | any video a user drops must open |
| AV1 decoding | dav1d | FFmpeg has no software AV1 decoder of its own |
| Encoders | `aac`, `mjpeg`, `libopenh264`, `libkvazaar`; macOS `h264/hevc_videotoolbox`; Windows `h264/hevc_mf` | H.264/HEVC export, AAC audio, JPEG previews |
| Muxers | `mp4`, `mov`, `ipod`, `image2` | MP4 output, stream-copy trims of `.mov`/`.mp4`/`.m4v`, preview frames |
| Filters | `scale` and those fftools insert: graph ends, `null`/`anull`, `format`/`aformat`, `aresample`, `trim`/`atrim`, `crop`, `transpose`/`hflip`/`vflip`/`rotate` | resizing, format conversion, `-ss`/`-t`, container cropping, display-matrix rotation |
| Protocols | `file` | FFmpeg only reads and writes local files |
| Wrapper dependencies | SDL2 (FFplay), JsonCpp (media information), zlib | needed by FFmpegKit itself |

Left out: network and TLS, input/output devices, hardware decoding, every other encoder, muxer and filter, and all
other external libraries. FFmpeg is configured with `--disable-autodetect`, so nothing is picked up from the build
machine.

## Licenses

| Component | License |
| --- | --- |
| FFmpeg | LGPL-2.1-or-later (built without `--enable-version3`, `--enable-gpl`, `--enable-nonfree`) |
| FFmpegKit wrapper | LGPL-3.0 |
| dav1d, OpenH264 | BSD-2-Clause |
| Kvazaar | BSD-3-Clause |
| SDL2, zlib | Zlib |
| JsonCpp | MIT |
| MinGW-w64 runtime, winpthreads (Windows) | MinGW-w64 runtime licenses (permissive) |

Every archive carries these license texts and `SOURCES.lock` in `licenses/`. The scripts in this repository are
under the MIT license (`LICENSE`).

## Sources

`sources.lock` pins every source as a git commit, so a moved tag cannot change a build: FFmpeg at the commit
FFmpegKit 0.10.5 was built from, the FFmpegKit wrapper (ffmpeg-kit-builders tags v0.10.5-macos/-linux/-windows) and
the external libraries at the versions FFmpegKit 0.10.5 uses. `build.sh` applies a few small build fixes to the
wrapper (link flags and Windows threading); they are in the script.

## Building

`release.env` names the release (`FFKIT_RELEASE`); bump its `asodev.N` suffix for any change to the recipe.

```sh
# macOS (Xcode required; tools go to ~/.cache/asodev-ffmpegkit, no Homebrew or sudo)
./bootstrap-macos.sh
./build.sh macos            # arm64 + x86_64 -> lib/libffmpegkit.dylib, universal

# Linux and Windows run in docker/Dockerfile (Ubuntu 22.04; mingw-w64 GCC for Windows)
./build.sh linux
./build.sh windows
```

Archives land in `~/.cache/asodev-ffmpegkit/out`: one directory with `lib/libffmpegkit.dylib` (macOS),
`lib/libffmpegkit.so` (Linux) or `bin/libffmpegkit.dll` (Windows), the public headers and `licenses/`. `--clean`
rebuilds from scratch; otherwise finished steps are skipped. `./build.sh sources` only fetches the locked sources.

## Checking and publishing

`./verify.sh <archive> <platform>` reads the FFmpeg configuration compiled into the library and fails on GPL or
non-free flags, any external library or encoder beyond the ones above, traces of removed libraries, build-machine
paths, or (Windows) imports of MinGW runtime DLLs.

`GITHUB_TOKEN=... ./publish.sh <archives>` verifies the archives, creates the release `FFKIT_RELEASE`, uploads them
with `ffmpegkit-<release>-source.tar.xz` (this recipe and every locked source tree) and prints their SHA-256 values.
It never replaces an asset of an existing release.
