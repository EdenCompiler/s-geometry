# M7 — Deployment and diagnostics

**Status: In progress.** The local Linux/SBCL implementation and native profiling checks below have passed. The hosted Windows and macOS CI jobs are configured but have not run; those targets remain unvalidated. M7 should remain in progress until the required platform checks and remaining acceptance work complete.

## Implemented areas

| Area | Current implementation | Source |
| --- | --- | --- |
| Native application builds | `sgeo.deployment:define-application` and `build-application` create a fresh SBCL executable, compile the declared assets, assemble a host-native package, and verify its hash manifest. Cross-compilation is rejected. | `src/deployment/build.lisp`, `src/deployment/packaging.lisp` |
| Package layouts | Linux launcher and `bin/` executable; Windows executable and `.cmd` launcher; macOS `.app` bundle. Each target has its own resource and native-library directory. The code defines layouts, but only locally exercised targets count as verified. | `src/deployment/packaging.lisp` |
| Native libraries | Release images resolve configured GLFW/OpenAL libraries and package them with license notices. Startup rebinds bundled GLFW/OpenAL CFFI names to absolute paths inside the package. Graphics drivers and other transitive dependencies remain host requirements unless supplied. | `src/deployment/build.lisp`, `src/deployment/packaging.lisp` |
| Asset packs | SGP packs are compiled from explicit manifests or byte inputs, validated before replacement, and loaded without evaluating Lisp. Cache identity includes source, importer version, dependencies, and importer options. A synchronous polling watcher can rebuild while retaining the last valid pack on failure. | `src/assets/compiler.lisp`, `src/assets/importers.lisp` |
| Standalone example | `sgeo-game` loads a packed geometry/audio asset set without loading the editor. It supports headless self-test, frame limits, hidden rendering, capture, audio output, and JSON profiling options. | `examples/simulation/standalone.lisp`, `tools/build.lisp` |
| Diagnostics | Scoped CPU timing and bounded timeline snapshots, allocation estimates where supported, renderer/error/recovery metadata, GPU elapsed-time queries, and supported GPU pipeline counters. Reports export JSON, human-readable text, or Chrome trace. | `src/diagnostics/profiler.lisp`, `src/render/render.lisp`, `backends/opengl/profiling.lisp`, `backends/vulkan/renderer.lisp`, `src/editor/opengl-workspace.lisp` |

See the [deployment guide](deployment.md) for build and run commands, asset manifest examples, package layouts, and profiler APIs. `docs/roadmap.md` remains the milestone tracker.

## Profiling behavior and limits

CPU measurements are explicit `with-profile-scope` instrumentation, not statistical sampling of every function. Scopes aggregate calls and inclusive/exclusive host duration by subsystem, function, object class, thread, and frame phase. Frame and CPU timeline timestamps use the profiler's monotonic host clock and origin. The editor's Profile workspace collects when selected and shows recent CPU scopes, allocation estimates, and renderer frame metrics.

On SBCL, allocation deltas use `SB-EXT:GET-BYTES-CONSED`, which is process-wide. A scope label identifies where the measured scope ran; its allocation estimate can include concurrent allocations from other threads. Other Common Lisp implementations report allocation as unavailable.

The OpenGL backend issues elapsed-time queries for frame GPU duration. It records primitives-generated and, if the pipeline-statistics extension is present, vertices-submitted, primitives-submitted, and vertex-shader invocations. The Vulkan backend uses timestamp query results with `timestampPeriod` and the queue's valid timestamp bits for wrap-safe duration, and requests input-assembly primitive, vertex-shader invocation, and fragment-shader invocation counters when supported by the device. Unsupported metrics are reported as unavailable; the engine does not synthesize GPU values from CPU submission time.

GPU durations use the GPU query clock domain. Delayed results carry their original CPU frame ID and are placed against that frame's recorded host start for timeline display. The frame ID links the events; the profiler does not claim absolute CPU/GPU clock synchronization.

## Verification evidence

The following is local evidence recorded in the current checkout. It does not establish hosted Windows or macOS support.

| Check | Result | Evidence |
| --- | --- | --- |
| Headless suite | 2,474 checks passed, zero skips or failures; the test launcher confirms no GLFW/OpenGL packages were loaded. | `sbcl --script tools/test.lisp`; `.cache/m7-tests-pre-ci.log` |
| Linux release build | `tools/build.lisp` produced the application directory and `.tar.gz` archive; the build ran package-manifest verification. | `.cache/m7-build-validation.log` |
| Example source assets | Geometry scene and PCM tone sources generated. | `sbcl --script tools/generate-game-assets.lisp`; `.cache/m7-assets-generation.log` |
| Standalone headless self-test | The game reached the expected state: three coins collected, door open, and game won; the release image omitted the editor. | `.cache/m7-standalone-headless.log` |
| Relocated Linux package isolation | In a `bwrap` sandbox with checkout, Quicklisp, SBCL, and installed GLFW/OpenAL masked, an isolated HOME and `/tmp` working directory, and a relocated package path containing spaces, the package passed 240 headless and 240 rendered frames. Both reports identified `editor-loaded=false`, `game.sgp`, and zero errors; rendered execution also wrote a native capture. | `.cache/m7-ci-headless.log`, `.cache/m7-ci-native.log` |
| External custom ASDF application | A packaged custom application ran after copying the package outside the checkout and masking source tree, Quicklisp, and SBCL. | Local external-application acceptance run |
| OpenGL profiler | 12 native frames produced 12 GPU samples and 12 pipeline-statistics records; query resources were drained at shutdown. | `sbcl --script tools/m7-profile-check.lisp`; `.cache/m7-opengl-profile.log` |
| Vulkan profiler | 12 native frames produced 12 GPU samples and 12 pipeline-statistics records; query pools were released. The acceptance tool also checks that renderer validation messages are empty. | `sbcl --script tools/m7-profile-check.lisp --vulkan`; `.cache/m7-vulkan-profile.log` |
| Editor Profile workspace | 12 hidden native editor frames produced 9 GPU samples; the profile panel was activated and drawn, a box was edited, timeline history stayed bounded, the profile JSON/Chrome trace and framebuffer capture were exported, and OpenGL profiling queries were cleaned up. | `sbcl --script tools/m7-editor-profile-check.lisp`; `.cache/m7-editor-profile.log` |

The [deployment workflow](../.github/workflows/deployment.yml) defines Linux, Windows, and macOS native build/package jobs, including relocation and rendering checks. Its Windows and macOS jobs are pending execution, so their package layouts and runtime behavior must not yet be described as successful.

## Remaining validation

- Run hosted Linux, Windows, and macOS deployment jobs and record their results. In particular, Windows and macOS remain pending.
- Keep platform claims tied to native-host test evidence; target layout support in source is not proof of a working binary on that platform.
- Treat profiler output as bounded, opt-in instrumentation. Allocation figures are process-wide estimates, and GPU query values are frame-correlated but not clock-synchronized with CPU timestamps.
- Audio output uses an optional OpenAL device path. The headless game check verifies gameplay without audio hardware and does not prove physical audio playback.
