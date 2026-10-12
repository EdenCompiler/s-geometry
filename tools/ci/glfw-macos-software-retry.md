# Patched GLFW source for macOS CI

The macOS CI helper builds GLFW 3.5.1 from the official release archive and
applies `glfw-macos-software-retry.patch` before building the shared library.
The accelerated NSOpenGL pixel-format request remains first. Only if it returns
nil does the patch retry with the same profile and framebuffer attributes, but
without `NSOpenGLPFAAccelerated`.

The source is pinned to the official `3.5.1` tag at commit
`d9d6f0f1f967807ffade6598ea9a631ebaf37a56`. The source archive URL is
<https://github.com/glfw/glfw/archive/refs/tags/3.5.1.tar.gz> and its verified
SHA-256 is
`5234f4f29473e9a06bc7847d8371858dd135d38466eeeaa652fdc9f8f9ff0c20`.
The build script checks the archive hash and release version, and leaves the
upstream `LICENSE.md` unchanged in its extracted source. It also copies that
license into the installation prefix root, alongside copies of this provenance
document and the applied patch. The deployment license collector scans the
library's parent directories for `LICENSE*` files, so the upstream license is
included in generated third-party notices.

Run `tools/ci/build-patched-glfw-macos.sh INSTALL_PREFIX` on macOS. The installed
`lib/libglfw.3.dylib` should be placed before Homebrew GLFW in
`SGEO_NATIVE_LIBRARY_PATH` by the macOS prerequisite installer. The normal
hardware-accelerated renderer remains the first selection; the fallback lets
macOS select its software renderer only when that first pixel-format request
fails. Engine profile requirements remain unchanged.
