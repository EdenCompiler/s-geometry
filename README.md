# S-Geometry/CL

S-Geometry/CL is a polygon modeling editor written in Common Lisp, inspired by [S-Geometry on the Symbolics Lisp machines](docs/original-s-geometry-summary.md).

You can work through the menus or through Lisp. Both use the same scene and meshes, so you can inspect an object, redefine an operation, and try it on the model you're already editing. The scene stays in the running Lisp image; graphics resources are rebuilt when it changes.

The editor currently targets Linux with SBCL. The geometry kernel handles orientable manifold solids and open surfaces.

## Run the editor

You'll need SBCL, Quicklisp, GLFW 3.3 or newer, FreeType, and an OpenGL 3.3 driver.

```bash
git clone https://github.com/EdenCompiler/s-geometry.git
cd s-geometry
sbcl --load tools/bootstrap.lisp --eval '(ql:quickload :sgeo/editor/opengl)' --quit
sbcl --script tools/run.lisp
```

The first SBCL command installs the Lisp dependencies. The launcher looks for Quicklisp at `~/quicklisp/setup.lisp`; if yours is elsewhere, load it explicitly:

```bash
sbcl --load /path/to/quicklisp/setup.lisp --script tools/run.lisp
```

The editor opens with a box ready to edit. `tools/editor.lisp` runs the same launcher.

## Editing

Choose objects, vertices, edges, faces, or face regions in the toolbar, then click in the viewport. The menus provide modeling operations such as edge splitting and face extrusion. The inspector lets you edit values directly. In region mode, Shift-click adds or removes faces from the selection.

| Control | Action |
| --- | --- |
| Alt + left drag | Orbit |
| Middle drag | Pan |
| Mouse wheel | Zoom |
| Right-click | Open the menu |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Ctrl+Enter | Evaluate listener input |

The viewport can switch between perspective, front, top, and side views. The File menu saves to `scene.sgeo` by default. To open a saved scene:

```bash
sbcl --script tools/run.lisp --open my-scene.sgeo
```

Use `--scene my-scene.sgeo` to set the save path for a new scene, or `--import model.glb` to import a glTF/GLB file. Run with `--help` for the remaining options.

## Working in Lisp

The listener below the viewport exposes the current scene as `sg:*world*` and the selection as `sg:*selection*`. For example, this moves the starting box and extrudes a face:

```lisp
(defparameter *box* (sg:find-object sg:*world* "EditableBox"))
(sg:translate *box* '(0 0.5d0 0))

(defparameter *mesh* (sg:mesh-object-geometry *box*))
(sg:extrude-face *mesh* (first (sg:mesh-faces *mesh*)) :distance 0.25d0)
```

These are the same operations the menus call. If an edit produces invalid geometry, the previous mesh is kept.

You can also start from an existing Lisp session:

```lisp
(load "/path/to/s-geometry/tools/bootstrap.lisp")
(asdf:load-system :sgeo/editor/opengl)
(sg:open-editor (sg:make-world))
```

Call `sg:open-editor` on the main thread. Load only `:sgeo` for geometry and scene work without a window.

## Examples

```bash
sbcl --script tools/animation-editor.lisp
sbcl --script tools/boids.lisp
sbcl --script tools/boids.lisp --packed
sbcl --script tools/game.lisp
```

The animation example opens an animated character in the editor. Tracks and keyframes are in Workspace → Timeline; see the [animation guide](docs/animation.md).

In the game, use WASD or the arrow keys to move, Space to jump, and E at the door after collecting two coins. P pauses and R restarts. `--audio` enables sound through OpenAL. The [simulation guide](docs/simulation.md) covers the game and both Boids implementations.

For the Vulkan PBR viewer, follow the setup in the [renderer notes](docs/m4-implementation.md), then run:

```bash
sbcl --dynamic-space-size 4096 --script tools/pbr-viewer.lisp
```

To build the game as a standalone application on Linux:

```bash
sbcl --load tools/bootstrap.lisp --eval "(ql:quickload '(:sgeo/assets/importers :sgeo/game/opengl))" --quit
sbcl --script tools/build.lisp --output artifacts/game/
./artifacts/game/sgeo-game
```

The build includes the game assets and runs without the editor or Quicklisp. See the [deployment guide](docs/deployment.md) for packaging and profiling options.

## Development

Install the test dependencies once, then run the headless suite:

```bash
sbcl --load tools/bootstrap.lisp --eval '(ql:quickload :sgeo/tests)' --quit
sbcl --script tools/test.lisp
```

The early scene demos are in `tools/demo.lisp`, with `--triangle` and `--kernel` options. Graphics checks are documented in the [editor notes](docs/m3-implementation.md).

The [roadmap](docs/roadmap.md) tracks completed work and what's still planned. The [architecture document](docs/modern-s-geometry-design.md) and [geometry-kernel specification](docs/sgeo-geometry-kernel-spec.md) describe the implementation.
