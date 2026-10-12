#!/usr/bin/env bash
set -euo pipefail

task_dir="${RUNNER_TEMP:-$(mktemp -d)}/sgeo-macos-tools"
mkdir -p "$task_dir"

case "$(uname -m)" in
  x86_64)
    sbcl_archive="sbcl-2.2.9-x86-64-darwin-binary.tar.bz2"
    sbcl_sha256="6f504b9282c83842c0601600f5e0663209b53b133125ec3334ff7a0bd0037ca6"
    ;;
  arm64)
    sbcl_archive="sbcl-2.4.0-arm64-darwin-binary.tar.bz2"
    sbcl_sha256="1d01fac2d9748f769c9246a0a11a2c011d7843337f8f06ca144f5a500e10c117"
    ;;
  *)
    echo "Arquitetura macOS não suportada: $(uname -m)" >&2
    exit 1
    ;;
esac

curl --fail --location --silent --show-error --retry 3 \
  "https://prdownloads.sourceforge.net/sbcl/$sbcl_archive" \
  --output "$task_dir/$sbcl_archive"
echo "$sbcl_sha256  $task_dir/$sbcl_archive" | shasum -a 256 --check
tar -xjf "$task_dir/$sbcl_archive" -C "$task_dir"
sbcl_dir="$task_dir/${sbcl_archive%-binary.tar.bz2}"
sbcl_prefix="$task_dir/sbcl"
(cd "$sbcl_dir" && sh install.sh --prefix="$sbcl_prefix")
"$sbcl_prefix/bin/sbcl" --version
echo "$sbcl_prefix/bin" >> "$GITHUB_PATH"

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
brew install --ignore-dependencies openal-soft

patched_glfw_prefix="$task_dir/patched-glfw"
bash "$(dirname "$0")/build-patched-glfw-macos.sh" "$patched_glfw_prefix"

headers_archive="SPIRV-Headers-vulkan-sdk-1.4.363.0.tar.gz"
headers_sha256="5b3a0d099f5c7649e29c0938476c462e71d66ad89a0bde42fa1ba3eb476956c9"
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-1.4.363.0.tar.gz" \
  --output "$task_dir/$headers_archive"
echo "$headers_sha256  $task_dir/$headers_archive" | shasum -a 256 --check
mkdir -p "$task_dir/headers-source"
tar -xzf "$task_dir/$headers_archive" -C "$task_dir/headers-source" --strip-components=1

spirv_archive="SPIRV-Tools-vulkan-sdk-1.4.363.0.tar.gz"
spirv_sha256="e6c83a215538fbfd265ccf398d3877985055df1273dbed73912bd05307664688"
curl --fail --location --silent --show-error --retry 3 \
  "https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/vulkan-sdk-1.4.363.0.tar.gz" \
  --output "$task_dir/$spirv_archive"
echo "$spirv_sha256  $task_dir/$spirv_archive" | shasum -a 256 --check
mkdir -p "$task_dir/spirv-source"
tar -xzf "$task_dir/$spirv_archive" -C "$task_dir/spirv-source" --strip-components=1
cmake -S "$task_dir/spirv-source" -B "$task_dir/spirv-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSPIRV-Headers_SOURCE_DIR="$task_dir/headers-source" \
  -DSPIRV_SKIP_TESTS=ON
cmake --build "$task_dir/spirv-build" --target spirv-val --parallel "$(sysctl -n hw.ncpu)"
"$task_dir/spirv-build/tools/spirv-val" --version
echo "$task_dir/spirv-build/tools" >> "$GITHUB_PATH"

native_path="$patched_glfw_prefix/lib:$(brew --prefix openal-soft)/lib"
echo "SGEO_NATIVE_LIBRARY_PATH=$native_path" >> "$GITHUB_ENV"
echo "DYLD_LIBRARY_PATH=$native_path${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" >> "$GITHUB_ENV"
