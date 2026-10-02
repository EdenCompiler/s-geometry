# S-Geometry/CL

S-Geometry/CL is a live Common Lisp geometry environment. Lisp objects own scene and geometry state; OpenGL buffers are disposable caches derived from those objects. The native editor combines a polygon modeling viewport, scene inspector, integrated Lisp listener, undo/redo, and versioned scene files.

The first implementation targets Linux and SBCL, using `cl-glfw3`, `cl-opengl`, CFFI, and `cl-freetype2` for the editor's font atlas. Dependencies are chosen to fit this project's backend and UI needs; the Symbolics and kons-9 tradition is a design reference, not a dependency-matching requirement. The [historical S-Geometry summary](docs/original-s-geometry-summary.md) records the original system's broader context and the scope of this implementation. See the [architecture](docs/modern-s-geometry-design.md), [roadmap](docs/roadmap.md), [M0/M1 implementation evidence](docs/m0-m1-implementation.md), [M2 implementation evidence](docs/m2-implementation.md), and [M3 implementation evidence](docs/m3-implementation.md).

## Requirements

- SBCL with ASDF; verified with SBCL 2.5.2.
- ASDF-visible `bordeaux-threads` and `fiveam` systems.
- ASDF-visible `cl-glfw3`, `cl-opengl`, `cffi` and `cl-freetype2` systems for the viewport and editor font atlas.
- For the viewport, native GLFW and an OpenGL 3.3 core context with access to a Linux display.

The launch scripts load `~/quicklisp/setup.lisp` when present and locate this project from their own path. With Quicklisp, dependencies can be prepared in a Lisp session:

```lisp
(ql:quickload '(:bordeaux-threads :fiveam :cl-glfw3 :cl-opengl :cffi :cl-freetype2))
```

Loading `sgeo` and running the core tests requires no graphics libraries or display. The editor's headless command, transaction, inspector, listener, and persistence API is in `:sgeo/editor`; the native frontend is loaded separately as `:sgeo/editor/opengl`. This keeps core scene work independent of a graphics context.

## Run

From the project directory:

```bash
sbcl --script tools/run.lisp
```

This opens the M1 scene with a spinning shaded cube and a wireframe cube. Enter Lisp forms at the terminal's `sgeo>` prompt while the window remains active.

| Input | Action |
| --- | --- |
| Left mouse button | Select the nearest mesh under the cursor |
| Right mouse drag | Orbit the camera |
| Middle mouse drag | Pan the camera |
| Mouse wheel | Zoom |
| W | Toggle wireframe on the scene's materials |
| Escape or terminal `:quit` | Close the viewport |

Run the M2 editable box, the M0 triangle, or a finite unattended scene:

```bash
sbcl --script tools/run.lisp --kernel
sbcl --script tools/run.lisp --triangle
sbcl --script tools/run.lisp --frames 120 --no-repl --capture artifacts/example.ppm
```

`--hidden` creates a hidden graphics window; it still needs a graphics context and display. `--help` lists the launcher options. A finite run returns a nonzero process status if the runtime reports a platform or rendering failure.

Open the native M3 editor with the editable box, or load a saved scene:

```bash
sbcl --script tools/editor.lisp
sbcl --script tools/editor.lisp --open artifacts/editor-acceptance.sgeo
sbcl --script tools/editor.lisp --frames 120 --hidden --no-repl --capture artifacts/editor.ppm
```

The editor also accepts `--scene` to set the save path, `--width` and `--height` to change the window size, and `--help` to list all options. The integrated listener evaluates Lisp in the running image; `sg:*world*` and `sg:*selection*` refer to the live editor scene.

From an existing Lisp image, the exported facade can open the editor over a world:

```lisp
(asdf:load-system :sgeo/editor/opengl)
(sgeo.editor:open-editor (sgeo.scene:make-world))
```

Use `sgeo.editor:make-editor` and `sgeo.editor:execute-editor-command` for headless command-driven editing, transactions, inspection, and replay without loading the native frontend.

## Change the running world

The terminal listener evaluates in the same image as the viewport. `sg:*world*` is the running world and `sg:*selection*` is the selected live object. Multiline forms and standard REPL value/form history are supported; evaluation errors are printed and the scene continues running.

```lisp
(defparameter *cube* (sg:find-object sg:*world* "Cube"))
(sg:translate *cube* '(0 0.5d0 0))
(sg:set-material-color (sg:mesh-object-material *cube*) '(0.9d0 0.3d0 0.2d0))
(setf sg:*selection* *cube*)

(defun sgeo.examples:spin-rate () 0d0)
(defun sgeo.examples:spin-rate () -0.8d0)

(sg:set-mesh-position (sg:mesh-object-geometry *cube*) 0 '(-1d0 -0.85d0 -0.85d0))
```

