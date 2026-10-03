# S-Geometry/CL

S-Geometry/CL is a Common Lisp 3D modeler inspired by the polygon editor and database of the original Symbolics S-Geometry.

The idea is to keep modeling and programming close together. Select a face in the editor, inspect its mesh in the listener, then write a function to change it. Both work with the same Lisp objects, so you can redefine that function and keep using the scene you already have open.

There's a working editor with polygon modeling, perspective and orthographic views, an inspector, undo/redo, and scene saving. The geometry kernel uses half-edge topology and supports orientable manifold solids and open surfaces. Development is on Linux with SBCL; the current editor uses OpenGL.

## Run it

You'll need SBCL, ASDF, GLFW, FreeType, and a display with OpenGL 3.3 support. The project is developed with SBCL 2.5.2. With Quicklisp installed, load the dependencies once:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cl-opengl :cffi :cl-freetype2 :fiveam))
```

Clone the repository and open the editor:

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --script tools/run.lisp
```

`tools/run.lisp` loads `~/quicklisp/setup.lisp` when it's available and opens an editable box. `tools/editor.lisp` runs the same launcher.

## A first edit

Use the toolbar to choose object, vertex, edge, face, or region selection, then click in the viewport. The menus provide modeling operations, and the inspector lets you edit numeric values. For a face region, Shift-click adds or removes faces.

Alt + left drag orbits the camera, middle drag pans, and the wheel zooms. Right-click opens the context menu. Ctrl+Z and Ctrl+Y undo and redo edits.

The File menu saves to `scene.sgeo` by default. To use another path or reopen a saved scene:

```bash
sbcl --script tools/run.lisp --scene my-scene.sgeo
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Other launcher options, including window size and frame capture, are listed by `sbcl --script tools/run.lisp --help`.

## Use the listener

The listener at the bottom of the editor evaluates Lisp in the running image. Enter adds a line; Ctrl+Enter evaluates the input. `sg:*world*` is the current world, and `sg:*selection*` is the selected object.

For example, move the default box and extrude one of its faces:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

These are the same operations used by the editor. You can put them in your own functions, redefine those functions, and apply them to the existing mesh. A failed geometry edit leaves the last valid mesh intact.

To start from an existing Lisp session, replace the path below with your checkout:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Call `open-editor` from the main thread. For geometry work without a window, load `:sgeo`. Editor commands and scene persistence are available through `:sgeo/editor`.

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

There are also standalone scene examples:

```bash
sbcl --script tools/demo.lisp
sbcl --script tools/demo.lisp --triangle
sbcl --script tools/demo.lisp --kernel
```

The [editor implementation notes](docs/m3-implementation.md) describe what the checks cover.

## Where the project is going

The basic editor and geometry kernel are in place. Shader Lisp and a Vulkan renderer are the next milestone; animation, simulation, and more modeling operations follow. The [roadmap](docs/roadmap.md) tracks what's finished and what's still ahead.

For more detail, see the [design document](docs/modern-s-geometry-design.md) and [geometry-kernel specification](docs/sgeo-geometry-kernel-spec.md). The [original S-Geometry summary](docs/original-s-geometry-summary.md) describes the system that inspired this project.
