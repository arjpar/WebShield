#!/bin/sh
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: build-rust.sh <package_dir> <plugin_work_dir>" >&2
  exit 1
fi

package_dir="$1"
plugin_work_dir="$2"
crate_dir="$package_dir/rust/adblock-ffi"
build_root="$plugin_work_dir/out"
cargo_workspace="$plugin_work_dir/cargo"
cargo_target_dir="$cargo_workspace/target"
lib_dir="$build_root/lib"
include_dir="$build_root/include"

mkdir -p "$lib_dir" "$include_dir" "$cargo_workspace" "$cargo_target_dir"

arch="${CURRENT_ARCH:-}"
if [ -z "$arch" ] || [ "$arch" = "undefined_arch" ]; then
  archs_first="${ARCHS%% *}"
  if [ -n "${ARCHS:-}" ] && [ "$archs_first" != "undefined_arch" ]; then
    arch="$archs_first"
  else
    arch="$(uname -m)"
  fi
fi

platform="${PLATFORM_NAME:-}"
if [ -z "$platform" ]; then
  case "${SDKROOT:-}" in
    *iPhoneSimulator*) platform="iphonesimulator" ;;
    *iPhoneOS*) platform="iphoneos" ;;
    *XRSimulator*) platform="xrsimulator" ;;
    *XROS*) platform="xros" ;;
    *) platform="macosx" ;;
  esac
fi

case "$arch" in
  arm64|aarch64) rust_arch="aarch64" ;;
  x86_64) rust_arch="x86_64" ;;
  *) echo "Unsupported Apple architecture: $arch" >&2; exit 1 ;;
esac

case "$platform" in
  iphoneos) rust_triple="aarch64-apple-ios" ;;
  iphonesimulator)
    if [ "$rust_arch" = "aarch64" ]; then
      rust_triple="aarch64-apple-ios-sim"
    else
      rust_triple="x86_64-apple-ios"
    fi
    ;;
  macosx) rust_triple="${rust_arch}-apple-darwin" ;;
  xros|visionos) rust_triple="aarch64-apple-visionos" ;;
  xrsimulator|visionossimulator) rust_triple="aarch64-apple-visionos-sim" ;;
  *) echo "Unsupported Apple platform: $platform" >&2; exit 1 ;;
esac

case "$platform" in
  macosx) export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-12.0}" ;;
  iphoneos|iphonesimulator) export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}" ;;
  xros|visionos|xrsimulator|visionossimulator) export XROS_DEPLOYMENT_TARGET="${XROS_DEPLOYMENT_TARGET:-1.0}" ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  for candidate in "${HOME:-/var/empty}/.cargo/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
    if [ -x "$candidate/cargo" ]; then
      PATH="$candidate:$PATH"
      export PATH
      break
    fi
  done
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found in PATH. Install Rust via https://rustup.rs/ and ensure ~/.cargo/bin is on PATH." >&2
  exit 1
fi

export CARGO_TARGET_DIR="$cargo_target_dir"
cargo build --manifest-path "$crate_dir/Cargo.toml" --release --locked --target "$rust_triple"

cp "$cargo_target_dir/$rust_triple/release/libadblock_ffi.a" "$lib_dir/libadblock_ffi.a"

header="$cargo_target_dir/cxxbridge/adblock-ffi/src/lib.rs.h"
if [ ! -f "$header" ]; then
  header=""
fi
if [ -z "$header" ]; then
  for candidate in $(find "$cargo_target_dir" -path '*/cxxbridge/*/src/lib.rs.h' -print); do
    header="$candidate"
    break
  done
fi

cxx_header="$cargo_target_dir/cxxbridge/rust/cxx.h"
if [ ! -f "$cxx_header" ]; then
  cxx_header=""
fi
if [ -z "$cxx_header" ]; then
  for candidate in $(find "$cargo_target_dir" -path '*/cxxbridge/rust/cxx.h' -print); do
    cxx_header="$candidate"
    break
  done
fi

if [ -z "$header" ]; then
  echo "Could not find generated CXX bridge header" >&2
  exit 1
fi
if [ -z "$cxx_header" ]; then
  echo "Could not find generated rust/cxx.h header" >&2
  exit 1
fi

mkdir -p "$include_dir/adblock_ffi/src" "$include_dir/rust"
cp "$header" "$include_dir/adblock_ffi/src/lib.rs.h"
cp "$cxx_header" "$include_dir/rust/cxx.h"
date > "$build_root/rust-build.stamp"
