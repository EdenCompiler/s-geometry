# S-Geometry/CL

S-Geometry/CL is a 3D editor written in Common Lisp, inspired by [the original S-Geometry for Symbolics Lisp machines](docs/original-s-geometry-summary.md).

The idea is to keep modeling and programming close together. The mesh you see in the viewport is a Lisp object you can inspect and change. Move a vertex with the mouse, try an operation in the listener, or redefine a function and apply it to the scene you already have open. The renderer gets its data from those objects.

The project is under development, with Linux and SBCL as the current target. The polygon kernel handles orientable manifold solids and open surfaces. See the [roadmap](docs/roadmap.md) for progress and remaining work.

## Opening the editor

Install SBCL, Quicklisp, GLFW 3.3 or newer, and FreeType. Your graphics driver needs OpenGL 3.3 support. With Quicklisp loaded in SBCL, install the Lisp dependencies:

```lisp
(ql:quickload '(:bordeaux-threads :cl-glfw3 :cl-opengl :cffi :cl-freetype2 :yason :fiveam))
```

Clone the repository and start it:

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --script tools/run.lisp
```

You'll get the editor with a box ready to edit. The launcher loads `~/quicklisp/setup.lisp` when available. `tools/editor.lisp` opens the same editor.

## Working with a scene

Pick a selection mode in the toolbar—objects, vertices, edges, faces, or face regions—then click in the viewport. Use the menus to split edges or extrude faces, and the inspector to change values. Shift-click adds or removes faces in region mode. The view can be switched between perspective, front, top, and side.

| Control | Action |
| --- | --- |
| Alt + left drag | Orbit |
| Middle drag | Pan |
| Mouse wheel | Zoom |
| Right-click | Open the menu |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Ctrl+Enter | Evaluate listener input |

In the listener below the viewport, `sg:*world*` is the current scene and `sg:*selection*` is the current selection. Try moving the starting box and extruding one of its faces:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

These are the same operations the menus call. If an edit produces invalid geometry, the mesh keeps its previous state and you can carry on editing.

The File menu saves to `scene.sgeo` by default. You can choose a different save path at startup, or open an existing scene:

```bash
sbcl --script tools/run.lisp --scene my-scene.sgeo
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Other launcher options are listed by `sbcl --script tools/run.lisp --help`.

## Using your own Lisp session

To open the editor from an existing image:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Replace the path with your checkout and call `sg:open-editor` on the main thread. For geometry work without a window, load just `:sgeo`.

## Examples

The editor can import glTF and GLB scenes. Animation clips and keyframes are available in Workspace → Timeline. To import a model or open the included animated character:

```bash
sbcl --script tools/run.lisp --import model.glb
sbcl --script tools/animation-editor.lisp
```

The [animation guide](docs/animation.md) covers tracks, skeletons, blending, and import/export.

For something different, there are two Boids implementations and a small game:

```bash
sbcl --script tools/boids.lisp
sbcl --script tools/boids.lisp --packed
sbcl --script tools/game.lisp
```

In the game, move with WASD or the arrow keys, jump with Space, and press E near the door after collecting two coins. P pauses and R restarts. Add `--audio` for sound; it requires OpenAL. The [simulation guide](docs/simulation.md) describes the APIs behind these examples.

There is also a Vulkan viewer with PBR materials, shadows, and shaders written in Lisp:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp
```

It has additional dependencies; see the [renderer notes](docs/m4-implementation.md).

## Development

Run the tests without a display:

```bash
sbcl --script tools/test.lisp
```

`tools/demo.lisp` opens the early scene demos. Use `--triangle` or `--kernel` to select one. The [editor notes](docs/m3-implementation.md) describe the checks that need a graphics context.

The [design document](docs/modern-s-geometry-design.md) explains the architecture. The [geometry-kernel specification](docs/sgeo-geometry-kernel-spec.md) covers mesh storage, editing rules, and topology.
