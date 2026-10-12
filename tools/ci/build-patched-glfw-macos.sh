#!/usr/bin/env bash
set -euo pipefail

# Compila a versao fixada do GLFW com uma nova tentativa restrita ao Cocoa.
# Uso: build-patched-glfw-macos.sh PREFIXO_DE_INSTALACAO

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script builds the Cocoa GLFW backend and must run on macOS." >&2
  exit 2
fi

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 INSTALL_PREFIX" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_prefix="$1"
runner_temp="${RUNNER_TEMP:-$(mktemp -d)}"
mkdir -p "$runner_temp"
task_dir="$(mktemp -d "$runner_temp/sgeo-patched-glfw-build.XXXXXX")"
source_dir="$task_dir/source"
build_dir="$task_dir/build"
archive="$task_dir/glfw-3.5.1.tar.gz"
source_url="https://github.com/glfw/glfw/archive/refs/tags/3.5.1.tar.gz"
source_sha256="5234f4f29473e9a06bc7847d8371858dd135d38466eeeaa652fdc9f8f9ff0c20"
source_commit="d9d6f0f1f967807ffade6598ea9a631ebaf37a56"

mkdir -p "$(dirname "$install_prefix")"
curl --fail --location --silent --show-error --retry 3 \
  "$source_url" --output "$archive"
echo "$source_sha256  $archive" | shasum -a 256 --check
mkdir -p "$source_dir"
tar -xzf "$archive" -C "$source_dir" --strip-components=1

test "$(sed -n 's/^project(GLFW VERSION \([^ ]*\).*/\1/p' "$source_dir/CMakeLists.txt" | head -n 1)" = "3.5.1"
echo "Pinned GLFW source commit: $source_commit"
grep -q 'Copyright (c) 2002-2006 Marcus Geelnard' "$source_dir/LICENSE.md"
patch --directory="$source_dir" --strip=1 --forward --input="$script_dir/glfw-macos-software-retry.patch"

cmake -S "$source_dir" -B "$build_dir" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$install_prefix" \
  -DBUILD_SHARED_LIBS=ON \
  -DGLFW_BUILD_EXAMPLES=OFF \
  -DGLFW_BUILD_TESTS=OFF \
  -DGLFW_BUILD_DOCS=OFF \
  -DGLFW_INSTALL=ON
cmake --build "$build_dir" --parallel "$(sysctl -n hw.ncpu)"
cmake --install "$build_dir"

# Mantem a licenca e a proveniencia junto da biblioteca para o empacotamento.
mkdir -p "$install_prefix"
cp "$source_dir/LICENSE.md" "$install_prefix/LICENSE.md"
cp "$script_dir/glfw-macos-software-retry.patch" \
  "$install_prefix/glfw-macos-software-retry.patch"
cp "$script_dir/glfw-macos-software-retry.md" \
  "$install_prefix/GLFW-PATCH-PROVENANCE.md"

test -f "$install_prefix/lib/libglfw.3.dylib"
echo "Built patched GLFW 3.5.1 at $install_prefix/lib/libglfw.3.dylib"
