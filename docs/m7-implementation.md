# M7 — Deployment and diagnostics

**Status: Complete.** Release builds, asset compilation and packed caches, native desktop packaging, profiling, and the standalone game are implemented and verified. Linux, Windows, macOS ARM64, and macOS Intel passed the native build/package workflow, including relocated headless and rendered game runs without the checkout or Quicklisp.

## Implemented areas

| Area | Current implementation | Source |
| --- | --- | --- |
| Native application builds | `sgeo.deployment:define-application` and `build-application` create a fresh SBCL executable, compile the declared assets, assemble a host-native package, and verify its hash manifest. Cross-compilation is rejected. | `src/deployment/build.lisp`, `src/deployment/packaging.lisp` |
| Package layouts | Linux launcher and `bin/` executable; Windows executable and `.cmd` launcher; macOS `.app` bundle. Each target has its own resource and native-library directory. All three layouts passed native-host package and runtime checks. | `src/deployment/packaging.lisp` |
| Native libraries | Release images resolve registered native CFFI libraries and package them with license notices. Startup rebinds each bundled library name to its absolute path inside the package. Graphics drivers and other transitive dependencies remain host requirements unless supplied. | `src/deployment/build.lisp`, `src/deployment/packaging.lisp` |
| Asset packs | SGP packs are compiled from explicit manifests or byte inputs, validated before replacement, and loaded without evaluating Lisp. Cache identity includes source, importer version, dependencies, and importer options. A synchronous polling watcher can rebuild while retaining the last valid pack on failure. | `src/assets/compiler.lisp`, `src/assets/importers.lisp` |
| Standalone example | `sgeo-game` loads a packed geometry/audio asset set without loading the editor. It supports headless self-test, frame limits, hidden rendering, capture, audio output, and JSON profiling options. | `examples/simulation/standalone.lisp`, `tools/build.lisp` |
| Diagnostics | Scoped CPU timing and bounded timeline snapshots, allocation estimates where supported, renderer/error/recovery metadata, GPU elapsed-time queries, and supported GPU pipeline counters. Reports export JSON, human-readable text, or Chrome trace. | `src/diagnostics/profiler.lisp`, `src/render/render.lisp`, `backends/opengl/profiling.lisp`, `backends/vulkan/renderer.lisp`, `src/editor/opengl-workspace.lisp` |

See the [deployment guide](deployment.md) for build and run commands, asset manifest examples, package layouts, and profiler APIs. `docs/roadmap.md` remains the milestone tracker.

## Profiling behavior and limits

CPU measurements are explicit `with-profile-scope` instrumentation, not statistical sampling of every function. Scopes aggregate calls and inclusive/exclusive host duration by subsystem, function, object class, thread, and frame phase. Frame and CPU timeline timestamps use the profiler's monotonic host clock and origin. The editor's Profile workspace collects when selected and shows recent CPU scopes, measured GPU duration, allocation estimates, and renderer frame metrics. Compact values precede function names so they remain visible in a narrow panel.

On SBCL, allocation deltas use `SB-EXT:GET-BYTES-CONSED`, which is process-wide. A scope label identifies where the measured scope ran; its allocation estimate can include concurrent allocations from other threads. Other Common Lisp implementations report allocation as unavailable.

The OpenGL backend issues elapsed-time queries for frame GPU duration. It records primitives-generated and, if the pipeline-statistics extension is present, vertices-submitted, primitives-submitted, and vertex-shader invocations. The Vulkan backend uses timestamp query results with `timestampPeriod` and the queue's valid timestamp bits for wrap-safe duration, and requests input-assembly primitive, vertex-shader invocation, and fragment-shader invocation counters when supported by the device. Unsupported metrics are reported as unavailable; the engine does not synthesize GPU values from CPU submission time.

GPU durations use the GPU query clock domain. Delayed results carry their original CPU frame ID and are placed against that frame's recorded host start for timeline display. The frame ID links the events; the profiler does not claim absolute CPU/GPU clock synchronization.

## Verification evidence

The following checks cover local isolation, application extensibility, and profiler behavior. Native-host CI results follow the table.

