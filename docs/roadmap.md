# S-Geometry/CL Roadmap

## Project direction

S-Geometry/CL is a live Common Lisp geometry, scene, and development environment. Lisp objects own the authoritative scene and geometry state. GPU resources, editor views, and saved files are derived representations of those objects.

The first target is **Linux with SBCL**, using **cl-glfw3, cl-opengl and CFFI** through engine-owned backend adapters, plus **cl-freetype2** for the editor's font atlas. Dependencies are selected for this project's requirements. The initial editor will have a faithful Symbolics-inspired feel: boxed menus, monospace labels, restrained colors, a live Lisp listener, and contextual mouse help.

The architecture is described in [Modern S-Geometry in Pure Common Lisp](modern-s-geometry-design.md). This roadmap preserves its M0–M8 milestone numbering and divides M3 into an initial editor and later expansion.

**Implementation status:** M0, M1, M2, M3a, M3b, M4 and M5 are **Complete**. Completion is tracked against the deliverables, tests, and demonstrations below. See [M0/M1 verification evidence](m0-m1-implementation.md), [M2 verification evidence](m2-implementation.md), and [M3 verification evidence](m3-implementation.md). See [M4 verification evidence](m4-implementation.md) for the shader compiler and Vulkan viewer, and [M5 verification evidence](m5-implementation.md) for animation and glTF. M6–M8 remain **Not started**.

Architectural commitments:

- Implement engine algorithms and editor logic in Common Lisp; use foreign libraries as backend services.
- Keep geometry usable headlessly, without initializing graphics or loading the editor.
- Give every GUI editing action an equivalent public Lisp operation.
- Edit and inspect the same live objects from the viewport, built-in listener, and external REPL.
- Preserve the running world when an edit, compilation, or resource update fails.

## First usable release

The first usable release includes **M0, M1, M2, and M3a**. Its defining demonstration is live modeling and code redefinition on the same mesh, followed by saving and reopening the scene.

| Milestone | Main deliverables | Exit criterion | Status |
| --- | --- | --- | --- |
| M0 — Foundation | Modular ASDF systems, math, IDs, base objects, conditions, tests, platform and graphics adapters. | Render a triangle through the engine abstraction. | Complete |
| M1 — Live scene | Hierarchy, transforms, camera, simple materials, viewport, picking, external REPL access. | Manipulate a running scene without restarting. | Complete |
| M2 — Geometry kernel | Half-edge storage, stable handles, primitives, topology queries, split/collapse, face and connected-region extrusion, normals, triangulation, render-mesh conversion. | Edit geometry and see the same live mesh update in the viewport. | Complete |
| M3a — Initial editor and persistence | Boxed menus, configurable perspective/front/top/side viewport, element selection, inspector, command history, contextual mouse help, integrated listener, transactions, undo/redo, local scene save/load. | Edit, inspect, redefine operations, save, and reopen a scene. | Complete |

### M0 — Foundation

**Status:** Complete. **Release:** First usable release.

- [x] Establish modular ASDF systems for core, math, geometry, scene, serialization, platform, rendering, editor, and tests.
- [x] Implement engine-owned vector, matrix, quaternion, transform, and basic geometry math.
- [x] Implement object IDs, base objects, revision tracking, and a condition hierarchy.
- [x] Establish the test framework and headless test entry point.
- [x] Implement the platform and OpenGL adapters with cl-glfw3, cl-opengl and CFFI.
- [x] Create a window and render a minimal triangle through the engine abstraction.
- [x] Pass foundation and adapter tests and demonstrate the triangle rendering.

**Exit criterion:** Lisp can create a window and render a triangle through the engine abstraction.

### M1 — Live scene

**Status:** Complete. **Release:** First usable release. **Depends on:** M0.

- [x] Implement scene objects, hierarchy, local/world transforms, and explicit mutation APIs.
- [x] Implement a perspective camera and basic camera navigation.
- [x] Add mesh renderables, simple materials, wireframe display, and basic shaded display.
- [x] Establish the minimal viewport and revision-driven render-update path needed by M2.
- [x] Implement object picking that resolves to live Lisp objects.
- [x] Keep an external REPL responsive in the same Lisp image while the scene runs.
- [x] Demonstrate scene edits and function redefinition without recreating the world.
- [x] Pass scene tests and demonstrate picking and REPL manipulation in the running viewport.

**Exit criterion:** A running scene can be edited from the REPL without restarting.

### M2 — Geometry kernel

**Status:** Complete. **Release:** First usable release. **Depends on:** M0 and M1's live viewport.

This milestone covers the Geometry Kernel deliverables in **§60 of the architecture document**. It does not promise every broader version-one modeling operation listed in §8.3.

The first kernel supports **orientable manifold solids and open surfaces**, with consistently oriented faces and support for mesh boundaries. Non-manifold connectivity and individual polygon faces with holes are outside the first-release contract.

