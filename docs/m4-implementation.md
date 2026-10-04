# M4 — Shader Lisp and modern renderer

M4 is complete against the deliverables in §60 of the [architecture document](modern-s-geometry-design.md) and the [roadmap](roadmap.md). The compiler, render graph, materials and live Vulkan viewer are implemented and verified by the checks below.

| Requirement | Evidence required |
| --- | --- |
| Typed Lisp shader frontend | Typed scalar, vector and matrix expressions, interfaces, shader helper functions, and useful errors; CPU tests of shared math. |
| SGIR and direct SPIR-V generation | The actual shadow, PBR and tone shaders pass `spirv-val --target-env vulkan1.2`; emission works without a GLSL compiler. |
| Vulkan backend | Real GPU rendering, resource cleanup, swapchain presentation and resize through the engine interfaces. |
| Material system and PBR | Live metallic/roughness materials, GGX/Smith/Schlick lighting, correct normal transforms, and persistence of material and light state. |
| Shadows and render graph | A depth-map pass feeds PBR shading; the compiled graph orders passes and memory dependencies, declares persistent targets, and supports acquisition/release of transient resources. |
| Shader hot reload | CPU compilation runs on a worker; the graphics thread builds and installs the candidate; compile and pipeline failures retain the previous program; retired pipelines survive outstanding commands. |
| Model viewer | An interactive Vulkan window renders editable polygon meshes with Lisp-authored shaders; a native acceptance run exercises live edits, shader replacement, failure recovery and a fresh saved-scene session. |

## Systems and entry points

`sgeo/shader` contains the Lisp compiler. `sgeo/render` contains the rendering protocol, render graph, stock SGL shaders, scene snapshots and shader replacement manager. Both can load without a window or graphics driver.

`sgeo/backend/vulkan` owns Vulkan resources and presentation. `sgeo/runtime/core` handles the shared window loop and scene interaction; `sgeo/runtime/vulkan` selects the Vulkan backend. The OpenGL editor remains the default application opened by `tools/run.lisp`.

The M4 viewer has its own launcher:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp
```

It needs a Vulkan driver and native GLFW. With Quicklisp loaded, install the dependencies and the `vk` source distribution:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cffi :alexandria))
(ql-dist:ensure-installed (ql-dist:find-system "vk"))
```

The second form installs the bindings without compiling them; the project prepares them when the Vulkan backend loads. The first compilation of the generated `vk` bindings needs more heap than SBCL's default. The backend uses CFFI and [vk](https://github.com/JolifantoBambla/vk) for API bindings. An older Quicklisp distribution has macro helper functions available only at compile time; the compatibility loader repairs a private copy under `.cache/vulkan-bindings/` when necessary. It preserves the dependency's license and leaves the shared installation alone.

