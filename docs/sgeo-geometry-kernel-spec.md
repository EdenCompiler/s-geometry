# S-Geometry/CL geometry kernel — M2

This specification implements the M2 contract in the [roadmap](roadmap.md) and [architecture §60](modern-s-geometry-design.md). The kernel stays usable in a headless Common Lisp image. Lisp topology and positions are authoritative; triangulated render data and GPU buffers are derived representations.

## Supported meshes

The kernel supports consistently oriented, orientable manifold solids and open surfaces, including multiple components and boundary loops. Every face has one simple polygon loop with at least three distinct vertices. Individual faces with holes, non-manifold connectivity, booleans, subdivision and global self-intersection repair are outside M2.

Faces need not be coplanar. A face must have a nonzero Newell normal and a simple, nondegenerate projection onto its dominant normal plane. Triangulation uses that projection while preserving the original 3D positions and editable polygon loop. This permits bent quads and non-coplanar region selections without silently replacing polygons by triangles.

An edge has at most two incident faces; their edge directions must oppose. Each used vertex has one connected face fan: a cycle in the interior or a path on a boundary. Border half-edges have no face and form linked cycles. Duplicate face cycles, repeated vertices within a face, bow-tie vertices and inconsistent winding are rejected.

## Storage and stable handles

`half-edge-mesh` derives from `sgeo-object`. Its state contains indexed arenas of vertex, edge, face and half-edge records, generation counters, identity maps and a recursive mesh lock. A face retains its polygon loop as vertex indices, and half-edge records explicitly store origin, twin, next, previous, edge and face indices. Boundary twins and boundary cycles are stored explicitly.

Public `mesh-handle` values contain mesh identity, element kind, slot index and generation. The kinds are `:vertex`, `:edge`, `:face` and `:half-edge`. Handles from another mesh, an inactive slot, a different kind or an old generation signal `stale-handle-error`. Reusing an arena slot never makes an old handle valid again.

Unaffected vertices and faces retain their handles. An edge retains identity while its endpoints survive unchanged. A half-edge retains identity while its owning face and directed endpoints survive unchanged. Splitting removes the original edge; collapsing removes the discarded vertex and any faces that cease to have three vertices. Extrusion retains the selected face handles for the new cap faces.

Public reads return handles or defensive copies of numeric values and lists. Callers change topology through the mutation API, rather than editing arena records or returned arrays.

## Atomic mutation

An edit acquires the mesh lock, clones candidate state, performs the requested edit, rebuilds indexed connectivity, validates topology and geometry, then publishes the candidate. Invalid candidates never replace the current state. A successful edit advances the object's revision once; a rejected edit leaves topology, positions, generations and revision unchanged.

Render conversion captures one coherent state and revision under the same lock. The scene keeps the same `half-edge-mesh` instance, and the OpenGL cache uses geometry identity plus revision to replace only affected GPU buffers.

Invalidation observers run after the revision advances. An observer error produces a warning and other observers still run; it cannot turn a committed valid edit into an apparent rejected edit.

`geometry-error` extends the engine's `validation-error`. `topology-error` reports invalid connectivity or polygons; `stale-handle-error` reports invalid handles; `geometry-edit-error` reports rejected operation parameters or candidate edits. Conditions contain the engine's context and message fields.

## Public API

| Capability | Operations |
| --- | --- |
| Construction | `make-half-edge-mesh :positions :faces`, `make-half-edge-box`, `make-sphere`, `make-cylinder`, `make-grid`, `make-torus` |
| Element enumeration | `mesh-vertices`, `mesh-edges`, `mesh-faces`, `mesh-half-edges`, `mesh-counts` |
| Handle inspection | `handle-kind`, `handle-index`, `handle-generation`, `handle-mesh-id` |
| Positions and adjacency | `vertex-position`, `vertex-neighbors`, `vertex-edges`, `vertex-faces`, `face-vertices`, `face-half-edges`, `face-neighbors`, `edge-vertices`, `edge-half-edges` |
| Half-edge traversal | `half-edge-origin`, `half-edge-destination`, `half-edge-next`, `half-edge-previous`, `half-edge-twin`, `half-edge-edge`, `half-edge-face` |
| Boundaries and regions | `boundary-edge-p`, `boundary-half-edge-p`, `boundary-loops`, `connected-face-region` |
| Geometry queries | `face-normal`, `vertex-normal`, `face-area`, `mesh-surface-area`, `bounds`, `mesh-ray-intersection`, `closest-point-on-mesh` |
| Conversion | `triangulate-face`, `compile-render-data` |
| Mutation | `set-vertex-position`, `split-edge`, `collapse-edge`, `extrude-face`, `extrude-face-region` |
| Validation | `validate-mesh` |

