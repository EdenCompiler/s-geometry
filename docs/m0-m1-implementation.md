# M0 and M1 implementation

This document records implementation evidence separately from the initial [roadmap baseline](roadmap.md). The [architecture](modern-s-geometry-design.md), §60, defines the milestone deliverables and exit criteria.

**Implementation status:** M0 and M1 are complete against their deliverables, tests and exit demonstrations. Their graphics adapter now uses cl-glfw3, cl-opengl and CFFI and passes the original demonstrations. See [M2 evidence](m2-implementation.md) for the added editable geometry kernel.

## M0 — Foundation

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Modular ASDF systems | `sgeo.asd`: core, math, geometry, scene, platform, render, backend, runtime, examples, tests, plus editor/persistence module boundaries | Fresh loading and test scripts |
| Engine-owned math | `src/math/math.lisp`: vectors, matrices, quaternions, TRS, projections, rays, AABBs and triangle intersections | `tests/core-math.lisp` |
| IDs, base objects, revisions, conditions | `src/core/core.lisp`: CLOS objects, per-image IDs, metadata, observers and typed conditions | Identity, isolation and invalidation tests |
| Headless test entry point | `tools/test.lisp`, `sgeo/tests` | Fresh image asserts absence of GLFW/OpenGL packages |
| Platform and graphics adapters | `src/platform`, `src/render`, `backends/opengl` | Real GLFW context and OpenGL rendering smoke |
| Triangle through engine abstraction | `examples/triangle.lisp`, `sg:run`, platform/render protocols | Three rendered frames and one GPU mesh upload |

## M1 — Live scene

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Scene hierarchy and transforms | `src/scene/scene.lisp`: hierarchy, world ownership, TRS and reparenting | Hierarchy, cycle, ownership, world transform and concurrent mutation tests |
| Perspective camera and navigation | Camera projection, orbit, pan, zoom and cursor rays | Math/scene tests and viewport input handlers |
| Mesh renderables and simple materials | CPU triangle meshes, RGB materials, shaded/wireframe OpenGL rendering | Live scene capture and graphics error checks |
| Viewport and revision-driven updates | Snapshot extraction and geometry/revision GPU cache | Transform/color edits retain two uploads; a mesh edit advances total uploads to three |
| Object picking | Cursor ray and exact triangle intersections return the original Lisp object | Transformed nearest-hit tests and running-world picking |
| Same-image external REPL | Runtime terminal listener on a worker | Multiline input, multiple values, selection, error recovery and listener shutdown |
| Live scene manipulation and redefinition | `examples/live-scene.lisp`: replaceable behavior on an existing CLOS instance | Running cube stops and resumes after function redefinition; identity and geometry remain unchanged |

## Conventions and ownership

CPU vectors and matrices use double floats. Matrices are column-major, coordinates are right-handed with +Y up, the camera looks along -Z in view space, and angles are radians. Local transforms compose as translation × rotation × scale. Rays have normalized directions, so intersection parameters are distances.

Use scene mutation functions rather than writing transform slots or hierarchy links directly. Public mesh arrays, bounds and compiled render data are defensive copies; changing a returned array does not edit the authoritative geometry. Use `set-mesh-position` or `set-mesh-data` to publish a revision. Existing snapshots retain their arrays after an edit. The renderer derives buffers from a geometry's identity and captured revision and releases resources when the runtime ends.

The local-transform, child-list and camera-vector readers also return copies. Parent and world ownership are read through public readers and changed through hierarchy operations. Detaching a subtree clears its selected object. Camera setters validate the view frame, field of view and clipping planes before publishing a change and advancing the revision.

World locks protect scene updates and snapshot reads. Mesh locks protect publication of positions, normals, indices and revision. Native window and OpenGL operations run on the main thread. A terminal error does not terminate the viewport, and recoverable callback/update/render errors are available through runtime reports. `sg:run` returns three values: the original world, the renderer after cleanup, and the execution report. GPU resources on the returned renderer have already been destroyed.

Hierarchy changes reject cycles and cross-world attachment. Preserving a world transform while reparenting supports signed scales and rejects singular or shear-producing local transforms before changing the hierarchy. This follows the current position/quaternion/scale representation.

## Reproduce the evidence

Run from the repository root:

```bash
sbcl --script tools/test.lisp
sbcl --script tools/smoke.lisp
sbcl --script tools/demo.lisp --triangle --frames 3 --hidden --no-repl
```

`tools/smoke.lisp` opens and closes three real graphics contexts in one image. It checks the ordinary loop without a frame hook, then performs picking, transforms, material and mesh edits, invalid-edit rollback, behavior redefinition and concurrent mutation with rendering active. Its terminal-listener run introduces intentional reader and evaluation errors, verifies subsequent successful forms and value history, and checks listener cleanup.

The original M0/M1 headless suite passed **158 checks**, including defensive API reads, invalid-camera rollback, reflection-preserving reparenting, atomic rejection of shear-producing reparenting and detached-selection cleanup. The combined suite now includes M2 coverage. The migrated graphics smoke verifies three M0 frames with one upload, eight M1 frames with three uploads, and successful REPL execution after rendering has begun and after both deliberate errors.

Captures are generated in the ignored `artifacts/` directory. M0's capture contains a shaded triangle; M1's capture contains a selected shaded cube and a wireframe cube.

## Next boundary

M0 and M1 establish live scene objects and renderable triangle meshes. M2 adds the [geometry kernel](sgeo-geometry-kernel-spec.md), editable half-edge topology and modeling operations. M3a supplies the GUI editor, transaction history and local scene persistence; those features remain planned.
