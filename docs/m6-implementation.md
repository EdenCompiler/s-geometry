# M6 — Input, simulation, physics, audio, and game examples

M6 adds optional headless services around the existing scene model. A world can opt into input, a fixed-step simulation clock, event dispatch, a scheduler, a spatial index, primitive rigid-body physics, debug drawing, and offline audio without creating a window or loading OpenGL/Vulkan. The services keep references to existing scene objects; they do not replace scene transforms or require visual meshes for collision bodies.

The milestone implementation is organized as follows:

| Area | Implementation |
| --- | --- |
| Input | Semantic maps for keys, mouse buttons, gamepad buttons/axes, contexts and rebinding; frame-stable pressed/released edges; focus-loss release. |
| Simulation | Optional per-world state, fixed-step accumulator, maximum catch-up steps, pause state, ordered phases, extensible scene-object fixed updates, simulation-time task scheduler. |
| Events | Queued event bus with stable priority ordering, one-shot subscriptions, snapshot dispatch and captured handler errors; physics contact callbacks feed the simulation bus. |
| Spatial index | Uniform grid for enabled scene-object AABBs, exact AABB filtering, overflow path for large bounds, ray-AABB results ordered by distance. |
| Physics | Spheres, oriented boxes and Y-axis capsules; world-transform-aware contacts, overlap/raycast/AABB queries, force and impulse integration, restitution/friction and positional correction, trigger events. |
| Debug drawing | Transient line, ray, AABB, sphere and bitmap-text commands batched by color and converted to renderer triangles. |
| Audio | PCM buffers, tones, forward-only streams, scene-attached sources/listeners, buses/effects, positional offline stereo mixer and WAV export. OpenAL output is optional. |
| Boids | Separation/alignment/cohesion demo in object-backed and flat-vector packed CPU modes. |
| Game | 3D coin-and-door demo with a dynamic player, trigger collectibles, jump and movement input, door animation, pause/restart, debug display and optional sound output. |

## Systems and entry points

`sgeo/physics`, `sgeo/input`, `sgeo/audio`, `sgeo/debug`, and `sgeo/simulation` are ASDF systems that can be loaded without the graphics runtime. `sgeo/examples/simulation` adds the Boids and game source without loading OpenGL; `sgeo/examples/simulation/opengl` adds the graphical launcher dependency. The scene package stays independent of these optional extensions.

The main launchers are:

```bash
sbcl --script tools/boids.lisp
sbcl --script tools/boids.lisp --packed --count 256
sbcl --script tools/game.lisp
sbcl --script tools/game.lisp --audio
```

Both accept `--hidden`, `--no-repl`, `--frames N`, and `--capture path.ppm`; Boids accepts `--count N` and `--packed`; the game accepts `--audio`. The default launcher opens a normal game mixer without an audio-device side effect. The launcher opens the optional OpenAL system and submits simulation PCM only for `--audio`. `run-boids` and `run-game` resolve the graphical runtime at invocation time, so loading the headless examples does not require the runtime package to be present.

See the [simulation guide](simulation.md) for API examples and the actual runtime behavior. The [roadmap](roadmap.md) records milestone scope; this note records implementation, checks, and limits.

## Fixed-step and transform contract

`attach-simulation` stores a state on the world and defaults to a 1/60-second step with eight catch-up steps per frame. It preserves time debt beyond the per-frame cap. Input edges are captured before `:pre-update`; fixed-step hooks and object methods run before physics; `:post-physics` and event dispatch follow each physics step. Variable update, scene animation, spatial refresh, audio rendering and `:post-update` then run once per frame. Pausing stops fixed time and evaluates animation at zero elapsed time while allowing variable frame hooks and audio extraction.

The physics world is separately constructed and optionally attached to the simulation. A rigid body references a scene object; its world transform is read for collision queries, and dynamic integration writes the world-space position back through the object's parent. Transform bases with shear are rejected. Boxes allow non-uniform scale and rotation; spheres/capsules require uniform world scale. Capsules are aligned to local Y.

The collision narrow phase covers all sphere/box/capsule pairings. Box-box uses the OBB separating-axis theorem. Capsule-box minimizes segment-to-box distance with a fixed bounded ternary search. The solver integrates translation only, uses inverse mass, applies linear restitution and friction impulses, and corrects penetration positionally. Trigger contacts report events but skip response. The physics step enumerates body pairs directly; `query-aabb` has a separate X-sorted sweep. Neither is a persistent broad-phase acceleration structure for physics stepping.

The simulation's `uniform-grid` is a distinct index for scene objects, not the physics collision index. It refreshes enabled scene objects' AABBs from mesh render positions, or from transformed origins for nodes without mesh geometry. Oversized cell ranges use an overflow list. These queries are appropriate for scene selection/nearby-object use, while physics `query-aabb` and `physics-ray-cast` operate on collider geometry.

## Event and scheduler behavior

The event bus queues events, sorts subscribers by stable descending priority, and dispatches a snapshot. An event emitted by a handler waits for the next dispatch. By default callback errors are retained in `event-bus-errors` and dispatch continues. Physics emits `:begin`, `:stay`, and `:end` callbacks through `physics-contact-handler`; attached simulation states forward them as event-bus events whose payload is the contact. Removing a body sends end callbacks for active contacts before clearing those contacts.

