# S-Geometry/CL

S-Geometry/CL is a 3D modeling environment written in Common Lisp, inspired by the original Symbolics S-Geometry.

The editor and Lisp listener work on the same objects. You can move a vertex, inspect a mesh, or redefine a modeling function while the window is open. Changes appear in the viewport without reloading the scene.

The project has a polygon geometry kernel, a scene editor, undo/redo, and scene files you can save and reopen. Development is on Linux with SBCL. The renderer currently uses OpenGL.

## Getting started

You'll need SBCL, ASDF, native GLFW and FreeType libraries, and a display with OpenGL 3.3 support. SBCL 2.5.2 is the version used for development.

With Quicklisp installed, load the Lisp dependencies:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cl-opengl :cffi :cl-freetype2 :fiveam))
```

Then, from a terminal:

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --script tools/run.lisp
```

The launcher loads `~/quicklisp/setup.lisp` if it exists. It opens the editor with an editable box.

## Using the editor

Select objects or mesh elements in the viewport, then use the menus or inspector to edit them. The toolbar switches between object, vertex, edge, face, and face-region selection. In region mode, Shift-click adds or removes faces.

| Input | Action |
| --- | --- |
| Left click | Select an object or mesh element |
| Right click | Open the context menu |
| Alt + left drag | Orbit the camera |
| Middle drag | Pan |
| Mouse wheel | Zoom |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Ctrl+Enter | Evaluate the listener input |

The File menu saves to `scene.sgeo` by default. You can choose the scene path at launch or open a saved file:

```bash
sbcl --script tools/run.lisp --scene my-scene.sgeo
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Run `sbcl --script tools/run.lisp --help` for the window size, capture, and other options. `tools/editor.lisp` is an alias for the same launcher.

## Working from Lisp

The listener has access to the current world through `sg:*world*` and the selected object through `sg:*selection*`. Enter inserts a new line; Ctrl+Enter evaluates the form.

Try this after opening the default scene:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

You can define your own functions around these operations and change them as you work. The mesh stays in the scene, and later calls use the new definition.

To open the editor from an existing Lisp session, use your checkout's path:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Call `open-editor` from the main thread. For geometry work without a window, load `:sgeo`; the editor's commands and persistence API are available in `:sgeo/editor`.

## Examples and tests

The standalone examples have their own launcher:

```bash
sbcl --script tools/demo.lisp
sbcl --script tools/demo.lisp --triangle
sbcl --script tools/demo.lisp --kernel
```

Run the core tests with:

```bash
sbcl --script tools/test.lisp
```

These tests run without a display. The native editor checks need a display and an OpenGL context:

```bash
sbcl --script tools/editor-acceptance.lisp
sbcl --script tools/editor-ui-smoke.lisp
sbcl --script tools/editor-selection-native.lisp
```

The [implementation notes](docs/m3-implementation.md) describe the checks in more detail.

## Project notes

The kernel supports manifold solids and open surfaces, with editable polygon faces and half-edge topology. Booleans, subdivision, animation, and a Vulkan renderer are planned.

See the [roadmap](docs/roadmap.md) for current progress, the [design document](docs/modern-s-geometry-design.md) for the broader architecture, and the [kernel specification](docs/sgeo-geometry-kernel-spec.md) for geometry details. The [original S-Geometry summary](docs/original-s-geometry-summary.md) records the historical reference behind the project.