| Check | Result | Evidence |
| --- | --- | --- |
| Headless suite | 2,505 checks passed, zero skips or failures; the test launcher confirms no GLFW/OpenGL packages were loaded, including with configured native-library paths. | `sbcl --script tools/test.lisp`; `.cache/m7-tests-configured-bootstrap.log` |
| Linux release build | `tools/build.lisp` produced the application directory and `.tar.gz` archive; the build ran package-manifest verification. | `.cache/m7-build-resolver-round6.log` |
| Example source assets | Geometry scene and PCM tone sources generated. | `sbcl --script tools/generate-game-assets.lisp`; `.cache/m7-assets-generation.log` |
| Standalone headless self-test | The game reached the expected state: three coins collected, door open, and game won; the release image omitted the editor. | `.cache/m7-standalone-headless.log` |
| Relocated Linux package isolation | In a `bwrap` sandbox with checkout, Quicklisp, SBCL, and installed GLFW/OpenAL masked, an isolated HOME and `/tmp` working directory, and a relocated package path containing spaces, the package passed 240 headless and 240 rendered frames. Both reports identified `editor-loaded=false`, `game.sgp`, and zero errors; rendered execution also wrote a native capture. | `.cache/m7-ci-headless.log`, `.cache/m7-ci-native.log` |
| Linux standalone audio variants | The relocated package completed a 240-frame rendered run with OpenAL's null driver and a separate 240-frame run without audio. Both ran with checkout, Quicklisp, SBCL, and installed GLFW/OpenAL masked; reports omitted the editor and reported zero errors. The null driver verifies the optional audio path, not physical device playback. | `.cache/m7-fixes-audio.log`, `.cache/m7-fixes-native.log` |
| External custom CFFI application | A relocated custom application loaded a registered native library through its packaged absolute binding, including after the packaged library copy was renamed, and returned the expected exit value 73. | `artifacts/m7-cffi-relocation/run-final.log` |
| OpenGL profiler | 12 native frames produced 12 GPU samples and 12 pipeline-statistics records; query resources were drained at shutdown. | `sbcl --script tools/m7-profile-check.lisp`; `.cache/m7-opengl-profile.log` |
| Vulkan profiler | 12 native frames produced 12 GPU samples and 12 pipeline-statistics records; query pools were destroyed, and Vulkan validation messages were clean. | `sbcl --script tools/m7-profile-check.lisp --vulkan`; `.cache/m7-vulkan-profile-final.log` |
| Editor Profile workspace | 12 hidden native editor frames produced 9 GPU samples; the profile panel was drawn with readable timing and allocation values, a box was edited, history remained bounded at 64 frames, the profile JSON/Chrome trace and framebuffer capture were exported, and profiling queries were cleaned up. | `sbcl --script tools/m7-editor-profile-check.lisp`; `.cache/m7-glfw-diagnostics-native.log` |

The [deployment workflow](../.github/workflows/deployment.yml) passed all four jobs in [run 38217645456](https://github.com/EdenCompiler/s-geometry/actions/runs/38217645456), at source commit `e4826bcd1ed7a1d40f349c2bd1db1faabe7064eb`:

| Native host | Headless suite | Rendered game | CI evidence |
| --- | --- | --- | --- |
| Linux x86-64 | 2,505 checks | OpenGL through Mesa llvmpipe | [Linux job](https://github.com/EdenCompiler/s-geometry/actions/runs/38217645456/job/114706031217) |
| Windows x86-64 | 2,497 checks | OpenGL 4.6 through Mesa 26.2.4 llvmpipe | [Windows job](https://github.com/EdenCompiler/s-geometry/actions/runs/38217645456/job/114706031327) |
| macOS ARM64 | 2,501 checks | OpenGL 4.1 through Apple Software Renderer | [ARM64 job](https://github.com/EdenCompiler/s-geometry/actions/runs/38217645456/job/114706031166) |
| macOS Intel | 2,501 checks | OpenGL 4.1 through Apple Software Renderer | [Intel job](https://github.com/EdenCompiler/s-geometry/actions/runs/38217645456/job/114706031040) |

Every suite has zero skips and failures. Each package ran from a relocated path containing spaces with an isolated home, the checkout and Quicklisp unavailable, and the editor absent. Both the headless and rendered self-tests completed 240 frames, collected three coins, opened the door, and won. Reports identify the packaged `game.sgp` and contain no errors. Each rendered report has 240 actual GPU timing samples and 240 pipeline records with positive results, and each framebuffer capture shows the completed game. The downloaded package trees and the contents of their `.zip`/`.tar.gz` archives match every manifest hash. Local copies are under `.cache/m7-ci-run38217645456-<platform>/`.

Windows CI adds the pinned Mesa runtime only to a temporary rendering copy; it is not part of the published package. macOS CI builds a pinned GLFW with an accelerated-first pixel-format retry that permits the system software renderer after accelerated selection fails. The retry preserves the engine's core profile and framebuffer requirements. Both bundled GLFW probes and game runs pass, and the packages include the original GLFW license. See the [GLFW patch provenance](../tools/ci/glfw-macos-software-retry.md).

## Runtime and cache limits

- SGP v2 uses fixed little-endian fields and importer-defined byte payloads. General packed arrays, prebuilt BVHs, shader compilation in the asset pipeline, and texture transcoding remain later cache optimizations from §29.2 of the design.
- Treat profiler output as bounded, opt-in instrumentation. Allocation figures are process-wide estimates, and GPU query values are frame-correlated but not clock-synchronized with CPU timestamps.
- Audio output uses an optional OpenAL device path. The headless game check verifies gameplay without audio hardware and does not prove physical audio playback.