Use right drag to orbit, middle drag to pan, the wheel to zoom, and left click to select. `R` requests shader recompilation. The terminal listener shares the world through `sg:*world*`, the selection through `sg:*selection*`, and the active renderer through `sg:*renderer*`.

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:set-pbr-material (sg:mesh-object-material *box*) :metallic 0.5d0 :roughness 0.2d0)
(sg:translate *box* '(0 0.25d0 0))
(sgeo.render:reload-renderer-shaders sg:*renderer*)
(sgeo.serialization:save-world sg:*world* "pbr-scene.sgeo")
```

To reopen the scene:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp --open pbr-scene.sgeo
```

## Writing shaders

The viewer's shadow, PBR and tone shaders live in [src/render/shaders.lisp](../src/render/shaders.lisp). Re-evaluate a `defshader` or shared `defgpu-function` in the running image, then request recompilation. The compiler keeps the typed Lisp forms and emits SPIR-V directly; GLSL output is available for inspection.

A small standalone shader definition looks like this:

```lisp
(sgeo.shader:defshader :vertex simple-vertex ((position :vec3 :location 0))
  (:position (vec4 position 1.0)))

(sgeo.shader:defshader :fragment simple-fragment ()
  (:color (vec4 0.8 0.2 0.1 1.0)))

(sgeo.shader:compile-shader-to-spirv
  (sgeo.shader:shader-definition-by-name 'simple-fragment))
```

The return values are SPIR-V octets and interface metadata. SGL supports typed scalar, vector and matrix expressions, `let`/`let*`, conditionals, field access, swizzles, texture sampling and pure shared helper functions. Unsupported forms signal a shader condition. The viewer's fixed resource interface uses set 0, binding 0 for the frame uniform block and binding 1 for the sampled image; a candidate that conflicts with that interface is rejected before installation.

## Verification

```bash
sbcl --script tools/test.lisp
sbcl --dynamic-space-size 4096 --script tools/vulkan-backend-check.lisp
sbcl --dynamic-space-size 4096 --script tools/vulkan-backend-check.lisp --validation
sbcl --dynamic-space-size 4096 --script tools/m4-acceptance.lisp
sbcl --dynamic-space-size 4096 --script tools/vulkan-presentation-check.lisp
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp --frames 8 --no-repl --capture artifacts/pbr.ppm
```

`spirv-val` enables the external binary checks. It must be available for the complete M4 verification; the suite reports those checks as skipped when it is absent. `--validation` and the full acceptance script require the Khronos Vulkan validation layer; requesting it without an installed layer fails explicitly.

The headless suite passes **1,325 checks with no skips or failures**. It verifies typed shader expressions, shared CPU/GPU math, all five stock SPIR-V stages validated for Vulkan 1.2, material/light round trips, inspector edits with undo and replay, render-graph invariants, shader failure recovery and a deterministic replacement race.

The native resource check has verified the actual validation callback with an intentional message and a 256-byte GPU image readback, followed by cleanup without validation messages. Separate context checks confirmed that messages stay with their own context and that no callback registrations remain after destruction.

The full native acceptance run completes **13 frames and 8 mesh uploads**. It checks pixel changes caused by shadows and a successful shader replacement; compile, resource-interface and missing-fragment failures preserve the previous pipeline and pixels. It edits vertices, splits an edge, extrudes a connected face region, changes PBR material values, and recovers from an invalid edit. It also checks cache retirement, partial target-allocation failure, a UBO allocation failure after image acquisition, and resize while a shader compiler worker is paused. The pending reload then installs into the same retained shader-program object. A fresh SBCL process reopens equivalent geometry, hierarchy order, materials and light state, and renders four more frames.

The presentation check forces a **BGRA8 sRGB swapchain**, recovers from an injected out-of-date acquisition, and compares **1,075,200 proxy bytes** against the rendered output. The gamma-encoded values are unchanged and the channel order is correct. The viewer launcher separately completes eight visible frames. All these runs include Khronos validation with synchronization checks and finish without validation messages, including during destruction.

The existing OpenGL editor also passes its 28-frame modeling demonstration, 50-frame UI demonstration, and native selection check. `tools/run.lisp` continues to open that editor.

## Current rendering contract

The initial graph renders a directional shadow map, metallic/roughness lighting into a floating-point HDR target, tone mapping into RGBA8, then readback and presentation. The uniform block is an explicitly laid-out 384-byte std140 structure shared by the passes. Mesh buffers are derived from the existing geometry revision; the editable topology remains in Lisp.

The viewer's graph declares persistent image targets, retained between frames and rebuilt atomically when the extent changes. Dynamic viewport and scissor state let the existing shader programs, pipelines and pending reloads survive resizing. The renderer releases them on shutdown. Transient graphs use first/last-use acquisition and release callbacks, including cleanup when a pass fails.

Presentation prefers UNORM surfaces. For an sRGB surface, the output is scaled and channel-converted into a matching UNORM proxy, then copied without another gamma conversion; [Vulkan's copy and blit rules](https://docs.vulkan.org/spec/latest/chapters/copies.html) govern this path.

The viewer's ambient term is a configurable constant. Environment maps, texture-based materials, more light types, MSAA, clustered lighting and instancing from §13's broader rendering direction remain later work outside §60's M4 deliverables. Compute simulation belongs to the later simulation work; the shader compiler must reject unsupported compute operations clearly rather than imply that they execute.
