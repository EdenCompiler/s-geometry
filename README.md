# S-Geometry/CL

A Common Lisp 3D modeler inspired by [S-Geometry on the Symbolics Lisp machines](docs/original-s-geometry-summary.md).

The editor and the Lisp listener work on the same scene. You can move a vertex in the viewport, inspect its mesh in Lisp, redefine an operation, and use it on the object that's already there. Geometry lives in Lisp objects; the renderer builds its buffers from them.

This is still a project in development. Linux and SBCL are the current target. The [roadmap](docs/roadmap.md) tracks what's finished and what's left to build.

## Run it

You'll need SBCL, Quicklisp, GLFW 3.3 or newer, FreeType, and OpenGL 3.3. At a Lisp prompt with Quicklisp loaded:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cl-opengl :cffi :cl-freetype2 :yason :fiveam))
```

Then:

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --script tools/run.lisp
```

That opens the editor with a box ready to edit. The launcher loads `~/quicklisp/setup.lisp` if it exists. `tools/editor.lisp` is an alias for the same launcher.

## A few things to try

Choose objects, vertices, edges, faces, or face regions in the toolbar, then click in the viewport. The menus offer modeling operations; the inspector lets you change values. In face-region mode, Shift-click adds or removes faces. You can switch between perspective, front, top, and side views.

| Control | Action |
| --- | --- |
| Alt + left drag | Orbit |
| Middle drag | Pan |
| Mouse wheel | Zoom |
| Right-click | Open the menu |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Ctrl+Enter | Evaluate listener input |

The listener below the viewport has `sg:*world*` and `sg:*selection*` available. For example:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

The menus call these same Lisp operations. A rejected geometry edit leaves the mesh in its last valid state.

The File menu saves to `scene.sgeo` by default. To use another path or reopen a scene:

```bash
sbcl --script tools/run.lisp --scene my-scene.sgeo
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Run `sbcl --script tools/run.lisp --help` for the other options.

## From a Lisp session

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Use your checkout's path and start the editor on the main thread. If you only need geometry, load `:sgeo`; it works without a window. The kernel supports orientable manifold solids and open surfaces.

## Other parts of the project

The editor can import glTF and GLB files, play animation clips, and edit their keys in Workspace → Timeline:

```bash
sbcl --script tools/run.lisp --import model.glb
sbcl --script tools/animation-editor.lisp
```

The second command opens a small rigged character. See the [animation guide](docs/animation.md) for tracks, skeletons, blending, and import/export details.

There are also Boids and a small coin-collecting game. Both run in the same live Lisp environment:

```bash
sbcl --script tools/boids.lisp
sbcl --script tools/boids.lisp --packed
sbcl --script tools/game.lisp
```

In the game, use WASD or the arrow keys to move, Space to jump, and E to open the door after collecting two coins. P pauses and R restarts. Add `--audio` for sound through OpenAL. The [simulation guide](docs/simulation.md) explains the input, physics, events, and audio APIs.

The editor uses OpenGL. A separate Vulkan viewer has PBR materials, shadows, and Lisp-authored shaders:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp
```

Check the [renderer notes](docs/m4-implementation.md) for its additional dependencies.

## Tests and documentation

The main suite runs without a display:

```bash
sbcl --script tools/test.lisp
```

`tools/demo.lisp` runs the scene examples; `--triangle` and `--kernel` select the smaller demos. Native editor checks are described in the [editor notes](docs/m3-implementation.md).

For the internals, start with the [design document](docs/modern-s-geometry-design.md) or the [geometry-kernel specification](docs/sgeo-geometry-kernel-spec.md).