- [x] Write the [geometry-kernel specification](sgeo-geometry-kernel-spec.md), including storage, mutation invariants, conditions, and test cases.
- [x] Implement indexed half-edge storage, generation-checked stable handles, and topology validation.
- [x] Implement box, sphere, cylinder, grid, and torus constructors.
- [x] Implement topology and geometry queries, including adjacency, normals, areas, bounds, ray intersections, and closest points.
- [x] Implement vertex editing and edge split/collapse operations.
- [x] Implement single-face and edge-connected region extrusion, including non-coplanar selections.
- [x] Implement normal calculation, deterministic triangulation, and indexed render-mesh conversion while preserving editable polygon topology.
- [x] Make mutations atomic, advance revisions on successful edits, and invalidate derived render data.
- [x] Test solids and open surfaces, invalid-edit rollback, stale handles, and live mesh updates.
- [x] Demonstrate vertex, edge, and face-region edits on the same live mesh.

**Exit criterion:** A box can be edited at vertex, edge, and face level, and the same live mesh is re-rendered after each valid edit. M3a supplies the complete GUI workflow.

**Verification:** 935 headless checks pass. The M2 native demonstration completes nine frames with eight geometry uploads on the same mesh, including failed-edit recovery and live function redefinition. See [M2 implementation and verification](m2-implementation.md).

### M3a — Initial editor and persistence

**Status:** Complete. **Release:** First usable release. **Depends on:** M1 and M2.

- [x] Make `tools/run.lisp` the canonical editor launcher; keep the scene demos in `tools/demo.lisp` and retain `tools/editor.lisp` as a compatibility alias.
- [x] Build a Symbolics-inspired geometry frame with boxed menus, monospace labels, and a persistent command/status area.
- [x] Provide one configurable viewport that switches between perspective, front, top, and side views.
- [x] Add an object list, navigable inspector, and numeric editing controls.
- [x] Add object, vertex, edge, and face selection, including connected face-region selection.
- [x] Provide menus for creation, transforms, selection, split, collapse, extrusion, and undo/redo; right-click opens the main menu.
- [x] Display contextual mouse help and replayable command history.
- [x] Integrate a multiline Lisp listener with current-world and selection access, results, and error reporting.
- [x] Support an external terminal REPL and optional SLIME/Sly access to the same live image.
- [x] Keep window, graphics, and world mutation ownership on the main thread; evaluate listener forms on a worker and marshal public edits to the owning thread.
- [x] Route GUI edits through public Lisp operations, transactions, and snapshot-based undo/redo.
- [x] Save and load versioned, readable Lisp scene data without serializing GPU caches.
- [x] Validate scenes before replacing the current scene and save through an atomic file replacement.
- [x] Complete the first-release acceptance demonstration described below.
- [x] Pass editor, transaction, undo/redo, and persistence verification.

**Exit criterion:** Basic modeling works through either GUI commands or equivalent Lisp calls; code can be redefined on existing objects, and edited scenes survive a fresh session.

**Verification:** 1,144 headless checks pass. The 28-frame native modeling demonstration verifies editing, live redefinition, failed-edit recovery, undo/redo, command replay, and equivalent scene reopening in a fresh SBCL process. The seven-frame native selection check exercises viewport picking, numeric vertex editing, edge splitting, face-region toggling, and listener-driven retirement of a selected edge. See [M3 implementation and verification](m3-implementation.md).

## Later milestones

These milestones are **outside the first usable release**. M3b extends the editor, M4 adds the modern renderer, and M5 adds animation and glTF interchange; all three are complete. M6–M8 remain future goals. Dates and duration estimates remain unset; the architecture document's numbering is preserved.

### M3b — Editor expansion

**Status:** Complete. **Release:** Additional editor expansion. **Depends on:** M3a.

- [x] Add transform gizmos and richer interactive manipulation.
- [x] Expand inspection and debugging views.
- [x] Add configurable workspace tools and panel layouts.
- [x] Integrate timeline and profiling views as their underlying systems become available.
- [x] Pass interaction tests and demonstrate the expanded editing workspace.

**Exit criterion:** The initial editor grows into a broader live development workspace while retaining equivalent Lisp operations for GUI actions.

**Verification:** Nine CPU gizmo cases pass, covering translation, rotation, scale, cancellation, zero-distance drags, transformed parents, groups, triangle meshes, and retired selections. Workspace checks cover panel configuration, scrolling, scene-clock controls, and rolling profiling samples. A 50-frame native UI demonstration verifies menus, inspector navigation, multiline listener input, gizmo dragging, workspace tools, panel configuration, and resizing; a second window verifies popup rendering and cleanup. M5 extends the scene-clock view with animation tracks and keyframes.

### M4 — Shader Lisp and modern renderer

**Status:** Complete. **Release:** Later.

- [x] Implement the typed shader AST and Lisp shader front end.
- [x] Implement SGIR and SPIR-V generation.
- [x] Add a Vulkan backend behind the rendering abstraction.
- [x] Expand the material system with PBR, shadows, and a render graph.
- [x] Implement shader hot reload with preservation of the previous working shader on failure.
- [x] Pass shader and rendering tests and demonstrate the Lisp-authored PBR model viewer.

**Exit criterion:** A PBR model viewer uses shaders authored in Lisp.

