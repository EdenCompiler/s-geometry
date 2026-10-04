# S-Geometry/CL

S-Geometry/CL is a 3D modeling environment written in Common Lisp, inspired by Symbolics' S-Geometry.

You can build and edit polygon meshes through the editor, through Lisp, or with a mixture of both. The viewport and listener share the same objects: a mesh you select on screen is the mesh your Lisp code changes. You can redefine a modeling function and try it on that mesh without reopening the scene.

The editor has perspective and orthographic views, vertex/edge/face selection, an inspector, undo and redo, and scene saving. The geometry kernel supports orientable manifold solids and open surfaces.

Development is on Linux with SBCL. The editor uses OpenGL. A separate Vulkan viewer supports PBR materials, shadows, and shaders written in Lisp. The [roadmap](docs/roadmap.md) records what's finished and what's still planned.

## Run it

You'll need SBCL, Quicklisp, the GLFW and FreeType shared libraries, and a display with OpenGL 3.3 support. Development currently uses SBCL 2.5.2. With Quicklisp loaded at the SBCL prompt, install the Lisp dependencies:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cl-opengl :cffi :cl-freetype2 :fiveam))
```

Clone the repository and open the editor:

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --script tools/run.lisp
```

The editor opens with an editable box. The launcher loads `~/quicklisp/setup.lisp` if it exists. `tools/editor.lisp` is an alias for the same launcher.

For the Vulkan viewer, see the [shader and renderer notes](docs/m4-implementation.md) for dependencies, then run:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp
```

## In the editor

Choose object, vertex, edge, face, or region selection in the toolbar, then click in the viewport. Modeling operations are in the menus; numeric values can be edited in the inspector. Shift-click adds or removes faces from a region selection.

Alt + left drag orbits the camera, middle drag pans, and the wheel zooms. Right-click opens the context menu. Ctrl+Z and Ctrl+Y undo and redo edits.

The File menu saves to `scene.sgeo` by default. To use another path or reopen a saved scene:

```bash
sbcl --script tools/run.lisp --scene my-scene.sgeo
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Run `sbcl --script tools/run.lisp --help` for the other launcher options.

## Working in Lisp

The listener at the bottom of the editor evaluates Lisp in the running image. Enter adds a line and Ctrl+Enter evaluates the input. `sg:*world*` holds the current world; `sg:*selection*` holds the selected object.

For example, move the default box and extrude one of its faces:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

The editor uses these same operations. A failed geometry edit leaves the last valid mesh intact, so you can correct the call and keep working.

To start from an existing Lisp session, replace the path below with your checkout:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Call `open-editor` from the main thread. Load `:sgeo` for geometry work without a window, or `:sgeo/editor` for editor commands and scene persistence without the graphical interface.

## Tests and examples

The core tests run without a display:

```bash
sbcl --script tools/test.lisp
```

The editor checks need a display and an OpenGL context:

```bash
sbcl --script tools/editor-acceptance.lisp
sbcl --script tools/editor-ui-smoke.lisp
sbcl --script tools/editor-selection-native.lisp
```

To run the scene examples:

```bash
sbcl --script tools/demo.lisp
sbcl --script tools/demo.lisp --triangle
sbcl --script tools/demo.lisp --kernel
```

The [editor implementation notes](docs/m3-implementation.md) describe what the checks cover. For the internals, see the [design document](docs/modern-s-geometry-design.md) and [geometry-kernel specification](docs/sgeo-geometry-kernel-spec.md). The [original S-Geometry summary](docs/original-s-geometry-summary.md) gives some background on the system that inspired this project.
