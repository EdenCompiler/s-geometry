# M2 implementation and verification

The geometry kernel implements the [M2 roadmap contract](roadmap.md) and [kernel specification](sgeo-geometry-kernel-spec.md). Lisp polygon topology and positions own the mesh state. Render meshes and GPU buffers are derived from a captured geometry revision.

**Status:** Complete. The combined headless suite passes **935 checks with zero failures**. The M0/M1 and M2 native demonstrations pass through the migrated graphics adapter, and the README's M2 modeling example runs successfully.

## Deliverables

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Indexed half-edge storage | `src/geometry/topology.lisp`: indexed vertex, edge, face and half-edge arenas; explicit twins and boundary cycles | Solid and open-surface tests, reciprocal link checks, face-loop and vertex-fan validation |
| Stable handles | Mesh identity, element kind, index and slot generation; surviving element identities retained during connectivity rebuilds | Foreign and malformed handles rejected; removed handles remain stale after slot reuse; unaffected edge/half-edge identities survive edits |
| Primitives | `src/geometry/primitives.lisp`: polygon box, sphere, capped/open cylinder, grid and torus | Counts, Euler characteristics, outward winding, seam/pole sharing and boundary loops |
| Geometry and topology queries | Adjacency and connected regions; normals, area, bounds, rays and closest points | Surface hits/misses, closest points, normal direction, defensive copies and independent components |
| Editable vertices and edges | `src/geometry/operations.lisp`: vertex position, edge split and eligible edge collapse | Border/interior split-collapse round trips; invalid solid collapse preserves state and identities |
| Face and region extrusion | Shared cap vertices, retained selected face handles, boundary walls, area-weighted normal or explicit vector offset | Single face, coplanar grid, non-coplanar region and entire closed region; no internal walls |
| Triangulation and render conversion | `src/geometry/polygons.lisp`: deterministic ear clipping, indexed flat-shaded render mesh, source polygon handles per triangle | Concave and collinear polygons; translated and tiny meshes; source topology remains polygonal |
| Atomic edits and cache invalidation | Candidate state cloned, connectivity rebuilt and validated, then published under a recursive mesh lock | Rejected candidates preserve state/revision; successful edits advance revision once; concurrent readers and writers; observer errors do not reject an already committed edit |
| Live scene integration | Existing mesh-object and render-snapshot protocols accept `half-edge-mesh`; OpenGL caches by object identity and revision | Same mesh and scene object survive all edits, rejected edit and function redefinition |

`make-box` retains the M1 triangle-mesh API. `make-half-edge-box` creates the editable box. Public operations and parameter semantics are documented in the kernel specification.

## Reproduce the evidence

```bash
sbcl --script tools/test.lisp
sbcl --script tools/smoke.lisp
sbcl --script tools/kernel-smoke.lisp
sbcl --script tools/demo.lisp --kernel
```

The headless test entry point loads no GLFW or OpenGL package. The graphics adapter uses **cl-glfw3, cl-opengl and CFFI**, matching the relevant dependencies in the [kons-9 ASDF manifest](https://github.com/kaveh808/kons-9/blob/main/kons-9.asd). Rendering requires a display and an OpenGL 3.3 core context.

The M2 graphics demonstration runs **nine frames with eight mesh uploads**. It moves a vertex, splits an edge, collapses the inserted segment, rejects a coincident-vertex edit without advancing the revision, extrudes a face and a connected non-coplanar region, and applies two live redefinitions of extrusion distance to the existing mesh. Picking still returns the original scene object. The runtime reports no platform or rendering error and releases its window and GPU resources afterward.

The ignored `artifacts/kernel-scene.ppm` capture records the edited mesh. M0/M1 graphics verification also passes through the migrated adapter, including repeated contexts, concurrent terminal evaluation and recovery from reader/evaluation errors.

Each runtime closes its window and deletes its GPU objects. On SBCL, GLFW remains initialized between runs to avoid repeated Wayland/libdecor initialization; it terminates at image exit or through `sgeo.backend.opengl:shutdown-opengl-backend` after all windows close.

## Remaining boundary

The kernel supports consistently oriented manifold solids and open surfaces. Individual polygon holes, non-manifold topology, booleans, subdivision and global self-intersection repair are future work. Geometry uses double floats and scale-relative polygon tolerances.

M3a supplies GUI element selection, menus, inspection, transactions, undo/redo and local scene persistence. The complete first-release demonstration, including reopening saved geometry in a fresh session, remains pending under M3a.