**Verification:** 1,325 headless checks pass, including external Vulkan 1.2 validation of all five stock shader stages. The 13-frame Vulkan demonstration verifies shadows, shader replacement and failure recovery, live mesh/material edits, GPU cache cleanup, allocation failure recovery, resizing with a pending reload, and scene reopening in a fresh SBCL process. A separate sRGB presentation check compares 1,075,200 bytes and exercises out-of-date swapchain recovery. Native runs finish without Vulkan validation messages. See the [M4 implementation and verification notes](m4-implementation.md).

### M5 — Animation and asset interoperability

**Status:** Complete. **Release:** Later.

- [x] Implement property animation tracks and interpolation.
- [x] Add a timeline editor.
- [x] Implement skeletons, skinning, and animation blending.
- [x] Add glTF interoperability, including animated model import.
- [x] Demonstrate live modification of an imported animated character.
- [x] Pass animation and glTF interoperability tests.

**Exit criterion:** An imported animated character plays and can be modified live.

**Verification:** 1,898 headless checks pass without skips or failures. The 12-frame OpenGL demonstration verifies playback, Lisp redefinition on the existing character, source geometry edits, failed-edit recovery, timeline interaction, undo/redo, and equivalent scene reopening in a fresh SBCL process. A six-frame Vulkan check verifies deformation and source edits without validation messages. Character glTF/GLB exports and the reopened export have zero Khronos validator errors. Image and texture data are preserved for interchange; the viewers currently use material factors. See the [M5 implementation and verification notes](m5-implementation.md).

### M6 — Simulation and game layer

**Status:** Not started. **Release:** Later.

- [ ] Expand the world loop for simulation and game updates.
- [ ] Implement semantic input maps, events, and debug drawing.
- [ ] Implement collision primitives and basic physics.
- [ ] Add an audio abstraction.
- [ ] Build a live Boids example and a small interactive game.
- [ ] Pass simulation and input tests and demonstrate the working examples.

**Exit criterion:** A small interactive 3D game can be built entirely in Common Lisp.

### M7 — Deployment

**Status:** Not started. **Release:** Later.

- [ ] Implement release builds and standalone application generation.
- [ ] Add deterministic asset compilation and disposable packed caches.
- [ ] Establish Windows, Linux, and macOS packaging and platform validation.
- [ ] Add profiling and deployment diagnostics.
- [ ] Ship an example game without requiring the development editor.
- [ ] Pass asset and packaging checks and demonstrate the standalone game.

**Exit criterion:** The example game runs standalone without the development editor.

### M8 — Advanced geometry

**Status:** Not started. **Release:** Later.

- [ ] Implement subdivision and robust mesh booleans.
- [ ] Add signed distance fields and implicit geometry tools.
- [ ] Expand curve and surface modeling.
- [ ] Add procedural node views backed by Lisp forms or dependency objects.
- [ ] Add GPU geometry processing.
- [ ] Expand modeling operations beyond the initial M2 contract as their specifications are established.
- [ ] Pass geometry and GPU processing tests and demonstrate live advanced modeling.

**Exit criterion:** Advanced geometry can be authored and modified live while preserving the authoritative Lisp object model.

## Completion and tracking

Check off a deliverable only after implementation and relevant verification. Mark a milestone complete only when its deliverables, relevant tests, and working demonstration pass. Update its status here and record any remaining limitations.

### First-release acceptance demonstration

- [x] Create a world and a half-edge box, then open the editor.
- [x] Select and edit vertices, split/collapse eligible edges, and extrude a face and a connected face region.
- [x] Confirm topology remains valid and render data updates from the same live mesh object.
- [x] Inspect the selected object and geometry from the GUI and Lisp listener.
- [x] Redefine an operation while the application runs and apply the new behavior to the existing mesh without restarting.
- [x] Reject an invalid edit, preserve the prior valid geometry, and continue editing.
- [x] Undo and redo geometry edits without reusing stale element handles.
- [x] Save the edited scene, start a fresh Lisp session, and reopen equivalent geometry and scene state.

### Verification requirements

- Geometry tests cover topology invariants, primitive construction, split/collapse, region extrusion, boundaries, winding, normals, triangulation, stale handles, and rollback.
- Scene tests cover transforms, revision invalidation, persistence round-trips, malformed files, and unsupported file versions.
- Editor verification covers picking, selection modes, view switching, resizing, listener responsiveness, undo/redo, and recoverable failures.
- Headless verification loads and exercises the geometry core without initializing a graphics backend.
- Later milestones add tests and demonstrations appropriate to their own capabilities before being marked complete.

## Design references

The [original S-Geometry summary](original-s-geometry-summary.md) records the historical polygon database and editor model supplied by the project owner. Its physical-camera, hidden-line, tablet, hardcopy, and S-Render capabilities are design references for future work; they do not change the first-release commitments.

- [Architecture and design specification](modern-s-geometry-design.md), especially §60–61 and §71.
- [Geometry-kernel specification](sgeo-geometry-kernel-spec.md) — storage, mutation invariants, operations, and verification contract for M2.
