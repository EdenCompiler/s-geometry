# Advanced geometry from Lisp

This guide covers the headless geometry APIs available after loading `:sgeo`. The examples use the public `sg:` facade and return ordinary editable half-edge meshes; they do not create a window or require a graphics device.

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo)
```

Replace the path with the checkout location. The API is also available from the editor listener after the editor system is loaded.

## Polygon editing

The half-edge mesh editor exposes transactional `sg:` operations. `sg:inset-face` preserves the selected face handle and adds a smaller inner face with a ring of quads. `sg:bevel-vertices` truncates selected vertices only when each has a closed manifold star; boundary vertices are rejected. Both operations validate the resulting mesh before publishing the edit.

```lisp
(let* ((inset-mesh (sg:make-half-edge-box :size 2d0))
       (face (first (sg:mesh-faces inset-mesh)))
       (inner (sg:inset-face inset-mesh face :fraction 0.2d0))
       (bevel-mesh (sg:make-half-edge-box :size 2d0))
       (caps (sg:bevel-vertices bevel-mesh
                                (list (first (sg:mesh-vertices bevel-mesh)))
                                :fraction 0.2d0)))
  (list (sg:face-vertices inset-mesh inner)
        (sg:mesh-counts inset-mesh)
        caps
        (sg:mesh-counts bevel-mesh)))
```

Other topology tools include `sg:split-face` (a diagonal between nonadjacent vertices of one face), `sg:triangulate-face` (returns triangles) and `sg:triangulate-mesh` (edits the mesh), `sg:flip-winding` (reverses all face cycles), and `sg:extract-connected-components` (copies edge-connected components into separate meshes). `sg:weld-vertices` takes a list of `(source . destination)` handle pairs and publishes only when the result remains manifold. `sg:bridge-boundary-loops` joins two disjoint oriented boundary loops with the same vertex count. `sg:duplicate-face-region` copies one connected face region by a nonzero offset.

Creation and deletion also respect the mesh domain: `sg:create-vertex` makes an isolated vertex and `sg:delete-vertex` removes only isolated vertices; `sg:create-face` requires ordered vertices that keep the mesh manifold; `sg:delete-face` cannot remove the last face and validates the remaining topology. Failed edits leave the previous mesh state intact.

## Subdivision

`sg:subdivide-mesh` returns a new half-edge mesh by default. Catmull–Clark accepts polygon faces of different sizes. Loop requires a triangular input, so triangulate a copy before using it. Both schemes apply boundary rules to open meshes as well as closed solids. Levels are limited to zero through eight.

```lisp
(let* ((box (sg:make-half-edge-box :size 2d0))
       (smooth (sg:subdivide-mesh box :scheme :catmull-clark))
       (triangles (sg:make-half-edge-box :size 2d0)))
  (sg:triangulate-mesh triangles)
  (list (sg:mesh-counts smooth)
        (sg:mesh-counts (sg:subdivide-mesh triangles :scheme :loop))))
```

Pass `:in-place t` to replace the input mesh while keeping its Lisp object identity. Replacement advances its revision and retires existing half-edge handles, so request fresh handles after an in-place operation.

## Boolean operations

`sg:csg-union`, `sg:csg-intersection`, and `sg:csg-difference` take closed, consistently oriented solid meshes. They return a new half-edge mesh, or `nil` when the result is empty. Open surfaces, boundary edges, inverted solids, and self-intersecting or overlapping input shells are rejected. Separate components may touch at a point or along an edge; positive-area coincident faces are not treated as a valid zero-volume contact.

```lisp
(let* ((outer (sg:make-half-edge-box :size 4d0))
       (inner (sg:make-half-edge-box :size 2d0))
       (shell (sg:csg-difference outer inner)))
  (list (sg:mesh-volume shell)
        (sg:mesh-counts shell)))
