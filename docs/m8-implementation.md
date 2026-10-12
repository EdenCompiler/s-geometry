# M8 — Advanced geometry

M8 adds subdivision, solid booleans, implicit fields, curves and surfaces, procedural graphs, and OpenGL compute processing. The public APIs are available through `sg:`. Geometry and its generating data remain Lisp objects; generated meshes and graphics buffers are updated from those objects.

The [geometry guide](advanced-geometry.md) has examples. `tools/run.lisp` remains the normal editor launcher. `tools/advanced-editor.lisp` opens a separate scene with eight advanced modeling examples and requests an OpenGL 4.3 context.

## Implementation

| Area | Implementation | Behavior |
| --- | --- | --- |
| Subdivision | `src/advanced/subdivision.lisp` | Catmull–Clark for polygons and Loop for triangles, including open-boundary rules and in-place replacement. |
| Solid booleans | `src/advanced/booleans.lisp`, `predicates.lisp` | Union, intersection, difference, exact rational classification and construction, shell validation, conforming edge reconstruction, and atomic target publication. |
| Implicit geometry | `src/fields/` | Editable primitive and compound fields, dependency revisions, sampling, and tetrahedral extraction into editable half-edge meshes. |
| Curves and surfaces | `src/curves/` | Polylines, Bézier and B-spline curves, editable Bézier surfaces, parametric callbacks, tessellation, sweep frames, and lathe meshes. |
| Procedural geometry | `src/procedural/`, `src/editor/procedural.lisp` | Cached dependency graphs, named Lisp generators, live invalidation and redefinition, a Nodes workspace, transactions, and persistence. |
| GPU processing | `src/geometry-processing/`, `backends/opengl/geometry-processing.lisp` | Compute shaders transform and deform positions and calculate normals; validated readback publishes into the same CPU mesh. |
| Polygon editing | `src/geometry/editing.lisp`, `modeling.lisp` | Face splitting, inset, vertex bevel, boundary bridges, welding, region duplication, creation/deletion, triangulation, winding reversal, and component extraction. |

Replacement operations preserve the mesh object and retire old element handles. Batch position edits, including GPU publication, preserve vertex handles. Successful edits advance the mesh revision; rejected edits keep the previous valid state.

Procedural generators execute ordinary Lisp functions registered in the current image. A changed source or generator invalidates its consumers. Unchanged frames reuse the cached result; a failed evaluation retains the previous mesh and its error until its inputs change. The node cards expose that same graph, with numeric editing, evaluation, and input rewiring through editor transactions.

Scene version 3 stores graph data and a geometry snapshot. It stores generator names rather than executable functions. Reopened meshes retain saved manual edits until the graph changes or regeneration is requested. Missing generators leave the saved geometry visible with an error on the node. Undo and redo restore graph parameters and geometry together, while keeping revisions monotonic.

## Verification

The integrated headless suite passes **2,841 checks**, with no skips or failures, without loading GLFW or OpenGL packages:

```bash
sbcl --script tools/test.lisp
```

The tests cover subdivision counts and boundaries; rotated, concave, nested, touching, nearly coplanar, and large-offset CSG inputs; malformed solids and rollback; closed field meshes; curve derivatives and seams; modeling invariants; generator redefinition and failed-edit recovery; safe graph files; frozen scene reopening; undo/redo; and retention of public exports when optional systems load.

The native compute check passes on an AMD Radeon Graphics device with Mesa OpenGL 4.6:

```bash
sbcl --script tools/m8-gpu-check.lisp
```

It checks a 24-vertex triangle box, an 8-vertex half-edge box, and a 120-vertex open grid. Readback positions match the analytical transformation, and normals match a CPU reference. It also checks stable half-edge handles, revision-bound normal caches, invalid-output rollback, restoration of caller GL bindings, and deletion of temporary buffers, shaders, and programs.

The bounded editor check and fresh-process reopening are run with:

```bash
sbcl --dynamic-space-size 4096 --script tools/m8-editor-check.lisp
```

It passes **74 checks over 15 frames with 29 geometry uploads**, without render or platform errors. It changes subdivision and CSG sources, a field radius, Bézier surface controls, and a sweep path, then publishes each result into its existing scene mesh. It also clicks the Nodes parameter and rewiring controls, redefines a running generator, recovers from a failed generation, processes a live mesh on the GPU, and exercises cache invalidation and undo/redo. The saved scene reopens with equivalent geometry and references in a fresh headless SBCL process, including a manual procedural-mesh edit that survives the first world update. IDs are local to each session and are normalized for the comparison.

The default launcher also completes a two-frame native check and opens the editor with its editable box.

The Linux CI job also runs both native checks under Xvfb with Mesa software rendering. The existing native package matrix continues to exercise headless tests and standalone builds on Linux, Windows, and both macOS architectures.

## Limits

The half-edge contract remains orientable manifold solids and open surfaces. Booleans require closed, correctly nested and oriented shells without crossing or overlapping faces. Separate components can touch at points or edges. Empty CSG results are `nil`; removing an object is explicit, and an empty result cannot replace a nonempty target.

CSG predicates and intersections use exact rationals derived from input coordinates. Output coordinates are doubles. Publication merges constructions within a tolerance limited by both coordinate precision and input edge size, then validates the result. Unrepresentable or invalid output is rejected; this does not promise exact real-valued output for arbitrary degeneracies.

Field meshes approximate a sampled zero surface. Features below the grid spacing can disappear, and clipped bounds can leave open surfaces. Field transforms support rigid motion and uniform scale. Curves are nonrational; NURBS remain future work.

GPU processing requires OpenGL 4.3 compute shaders and SSBOs. Its current operations are scale, translation, sine deformation, and vertex-normal calculation. GPU arithmetic is float32, followed by CPU validation and a revision check before publication. Unsupported devices report the missing capability. Subdivision, booleans, field extraction, and surface tessellation run on the CPU.

The [roadmap](roadmap.md) records milestone completion. The [architecture](modern-s-geometry-design.md) and [kernel specification](sgeo-geometry-kernel-spec.md) remain the design references.