`make-half-edge-mesh` takes a sequence of three-component position sequences and a sequence of polygon index sequences. It requires at least one valid face. Position indices in the constructor are zero-based; subsequent editing uses handles. `make-box` remains the M1 triangle-mesh constructor for compatibility; `make-half-edge-box` creates an editable polygon box.

`mesh-counts` reports active `:vertices`, `:edges`, `:faces`, `:half-edges` and `:boundary-edges`. Adjacency functions return lists of handles. `boundary-loops` returns lists of boundary half-edge handles. `half-edge-face` returns `nil` for a border. `connected-face-region` traverses edge adjacency and can restrict eligible faces with a predicate.

`triangulate-face` returns triples of vertex handles without editing the source face. `compile-render-data` returns the existing render-mesh protocol: flat double-float positions/normals, unsigned 32-bit indices and captured revision. Vertices are shared within each polygon and duplicated at polygon boundaries for flat shading. `render-mesh-source-faces` maps every rendered triangle to its polygon face handle. Triangulation is deterministic for the same polygon and positions, supports concavity and collinear boundary vertices, and emits nonzero-area triangles with the source winding.

`mesh-ray-intersection` returns distance, face handle and hit point, or `nil` on a miss. `closest-point-on-mesh` returns point, distance and face handle. Both operate on the triangulated surface while retaining polygon face identity.

## Modeling semantics

- `set-vertex-position` moves one vertex and validates the complete candidate mesh.
- `split-edge :parameter t` inserts one interpolated vertex with `0 < t < 1` into both incident polygon loops, or the single loop of a border edge. It returns the new vertex handle.
- `collapse-edge :keep vertex :position point` contracts to one endpoint, at the supplied position or the midpoint. It returns the surviving vertex handle. Adjacent repetitions are removed and faces with fewer than three vertices are retired. Candidates that violate the manifold, winding, duplicate-face or geometric contract are rejected; removing the last face is rejected.
- `extrude-face` is the single-face form of `extrude-face-region` and returns the retained cap face handle.
- `extrude-face-region` accepts unique, nonempty, edge-connected face handles. It duplicates each selected vertex once, replaces the selected faces with cap loops, and creates walls only along the region boundary. Internal selected edges produce no walls. Old interior vertices that become unused are retired. The operation returns the cap face handles.
- With `:offset`, extrusion applies one translation vector. Otherwise `:distance` offsets each selected vertex along its area-weighted selected-face normal. This defines non-coplanar region extrusion without duplicating vertices shared inside the region. Zero displacement, canceling normals or degenerate walls are rejected.

Primitive constructors validate finite positive dimensions and subdivision counts. A sphere shares seam vertices and has one vertex at each pole; `:segments` is at least three and `:rings` at least two. A cylinder uses at least three `:segments` and can be capped or open with `:capped-p`. The grid lies in XZ with +Y winding; `:columns` and `:rows` count vertices in each direction and are at least two. A torus has periodic connectivity, at least three `:segments` and `:sides`, and requires major radius greater than minor radius. The box has eight vertices and six quad faces; `:size` accepts one dimension or three dimensions.

## Verification and acceptance

Headless tests must cover:

- Closed box/sphere/cylinder, an open grid/cylinder, and a torus; Euler counts, outward winding and boundary cycles.
- Half-edge twin/next/previous consistency, vertex fans, adjacency and disconnected components.
- Non-manifold edges, bow-tie vertices, duplicate faces, inconsistent winding and invalid polygon rejection.
- Concave and collinear-boundary polygons, deterministic triangulation, normals, area, bounds, ray hits and closest points.
- Vertex moves, border/interior splits and eligible collapses; split/collapse round trips and invalid-candidate rollback.
- Single-face, connected coplanar/non-coplanar region and open-surface extrusion; shared region vertices and absence of internal walls.
- Stable surviving handles, stale removed handles, slot reuse, wrong-mesh handles and defensive read isolation.
- Coherent revision-driven render data and headless loading without foreign graphics packages.

The live demonstration creates one editable half-edge box, displays it through M1's viewport, edits vertices and edges, extrudes a face and a connected non-coplanar face region, and observes revision-driven GPU updates on the same Lisp geometry object. It redefines modeling behavior in the running image and recovers after a rejected edit. M3a adds GUI element selection and the full editor workflow.

## Technical references

The representation follows the orientable-surface incidence model described in the [CGAL half-edge documentation](https://doc.cgal.org/latest/HalfedgeDS/). Collapse eligibility is validated against this kernel's manifold contract; see the [CGAL simplification manual](https://doc.cgal.org/latest/Surface_mesh_simplification/) for the distinction between edge contraction and arbitrary vertex-pair contraction. CGAL is a reference, not a runtime dependency.
