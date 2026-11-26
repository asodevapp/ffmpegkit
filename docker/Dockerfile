# Linux and Windows build environment for build.sh. Ubuntu 22.04 is the image the app's Linux build uses, so
# libffmpegkit.so needs no newer glibc than the app; Windows uses its mingw-w64 GCC.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential ca-certificates git make nasm pkg-config python3 python3-venv zip \
      g++-mingw-w64-x86-64-posix gcc-mingw-w64-x86-64-posix mingw-w64-tools \
      libasound2-dev libpulse-dev libx11-dev libxext-dev libxrandr-dev libxcursor-dev libxi-dev libxss-dev \
      libxfixes-dev libxkbcommon-dev libwayland-dev libwayland-bin wayland-protocols libegl1-mesa-dev libgl1-mesa-dev libdrm-dev libgbm-dev \
    && rm -rf /var/lib/apt/lists/*

# The same CMake, Ninja and Meson versions as bootstrap-macos.sh.
RUN python3 -m venv /opt/tools && /opt/tools/bin/pip install -q 'cmake==3.31.6' 'ninja==1.11.1.4' 'meson==1.7.2'
ENV PATH=/opt/tools/bin:$PATH
