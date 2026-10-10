# S-Geometry/CL

S-Geometry/CL is a 3D modeler written in Common Lisp, inspired by [S-Geometry on the Symbolics Lisp machines](docs/original-s-geometry-summary.md). It brings polygon editing and Lisp programming into the same environment.

You can select vertices, edges, and faces in the viewport, then edit them through the menus or the Lisp listener. Both work on the same objects. Redefine a modeling function while the editor is running and try it on the mesh already in front of you.

The project is under development on Linux with SBCL. The [roadmap](docs/roadmap.md) records what's working and what comes next.

## Getting started

You'll need SBCL, Quicklisp, GLFW, FreeType, and a display with OpenGL 3.3 support. The development environment uses SBCL 2.5.2. At a Lisp prompt with Quicklisp loaded, install the dependencies:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cl-opengl :cffi :cl-freetype2 :yason :fiveam))
```

Then clone the repository and start the editor:

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --script tools/run.lisp
```

You'll get a box to start editing. The launcher loads `~/quicklisp/setup.lisp` when present; `tools/editor.lisp` opens the same editor.

## In the editor

Use the toolbar to choose what you're selecting: objects, vertices, edges, faces, or face regions. Click in the viewport, then choose an operation from the menus or edit a value in the inspector. In face-region mode, Shift-click adds or removes faces. Perspective, front, top, and side views are available.

| Action | Control |
| --- | --- |
| Orbit | Alt + left drag |
| Pan | Middle drag |
| Zoom | Mouse wheel |
| Open the context menu | Right-click |
| Undo / redo | Ctrl+Z / Ctrl+Y |
| Evaluate listener input | Ctrl+Enter |

The File menu saves to `scene.sgeo` by default. You can choose a different save path at startup, or reopen a scene:

```bash
sbcl --script tools/run.lisp --scene my-scene.sgeo
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Other startup options are listed by `sbcl --script tools/run.lisp --help`.

## Working in Lisp

The listener at the bottom of the editor has access to the running world through `sg:*world*` and the selected object through `sg:*selection*`. Enter adds a line; Ctrl+Enter evaluates the input.

For example, this moves the starting box and extrudes a face:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

These are the same operations the editor calls. If a geometry edit fails, the mesh keeps its last valid state.

You can also open the editor from an existing Lisp session:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Replace `/path/to/s-geometry` with your checkout and call `open-editor` from the main thread. For geometry work without a window, load `:sgeo`. The kernel handles orientable manifold solids and open surfaces.

## Animation and rendering

To open a glTF or GLB model in the editor:

```bash
sbcl --script tools/run.lisp --import model.glb
```

Workspace → Timeline lets you play clips, scrub through poses, and edit keys. The animation and geometry share the editor's undo history and scene files. There's a small rigged character to try:

```bash
sbcl --script tools/animation-editor.lisp
```

The [animation guide](docs/animation.md) covers tracks, blending, skeletons, and glTF import and export.

The editor uses OpenGL. A separate Vulkan viewer has PBR materials, shadows, and shaders written in Lisp. See the [renderer notes](docs/m4-implementation.md) for its dependencies before running:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp
```

## Tests and examples

Run the tests without a display:

```bash
sbcl --script tools/test.lisp
```

The scene examples have their own launcher:

```bash
sbcl --script tools/demo.lisp
sbcl --script tools/demo.lisp --triangle
sbcl --script tools/demo.lisp --kernel
```

For native editor checks, see the [editor notes](docs/m3-implementation.md). The [design document](docs/modern-s-geometry-design.md) describes the architecture, and the [kernel specification](docs/sgeo-geometry-kernel-spec.md) covers mesh storage and editing rules.