Redefining `spin-rate` changes the existing cube's behavior without replacing its world, object, or geometry. Geometry edits validate their candidate data before publication; invalid edits preserve the prior valid mesh. Transform and color changes use existing GPU geometry buffers; geometry revisions trigger a new upload.

With `--kernel`, edit the existing polygon box through generation-checked handles:

```lisp
(defparameter *mesh* (sg:mesh-object-geometry
                     (sg:find-object sg:*world* "EditableBox")))
(defparameter *vertex* (first (sg:mesh-vertices *mesh*)))
(sg:set-vertex-position *mesh* *vertex*
                        (sg:v+ (sg:vertex-position *mesh* *vertex*) (sg:vec3 -0.1d0 0 0)))
(sg:split-edge *mesh* (first (sg:mesh-edges *mesh*)))
(defparameter *face* (first (sg:mesh-faces *mesh*)))
(sg:extrude-face *mesh* *face* :distance 0.3d0)
(sg:extrude-face-region *mesh* (list *face* (first (sg:face-neighbors *mesh* *face*)))
                        :distance 0.2d0)
(defun sgeo.examples:kernel-extrude-distance () 0.15d0)
(sgeo.examples:extrude-demo-face *mesh* *face*)
```

Surviving handles retain their identities; handles for removed elements signal `stale-handle-error`, including after their slots are reused. A rejected edit preserves geometry and revision. Constructors include `make-half-edge-box`, `make-sphere`, `make-cylinder`, `make-grid`, and `make-torus`; see the [kernel contract](docs/sgeo-geometry-kernel-spec.md) for queries and operation semantics.

## Load from an existing Lisp image

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo)
(defparameter *scene* (sg:make-world))
(sg:add-to-world *scene* (sg:make-mesh-object (sg:make-box) :name "Box"))

(asdf:load-system :sgeo/runtime)
(sg:run *scene* :repl t)
```

Call `sg:run` from the main thread. The native window and GPU context stay on that thread; the terminal listener uses a worker. Public scene mutations acquire the world's recursive lock, and mesh edits publish coherent state under a separate mesh lock. Group several scene operations with `sg:with-world-lock` when they must be seen together.

## Verify the core and rendering adapters

```bash
sbcl --script tools/test.lisp
sbcl --script tools/smoke.lisp
sbcl --script tools/kernel-smoke.lisp
```

The first command exercises math, identity, revision tracking, mesh validation, scene transforms, cameras, picking, redefinition, concurrent edits, half-edge topology, primitives, geometry queries, and modeling operations. It confirms that GLFW/OpenGL packages were not loaded. The second uses real GLFW/OpenGL contexts to verify triangle rendering, live mesh cache updates, picking, function redefinition, concurrent REPL execution, error recovery, and cleanup. It writes `artifacts/triangle.ppm` and `artifacts/live-scene.ppm`. The third edits the same live half-edge mesh over nine frames, verifies eight GPU uploads, recovers from an invalid edit, redefines modeling behavior, and writes `artifacts/kernel-scene.ppm`.

## Verify the M3 editor

The current headless suite passes 1,144 checks. CPU-only checks exercise gizmo drag/undo/cancel behavior and workspace sizing, visibility, clock controls, and profile samples:

```bash
sbcl --script tools/editor-gizmo-check.lisp
sbcl --script tools/editor-workspace-check.lisp
```

Run the native M3 first-release demonstration on a machine with a display and an OpenGL 3.3 context:

```bash
sbcl --script tools/editor-acceptance.lisp
```

The acceptance run completed 28 native frames, drove editor commands through the native frame loop, checked recovery and history behavior, used the integrated listener to redefine and apply an operation, saved a versioned scene, and started a fresh SBCL process to compare the reopened scene. The UI smoke passed 50 native frames plus popup recreation/capture checks, covering menus, views, numeric inspector edits, listener input, gizmo dragging, profile/debug/layout panels, resizing, and timeline controls. The dedicated selection test passed seven native frames, including viewport picking and listener-side topology-edit recovery:

```bash
sbcl --script tools/editor-ui-smoke.lisp
sbcl --script tools/editor-selection-native.lisp
```

The selection test checked object and visible vertex/edge/face picking, numeric editing of the selected vertex, edge split from Edit, face-region selection and Shift-click add/remove, plus worker-to-owner listener mutation and retired-edge cleanup with inspector fallback. The UI smoke wrote `artifacts/editor-ui.ppm`, `artifacts/editor-profile.ppm`, and `artifacts/editor-popup.ppm`. See [M3 implementation and verification](docs/m3-implementation.md) for test boundaries and scope.

## Scope

The M2 kernel supports orientable manifold solids and open surfaces. It preserves polygon faces while deriving triangulated render data; the M0/M1 triangle-mesh API remains available. Non-manifold topology, individual faces with holes, booleans, subdivision and global self-intersection repair remain outside this kernel's contract.