```

The shell has volume `56d0`: the inner box becomes a cavity. CSG validates solid inputs and the published result; point- or edge-contact unions can retain separate components. Identical subtraction and disjoint intersection return `nil`:

```lisp
(let* ((box (sg:make-half-edge-box :size 2d0))
       (distant (sg:make-half-edge-box :size 2d0)))
  (sg:set-vertex-positions
   distant (mapcar (lambda (vertex)
                     (cons vertex (sg:v+ (sg:vertex-position distant vertex)
                                         (sg:make-vec3 5d0 0d0 0d0))))
                   (sg:mesh-vertices distant))
  (list (sg:csg-difference box box)
        (sg:csg-intersection box distant)))
```

Use `:target` to publish a nonempty result back into an existing half-edge mesh. The target keeps its Lisp identity, its revision advances, and old element handles become stale. An empty result cannot replace a nonempty target; that call signals an error and leaves the target unchanged.

```lisp
(let* ((target (sg:make-half-edge-box :size 4d0))
       (cutter (sg:make-half-edge-box :size 2d0))
       (identity-before target))
  (sg:csg-difference target cutter :target target)
  (list (eq target identity-before) (sg:mesh-volume target)))
```

The Boolean predicates and polygon splitting use rational arithmetic derived from the input coordinates. Publication converts constructed vertices back to the kernel's double-precision coordinates and merges points within a scale-aware tolerance. Exact predicates improve intersection classification; the published result is still finite-precision geometry, and inputs must meet the solid contract above.

## Signed-distance fields

The field API includes sphere, box, torus, capsule, and plane fields. Union, intersection, difference, smooth union, and supported rigid or uniform-scale transforms compose into fields that can be sampled or meshed.

```lisp
(let* ((outer (sg:make-sphere-field :radius 1.25d0))
       (inner (sg:make-sphere-field :radius 0.5d0))
       (field (sg:make-difference-field outer inner))
       (mesh (sg:field->mesh field :resolution 14)))
  (list (sg:field-distance field (sg:make-vec3 0d0 0d0 0d0))
        (sg:mesh-counts mesh)))
```

`field->mesh` samples a regular finite grid and polygonizes the zero surface with a consistent tetrahedral decomposition. An integer resolution uses that many samples on each axis; a three-element resolution vector sets the dimensions independently. Bounded fields supply default bounds. Unbounded fields such as a plane need an explicit `:bounds` box:

```lisp
(let* ((field (sg:make-plane-field))
       (bounds (sg:make-aabb (sg:make-vec3 -1d0 -1d0 -1d0)
                             (sg:make-vec3 1d0 1d0 1d0))))
  (sg:field->mesh field :bounds bounds :resolution #(12 12 12)))
```

The output is an editable half-edge mesh. A closed field surface contained inside the bounds produces a closed mesh; if the bounds cut through the surface, the result has boundary edges at the grid boundary. Its shape approximates the field at the selected grid spacing: narrow features may disappear, and bounds must include the surface. Increase resolution or adjust bounds when the output does not capture the intended feature. A grid with no zero-surface crossing signals a validation error.

Primitive parameters are authoritative Lisp data. Change them with `sg:set-field-parameter`; compound fields track their dependencies and advance revisions when a child changes.

## Curves and surfaces

Polyline, Bézier, and nonrational B-spline curves evaluate on the normalized parameter interval `[0,1]`. `sg:curve-derivative` returns the derivative, and `sg:curve-tangent` normalizes it when nonzero. B-splines accept an optional knot vector. Control points are editable with `sg:set-curve-control-point`, which advances the curve revision.

```lisp
(let* ((curve (sg:make-bezier-curve
               #(#(0d0 0d0 0d0) #(1d0 0d0 0d0) #(1d0 1d0 0d0))))
       (point (sg:curve-point curve 0.5d0))
       (derivative (sg:curve-derivative curve 0.5d0)))
  (list point derivative))
```

This nonrational quadratic B-spline has one internal knot. The same control-point setter works for polylines, Bézier curves, and B-splines; each edit advances the curve revision.

```lisp
(let ((curve (sg:make-bspline-curve
              #(#(0d0 0d0 0d0) #(1d0 0d0 0d0)
                #(1d0 1d0 0d0) #(2d0 1d0 0d0))
              :degree 2 :knots #(0d0 0d0 0d0 0.5d0 1d0 1d0 1d0))))
  (sg:set-curve-control-point curve 1 #(1d0 0.25d0 0d0))
  (list (sg:curve-point curve 0.5d0)
        (sg:curve-derivative curve 0.5d0)))
```

Parametric surfaces can be sampled or tessellated; Bézier surfaces use a control grid. Tessellation returns an editable half-edge patch. The surface need not be closed, so a tessellated patch is not automatically a solid.

```lisp
(let* ((grid (make-array '(2 2) :initial-contents
                         (list (list #(0d0 0d0 0d0) #(0d0 1d0 0d0))
                               (list #(1d0 0d0 0d0) #(1d0 1d0 0d0)))))
       (surface (sg:make-bezier-surface grid))
       (parametric (sg:make-parametric-surface
                    (lambda (u v)
                      (sg:make-vec3 (- (* 2d0 u) 1d0)
                                    (- (* 2d0 v) 1d0)
                                    (* 0.2d0 (sin (* pi u)) (sin (* pi v))))))))
  (sg:set-surface-control-point surface 1 1 #(1d0 1d0 0.25d0))
  (list (sg:tessellate-surface surface :u-segments 12 :v-segments 8)
        (sg:tessellate-surface parametric :u-segments 12 :v-segments 8)))
```

`sg:sweep-curve` carries a closed 2D profile along a curve and returns an editable mesh with open ends. `sg:lathe-surface` revolves a `(radius, z)` profile around the Z axis; poles on the axis are welded to avoid degenerate rings.

```lisp
(let* ((path (sg:make-polyline-curve #(#(0d0 0d0 0d0) #(0d0 0d0 2d0))))
       (square #(#(-0.5d0 -0.5d0) #(0.5d0 -0.5d0)
                 #(0.5d0 0.5d0) #(-0.5d0 0.5d0)))
       (sweep (sg:sweep-curve path square :path-segments 16))
       (turned (sg:lathe-surface #(#(0d0 0d0) #(1d0 0d0)
                                   #(1d0 1d0) #(0d0 1d0))
                                 :segments 24)))
  (list (sg:mesh-counts sweep) (sg:mesh-counts turned)))
```

These APIs do not include NURBS. B-spline curves are polynomial rather than rational; the current surface options are parametric callbacks and Bézier control grids.

## Procedural graphs and the node editor

A dependency graph stores parameter nodes and named generator nodes. Evaluation is on demand and cached. Changing a value invalidates its consumers; failed regeneration keeps the last valid mesh and records the error. Define reusable generators in Lisp, then add them to a graph:

```lisp
(sg:define-geometry-generator guide-box ()
  (sg:make-half-edge-box :size (gethash "size" dependencies)))

(let* ((graph (sg:make-dependency-graph)))
  (sg:add-parameter-node graph :size 2d0)
  (sg:add-generator-node graph :mesh 'guide-box '(:size))
  (sg:evaluate-node graph :mesh))
```

To attach a graph to a scene object, use `sg:make-procedural-object` with the graph and output node. In the editor, select that object and open the Procedural Nodes workspace. It displays node cards and their connections, lets you edit parameters, evaluate the output, and rewire generator inputs. These edits use the editor's undo and redo transactions.

Scene persistence is provided by the separate `:sgeo/serialization` system. Load it before calling `sgeo.serialization:save-world` or `sgeo.serialization:load-world`:

```lisp
(asdf:load-system :sgeo/serialization)
(sg:define-geometry-generator saved-box ()
  (sg:make-half-edge-box :size (gethash "size" dependencies)))

(let* ((graph (sg:make-dependency-graph))
       (path #p"/tmp/sgeo-procedural-example.sgeo"))
  (sg:add-parameter-node graph :size 2d0)
  (sg:add-generator-node graph :mesh 'saved-box '(:size))
  (let* ((object (sg:make-procedural-object graph :mesh))
         (world (sg:make-world :root object)))
    (unwind-protect
         (progn
           (sgeo.serialization:save-world world path)
           (sgeo.serialization:load-world path))
      (when (probe-file path) (delete-file path)))))
```

The file stores inert graph data and the current geometry snapshot. It does not save or evaluate Lisp functions. On load, generator names resolve against definitions registered in the running Lisp image. If a generator is unavailable, the saved mesh remains visible as frozen geometry and the missing node reports an error; editing the graph requires that generator to be registered again.

## OpenGL compute processing

The headless `:sgeo` API includes the geometry-processing protocol, but `:opengl` processing requires an active OpenGL 4.3 context with compute shaders and shader-storage buffers. Query `sgeo.geometry-processing:processor-capabilities` for `:opengl` inside that context before calling `process-geometry`.

The current OpenGL processor applies scale and translation and can add a sine-wave deformation. Its shader buffers use 32-bit floats. Results are read back, checked for finite positions and unit normals, and committed to the authoritative CPU mesh only if its revision has not changed during processing. The returned/cache normals are tied to that published revision and become stale after later mesh edits. The GPU path does not run CSG, subdivision, field meshing, or curve/surface tessellation; those remain CPU operations.

```lisp
;; Run only with an initialized OpenGL 4.3 context and the OpenGL backend loaded.
(let* ((mesh (sg:make-half-edge-box :size 2d0))
       (caps (sgeo.geometry-processing:processor-capabilities :opengl)))
  (when (sgeo.geometry-processing:capabilities-supported-p caps)
    (sgeo.geometry-processing:process-geometry
     :opengl mesh :scale #(1d0 1d0 1d0) :translation #(0d0 0d0 0d0)
     :amplitude 0.1d0 :frequency 2d0 :phase 0d0)))
```

GPU results therefore have float32 precision even though the CPU mesh stores double-precision coordinates. The CPU revision and validation checks govern publication; GPU output is a derived calculation, not a separate authoritative copy.
