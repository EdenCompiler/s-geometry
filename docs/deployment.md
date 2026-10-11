# Deployment and diagnostics

This guide describes the current source-level build, asset, standalone-game, and profiling interfaces. Native packages are built for the host running the build; the build code does not cross-compile. The package layouts described below are implemented in the source, but platform success should be claimed only after that platform is exercised by CI or a native-host run.

## Build a native application package

The deployment API is in `sgeo.deployment`. Register an application with an entry point, systems to include in its release image, and its asset manifest, then call `build-application`:

```lisp
(asdf:load-system :sgeo/deployment)
(asdf:load-system :sgeo/assets/importers)

(sgeo.deployment:define-application my-game
  :entry-point 'my.game:main
  :systems '(:my/game)
  :version "1.0.0"
  :target :desktop
  :assets '((:name "level" :source "assets/level.sgeo" :importer "scene")))

(sgeo.deployment:build-application 'my-game
  :project-root #P"/path/to/project/"
  :output-directory #P"/path/to/output/")
```

`define-application` options include `:native-libraries`, `:debug`, and `:target` (`:desktop`, `:linux`, `:windows`, or `:macos`). `:desktop` selects the current host. The build compiles the manifest into `game.sgp`, saves a fresh SBCL executable image in a child process, assembles the package, and verifies its manifest. It rejects a target different from `host-target`; build each release on its target host. A release image also refuses to include the editor unless `:debug` is true.

The repository's example build command is:

```sh
sbcl --script tools/build.lisp --output artifacts/releases/my-game \
  --native-lib /path/to/optional-native-library.so
```

`--native-lib` can be repeated. The example build script tries to resolve OpenAL on the build host. The release-image builder also records loaded GLFW/OpenAL libraries, resolves those recognized libraries, and packages them alongside explicitly supplied libraries. At startup, the runtime adds the package's native-library directory to CFFI's search path. For a bundled GLFW or OpenAL library, it also rebinds that CFFI library name to the absolute path of the packaged file before loading it, so a same-named host copy does not take precedence. System graphics drivers and transitive native dependencies are still host prerequisites unless separately supplied.

The package layouts currently emitted by the source are:

| Host target | Application and resources | Archive |
| --- | --- | --- |
| Linux | executable in `bin/`, launcher at the package root, native libraries in `lib/`, assets in `assets/` | `.tar.gz` |
| Windows | executable and launcher at the package root, native libraries alongside them, assets in `resources/` | `.zip` |
| macOS | `.app` bundle with executable in `Contents/MacOS`, libraries in `Contents/Frameworks`, assets in `Contents/Resources` | `.tar.gz` |

Use `application-resource-path` in application code to locate packaged resources relative to the running package instead of the current working directory. Packaging writes a `MANIFEST.sha256` with file hashes and package diagnostics; `verify-package` checks the package contents. Builds also include `THIRD-PARTY.txt` with locally discovered dependency notices and explicit diagnostics for texts that could not be located.

## Asset manifests, caches, and watching

Asset APIs live in `sgeo.assets`. An explicit manifest names each asset and its importer. Dependencies are named by asset name, and every dependency must also appear in the manifest. For example, a glTF file with a sidecar buffer declares the sidecar as a byte asset and maps the URI to that dependency:

```lisp
'((:name "model" :source "assets/model.gltf" :importer "gltf"
   :dependencies ("model-buffer")
   :external-resources (("model.bin" . "model-buffer")))
  (:name "model-buffer" :source "assets/model.bin" :importer "bytes"))
```

Every external glTF buffer or image URI must be mapped exactly once to a declared dependency using the `bytes` importer. Data URIs are embedded and need no mapping. This makes sidecar inputs explicit build dependencies rather than implicit files read during import.

`compile-assets` compiles a manifest to an SGP pack, validates the temporary pack, and replaces the destination only after validation. `load-asset-pack` reads and validates an existing pack without executing Lisp. `load-or-build-asset-pack` reuses a current cache or rebuilds it when manifest inputs, importer versions, dependencies, or options change. The deployment builder accepts a path or pathname as an asset input as well as explicit manifest entries: a directory is recursively collected as byte assets, with safe relative traversal and symlinks rejected. Use explicit manifests when importers, stable names, dependency relationships, or glTF sidecars matter.

For development-time reload, `make-asset-watcher` creates a synchronous polling watcher; it starts no background thread. Call `poll-asset-watcher` at a point where replacing assets is safe. It returns the current pack, a rebuild flag, and an error condition. On errors it retains the previous pack and exposes the condition through the return values and `asset-watcher-last-error`; an optional `:on-error` callback can report it. Call `stop-asset-watcher` when done. Stopping releases the watcher's manifest/signature state; it does not delete the cache file or dispose a pack object held by application code.

