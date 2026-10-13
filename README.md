# S-Geometry/CL

S-Geometry/CL is a 3D modeler written in Common Lisp, inspired by [S-Geometry on the Symbolics Lisp machines](docs/original-s-geometry-summary.md).

The menus and the Lisp listener work on the same objects. You can move a vertex with the mouse, inspect the mesh in Lisp, redefine a function, and use it on that mesh without restarting the editor. Lisp objects hold the scene; the renderer builds its buffers from them.

The main development setup is Linux and SBCL. The polygon kernel supports orientable manifold solids and open surfaces. The [roadmap](docs/roadmap.md) records what is finished and what is still being built.

## Getting started

You'll need SBCL, Quicklisp, GLFW 3.3 or newer, FreeType with its development headers, and an OpenGL 3.3 driver.

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --load tools/bootstrap.lisp --eval '(ql:quickload :sgeo/editor/opengl)' --quit
sbcl --script tools/run.lisp
```

The first SBCL command installs the Lisp dependencies. The launcher loads Quicklisp from `~/quicklisp/setup.lisp`. If you keep it elsewhere:

```bash
sbcl --load /path/to/quicklisp/setup.lisp --script tools/run.lisp
```

`tools/run.lisp` opens the editor with a box ready to edit. `tools/editor.lisp` is an alias for it.

## In the editor

Choose a selection mode in the toolbar, then click an object, vertex, edge, or face in the viewport. Right-click opens the menus. You can split edges, extrude faces, edit values in the inspector, and undo your changes. In face-region mode, Shift-click adds or removes faces.

| Control | Action |
| --- | --- |
| Alt + left drag | Orbit |
| Middle drag | Pan |
| Mouse wheel | Zoom |
| Right-click | Open the menu |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Ctrl+Enter | Evaluate listener input |

Switch between perspective, front, top, and side views from the viewport controls. The File menu saves to `scene.sgeo` by default. To return to a saved scene:

```bash
sbcl --script tools/run.lisp --open my-scene.sgeo
```

`--scene my-scene.sgeo` sets the save path for a new scene; `--import model.glb` imports a glTF/GLB file. See `--help` for the other launcher options.

## Using Lisp

In the listener below the viewport, `sg:*world*` is the current scene and `sg:*selection*` is the current selection. This moves the starting box and extrudes one of its faces:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

The menus call these same operations. A rejected geometry edit leaves the previous mesh intact.

From an existing Lisp session:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Call `sg:open-editor` on the main thread. For geometry and scene work without a window, load `:sgeo` on its own.

## Other things to try

```bash
sbcl --script tools/advanced-editor.lisp
sbcl --script tools/animation-editor.lisp
sbcl --script tools/boids.lisp
sbcl --script tools/boids.lisp --packed
sbcl --script tools/game.lisp
```

The advanced geometry scene brings together subdivision, booleans, distance fields, curves, and procedural nodes. It needs OpenGL 4.3; the [geometry guide](docs/advanced-geometry.md) also shows how to use these tools from Lisp without a window.

The animation example opens a character in the editor, with tracks and keyframes under Workspace → Timeline. The [animation guide](docs/animation.md) explains how to work with them.

The [simulation guide](docs/simulation.md) covers the small game and the two Boids examples. There is also a [Vulkan PBR viewer](docs/m4-implementation.md) and a [standalone game build](docs/deployment.md).

## Development

Install the test dependencies once, then run the headless suite:

```bash
sbcl --load tools/bootstrap.lisp --eval '(ql:quickload :sgeo/tests)' --quit
sbcl --script tools/test.lisp
```

Graphics checks are described in the [editor notes](docs/m3-implementation.md). The early triangle and kernel demos are still available through `tools/demo.lisp`.

For the design and kernel internals, see the [architecture document](docs/modern-s-geometry-design.md) and [geometry-kernel specification](docs/sgeo-geometry-kernel-spec.md).