Scheduled functions take `(world state)` and use the fixed simulation clock. Repeating deadlines advance before callback execution. These are in-process callbacks and are not serialized. Call `detach-simulation` to restore the physics world's previous contact handler and clear input state; `:close-audio t` also closes the offline mixer.

## Input, debug drawing, and audio details

Input maps normalize the platform event vocabulary into semantic actions. `begin-input-frame` applies queued events and preserves action edges across all fixed substeps in that rendered frame. The graphical runtime handles keyboard/mouse and gamepad polling; direct `queue-input-event` calls provide the same behavior in tests or headless tools.

Debug primitives are transient per-world commands, not scene graph objects. Text is rendered from a small built-in bitmap font; `:height` is the size in world units. Zero duration lasts until the next update boundary, positive durations count down at update boundaries, and `:duration -1d0` persists until cleared. Explicit cleanup is available through `clear-debug-draw`.

The mixer renders deterministic offline interleaved stereo PCM and can write WAV files. It supports buffers and generator-fed stream queues, mono/stereo sources, pitch, looping for memory buffers, listener-relative left/right panning, inverse-distance attenuation, buses, and user-defined in-place effects. Streams are forward-only: no looping or backward seeking is provided. An optional OpenAL output path consumes PCM produced by the mixer; headless tests cover the mixer but do not establish native device playback.

## Examples

Boids uses a stable snapshot of positions and velocities for each step, so changing object iteration does not change the flock update. The object mode rereads live scene transforms. The packed mode stores the same state in flat double-float vectors and writes results back to visible scene objects. Both modes currently use a CPU quadratic neighbor scan; packed is not GPU compute.

The game creates a 14-by-10 stage with static walls and obstacles, a dynamic sphere player, three static trigger spheres, and a static box door. The input map supports WASD/arrows/left stick, Space/gamepad A, E/mouse-left/gamepad X, P, R and F1. Contact-begin events collect coins and play offline tone sources. Two coins unlock the door; a nearby interaction plays a scene animation and removes the door collider after 0.7 simulation seconds. Collecting all three coins and crossing the exit sets the state to won. Restart restores coin objects and bodies and reattaches the original door body. `make-game-world` returns `(values world game-state)`; the most recently created game is also exposed as `*game*` for REPL work. The game object stores its scene, input, physics, simulation, door and collectible references explicitly rather than hiding them in scene metadata.

## Verification

The headless suite has passed **2,346 checks with no skips or failures** through `sbcl --dynamic-space-size 4096 --script tools/test.lisp`. Coverage includes input transitions and contexts, fixed-step timing and debt, scheduler and event error behavior, grid overflow and ray order, collision shapes and parent transforms, restitution/friction and contact events, offline PCM mixing/stream refill, debug-draw lifetimes and geometry, both Boids modes, and game collection/jumping/door/win/restart/live tuning.

Native verification passed on Linux/SBCL:

- `sbcl --script tools/m6-acceptance.lisp`: **579 checks**. The game completes **172 frames**, driven through the registered keyboard callbacks: coin collection, door interaction and animation, victory, restart, jump, focus-loss release, pause/resume, collision drawing, and function redefinition on the same game objects. Each Boids mode completes **12 frames**, with visible movement, live speed changes, and function redefinition on the existing flock.
- `sbcl --dynamic-space-size 4096 --script tools/m6-vulkan-check.lisp`: **8 frames and 14 uploads**, verifying simulation-driven image changes, debug-draw expiration and GPU cache cleanup, with no Khronos validation messages through shutdown. A second **4-frame game run** verifies restart, separation of game and viewer shortcuts, and focus-loss release through the native callback. This check requires the Vulkan dependencies and validation layer described in the [renderer notes](m4-implementation.md).
- `sbcl --script tools/audio-check.lisp`: **10 checks**, including signed PCM conversion, list/vector submission, invalid-input recovery without consuming queue capacity, bounded native queues, invalid-device handling, and idempotent cleanup. These use OpenAL Soft's null driver; they verify the native API without claiming physical speaker playback.
- `ALSOFT_DRIVERS=null sbcl --script tools/game.lisp --audio --hidden --no-repl --frames 3`: the launcher connects simulation PCM to OpenAL and exits cleanly.
- The existing M5 editor acceptance demonstration still passes **12 frames**, followed by scene reopening and playback in a fresh SBCL process. The default `tools/run.lisp` launcher also completes **3 frames** and opens the editor.

The OpenGL demonstration writes framebuffer captures and a nonzero game-tone WAV under `artifacts/`. These are generated verification artifacts, excluded from Git. The native window checks used hidden windows with real graphics contexts.

## Known limits

M6's physics is translational and does not solve angular velocity, torque, or rotational inertia. It uses a simple iterative contact impulse and positional correction rather than a full constraint solver; body-pair generation remains quadratic. Sheared body transforms and non-uniformly scaled spheres/capsules are rejected. The scene uniform grid accelerates scene-object lookup only and is not connected to the physics step.

Audio stream sources move only forward and do not loop or seek. The mixer is offline until a caller or launcher submits its PCM to an output backend. Boids are CPU simulations in both object and packed modes; GPU compute is future work. The game is an intentionally small demonstration and does not promise save-game persistence or a generalized character controller.