The checked-in standalone example assets can be regenerated with:

```sh
sbcl --script tools/generate-game-assets.lisp
```

This writes `assets/game/geometry.sgeo` and `assets/game/collect.pcm`. The ordinary build consumes these source files and does not regenerate them.

## Standalone game

`tools/build.lisp` builds the `sgeo-game` release executable. Its entry point accepts these options:

| Option | Behavior |
| --- | --- |
| `--help` | Print the available options. |
| `--headless` | Run simulation updates without opening a window; cannot be combined with `--audio`. |
| `--self-test` | Drive the example through semantic input and check the expected win state. |
| `--hidden` | Create the window loop with the window hidden. |
| `--frames N` | Stop after a positive number of frames. Headless and self-test runs default to 240 if omitted. |
| `--assets FILE` | Load an asset pack from the given path; otherwise use packaged `game.sgp`. |
| `--capture FILE.ppm` | Save a rendered capture to the specified PPM path. |
| `--audio` | Request OpenAL output in the window loop. |
| `--profile FILE.json` | Save the full profiler report as JSON after the run, including when the game reports an error. |
| `--diagnostics` | Print the profiler's JSON report to standard output after the run. |

For example:

```sh
./sgeo-game --headless --self-test
./sgeo-game --hidden --frames 60 --capture frame.ppm
./sgeo-game --headless --frames 240 --profile run.json --diagnostics
```

The executable name and launcher location depend on the native package layout. The example has no editor in its release image and does not start a REPL.

## CPU and GPU profiling

Profiling is opt-in. Create a collector with `make-profiler`, pass it to `begin-frame` and `end-frame`, and bind instrumented code with `with-profile-scope`. An explicit `:profiler` is useful at integration boundaries; nested calls can use the dynamically bound collector:

```lisp
(let ((profiler (sgeo.diagnostics:make-profiler :timeline-limit 4096)))
  (let ((frame (sgeo.diagnostics:begin-frame profiler "update")))
    (unwind-protect
         (sgeo.diagnostics:with-profile-scope
             ("world/update" :profiler profiler :subsystem :simulation
              :function "update-world" :frame-phase :update)
           (sgeo.scene:update-world world dt))
      (sgeo.diagnostics:end-frame profiler frame "update")))
  (sgeo.diagnostics:write-profile-report profiler "profile.json" :format :json)
  (sgeo.diagnostics:write-profile-report profiler "profile.trace.json" :format :chrome-trace)
  (write-string (sgeo.diagnostics:profile-report profiler :format :text)))
```

Scope aggregates group by subsystem, function, object class, thread, and frame phase. They report inclusive and exclusive CPU duration, calls, and allocation deltas when available. Timeline records have a bounded history (`:timeline-limit`, default 2048). `profile-report` returns JSON by default; `:text` produces a human-readable summary and `:chrome-trace` produces a Chrome trace event document. `write-profile-report` writes any of these formats to a pathname or stream. Snapshots and renderer-info are safe copies; arbitrary runtime objects are not retained as report payloads. `set-profiler-renderer-info` can attach backend/device/version/resource information as data without a diagnostics dependency on a renderer backend.

Host CPU timestamps are monotonic nanoseconds relative to that profiler's origin. GPU samples are actual query durations in nanoseconds and retain the originating CPU frame ID. The profiler places delayed GPU records at that frame's recorded host start for visualization, but GPU query time and host time are distinct clock domains: this is frame correlation, not absolute CPU/GPU clock synchronization. Pipeline-statistics records are integer counters associated with the same frame metadata.

Reports state capabilities independently for CPU, allocation, GPU duration, and GPU pipeline statistics. The OpenGL backend uses elapsed-time queries; it adds primitives-generated and, when the extension is present, vertices-submitted, primitives-submitted, and vertex-shader-invocation counters. Vulkan uses timestamp queries and requests input-assembly primitive, vertex-shader invocation, and fragment-shader invocation counters when the physical device supports pipeline-statistics queries. GPU duration is reported only after actual query results are available. Allocation measurement uses SBCL `SB-EXT:GET-BYTES-CONSED`; it measures process-wide allocation, not just the current thread. Scope labels identify where code ran, but an allocation delta may include allocations from other threads that ran concurrently. On other Common Lisp implementations allocation metrics are reported as unavailable. GPU and pipeline statistics are reported as unavailable until the active backend actually supplies measurements; availability depends on backend/device support. No pipeline statistic should be inferred from a CPU draw count.

Profilers also retain bounded diagnostic error and recovery records. Use `record-diagnostic-error` and `record-recovery` when the application wants these events included in the same report. Keep profiling disabled or do not bind a collector in normal operation; `with-profile-scope` executes its body directly when no enabled collector is active.
